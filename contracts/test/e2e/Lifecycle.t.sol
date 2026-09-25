// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {SystemFixture} from "../utils/SystemFixture.sol";
import {ILoanRegistry} from "../../src/interfaces/ILoanRegistry.sol";
import {ILossWaterfall} from "../../src/interfaces/ILossWaterfall.sol";
import {IInsuranceBasket} from "../../src/interfaces/IInsuranceBasket.sol";
import {LoanState, Tier, Tranche} from "../../src/libraries/Types.sol";

contract LifecycleTest is SystemFixture {
    function _bal(address a) internal view returns (uint256) {
        return s.usdc.balanceOf(a);
    }

    // E2E-01
    function test_happyPath() public {
        uint256 b0 = _bal(borrower);
        uint256 v10 = _bal(v1);
        uint256 l10 = _bal(l1);
        uint256 l20 = _bal(l2);
        uint256 bid = s.basket.basketIdOf(2, Tier.A);
        uint256 cap0 = s.basket.capital(bid);

        uint256 id = _activeLoan();
        ILoanRegistry.Dues memory d = s.registry.duesOf(id);
        // pay the six installments on schedule
        ILoanRegistry.Loan memory l = s.registry.loanOf(id);
        for (uint256 k = 1; k <= 6; k++) {
            vm.warp(l.start + k * (TERM / 6));
            uint256 due = s.registry.amountDueBy(id, block.timestamp) - s.registry.duesOf(id).repaid;
            vm.prank(borrower);
            s.registry.repay(id, due);
            assertFalse(s.registry.isDefaultable(id));
        }
        assertEq(uint8(_state(id)), uint8(LoanState.Repaid));

        vm.prank(borrower);
        s.registry.withdrawCollateral(id);
        vm.prank(v1);
        s.vouching.claim(id);
        vm.prank(v2);
        s.vouching.claim(id);
        vm.prank(l1);
        s.registry.claim(id);
        vm.prank(l2);
        s.registry.claim(id);
        s.auction.refund(id, 1); // unfilled part of lender 2's marginal bid

        // borrower paid principal + interest + premiums + reserve fee
        assertEq(b0 - _bal(borrower), d.totalDue - P + 15e6);
        assertGt(_bal(v1), v10); // voucher earned premium
        assertApproxEqAbs(_bal(l1) - l10 + _bal(l2) - l20, d.lenderDue - P, 1); // lenders earned the interest
        assertEq(s.basket.capital(bid) - cap0, d.insurancePremiumDue); // insurers earned premium
        assertEq(s.reserve.reserveAssets(), 0); // outstanding fell to 0: fee rebated
        assertEq(_bal(rebate), 15e6);
        assertEq(s.credit.creditLimit(borrower, Tier.A), 4_000e6); // credit limit stepped up
    }

    // E2E-02
    function test_defaultCoveredByCollateralAndVouchers() public {
        uint256 id = _activeLoan();
        uint256 bid = s.basket.basketIdOf(2, Tier.A);
        uint256 cap0 = s.basket.capital(bid);
        vm.prank(borrower);
        s.registry.repay(id, 500e6);
        vm.warp(s.registry.loanOf(id).start + TERM + 30 days);
        s.registry.markDefault(id);
        ILossWaterfall.Allocation memory a = s.waterfall.allocationOf(id);
        assertEq(a.collateral, 300e6);
        assertGt(a.vouchers, 0);
        assertLt(a.vouchers, 600e6);
        assertEq(a.basketJunior + a.basketSenior + a.reserve + a.lenderLoss, 0);
        assertGe(s.basket.capital(bid), cap0); // basket untouched (only premium added)
        // vouchers keep the rest of their stake pro rata
        vm.prank(v1);
        uint256 back1 = s.vouching.claim(id);
        vm.prank(v2);
        uint256 back2 = s.vouching.claim(id);
        assertApproxEqAbs(back1, 2 * back2, 3);
        // lenders are whole
        assertEq(s.registry.duesOf(id).lenderCash, s.registry.duesOf(id).lenderDue);
    }

    // E2E-03
    function test_defaultReachesBasketJuniorAndSenior() public {
        _seedBasket(3, Tier.A, 50e6, 1_000e6);
        uint256 id = _propose(borrower, P);
        _scoreLoan(id, borrower, 3, 0);
        _open(id);
        _backAndBid(id);
        assertTrue(_settle(id));
        vm.prank(borrower);
        s.registry.drawdown(id, keccak256("a"));
        ILoanRegistry.Dues memory d = s.registry.duesOf(id);
        vm.warp(s.registry.loanOf(id).start + TERM + 30 days);
        s.registry.markDefault(id);
        ILossWaterfall.Allocation memory a = s.waterfall.allocationOf(id);
        assertEq(a.collateral, 300e6);
        assertEq(a.vouchers, 600e6);
        assertEq(a.basketJunior, 50e6);
        assertEq(a.basketSenior, d.insuredExposure - 50e6);
        assertEq(a.reserve + a.lenderLoss, 0);
    }

    struct BadYear {
        uint256[] ids;
        address[] borrowers;
    }

    /// Eight loans over four months in a thin band-3 basket, all defaulting: a bad year.
    function _badYear() internal returns (BadYear memory y) {
        _seedBasket(3, Tier.A, 100e6, 300e6); // capacity 1200, per key 300
        y.ids = new uint256[](8);
        y.borrowers = new address[](8);
        for (uint256 i; i < 8; i++) {
            address b = makeAddr(string(abi.encodePacked("bad", i)));
            y.borrowers[i] = b;
            uint16 country = uint16(100 + i); // the 25% country cap would otherwise stop the third loan
            s.gate.setCountryTier(country, Tier.A);
            _onboard(b, country);
            s.usdc.mint(b, 1_000e6);
            vm.startPrank(b);
            s.usdc.approve(address(s.escrow), type(uint256).max);
            uint256 id = s.registry.propose(P, TERM, 6, 1_500, uint16(10 + i), 0);
            vm.stopPrank();
            _scoreLoan(id, b, 3, 0);
            _open(id);
            _backAndBid(id);
            assertTrue(_settle(id), "settle");
            vm.prank(b);
            s.registry.drawdown(id, keccak256("a"));
            y.ids[i] = id;
            if (i % 2 == 1) vm.warp(block.timestamp + 30 days); // two loans per origination month
        }
        vm.warp(block.timestamp + TERM + 30 days);
    }

    // E2E-04
    function test_badYearReservePaysAfterBasket() public {
        BadYear memory y = _badYear();
        uint256 bid = s.basket.basketIdOf(3, Tier.A);
        uint256 reserve0 = s.reserve.reserveAssets();
        assertGt(reserve0, 0);
        bool reserveUsed;
        for (uint256 i; i < y.ids.length; i++) {
            uint256 capBefore = s.basket.capital(bid);
            uint256 resBefore = s.reserve.reserveAssets();
            s.registry.markDefault(y.ids[i]);
            ILossWaterfall.Allocation memory a = s.waterfall.allocationOf(y.ids[i]);
            if (a.reserve > 0) {
                reserveUsed = true;
                assertEq(a.basketJunior + a.basketSenior, capBefore); // basket exhausted first
            }
            if (a.lenderLoss > 0) assertEq(a.reserve, resBefore); // reserve exhausted first
        }
        assertTrue(reserveUsed);
        assertEq(s.basket.capital(bid), 0);
    }

    // E2E-05
    function test_badYearSeniorLendersLoseLast() public {
        BadYear memory y = _badYear();
        uint256 lenderLoss;
        for (uint256 i; i < y.ids.length; i++) {
            s.registry.markDefault(y.ids[i]);
            ILossWaterfall.Allocation memory a = s.waterfall.allocationOf(y.ids[i]);
            if (a.lenderLoss > 0) {
                assertEq(a.collateral, 300e6);
                assertEq(a.vouchers, 600e6);
                assertEq(s.basket.capital(s.basket.basketIdOf(3, Tier.A)), 0);
            }
            lenderLoss += a.lenderLoss;
            // lenders of each loan still recover everything the layers paid
            ILoanRegistry.Dues memory d = s.registry.duesOf(y.ids[i]);
            assertEq(d.lenderCash + a.lenderLoss, d.lenderDue);
        }
        assertGt(lenderLoss, 0);
        assertEq(s.reserve.reserveAssets(), 0);
    }

    // E2E-06
    function test_lenderVaultEarns() public {
        address depositor = makeAddr("depositor");
        address allocator = makeAddr("allocator");
        s.lenderVault.grantRole(s.lenderVault.ALLOCATOR_ROLE(), allocator);
        s.usdc.mint(depositor, 20_000e6);
        vm.startPrank(depositor);
        s.usdc.approve(address(s.lenderVault), type(uint256).max);
        uint256 shares = s.lenderVault.deposit(20_000e6, depositor);
        vm.stopPrank();

        uint256 id = _openLoan(borrower, P);
        _collateral(id, 300e6);
        _vouch(id, v1, 600e6);
        vm.prank(allocator);
        s.lenderVault.bid(id, P, 700);
        assertTrue(_settle(id));
        vm.prank(borrower);
        s.registry.drawdown(id, keccak256("a"));
        _repayAll(id);
        s.lenderVault.harvest(id);

        vm.prank(depositor);
        uint256 out = s.lenderVault.redeem(shares, depositor, depositor);
        assertEq(out, 20_000e6 + s.registry.duesOf(id).lenderDue - P - 1); // virtual-share rounding keeps 1 wei
    }

    // E2E-07
    function test_failedAuctionRefundsEveryone() public {
        uint256 b0 = _bal(borrower);
        uint256 v10 = _bal(v1);
        uint256 l10 = _bal(l1);
        uint256 id = _openLoan(borrower, P);
        _collateral(id, 300e6);
        _vouch(id, v1, 600e6);
        _bid(id, l1, 400e6, 800);
        assertFalse(_settle(id));
        s.auction.refund(id, 0);
        vm.prank(v1);
        s.vouching.unstake(id);
        vm.prank(borrower);
        s.registry.withdrawCollateral(id);
        assertEq(_bal(borrower), b0);
        assertEq(_bal(v1), v10);
        assertEq(_bal(l1), l10);
    }

    // E2E-08
    function test_missedDrawdownRefundsEveryone() public {
        uint256 b0 = _bal(borrower);
        uint256 l10 = _bal(l1);
        uint256 l20 = _bal(l2);
        uint256 v20 = _bal(v2);
        uint256 id = _fundedLoan();
        vm.warp(block.timestamp + 8 days);
        s.registry.cancelExpired(id);
        s.auction.refund(id, 0);
        s.auction.refund(id, 1);
        vm.prank(v1);
        s.vouching.unstake(id);
        vm.prank(v2);
        s.vouching.unstake(id);
        vm.prank(borrower);
        s.registry.withdrawCollateral(id);
        assertEq(_bal(borrower), b0);
        assertEq(_bal(l1), l10);
        assertEq(_bal(l2), l20);
        assertEq(_bal(v2), v20);
        assertEq(s.credit.historyOf(borrower).outstandingPrincipal, 0);
    }
}
