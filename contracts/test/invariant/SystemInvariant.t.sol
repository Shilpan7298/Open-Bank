// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {SystemFixture} from "../utils/SystemFixture.sol";
import {ScoreSigner} from "../utils/ScoreSigner.sol";
import {DeployLib} from "../../script/DeployLib.sol";
import {ILoanRegistry} from "../../src/interfaces/ILoanRegistry.sol";
import {ILossWaterfall} from "../../src/interfaces/ILossWaterfall.sol";
import {IVouchingModule} from "../../src/interfaces/IVouchingModule.sol";
import {IRateAuction} from "../../src/interfaces/IRateAuction.sol";
import {IScoreOracle} from "../../src/interfaces/IScoreOracle.sol";
import {LoanState, Tier, Tranche} from "../../src/libraries/Types.sol";

/// @notice Drives the whole lifecycle with random actions and records any breach of the protocol invariants in
/// ghost counters, which the invariant functions then assert are zero.
contract SystemHandler is ScoreSigner {
    DeployLib.System internal s;
    uint256 internal scorerPk;
    address[3] internal borrowers;
    address[2] internal vouchers;
    address[3] internal lenders;
    address[2] internal insurers;
    uint256 public basketId;

    uint256[] public loans;
    mapping(uint256 loanId => uint256) public lockedShares;

    // ghost counters (must stay zero)
    uint256 public waterfallViolations; // INV-01
    uint256 public lockedStakeViolations; // INV-03
    uint256 public fundingViolations; // INV-04
    uint256 public scoreViolations; // INV-05
    uint256 public basketViolations; // INV-07
    uint256 public sanctionViolations; // INV-08

    bool public lossHappened;
    address public sanctioned;
    uint256 public sanctionedBalance;
    uint256 public defaults;
    uint256 public funded;

    constructor(
        DeployLib.System memory sys,
        uint256 pk,
        address[3] memory b,
        address[2] memory v,
        address[3] memory l,
        address[2] memory ins
    ) {
        s = sys;
        scorerPk = pk;
        borrowers = b;
        vouchers = v;
        lenders = l;
        insurers = ins;
        basketId = s.basket.basketIdOf(2, Tier.A);
    }

    // ---------------------------------------------------------------- helpers

    function _loan(uint256 idx) internal view returns (uint256 id, bool ok) {
        if (loans.length == 0) return (0, false);
        return (loans[idx % loans.length], true);
    }

    /// A loan in `state`, starting the search at a random position.
    function _pick(LoanState state, uint256 idx) internal view returns (uint256 id, bool ok) {
        uint256 n = loans.length;
        for (uint256 k; k < n; k++) {
            id = loans[(idx + k) % n];
            if (s.registry.loanOf(id).state == state) return (id, true);
        }
        return (0, false);
    }

    function _basketWithin() internal view returns (bool) {
        uint256 cap = s.basket.capacity(basketId);
        uint256 concCap = cap * 2_500 / 10_000;
        (uint256 c, uint256 se, uint256 m) = s.basket.maxConcentration(basketId);
        return s.basket.exposureOf(basketId) <= cap && c <= concCap && se <= concCap && m <= concCap;
    }

    modifier checked() {
        bool before = _basketWithin();
        _;
        if (before && !_basketWithin()) basketViolations++;
        if (sanctioned != address(0) && s.usdc.balanceOf(sanctioned) > sanctionedBalance) sanctionViolations++;
    }

    // ---------------------------------------------------------------- actions

    function newLoan(uint256 who, uint256 principal, uint256 seed) external checked {
        bool scored = seed % 10 != 0;
        address b = borrowers[who % 3];
        Tier tier = Tier.A;
        principal = bound(principal, 100e6, 1_000e6);
        if (s.credit.availableCredit(b, tier) < principal || !s.gate.isEligibleBorrower(b)) return;
        vm.prank(b);
        uint256 id = s.registry.propose(principal, 90 days, 3, 1_500, uint16(who % 5), 0);
        if (scored) {
            IScoreOracle.Score memory sc = _score(id, b, 2);
            vm.prank(vm.addr(scorerPk));
            bytes32 uid = s.eas.attest(DeployLib.SCORE_SCHEMA, b, 0, abi.encode(sc));
            s.scoreOracle.submitScore(uid, _sign(s.scoreOracle, scorerPk, sc));
        }
        vm.prank(b);
        try s.registry.open(id) {
            if (!scored) scoreViolations++; // INV-05: opening needs a score
            loans.push(id);
            _back(id, seed);
        } catch {}
    }

    /// Back a loan: usually to its full requirements, sometimes short (so failures still occur).
    function _back(uint256 id, uint256 seed) internal {
        ILoanRegistry.Loan memory l = s.registry.loanOf(id);
        if (l.state != LoanState.Open || block.timestamp >= l.auctionEnd) return;
        seed = uint256(keccak256(abi.encode(seed)));
        bool short = seed % 6 == 0;
        uint256 target = l.requiredCollateral - (short && seed % 2 == 0 ? 1 : 0);
        uint256 posted = s.escrow.collateralOf(id);
        if (target > posted) {
            vm.prank(l.borrower); // amount computed first: an external call in the arguments would eat the prank
            s.registry.postCollateral(id, target - posted);
        }
        IVouchingModule.Cover memory c = s.vouching.coverOf(id);
        uint256 want = l.requiredCover > c.coverPrincipal ? l.requiredCover - c.coverPrincipal : 0;
        if (short && seed % 2 == 1) want = want / 2;
        if (want >= 20e6) {
            vm.prank(vouchers[seed % 2]);
            s.vouching.stake(id, want / 2);
            vm.prank(vouchers[(seed + 1) % 2]);
            s.vouching.stake(id, want - want / 2);
        }
        for (uint256 i; i < 2; i++) {
            address lender = lenders[(seed >> (8 * i)) % 3];
            if (lender == sanctioned) continue;
            vm.prank(lender);
            s.auction.placeBid(id, l.principal * 6 / 10, uint16(bound(seed >> (16 * i), 4, 60) * 25));
        }
    }

    function postCollateral(uint256 idx, uint256 bps) external checked {
        (uint256 id, bool ok) = _loan(idx);
        if (!ok) return;
        ILoanRegistry.Loan memory l = s.registry.loanOf(id);
        if (l.state != LoanState.Open || block.timestamp >= l.auctionEnd) return;
        vm.prank(l.borrower);
        s.registry.postCollateral(id, l.principal * bound(bps, 1_000, 5_000) / 10_000);
    }

    function stake(uint256 idx, uint256 who, uint256 bps) external checked {
        (uint256 id, bool ok) = _loan(idx);
        if (!ok) return;
        ILoanRegistry.Loan memory l = s.registry.loanOf(id);
        if (l.state != LoanState.Open || block.timestamp >= l.auctionEnd) return;
        uint256 amount = l.principal * bound(bps, 1_000, 7_000) / 10_000;
        IVouchingModule.Cover memory c = s.vouching.coverOf(id);
        if (amount < 10e6 || c.coverPrincipal + amount > c.maxCover) return;
        vm.prank(vouchers[who % 2]);
        s.vouching.stake(id, amount);
    }

    function bid(uint256 idx, uint256 who, uint256 bps, uint256 rateTicks) external checked {
        (uint256 id, bool ok) = _loan(idx);
        if (!ok) return;
        ILoanRegistry.Loan memory l = s.registry.loanOf(id);
        if (l.state != LoanState.Open || block.timestamp >= l.auctionEnd) return;
        IRateAuction.Auction memory a = s.auction.auctionOf(id);
        if (a.bidCount >= 100) return;
        uint256 amount = l.principal * bound(bps, 2_000, 12_000) / 10_000;
        if (amount < a.minBid) return;
        address lender = lenders[who % 3];
        if (lender == sanctioned) return;
        vm.prank(lender);
        s.auction.placeBid(id, amount, uint16(bound(rateTicks, 1, 60) * 25));
    }

    function settle(uint256 idx) external checked {
        (uint256 id, bool ok) = _pick(LoanState.Open, idx);
        if (!ok) return;
        ILoanRegistry.Loan memory l = s.registry.loanOf(id);
        if (block.timestamp < l.auctionEnd) vm.warp(l.auctionEnd);
        IScoreOracle.Consensus memory c = s.scoreOracle.consensus(id, l.borrower);
        uint256 collateral = s.escrow.collateralOf(id);
        uint256 cover = s.vouching.coverOf(id).coverPrincipal;
        bool eligible = s.gate.isEligibleBorrower(l.borrower);
        uint256 available = s.credit.availableCredit(l.borrower, l.tier);
        if (s.registry.settle(id)) {
            funded++;
            if (!c.ok) scoreViolations++; // INV-05
            if (collateral < l.requiredCollateral || collateral * 10_000 < l.principal * 2_000) fundingViolations++;
            if (cover < l.requiredCover || !eligible || available < l.principal) fundingViolations++; // INV-04
            lockedShares[id] = s.vouching.coverOf(id).shares;
        }
    }

    function drawdown(uint256 idx) external checked {
        (uint256 id, bool ok) = _pick(LoanState.Funded, idx);
        if (!ok) return;
        ILoanRegistry.Loan memory l = s.registry.loanOf(id);
        if (l.state != LoanState.Funded || block.timestamp > l.drawdownDeadline) return;
        if (!s.gate.isEligibleBorrower(l.borrower)) return;
        vm.prank(l.borrower);
        s.registry.drawdown(id, keccak256("agreement"));
    }

    function repay(uint256 idx, uint256 frac) external checked {
        (uint256 id, bool ok) = _pick(LoanState.Active, idx);
        if (!ok || s.registry.loanOf(id).state != LoanState.Active) return;
        ILoanRegistry.Dues memory d = s.registry.duesOf(id);
        uint256 amount = bound(frac, 1, d.totalDue - d.repaid);
        vm.prank(s.registry.loanOf(id).borrower);
        s.registry.repay(id, amount);
    }

    /// INV-01: record every layer's capacity right before the default and check the allocation order.
    /// Losses may legitimately push the basket over its limits (Nexus pitfall 3), so no `checked` here.
    function markDefault(uint256 idx) external {
        (uint256 id, bool ok) = _pick(LoanState.Active, idx);
        if (!ok) return;
        ILoanRegistry.Loan memory l = s.registry.loanOf(id);
        vm.warp(block.timestamp > l.start + l.term + 31 days ? block.timestamp : l.start + l.term + 31 days);
        uint256 collateral = s.escrow.collateralOf(id);
        uint256 stakeValue = s.vouching.coverValue(id);
        uint256 exposure = s.basket.coverOf(id).exposure;
        uint256 capital = s.basket.capital(basketId);
        uint256 junior = s.basket.trancheOf(basketId, Tranche.Junior).assets;
        uint256 reserveAssets = s.reserve.reserveAssets();
        s.registry.markDefault(id);
        defaults++;
        lossHappened = true;
        ILossWaterfall.Allocation memory a = s.waterfall.allocationOf(id);
        uint256 basketPaid = a.basketJunior + a.basketSenior;
        // Layers 3-4 cover unpaid principal only (security H-1): their limit for this loan is what is left of
        // the insurable principal after the borrower's layers.
        uint256 borrowerSide = a.collateral + a.vouchers;
        uint256 insLeft = a.insurable > borrowerSide ? a.insurable - borrowerSide : 0;
        uint256 basketCap = exposure < capital ? exposure : capital;
        if (insLeft < basketCap) basketCap = insLeft;
        uint256 reserveCap = insLeft - basketPaid < reserveAssets ? insLeft - basketPaid : reserveAssets;
        if (a.vouchers > 0 && a.collateral < collateral) waterfallViolations++;
        if (basketPaid > 0 && (a.collateral < collateral || a.vouchers < stakeValue)) waterfallViolations++;
        if (a.basketSenior > 0 && a.basketJunior < junior && a.basketJunior < exposure) waterfallViolations++;
        if (a.reserve > 0 && basketPaid < basketCap) waterfallViolations++;
        if (a.lenderLoss > 0 && (a.collateral < collateral || a.vouchers < stakeValue)) waterfallViolations++;
        if (a.lenderLoss > 0 && (basketPaid < basketCap || a.reserve < reserveCap)) waterfallViolations++;
        if (basketPaid + a.reserve > a.insurable) waterfallViolations++; // insurers never pay interest
    }

    function claims(uint256 idx, uint256 who) external checked {
        (uint256 id, bool ok) = _loan(idx);
        if (!ok) return;
        address lender = lenders[who % 3];
        if (lender != sanctioned && s.registry.claimable(id, lender) > 0) {
            vm.prank(lender);
            s.registry.claim(id);
        }
        IRateAuction.Auction memory a = s.auction.auctionOf(id);
        for (uint256 i; i < a.bidCount; i++) {
            IRateAuction.Bid memory b = s.auction.bidOf(id, i);
            if (b.lender != sanctioned && s.auction.refundable(id, i) > 0) s.auction.refund(id, i);
        }
        ILoanRegistry.Loan memory l = s.registry.loanOf(id);
        bool finished = l.state == LoanState.Repaid || l.state == LoanState.Defaulted || l.state == LoanState.Cancelled;
        if (finished && s.escrow.collateralOf(id) > 0 && s.gate.isEligibleBorrower(l.borrower)) {
            vm.prank(l.borrower);
            s.registry.withdrawCollateral(id);
        }
        address v = vouchers[who % 2];
        IVouchingModule.Slice memory sl = s.vouching.sliceOf(id, v);
        IVouchingModule.CoverState cs = s.vouching.coverOf(id).state;
        if (sl.principal > 0 && !sl.claimed) {
            vm.startPrank(v);
            if (cs == IVouchingModule.CoverState.Released || cs == IVouchingModule.CoverState.Defaulted) {
                s.vouching.claim(id);
            } else if (cs == IVouchingModule.CoverState.Cancelled) {
                s.vouching.unstake(id);
            } else if (cs == IVouchingModule.CoverState.Locked) {
                // INV-03: locked stake must not come out
                try s.vouching.unstake(id) {
                    lockedStakeViolations++;
                } catch {}
                try s.vouching.claim(id) {
                    lockedStakeViolations++;
                } catch {}
            }
            vm.stopPrank();
        }
    }

    function insure(uint256 who, bool senior, uint256 amount) external checked {
        address ins = insurers[who % 2];
        vm.prank(ins);
        s.basket.deposit(basketId, senior ? Tranche.Senior : Tranche.Junior, bound(amount, 1e6, 2_000e6));
    }

    function insurerExit(uint256 who, bool senior, uint256 frac) external checked {
        address ins = insurers[who % 2];
        Tranche t = senior ? Tranche.Senior : Tranche.Junior;
        uint256 bal = s.basket.sharesOf(basketId, t, ins);
        if (bal > 0) {
            vm.prank(ins);
            s.basket.requestWithdrawal(basketId, t, bound(frac, 1, bal));
        }
        s.basket.processWithdrawals(basketId, t, 3);
        if (s.basket.claimableOf(ins) > 0) {
            vm.prank(ins);
            s.basket.claimWithdrawals();
        }
    }

    function sanctionLender(uint256 who) external checked {
        if (sanctioned != address(0)) return;
        sanctioned = lenders[who % 3];
        s.sanctions.setSanctioned(sanctioned, true);
        sanctionedBalance = s.usdc.balanceOf(sanctioned);
    }

    /// Sanctioned lender tries to take payouts: every attempt must fail.
    function sanctionedTries(uint256 idx) external checked {
        (uint256 id, bool ok) = _loan(idx);
        if (!ok || sanctioned == address(0)) return;
        vm.prank(sanctioned);
        try s.registry.claim(id) {
            sanctionViolations++;
        } catch {}
        IRateAuction.Auction memory a = s.auction.auctionOf(id);
        for (uint256 i; i < a.bidCount; i++) {
            if (s.auction.bidOf(id, i).lender == sanctioned) {
                try s.auction.refund(id, i) {
                    sanctionViolations++;
                } catch {}
            }
        }
    }

    function toggleScorer(bool registered) external checked {
        vm.prank(address(this));
        s.scoreOracle.setScorer(vm.addr(scorerPk), registered);
    }

    function warp(uint256 dt) external checked {
        vm.warp(block.timestamp + bound(dt, 1 hours, 20 days));
    }

    function loanCount() external view returns (uint256) {
        return loans.length;
    }

    /// INV-03: a loan that is Active keeps exactly the stake shares it had at funding.
    function lockedStakeHeld() external view returns (bool) {
        for (uint256 i; i < loans.length; i++) {
            uint256 id = loans[i];
            if (s.registry.loanOf(id).state != LoanState.Active) continue;
            IVouchingModule.Cover memory c = s.vouching.coverOf(id);
            if (c.state != IVouchingModule.CoverState.Locked || c.shares != lockedShares[id]) return false;
        }
        return true;
    }
}

