// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IdentityGate} from "../../src/IdentityGate.sol";
import {InsuranceBasket} from "../../src/InsuranceBasket.sol";
import {IInsuranceBasket} from "../../src/interfaces/IInsuranceBasket.sol";
import {IIdentityGate} from "../../src/interfaces/IIdentityGate.sol";
import {Tier, Tranche} from "../../src/libraries/Types.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockEAS} from "../../src/mocks/MockEAS.sol";
import {MockSanctionsOracle} from "../../src/mocks/MockSanctionsOracle.sol";

contract BasketFixture is Test {
    address admin = makeAddr("timelock");
    address registry = makeAddr("loanRegistry");
    address waterfall = makeAddr("waterfall");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    MockUSDC usdc;
    MockSanctionsOracle oracle;
    InsuranceBasket basket;
    uint256 B; // band 2, tier A

    function _deployBasket() internal {
        usdc = new MockUSDC();
        oracle = new MockSanctionsOracle();
        IdentityGate gate = new IdentityGate(admin, address(0), new MockEAS(), oracle, bytes32(0));
        basket = new InsuranceBasket(admin, address(0), usdc, gate);
        vm.startPrank(admin);
        basket.grantRole(basket.REGISTRY_ROLE(), registry);
        basket.grantRole(basket.WATERFALL_ROLE(), waterfall);
        vm.stopPrank();
        B = basket.basketIdOf(2, Tier.A);
        address[3] memory users = [alice, bob, registry];
        for (uint256 i; i < 3; i++) {
            usdc.mint(users[i], 10_000_000e6);
            vm.prank(users[i]);
            usdc.approve(address(basket), type(uint256).max);
        }
        vm.warp(365 days); // non-zero origination month
    }

    function _deposit(address who, Tranche t, uint256 amount) internal returns (uint256) {
        vm.prank(who);
        return basket.deposit(B, t, amount);
    }

    function _assign(uint256 loanId, uint256 exposure, uint16 country, uint16 sector) internal {
        vm.prank(registry);
        basket.assignCover(loanId, B, exposure, country, sector);
    }
}

