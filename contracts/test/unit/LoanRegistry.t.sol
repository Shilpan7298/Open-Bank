// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {SystemFixture} from "../utils/SystemFixture.sol";
import {ILoanRegistry} from "../../src/interfaces/ILoanRegistry.sol";
import {IIdentityGate} from "../../src/interfaces/IIdentityGate.sol";
import {IVouchingModule} from "../../src/interfaces/IVouchingModule.sol";
import {IRateAuction} from "../../src/interfaces/IRateAuction.sol";
import {ILossWaterfall} from "../../src/interfaces/ILossWaterfall.sol";
import {ICreditRegistry} from "../../src/interfaces/ICreditRegistry.sol";
import {LoanState, Stage, Tier, Tranche} from "../../src/libraries/Types.sol";
import {DeployLib} from "../../script/DeployLib.sol";

contract LoanRegistryTest is SystemFixture {
    event LoanCancelled(uint256 indexed loanId, bytes32 reason);

    function _expectCancel(uint256 id, bytes32 reason) internal {
        vm.warp(s.registry.loanOf(id).auctionEnd);
        vm.expectEmit(true, false, false, true, address(s.registry));
        emit LoanCancelled(id, reason);
        assertFalse(s.registry.settle(id));
        assertEq(uint8(_state(id)), uint8(LoanState.Cancelled));
    }

    // LR-01
    function test_propose() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IIdentityGate.NotVerified.selector, stranger));
        s.registry.propose(P, TERM, 6, 1_500, SECTOR, 0);

        vm.startPrank(borrower);
        vm.expectRevert(ILoanRegistry.InvalidTerms.selector);
        s.registry.propose(P, 1 days, 6, 1_500, SECTOR, 0); // term too short
        vm.expectRevert(ILoanRegistry.InvalidTerms.selector);
        s.registry.propose(P, TERM, 0, 1_500, SECTOR, 0);
        vm.expectRevert(ILoanRegistry.InvalidTerms.selector);
        s.registry.propose(P, TERM, 6, 1_510, SECTOR, 0); // off tick
        vm.expectRevert(abi.encodeWithSelector(ILoanRegistry.ExceedsCreditLimit.selector, 2_001e6, 2_000e6));
        s.registry.propose(2_001e6, TERM, 6, 1_500, SECTOR, 0);
        uint256 id = s.registry.propose(P, TERM, 6, 1_500, SECTOR, keccak256("p"));
        vm.stopPrank();
        ILoanRegistry.Loan memory l = s.registry.loanOf(id);
        assertEq(id, 1);
        assertEq(uint8(l.state), uint8(LoanState.Proposed));
        assertEq(uint8(l.tier), uint8(Tier.A));
        assertEq(l.country, COUNTRY_A);
    }

    // LR-02
    function test_openNeedsScoreThatCanOnlyRaiseCover() public {
        uint256 id = _propose(borrower, P);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(ILoanRegistry.NoScoreConsensus.selector, id));
        s.registry.open(id);

        _scoreLoan(id, borrower, 3, 1_000); // suggests 10%, table says 60%
        _open(id);
        ILoanRegistry.Loan memory l = s.registry.loanOf(id);
        assertEq(l.riskBand, 3);
        assertEq(l.requiredCollateral, 300e6);
        assertEq(l.requiredCover, 600e6);

        uint256 id2 = _propose(borrower, P);
        _scoreLoan(id2, borrower, 2, 8_000); // suggests 80%: raises
        _open(id2);
        assertEq(s.registry.loanOf(id2).requiredCover, 800e6);
    }

    // LR-03
    function test_postCollateral() public {
        uint256 id = _openLoan(borrower, P);
        vm.prank(v1);
        vm.expectRevert(ILoanRegistry.NotBorrower.selector);
        s.registry.postCollateral(id, 1e6);
        _collateral(id, 300e6);
        assertEq(s.escrow.collateralOf(id), 300e6);
        vm.warp(s.registry.loanOf(id).auctionEnd);
        vm.prank(borrower);
        vm.expectRevert();
        s.registry.postCollateral(id, 1e6);
    }

    // LR-04
    function test_settleFunds() public {
        uint256 id = _fundedLoan();
        ILoanRegistry.Loan memory l = s.registry.loanOf(id);
        ILoanRegistry.Dues memory d = s.registry.duesOf(id);
        assertEq(uint8(l.state), uint8(LoanState.Funded));
        assertEq(l.rateBps, 900);
        assertEq(d.coverPrincipal, 600e6);
        assertEq(d.lenderDue, 1_044_383_562); // 1000 + 9% x 180/365, rounded up
        assertEq(d.insuredExposure, P - 900e6); // principal only (security H-1)
        assertEq(d.totalDue, d.lenderDue + d.voucherPremiumDue + d.insurancePremiumDue);
        assertEq(uint8(s.vouching.coverOf(id).state), uint8(IVouchingModule.CoverState.Locked));
        assertEq(s.basket.exposureOf(s.basket.basketIdOf(2, Tier.A)), d.insuredExposure);
        assertEq(s.credit.historyOf(borrower).outstandingPrincipal, P);
    }

    // LR-05
    function testFuzz_cancelsBelowCollateral(uint256 collateral) public {
        collateral = bound(collateral, 0, 300e6 - 1);
        uint256 id = _openLoan(borrower, P);
        if (collateral > 0) _collateral(id, collateral);
        _vouch(id, v1, 600e6);
        _bid(id, l1, P, 800);
        _expectCancel(id, "COLLATERAL");
        assertEq(s.auction.refundable(id, 0), P);
        vm.prank(v1);
        s.vouching.unstake(id);
        if (collateral > 0) {
            vm.prank(borrower);
            assertEq(s.registry.withdrawCollateral(id), collateral);
        }
    }

    // LR-06
    function testFuzz_cancelsBelowCover(uint256 cover) public {
        cover = bound(cover, 0, 600e6 - 1);
        uint256 id = _openLoan(borrower, P);
        _collateral(id, 400e6);
        if (cover >= 10e6) _vouch(id, v1, cover);
        _bid(id, l1, P, 800);
        _expectCancel(id, "COVER");
    }

    // LR-07
    function test_cancelsWhenSanctionedOrRevoked() public {
        uint256 id = _openLoan(borrower, P);
        _backAndBid(id);
        s.sanctions.setSanctioned(borrower, true);
        _expectCancel(id, "IDENTITY");

        s.sanctions.setSanctioned(borrower, false);
        uint256 id2 = _openLoan(borrower, P);
        _backAndBid(id2);
        bytes32 uid = s.gate.identityOf(borrower);
        vm.prank(attester);
        s.eas.revoke(uid);
        _expectCancel(id2, "IDENTITY");
    }

    // LR-08
    function test_cancelsOverCreditLimit() public {
        uint256 a = _openLoan(borrower, 1_500e6);
        uint256 b = _openLoan(borrower, 1_500e6);
        for (uint256 i; i < 2; i++) {
            uint256 id = i == 0 ? a : b;
            _collateral(id, 450e6);
            _vouch(id, v1, 900e6);
            _bid(id, l1, 1_500e6, 800);
        }
        assertTrue(_settle(a));
        _expectCancel(b, "CREDIT_LIMIT");
    }

    // LR-09
    function test_cancelsWhenScoreNoLongerValid() public {
        uint256 id = _openLoan(borrower, P);
        _backAndBid(id);
        s.scoreOracle.setScorer(vm.addr(scorerPk), false);
        _expectCancel(id, "SCORE");
    }

    // LR-10: a valid (best possible) score is required but never sufficient.
    function testFuzz_scoreNeverSufficient(uint8 missing) public {
        missing = uint8(bound(missing, 0, 5));
        _onboard(v1, COUNTRY_A); // keep the fixture's actors valid
        uint256 id = _propose(borrower, P);
        _scoreLoan(id, borrower, 1, 0); // band 1: lowest risk
        _open(id);
        if (missing != 0) _collateral(id, 300e6);
        if (missing != 1) _vouch(id, v1, 600e6);
        if (missing != 2) _bid(id, l1, P, 800);
        else _bid(id, l1, P / 2, 800);
        if (missing == 3) s.sanctions.setSanctioned(borrower, true);
        if (missing == 4) s.credit.setLimitParams(Tier.A, ICreditRegistry.LimitParams(1, 0, 1)); // limit shrinks
        // missing == 5: band-1 basket has no capital, so insurance cannot cover
        vm.warp(s.registry.loanOf(id).auctionEnd);
        assertFalse(s.registry.settle(id));
        assertEq(uint8(_state(id)), uint8(LoanState.Cancelled));
        assertEq(s.credit.historyOf(borrower).outstandingPrincipal, 0);
    }

    // LR-11
    function test_cancelsWithoutInsuranceCapacity() public {
        uint256 id = _propose(borrower, P);
        _scoreLoan(id, borrower, 4, 0); // band 4 tier A basket is empty
        _open(id);
        _backAndBid(id);
        _expectCancel(id, "INSURANCE_CAPACITY");
    }

    // LR-12
    function test_tierCNeedsFullEconomicSecurity() public {
        address cb = makeAddr("tierCBorrower");
        _onboard(cb, COUNTRY_C);
        s.usdc.mint(cb, 1_000e6);
        vm.prank(cb);
        s.usdc.approve(address(s.escrow), type(uint256).max);
        s.credit.setRequirement(Stage.New, Tier.C, 2_000, 5_000);
        _seedBasket(2, Tier.C, 500e6, 0);

        uint256 id = _openLoan(cb, 500e6);
        _collateral(id, 100e6);
        _vouch(id, v1, 250e6); // 20% + 50% = 70% < 100%
        _bid(id, l1, 500e6, 800);
        _expectCancel(id, "ECONOMIC_SECURITY");

        uint256 id2 = _openLoan(cb, 500e6);
        _collateral(id2, 100e6);
        _vouch(id2, v2, 400e6); // 20% + 80% = 100%
        _bid(id2, l2, 500e6, 800);
        assertTrue(_settle(id2));
        // collateral + stakes cover all principal, so nothing is insured (interest risk stays with lenders)
        ILoanRegistry.Dues memory d = s.registry.duesOf(id2);
        assertEq(d.insuredExposure, 0);
    }

    // LR-13
    function test_drawdown() public {
        uint256 id = _fundedLoan();
        vm.prank(v1);
        vm.expectRevert(ILoanRegistry.NotBorrower.selector);
        s.registry.drawdown(id, keccak256("a"));
        vm.prank(borrower);
        vm.expectRevert(ILoanRegistry.EmptyAgreement.selector);
        s.registry.drawdown(id, 0);

        uint256 before = s.usdc.balanceOf(borrower);
        vm.prank(borrower);
        s.registry.drawdown(id, keccak256("agreement"));
        ILoanRegistry.Loan memory l = s.registry.loanOf(id);
        assertEq(l.agreementHash, keccak256("agreement"));
        assertEq(uint8(l.state), uint8(LoanState.Active));
        assertEq(s.registry.duesOf(id).reserveFee, 15e6); // 1.5%, below the 5% cap
        assertEq(s.reserve.reserveAssets(), 15e6);
        assertEq(s.usdc.balanceOf(borrower) - before, P - 15e6);
        assertEq(s.registry.totalOutstandingPrincipal(), P);
    }

    function test_drawdownExpired() public {
        uint256 id = _fundedLoan();
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(ILoanRegistry.DrawdownExpired.selector, id));
        s.registry.drawdown(id, keccak256("a"));
    }

    // LR-14
    function test_cancelExpired() public {
        uint256 id = _fundedLoan();
        vm.expectRevert(abi.encodeWithSelector(ILoanRegistry.DrawdownNotExpired.selector, id));
        s.registry.cancelExpired(id);
        vm.warp(block.timestamp + 7 days + 1);
        s.registry.cancelExpired(id);
        assertEq(uint8(_state(id)), uint8(LoanState.Cancelled));
        assertEq(s.auction.refundable(id, 0), 600e6);
        assertEq(s.auction.refundable(id, 1), 600e6);
        assertEq(s.basket.exposureOf(s.basket.basketIdOf(2, Tier.A)), 0);
        assertEq(s.credit.historyOf(borrower).outstandingPrincipal, 0);
        vm.prank(v1);
        s.vouching.unstake(id);
        vm.prank(borrower);
        assertEq(s.registry.withdrawCollateral(id), 300e6);
    }

    // LR-15
    function test_repayFlow() public {
        uint256 id = _activeLoan();
        ILoanRegistry.Dues memory d = s.registry.duesOf(id);
        uint256 bid = s.basket.basketIdOf(2, Tier.A);
        uint256 capBefore = s.basket.capital(bid);

        vm.prank(borrower);
        s.registry.repay(id, d.totalDue / 3);
        assertEq(uint8(_state(id)), uint8(LoanState.Active));
        _repayAll(id);
        assertEq(uint8(_state(id)), uint8(LoanState.Repaid));

        d = s.registry.duesOf(id);
        assertEq(d.lenderCash, d.lenderDue);
        assertEq(s.vouching.coverOf(id).premium, d.voucherPremiumDue);
        assertEq(s.basket.capital(bid) - capBefore, d.insurancePremiumDue);
        assertEq(s.basket.exposureOf(bid), 0);
        assertEq(s.credit.historyOf(borrower).repaidLoans, 1);
        assertEq(s.credit.creditLimit(borrower, Tier.A), 4_000e6);
        assertEq(s.registry.totalOutstandingPrincipal(), 0);

        vm.prank(borrower);
        assertEq(s.registry.withdrawCollateral(id), 300e6);
        vm.prank(v1);
        uint256 got = s.vouching.claim(id);
        assertApproxEqAbs(got, 400e6 + d.voucherPremiumDue * 2 / 3, 2);

        // Overpaying is capped; nothing left afterwards.
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(ILoanRegistry.WrongState.selector, id, LoanState.Repaid));
        s.registry.repay(id, 1);
    }

    // LR-16
    function testFuzz_splitExactAtFullRepayment(uint256[6] memory parts, uint16 rate) public {
        rate = uint16(bound(rate, 1, 60) * 25);
        uint256 id = _openLoan(borrower, P);
        _collateral(id, 300e6);
        _vouch(id, v1, 600e6);
        _bid(id, l1, P, rate);
        assertTrue(_settle(id));
        vm.prank(borrower);
        s.registry.drawdown(id, keccak256("a"));
        uint256 bid = s.basket.basketIdOf(2, Tier.A);
        uint256 capBefore = s.basket.capital(bid);
        ILoanRegistry.Dues memory d = s.registry.duesOf(id);
        uint256 lenderPrev;
        uint256 voucherPrev;
        for (uint256 i; i < parts.length; i++) {
            uint256 amt = bound(parts[i], 1, d.totalDue / 8); // six parts never finish the loan
            vm.prank(borrower);
            s.registry.repay(id, amt);
            ILoanRegistry.Dues memory now_ = s.registry.duesOf(id);
            assertGe(now_.lenderCash, lenderPrev);
            assertGe(s.vouching.coverOf(id).premium, voucherPrev);
            lenderPrev = now_.lenderCash;
            voucherPrev = s.vouching.coverOf(id).premium;
        }
        _repayAll(id);
        d = s.registry.duesOf(id);
        assertEq(d.lenderCash, d.lenderDue);
        assertEq(s.vouching.coverOf(id).premium, d.voucherPremiumDue);
        assertEq(s.basket.capital(bid) - capBefore, d.insurancePremiumDue);
    }

    // LR-17
    function test_installmentsAndDefaultGrace() public {
        uint256 id = _activeLoan();
        ILoanRegistry.Loan memory l = s.registry.loanOf(id);
        ILoanRegistry.Dues memory d = s.registry.duesOf(id);
        uint256 period = TERM / 6;
        assertEq(s.registry.amountDueBy(id, l.start), 0);
        assertEq(s.registry.amountDueBy(id, l.start + period - 1), 0);
        assertEq(s.registry.amountDueBy(id, l.start + period), (d.totalDue + 5) / 6);
        assertEq(s.registry.amountDueBy(id, l.start + TERM), d.totalDue);

        vm.warp(l.start + period + 30 days - 1);
        assertFalse(s.registry.isDefaultable(id));
        vm.expectRevert(abi.encodeWithSelector(ILoanRegistry.NotDefaultable.selector, id));
        s.registry.markDefault(id);
        vm.warp(l.start + period + 30 days);
        assertTrue(s.registry.isDefaultable(id));
        // Paying the first installment cures it.
        vm.prank(borrower);
        s.registry.repay(id, (d.totalDue + 5) / 6);
        assertFalse(s.registry.isDefaultable(id));
    }

    // LR-18
    function test_markDefault() public {
        uint256 id = _activeLoan();
        ILoanRegistry.Dues memory d = s.registry.duesOf(id);
        vm.prank(borrower);
        s.registry.repay(id, 100e6);
        vm.warp(s.registry.loanOf(id).start + TERM + 30 days);
        s.registry.markDefault(id);
        assertEq(uint8(_state(id)), uint8(LoanState.Defaulted));

        ILossWaterfall.Allocation memory a = s.waterfall.allocationOf(id);
        uint256 lenderPaid = 100e6 * d.lenderDue / d.totalDue;
        assertEq(a.loss, d.lenderDue - lenderPaid);
        assertEq(a.collateral, 300e6);
        assertEq(a.vouchers, 600e6);
        uint256 lenderPaidExact = 100e6 * d.lenderDue / d.totalDue;
        assertEq(a.insurable, P - lenderPaidExact * P / d.lenderDue); // unpaid principal (pro rata split)
        assertEq(a.basketJunior + a.basketSenior, a.insurable - 900e6); // basket covers the principal gap
        assertLe(a.lenderLoss, d.lenderDue - P); // lenders lose at most interest, never principal
        assertEq(s.registry.duesOf(id).lenderCash + a.lenderLoss, d.lenderDue);
        assertEq(s.credit.creditLimit(borrower, Tier.A), 0);
        assertEq(s.registry.totalOutstandingPrincipal(), 0);
        vm.expectRevert();
        s.registry.markDefault(id);
    }

    // LR-19
    function test_lenderClaimsProRata() public {
        uint256 id = _activeLoan();
        _repayAll(id);
        ILoanRegistry.Dues memory d = s.registry.duesOf(id);
        vm.prank(l1);
        uint256 a = s.registry.claim(id);
        s.sanctions.setSanctioned(l2, true);
        vm.prank(l2);
        vm.expectRevert(abi.encodeWithSelector(IIdentityGate.Sanctioned.selector, l2));
        s.registry.claim(id);
        s.sanctions.setSanctioned(l2, false);
        vm.prank(l2);
        uint256 b = s.registry.claim(id);
        assertEq(a, d.lenderDue * 600 / 1000);
        assertEq(b, d.lenderDue * 400 / 1000);
        assertLe(a + b, d.lenderDue);
        vm.prank(l1);
        vm.expectRevert(ILoanRegistry.NothingToClaim.selector);
        s.registry.claim(id);
        vm.prank(l3);
        vm.expectRevert(ILoanRegistry.NothingToClaim.selector);
        s.registry.claim(id);
    }

    // LR-20
    function test_pauseKeepsRepayAndDefault() public {
        uint256 id = _activeLoan();
        vm.prank(guardian);
        s.registry.pause();
        vm.prank(borrower);
        vm.expectRevert();
        s.registry.propose(P, TERM, 6, 1_500, SECTOR, 0);
        vm.prank(borrower);
        s.registry.repay(id, 10e6);
        vm.warp(s.registry.loanOf(id).start + TERM + 30 days);
        s.registry.markDefault(id);
        vm.prank(l1);
        s.registry.claim(id);
    }
}