/// INV-01 .. INV-08 over random full-system runs. With the weighted selectors below, about 95% of runs fund
/// loans and about 90% reach at least one default (measured with 64 runs x 150 calls).
/// forge-config: default.invariant.depth = 150
contract SystemInvariantTest is SystemFixture {
    SystemHandler handler;

    function setUp() public override {
        super.setUp();
        address b2 = makeAddr("borrower2");
        address b3 = makeAddr("borrower3");
        s.gate.setCountryTier(3, Tier.A);
        s.gate.setCountryTier(4, Tier.A);
        _onboard(b2, 3);
        _onboard(b3, 4);
        address[2] memory extra = [b2, b3];
        for (uint256 i; i < 2; i++) {
            s.usdc.mint(extra[i], 10_000_000e6);
            vm.startPrank(extra[i]);
            s.usdc.approve(address(s.escrow), type(uint256).max);
            s.usdc.approve(address(s.registry), type(uint256).max);
            vm.stopPrank();
        }
        handler = new SystemHandler(s, scorerPk, [borrower, b2, b3], [v1, v2], [l1, l2, l3], [insJ, insS]);
        // The handler plays governance for the scorer toggle only.
        s.scoreOracle.grantRole(bytes32(0), address(handler));
        targetContract(address(handler));
        // Weight the lifecycle so runs reach funding, repayment and default (listed selectors are drawn uniformly).
        bytes4[] memory sel = new bytes4[](22);
        bytes4[4] memory heavy = [
            SystemHandler.newLoan.selector,
            SystemHandler.settle.selector,
            SystemHandler.drawdown.selector,
            SystemHandler.markDefault.selector
        ];
        for (uint256 i; i < 4; i++) {
            sel[3 * i] = heavy[i];
            sel[3 * i + 1] = heavy[i];
            sel[3 * i + 2] = heavy[i];
        }
        sel[12] = SystemHandler.repay.selector;
        sel[13] = SystemHandler.claims.selector;
        sel[14] = SystemHandler.insure.selector;
        sel[15] = SystemHandler.insurerExit.selector;
        sel[16] = SystemHandler.sanctionLender.selector;
        sel[17] = SystemHandler.sanctionedTries.selector;
        sel[18] = SystemHandler.toggleScorer.selector;
        sel[19] = SystemHandler.warp.selector;
        sel[20] = SystemHandler.stake.selector;
        sel[21] = SystemHandler.bid.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }

    // INV-01
    function invariant_waterfallOrder() public view {
        assertEq(handler.waterfallViolations(), 0);
    }

    // INV-02: every module's internal accounting matches its token balance to the wei (dust only in the
    // protocol's favour, i.e. balance >= obligations where rounding happens).
    function invariant_conservation() public view {
        uint256 n = s.registry.loanCount();
        uint256 escrowSum;
        uint256 registryOwed;
        uint256 auctionHeld;
        for (uint256 id = 1; id <= n; id++) {
            escrowSum += s.escrow.collateralOf(id);
            ILoanRegistry.Dues memory d = s.registry.duesOf(id);
            registryOwed += d.lenderCash - d.lenderClaimed;
            IRateAuction.Auction memory a = s.auction.auctionOf(id);
            uint256 refunded;
            for (uint256 i; i < a.bidCount; i++) refunded += s.auction.bidOf(id, i).refunded;
            uint256 held = a.totalBid - refunded;
            if (a.status == IRateAuction.Status.Disbursed) held -= a.principal;
            auctionHeld += held;
            // lenders' claims never exceed the cash credited to them
            assertLe(d.lenderClaimed, d.lenderCash);
        }
        assertEq(s.usdc.balanceOf(address(s.escrow)), escrowSum);
        assertGe(s.usdc.balanceOf(address(s.registry)), registryOwed);
        assertLe(s.usdc.balanceOf(address(s.registry)) - registryOwed, n * 3); // claim rounding dust only
        assertEq(s.usdc.balanceOf(address(s.auction)), auctionHeld);
        assertEq(
            s.usdc.balanceOf(address(s.basket)),
            s.basket.capital(handler.basketId()) + s.basket.totalClaimable()
        );
        assertEq(s.usdc.balanceOf(address(s.reserve)), s.reserve.reserveAssets());
        assertEq(s.stakeVault.totalSupply(), s.stakeVault.balanceOf(address(s.vouching)));
    }

    // INV-03
    function invariant_lockedStakes() public view {
        assertEq(handler.lockedStakeViolations(), 0);
        assertTrue(handler.lockedStakeHeld());
    }

    // INV-04
    function invariant_fundingConditions() public view {
        assertEq(handler.fundingViolations(), 0);
    }

    // INV-05
    function invariant_scoreRequired() public view {
        assertEq(handler.scoreViolations(), 0);
    }

    // INV-06
    function invariant_reserveCap() public view {
        assertLe(s.reserve.reserveAssets(), s.reserve.cap());
    }

    // INV-07
    function invariant_basketLimits() public view {
        assertEq(handler.basketViolations(), 0);
    }

    // INV-08
    function invariant_sanctionedNoPayouts() public view {
        assertEq(handler.sanctionViolations(), 0);
    }

    /// Shows that runs exercise the lifecycle (visible with -vv).
    function afterInvariant() public view {
        console.log("loans %s funded %s defaults %s", handler.loanCount(), handler.funded(), handler.defaults());
    }
}
