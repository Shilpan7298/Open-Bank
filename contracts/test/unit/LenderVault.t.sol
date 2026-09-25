// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {SystemFixture} from "../utils/SystemFixture.sol";
import {LenderVault} from "../../src/LenderVault.sol";
import {ILenderVault} from "../../src/interfaces/ILenderVault.sol";
import {ILoanRegistry} from "../../src/interfaces/ILoanRegistry.sol";
import {IIdentityGate} from "../../src/interfaces/IIdentityGate.sol";
import {LoanState} from "../../src/libraries/Types.sol";

contract LenderVaultTest is SystemFixture {
    LenderVault vault;
    address allocator = makeAddr("allocator");
    address depositor = makeAddr("depositor");

    function setUp() public override {
        super.setUp();
        vault = s.lenderVault;
        vault.grantRole(vault.ALLOCATOR_ROLE(), allocator);
        s.usdc.mint(depositor, 1_000_000e6);
        vm.prank(depositor);
        s.usdc.approve(address(vault), type(uint256).max);
        vm.prank(depositor);
        vault.deposit(20_000e6, depositor);
    }

    function _vaultBid(uint256 id, uint256 amount, uint16 rate) internal {
        vm.prank(allocator);
        vault.bid(id, amount, rate);
    }

    /// Loan funded entirely by the vault at 8%.
    function _vaultLoan() internal returns (uint256 id) {
        id = _openLoan(borrower, P);
        _collateral(id, 300e6);
        _vouch(id, v1, 600e6);
        _vaultBid(id, P, 800);
        assertTrue(_settle(id));
        vm.prank(borrower);
        s.registry.drawdown(id, keccak256("a"));
    }

    // LV-01
    function test_depositWithdrawSanctions() public {
        assertEq(vault.totalAssets(), 20_000e6);
        assertEq(vault.idle(), 20_000e6);
        vm.prank(depositor);
        vault.withdraw(1_000e6, depositor, depositor);
        assertEq(vault.idle(), 19_000e6);
        s.sanctions.setSanctioned(depositor, true);
        vm.prank(depositor);
        vm.expectRevert(abi.encodeWithSelector(IIdentityGate.Sanctioned.selector, depositor));
        vault.deposit(1e6, depositor);
        vm.prank(depositor);
        vm.expectRevert(abi.encodeWithSelector(IIdentityGate.Sanctioned.selector, depositor));
        vault.withdraw(1e6, depositor, depositor);
    }

    // LV-02
    function test_bidRules() public {
        uint256 id = _openLoan(borrower, P);
        vm.prank(depositor);
        vm.expectRevert();
        vault.bid(id, 100e6, 800);

        uint256 other = _propose(borrower, P);
        _scoreLoan(other, borrower, 3, 0);
        _open(other);
        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(ILenderVault.WrongBand.selector, 3, 2));
        vault.bid(other, 100e6, 800);

        uint256 proposed = _propose(borrower, P);
        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(ILenderVault.LoanNotOpen.selector, proposed));
        vault.bid(proposed, 100e6, 800);

        _vaultBid(id, 500e6, 800);
        assertEq(vault.idle(), 19_500e6);
        assertEq(vault.totalAssets(), 20_000e6);
        assertEq(vault.borrowerExposure(borrower), 500e6);
    }

    // LV-03
    function test_caps() public {
        uint256 id = _openLoan(borrower, 2_000e6);
        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(ILenderVault.BorrowerCapExceeded.selector, borrower));
        vault.bid(id, 2_000e6 + 1, 800); // 10% of 20k
        _vaultBid(id, 2_000e6, 800);

        vault.setCaps(10_000, 1_500); // at most 15% deployed
        address b2 = makeAddr("b2");
        _onboard(b2, COUNTRY_A);
        uint256 id2 = _openLoan(b2, 2_000e6);
        vm.prank(allocator);
        vm.expectRevert(ILenderVault.DeployedCapExceeded.selector);
        vault.bid(id2, 1_001e6, 800);
        _vaultBid(id2, 1_000e6, 800);
    }

    // LV-04
    function test_harvestAfterRepayment() public {
        uint256 id = _vaultLoan();
        assertEq(vault.totalAssets(), 20_000e6); // at cost while live
        _repayAll(id);
        ILoanRegistry.Dues memory d = s.registry.duesOf(id);
        uint256 gain = d.lenderDue - P;
        assertEq(vault.totalAssets(), 20_000e6 + gain); // recognised as soon as the loan is repaid
        vault.harvest(id);
        assertEq(vault.idle(), 20_000e6 + gain);
        assertEq(vault.totalAssets(), 20_000e6 + gain);
        assertTrue(vault.positionOf(id).closed);
        assertEq(vault.openPositions().length, 0);
        assertEq(vault.borrowerExposure(borrower), 0);
    }

    // LV-05
    function test_defaultReflectedImmediately() public {
        uint256 id = _vaultLoan();
        vm.warp(s.registry.loanOf(id).start + TERM + 30 days);
        s.registry.markDefault(id);
        uint256 expected = vault.idle() + s.registry.claimable(id, address(vault));
        assertEq(vault.totalAssets(), expected);
        vault.harvest(id);
        assertEq(vault.totalAssets(), expected);
        assertTrue(vault.positionOf(id).closed);
    }

    // LV-06
    function test_withdrawLimitedToIdle() public {
        vm.prank(depositor);
        vault.withdraw(18_000e6, depositor, depositor);
        vault.setCaps(10_000, 10_000); // this test is about idle cash, not caps
        uint256 id = _openLoan(borrower, P);
        _vaultBid(id, 1_000e6, 800);
        assertEq(vault.maxWithdraw(depositor), 1_000e6);
        vm.prank(depositor);
        vm.expectRevert();
        vault.withdraw(1_000e6 + 1, depositor, depositor);
    }

    // LV-07
    function test_inflationAttackUnprofitable() public {
        LenderVault fresh = new LenderVault(
            address(this), guardian, s.usdc, s.registry, s.auction, s.gate, 2, "v", "v"
        );
        address attacker = makeAddr("attacker");
        address victim = makeAddr("victim");
        s.usdc.mint(attacker, 1_000_001e6);
        s.usdc.mint(victim, 1_000e6);
        vm.startPrank(attacker);
        s.usdc.approve(address(fresh), type(uint256).max);
        fresh.deposit(1, attacker);
        s.usdc.transfer(address(fresh), 1_000_000e6); // donation is inert: cash is tracked internally
        vm.stopPrank();
        vm.startPrank(victim);
        s.usdc.approve(address(fresh), type(uint256).max);
        uint256 shares = fresh.deposit(1_000e6, victim);
        vm.stopPrank();
        assertApproxEqAbs(fresh.previewRedeem(shares), 1_000e6, 1);
        assertLe(fresh.previewRedeem(fresh.balanceOf(attacker)), 1);
    }

    // LV-08
    function testFuzz_totalAssetsIsIdlePlusPositions(uint256 a1, uint256 a2, bool repay, bool fail) public {
        a1 = bound(a1, 10e6, 1_000e6);
        a2 = bound(a2, 10e6, 1_000e6);
        uint256 id = _openLoan(borrower, P);
        _collateral(id, 300e6);
        _vouch(id, v1, 600e6);
        _vaultBid(id, a1, 700);
        if (!fail) _bid(id, l1, P, 900);
        address b2 = makeAddr("b2");
        _onboard(b2, COUNTRY_A);
        uint256 id2 = _openLoan(b2, P);
        _vaultBid(id2, a2, 800);
        bool funded = _settle(id);
        if (funded) {
            vm.prank(borrower);
            s.registry.drawdown(id, keccak256("a"));
            if (repay) _repayAll(id);
        }
        uint256 sum = vault.idle();
        uint256[] memory open = vault.openPositions();
        for (uint256 i; i < open.length; i++) sum += vault.positionValue(open[i]);
        assertEq(vault.totalAssets(), sum);
        vault.harvest(id);
        sum = vault.idle();
        open = vault.openPositions();
        for (uint256 i; i < open.length; i++) sum += vault.positionValue(open[i]);
        assertEq(vault.totalAssets(), sum);
        assertGe(vault.totalAssets(), 20_000e6); // no losses in these paths
        if (funded && !repay) assertEq(uint8(_state(id)), uint8(LoanState.Active));
    }
}