/// Real-economy use: money arrives where the borrower can spend it, and repayment can come from anyone.
contract RealEconomyTest is SystemFixture {
    address offRamp = makeAddr("mobileMoneyOffRamp");

    // LR-21
    function test_drawdownToOffRampPartner() public {
        uint256 id = _fundedLoan();
        uint256 before = s.usdc.balanceOf(borrower);
        vm.prank(borrower);
        s.registry.drawdownTo(id, keccak256("agreement"), offRamp);
        assertEq(s.usdc.balanceOf(offRamp), P - 15e6);
        assertEq(s.usdc.balanceOf(borrower), before); // the borrower's wallet is not involved
        assertEq(uint8(_state(id)), uint8(LoanState.Active));
        assertEq(s.registry.loanOf(id).borrower, borrower); // the debt stays with the borrower
    }

    function test_drawdownToRejectsSanctionedOrZero() public {
        uint256 id = _fundedLoan();
        vm.prank(borrower);
        vm.expectRevert();
        s.registry.drawdownTo(id, keccak256("a"), address(0));
        s.sanctions.setSanctioned(offRamp, true);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(IIdentityGate.Sanctioned.selector, offRamp));
        s.registry.drawdownTo(id, keccak256("a"), offRamp);
        vm.prank(offRamp);
        vm.expectRevert(ILoanRegistry.NotBorrower.selector); // only the borrower chooses where money goes
        s.registry.drawdownTo(id, keccak256("a"), offRamp);
    }

    // LR-22
    function test_anyoneCanRepayOnBehalf() public {
        uint256 id = _activeLoan();
        address relative = makeAddr("relativeAbroad");
        address agent = makeAddr("cashInAgent");
        ILoanRegistry.Dues memory d = s.registry.duesOf(id);
        s.usdc.mint(relative, d.totalDue);
        s.usdc.mint(agent, d.totalDue);
        vm.startPrank(relative);
        s.usdc.approve(address(s.registry), type(uint256).max);
        s.registry.repay(id, d.totalDue / 2);
        vm.stopPrank();
        vm.startPrank(agent);
        s.usdc.approve(address(s.registry), type(uint256).max);
        s.registry.repay(id, d.totalDue);
        vm.stopPrank();
        assertEq(uint8(_state(id)), uint8(LoanState.Repaid));
        assertEq(s.credit.historyOf(borrower).repaidLoans, 1); // the borrower's record improves
        assertEq(s.usdc.balanceOf(agent), d.totalDue - (d.totalDue - d.totalDue / 2)); // overpayment capped
    }
}