contract InsuranceBasketTest is BasketFixture {
    function setUp() public {
        _deployBasket();
    }

    // IB-01
    function test_deposit() public {
        uint256 s1 = _deposit(alice, Tranche.Junior, 1_000e6);
        uint256 s2 = _deposit(bob, Tranche.Junior, 500e6);
        assertEq(s1, 2 * s2);
        assertEq(basket.sharesOf(B, Tranche.Junior, alice), s1);
        assertEq(basket.trancheOf(B, Tranche.Junior).assets, 1_500e6);
        assertEq(basket.capital(B), 1_500e6);
        vm.expectRevert(abi.encodeWithSelector(IInsuranceBasket.InvalidBasket.selector, 0));
        basket.deposit(0, Tranche.Junior, 1);
        oracle.setSanctioned(alice, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IIdentityGate.Sanctioned.selector, alice));
        basket.deposit(B, Tranche.Senior, 1e6);
    }

    // IB-02
    function test_leverage() public {
        _deposit(alice, Tranche.Junior, 1_000e6);
        assertEq(basket.capacity(B), 3_000e6);
        // One origination month may hold at most 25% of capacity, so spread loans over months.
        for (uint16 i = 1; i <= 4; i++) {
            _assign(i, 700e6, i, i);
            vm.warp(block.timestamp + 30 days);
        }
        assertTrue(basket.canCover(B, 200e6, 5, 5));
        assertFalse(basket.canCover(B, 201e6, 5, 5));
        vm.prank(registry);
        vm.expectRevert(abi.encodeWithSelector(IInsuranceBasket.NoCapacity.selector, B, 201e6));
        basket.assignCover(5, B, 201e6, 5, 5);
        vm.prank(registry);
        vm.expectRevert(abi.encodeWithSelector(IInsuranceBasket.AlreadyCovered.selector, 1));
        basket.assignCover(1, B, 1e6, 6, 6);
    }

    // IB-03
    function test_concentration() public {
        _deposit(alice, Tranche.Junior, 1_000e6); // capacity 3000, per-key cap 750
        _assign(1, 750e6, 1, 1);
        vm.startPrank(registry);
        vm.expectRevert(abi.encodeWithSelector(IInsuranceBasket.ConcentrationExceeded.selector, B, uint8(0)));
        basket.assignCover(2, B, 1e6, 1, 2); // same country
        vm.expectRevert(abi.encodeWithSelector(IInsuranceBasket.ConcentrationExceeded.selector, B, uint8(1)));
        basket.assignCover(2, B, 1e6, 2, 1); // same sector
        vm.expectRevert(abi.encodeWithSelector(IInsuranceBasket.ConcentrationExceeded.selector, B, uint8(2)));
        basket.assignCover(2, B, 750e6, 2, 2); // same origination month
        vm.stopPrank();
        vm.warp(block.timestamp + 30 days);
        _assign(2, 750e6, 2, 2);
    }

    function test_concentrationMonth() public {
        _deposit(alice, Tranche.Junior, 10_000e6); // capacity 30000, per-key cap 7500
        for (uint16 i = 1; i <= 7; i++) _assign(i, 1_000e6, i, i);
        _assign(8, 500e6, 8, 8);
        vm.prank(registry);
        vm.expectRevert(abi.encodeWithSelector(IInsuranceBasket.ConcentrationExceeded.selector, B, uint8(2)));
        basket.assignCover(9, B, 1e6, 9, 9); // same origination month
        vm.warp(block.timestamp + 30 days);
        _assign(9, 1e6, 9, 9); // next month is fine
        (uint256 c, uint256 s, uint256 m) = basket.maxConcentration(B);
        assertEq(c, 1_000e6);
        assertEq(s, 1_000e6);
        assertEq(m, 7_500e6);
    }

    // IB-04
    function test_absorbLossJuniorFirst() public {
        _deposit(alice, Tranche.Junior, 300e6);
        _deposit(bob, Tranche.Senior, 2_700e6); // capacity 9000, per-key cap 2250
        _assign(1, 800e6, 1, 1);
        vm.prank(waterfall);
        (uint256 j, uint256 s) = basket.absorbLoss(1, 200e6, waterfall);
        assertEq(j, 200e6);
        assertEq(s, 0);
        assertEq(basket.exposureOf(B), 0);

        _assign(2, 2_000e6, 2, 2);
        vm.prank(waterfall);
        (j, s) = basket.absorbLoss(2, 5_000e6, waterfall); // capped at exposure 2000
        assertEq(j, 100e6);
        assertEq(s, 1_900e6);
        assertEq(basket.capital(B), 800e6);
        assertEq(usdc.balanceOf(waterfall), 2_200e6);

        vm.prank(waterfall);
        (j, s) = basket.absorbLoss(99, 1e6, waterfall); // no cover: nothing
        assertEq(j + s, 0);
    }

    // IB-05
    function test_premiumSplit() public {
        _deposit(alice, Tranche.Junior, 250e6);
        _deposit(bob, Tranche.Senior, 750e6);
        _assign(1, 100e6, 1, 1);
        vm.prank(registry);
        basket.addPremium(1, 100e6);
        // senior: 100 * 750/1000 * 70% = 52.5; junior gets the rest
        assertEq(basket.trancheOf(B, Tranche.Senior).assets, 750e6 + 52.5e6);
        assertEq(basket.trancheOf(B, Tranche.Junior).assets, 250e6 + 47.5e6);
    }

    // IB-06
    function test_noticePeriod() public {
        _deposit(alice, Tranche.Junior, 1_000e6);
        uint256 shares = basket.sharesOf(B, Tranche.Junior, alice);
        vm.prank(alice);
        uint256 id = basket.requestWithdrawal(B, Tranche.Junior, shares);
        IInsuranceBasket.WithdrawalRequest memory r = basket.requestOf(B, Tranche.Junior, id);
        assertGe(r.eligibleAt, block.timestamp + 30 days);
        assertEq(r.eligibleAt % 7 days, 0);
        vm.warp(r.eligibleAt - 1);
        assertEq(basket.processWithdrawals(B, Tranche.Junior, 10), 0);
        assertEq(basket.claimableOf(alice), 0);
        vm.warp(r.eligibleAt);
        assertEq(basket.processWithdrawals(B, Tranche.Junior, 10), 1);
        assertApproxEqAbs(basket.claimableOf(alice), 1_000e6, 1);
    }

    // IB-07
    function test_queuedSharesAbsorbLoss() public {
        _deposit(alice, Tranche.Junior, 500e6);
        _deposit(bob, Tranche.Junior, 500e6);
        _assign(1, 400e6, 1, 1);
        uint256 shares = basket.sharesOf(B, Tranche.Junior, alice);
        vm.prank(alice);
        basket.requestWithdrawal(B, Tranche.Junior, shares);
        vm.prank(waterfall);
        basket.absorbLoss(1, 400e6, waterfall); // junior 1000 -> 600
        vm.warp(block.timestamp + 40 days);
        basket.processWithdrawals(B, Tranche.Junior, 10);
        assertApproxEqAbs(basket.claimableOf(alice), 300e6, 1); // took half the loss
    }

    // IB-08
    function test_withdrawalLimitedByFreeCapital() public {
        _deposit(alice, Tranche.Junior, 600e6);
        _deposit(bob, Tranche.Junior, 400e6);
        _assign(1, 700e6, 1, 1); // leverage needs 233.34; concentration (per-key 750 max 700) needs 933.34
        assertApproxEqAbs(basket.freeCapital(B), 1_000e6 - 933_333_334, 1);
        uint256 shares = basket.sharesOf(B, Tranche.Junior, alice);
        vm.prank(alice);
        basket.requestWithdrawal(B, Tranche.Junior, shares);
        vm.warp(block.timestamp + 40 days);
        assertEq(basket.processWithdrawals(B, Tranche.Junior, 10), 0); // partial only
        uint256 paid = basket.claimableOf(alice);
        assertApproxEqAbs(paid, 66_666_666, 2);
        (uint256 c,,) = basket.maxConcentration(B);
        assertLe(c, basket.capacity(B) * 2_500 / 10_000 + 1);
        vm.prank(registry);
        basket.releaseCover(1); // loan repaid: rest can go
        basket.processWithdrawals(B, Tranche.Junior, 10);
        assertApproxEqAbs(basket.claimableOf(alice), 600e6, 2);
    }

    // IB-09
    function test_claimWithdrawals() public {
        _deposit(alice, Tranche.Senior, 100e6);
        uint256 shares = basket.sharesOf(B, Tranche.Senior, alice);
        vm.prank(alice);
        basket.requestWithdrawal(B, Tranche.Senior, shares);
        vm.warp(block.timestamp + 40 days);
        basket.processWithdrawals(B, Tranche.Senior, 1);
        oracle.setSanctioned(alice, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IIdentityGate.Sanctioned.selector, alice));
        basket.claimWithdrawals();
        oracle.setSanctioned(alice, false);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        basket.claimWithdrawals();
        assertApproxEqAbs(usdc.balanceOf(alice) - before, 100e6, 1);
        vm.prank(alice);
        vm.expectRevert(IInsuranceBasket.NothingToClaim.selector);
        basket.claimWithdrawals();
    }

    // IB-12
    function testFuzz_queuedValueTracksNav(uint256 dep, uint256 other, uint256 loss, uint256 premium) public {
        dep = bound(dep, 1e6, 1_000_000e6);
        other = bound(other, 1e6, 1_000_000e6);
        _deposit(alice, Tranche.Junior, dep);
        _deposit(bob, Tranche.Junior, other);
        uint256 total = dep + other;
        loss = bound(loss, 0, total * 3 / 4); // one loan's exposure is at most 25% of 3x capital
        premium = bound(premium, 0, total);
        uint256 shares = basket.sharesOf(B, Tranche.Junior, alice);
        vm.prank(alice);
        basket.requestWithdrawal(B, Tranche.Junior, shares);
        if (loss > 0) {
            _assign(1, loss, 1, 1 + 0);
            vm.prank(waterfall);
            basket.absorbLoss(1, loss, waterfall);
        }
        if (premium > 0) {
            _assign(2, 1, 2, 2);
            vm.prank(registry);
            basket.addPremium(2, premium);
            vm.prank(registry);
            basket.releaseCover(2);
        }
        uint256 nav = total - loss + premium;
        vm.warp(block.timestamp + 40 days);
        basket.processWithdrawals(B, Tranche.Junior, 1);
        uint256 expected = nav * dep / total;
        assertApproxEqAbs(basket.claimableOf(alice), expected, expected / 1e5 + 2);
        assertLe(basket.claimableOf(alice), expected + 1);
    }

    function test_paramBounds() public {
        vm.startPrank(admin);
        vm.expectRevert();
        basket.setParams(IInsuranceBasket.Params(30_001, 2_500, 30 days, 7 days, 0));
        vm.expectRevert();
        basket.setParams(IInsuranceBasket.Params(30_000, 2_501, 30 days, 7 days, 0));
        vm.expectRevert();
        basket.setParams(IInsuranceBasket.Params(30_000, 2_500, 29 days, 7 days, 0));
        vm.expectRevert();
        basket.setParams(IInsuranceBasket.Params(30_000, 2_500, 91 days, 7 days, 0));
        basket.setParams(IInsuranceBasket.Params(20_000, 2_000, 90 days, 30 days, 0));
        vm.stopPrank();
    }
}
