// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ProtocolAccess} from "./libraries/ProtocolAccess.sol";
import {BPS, YEAR, LoanState, Tier} from "./libraries/Types.sol";
import {ILoanRegistry} from "./interfaces/ILoanRegistry.sol";
import {IIdentityGate} from "./interfaces/IIdentityGate.sol";
import {ICreditRegistry} from "./interfaces/ICreditRegistry.sol";
import {ICollateralEscrow} from "./interfaces/ICollateralEscrow.sol";
import {IVouchingModule} from "./interfaces/IVouchingModule.sol";
import {IRateAuction} from "./interfaces/IRateAuction.sol";
import {IInsuranceBasket} from "./interfaces/IInsuranceBasket.sol";
import {IReserveVault} from "./interfaces/IReserveVault.sol";
import {ILossWaterfall} from "./interfaces/ILossWaterfall.sol";
import {IScoreOracle} from "./interfaces/IScoreOracle.sol";

/// @title LoanRegistry
/// @notice See {ILoanRegistry}. The AI score is one of several independent funding conditions: it sets the risk
/// band and can only raise the voucher cover requirement. No path funds a loan on the score alone.
contract LoanRegistry is ILoanRegistry, ProtocolAccess, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Modules {
        IERC20 asset;
        IIdentityGate gate;
        ICreditRegistry credit;
        ICollateralEscrow escrow;
        IVouchingModule vouching;
        IRateAuction auction;
        IInsuranceBasket basket;
        IReserveVault reserve;
        ILossWaterfall waterfall;
        IScoreOracle oracle;
    }

    bytes32 public constant REASON_AUCTION_FAILED = "AUCTION_FAILED";
    bytes32 public constant REASON_IDENTITY = "IDENTITY";
    bytes32 public constant REASON_SCORE = "SCORE";
    bytes32 public constant REASON_COLLATERAL = "COLLATERAL";
    bytes32 public constant REASON_COVER = "COVER";
    bytes32 public constant REASON_ECONOMIC_SECURITY = "ECONOMIC_SECURITY";
    bytes32 public constant REASON_CREDIT_LIMIT = "CREDIT_LIMIT";
    bytes32 public constant REASON_INSURANCE = "INSURANCE_CAPACITY";
    bytes32 public constant REASON_DRAWDOWN_EXPIRED = "DRAWDOWN_EXPIRED";

    IERC20 public immutable asset;
    IIdentityGate public immutable gate;
    ICreditRegistry public immutable credit;
    ICollateralEscrow public immutable escrow;
    IVouchingModule public immutable vouching;
    IRateAuction public immutable auction;
    IInsuranceBasket public immutable basket;
    IReserveVault public immutable reserve;
    ILossWaterfall public immutable waterfall;
    IScoreOracle public immutable oracle;

    Params public params;
    uint256 public loanCount;
    uint256 public totalOutstandingPrincipal;

    mapping(uint256 loanId => Loan) private _loans;
    mapping(uint256 loanId => Dues) private _dues;
    mapping(uint256 loanId => mapping(address lender => uint256)) public lenderClaimedBy;

    constructor(address admin, address guardian, Modules memory m) ProtocolAccess(admin, guardian) {
        asset = m.asset;
        gate = m.gate;
        credit = m.credit;
        escrow = m.escrow;
        vouching = m.vouching;
        auction = m.auction;
        basket = m.basket;
        reserve = m.reserve;
        waterfall = m.waterfall;
        oracle = m.oracle;
        _setParams(
            Params({
                auctionDuration: 3 days,
                drawdownWindow: 7 days,
                defaultGracePeriod: 30 days,
                minTerm: 30 days,
                maxTerm: 730 days,
                maxInstallments: 24,
                voucherPremiumBps: 400
            })
        );
        m.asset.forceApprove(address(m.vouching), type(uint256).max);
        m.asset.forceApprove(address(m.basket), type(uint256).max);
        m.asset.forceApprove(address(m.reserve), type(uint256).max);
    }

    // ---------------------------------------------------------------- borrower flow

    /// @inheritdoc ILoanRegistry
    function propose(
        uint256 principal,
        uint64 term,
        uint16 numInstallments,
        uint16 maxRateBps,
        uint16 sector,
        bytes32 purposeHash
    ) external whenNotPaused returns (uint256 loanId) {
        (Tier tier, uint16 country) = gate.borrowerProfile(msg.sender);
        Params memory p = params;
        if (
            principal == 0 || term < p.minTerm || term > p.maxTerm || numInstallments == 0
                || numInstallments > p.maxInstallments || maxRateBps == 0 || maxRateBps > auction.MAX_RATE_BPS()
                || maxRateBps % auction.TICK_BPS() != 0
        ) revert InvalidTerms();
        uint256 available = credit.availableCredit(msg.sender, tier);
        if (principal > available) revert ExceedsCreditLimit(principal, available);

        loanId = ++loanCount;
        Loan storage l = _loans[loanId];
        l.borrower = msg.sender;
        l.state = LoanState.Proposed;
        l.tier = tier;
        l.country = country;
        l.sector = sector;
        l.maxRateBps = maxRateBps;
        l.numInstallments = numInstallments;
        l.term = term;
        l.principal = principal;
        l.purposeHash = purposeHash;
        emit LoanProposed(loanId, msg.sender, principal, term);
    }

    /// @inheritdoc ILoanRegistry
    function open(uint256 loanId) external whenNotPaused {
        Loan storage l = _requireBorrowerState(loanId, LoanState.Proposed);
        (Tier tier, uint16 country) = gate.borrowerProfile(msg.sender);
        IScoreOracle.Consensus memory c = oracle.consensus(loanId, msg.sender);
        if (!c.ok) revert NoScoreConsensus(loanId);

        (uint16 collateralBps, uint16 coverBps) = credit.requirementsFor(msg.sender, tier);
        if (c.minVoucherCoverBps > coverBps) coverBps = c.minVoucherCoverBps; // the score can only raise cover
        uint256 p = l.principal;
        l.tier = tier;
        l.country = country;
        l.riskBand = c.riskBand;
        l.requiredCollateral = Math.mulDiv(p, collateralBps, BPS, Math.Rounding.Ceil);
        l.requiredCover = Math.mulDiv(p, coverBps, BPS, Math.Rounding.Ceil);
        l.auctionEnd = uint64(block.timestamp) + params.auctionDuration;
        l.state = LoanState.Open;

        vouching.openCover(loanId, msg.sender, p, l.auctionEnd);
        auction.openAuction(loanId, msg.sender, p, l.maxRateBps, l.auctionEnd);
        emit LoanOpened(loanId, c.riskBand, l.requiredCollateral, l.requiredCover);
    }

    /// @inheritdoc ILoanRegistry
    function postCollateral(uint256 loanId, uint256 amount) external whenNotPaused nonReentrant {
        Loan storage l = _requireBorrowerState(loanId, LoanState.Open);
        if (block.timestamp >= l.auctionEnd) revert WrongState(loanId, l.state);
        escrow.deposit(loanId, msg.sender, amount);
        emit CollateralPosted(loanId, amount);
    }

    /// @inheritdoc ILoanRegistry
    function settle(uint256 loanId) external whenNotPaused nonReentrant returns (bool funded) {
        Loan storage l = _requireState(loanId, LoanState.Open);
        if (block.timestamp < l.auctionEnd) revert AuctionNotEnded(loanId);

        (bool cleared, uint16 rateBps) = auction.settle(loanId);
        if (!cleared) {
            _cancel(loanId, l, REASON_AUCTION_FAILED);
            return false;
        }

        Dues memory d = _quoteDues(loanId, l, rateBps);
        bytes32 reason = _fundingCheck(loanId, l, d);
        if (reason != bytes32(0)) {
            auction.cancel(loanId);
            _cancel(loanId, l, reason);
            return false;
        }

        // Every condition holds: lock backing, assign insurance, reserve credit.
        vouching.lockCover(loanId);
        if (d.insuredExposure > 0) {
            basket.assignCover(loanId, _basketId(l), d.insuredExposure, l.country, l.sector);
        }
        credit.onLoanFunded(l.borrower, l.tier, l.principal);
        _dues[loanId] = d;
        l.rateBps = rateBps;
        l.drawdownDeadline = uint64(block.timestamp) + params.drawdownWindow;
        l.state = LoanState.Funded;
        emit LoanFunded(loanId, rateBps, d.totalDue, d.insuredExposure);
        return true;
    }

    /// @inheritdoc ILoanRegistry
    function drawdown(uint256 loanId, bytes32 agreementHash) external whenNotPaused nonReentrant {
        _drawdown(loanId, agreementHash, msg.sender);
    }

    /// @inheritdoc ILoanRegistry
    function drawdownTo(uint256 loanId, bytes32 agreementHash, address recipient)
        external
        whenNotPaused
        nonReentrant
    {
        _drawdown(loanId, agreementHash, recipient);
    }

    function _drawdown(uint256 loanId, bytes32 agreementHash, address recipient) internal {
        Loan storage l = _requireBorrowerState(loanId, LoanState.Funded);
        if (block.timestamp > l.drawdownDeadline) revert DrawdownExpired(loanId);
        if (agreementHash == bytes32(0)) revert EmptyAgreement();
        gate.borrowerProfile(msg.sender); // payout: identity still valid, not sanctioned, not blocked
        if (recipient == address(0)) revert ZeroAddress();
        if (recipient != msg.sender) gate.requireNotSanctioned(recipient);

        uint256 p = l.principal;
        l.agreementHash = agreementHash;
        l.start = uint64(block.timestamp);
        l.state = LoanState.Active;
        totalOutstandingPrincipal += p; // before the fee, so the reserve cap includes this loan

        auction.disburse(loanId);
        uint256 fee = reserve.collectFee(p);
        _dues[loanId].reserveFee = fee;
        asset.safeTransfer(recipient, p - fee);
        emit LoanDrawn(loanId, agreementHash, fee, p - fee, recipient);
    }

    /// @inheritdoc ILoanRegistry
    function cancelExpired(uint256 loanId) external nonReentrant {
        Loan storage l = _requireState(loanId, LoanState.Funded);
        if (block.timestamp <= l.drawdownDeadline) revert DrawdownNotExpired(loanId);
        auction.cancel(loanId);
        basket.releaseCover(loanId);
        credit.onLoanCancelled(l.borrower, l.principal);
        _cancel(loanId, l, REASON_DRAWDOWN_EXPIRED);
    }

    /// @inheritdoc ILoanRegistry
    function repay(uint256 loanId, uint256 amount) external nonReentrant {
        Loan storage l = _requireState(loanId, LoanState.Active);
        Dues storage d = _dues[loanId];
        uint256 remaining = d.totalDue - d.repaid;
        if (amount > remaining) amount = remaining;
        if (amount == 0) revert NothingToRepay();
        asset.safeTransferFrom(msg.sender, address(this), amount);

        (uint256 lenderOld, uint256 voucherOld,) = _split(d, d.repaid);
        uint256 repaid = d.repaid + amount;
        (uint256 lenderNew, uint256 voucherNew,) = _split(d, repaid);
        uint256 lenderPart = lenderNew - lenderOld;
        uint256 voucherPart = voucherNew - voucherOld;
        uint256 insurancePart = amount - lenderPart - voucherPart;
        d.repaid = repaid;
        d.lenderCash += lenderPart;
        if (voucherPart > 0) vouching.addPremium(loanId, voucherPart);
        if (insurancePart > 0) basket.addPremium(loanId, insurancePart);
        emit Repaid(loanId, msg.sender, amount, repaid);

        if (repaid == d.totalDue) {
            l.state = LoanState.Repaid;
            vouching.releaseCover(loanId);
            basket.releaseCover(loanId);
            credit.onLoanRepaid(l.borrower, l.principal);
            totalOutstandingPrincipal -= l.principal;
            reserve.sync();
            emit LoanRepaid(loanId);
        }
    }

    /// @inheritdoc ILoanRegistry
    function markDefault(uint256 loanId) external nonReentrant {
        Loan storage l = _requireState(loanId, LoanState.Active);
        if (!isDefaultable(loanId)) revert NotDefaultable(loanId);
        Dues storage d = _dues[loanId];
        l.state = LoanState.Defaulted;
        (uint256 lenderPaid,,) = _split(d, d.repaid);
        uint256 loss = d.lenderDue - lenderPaid;
        // Lender receipts repay principal and interest pro rata; the principal still unpaid is insurable.
        uint256 principalPaid = Math.mulDiv(lenderPaid, l.principal, d.lenderDue);
        uint256 insurable = l.principal - principalPaid;

        ILossWaterfall.Allocation memory a = waterfall.executeDefault(loanId, loss, insurable);
        uint256 recovered = loss - a.lenderLoss;
        d.lenderCash += recovered;
        credit.onLoanDefaulted(l.borrower, l.principal);
        totalOutstandingPrincipal -= l.principal;
        reserve.sync();
        emit LoanDefaulted(loanId, loss, recovered);
    }

    /// @inheritdoc ILoanRegistry
    function claim(uint256 loanId) external nonReentrant returns (uint256 amount) {
        gate.requireNotSanctioned(msg.sender);
        amount = claimable(loanId, msg.sender);
        if (amount == 0) revert NothingToClaim();
        lenderClaimedBy[loanId][msg.sender] += amount;
        _dues[loanId].lenderClaimed += amount;
        asset.safeTransfer(msg.sender, amount);
        emit LenderClaimed(loanId, msg.sender, amount);
    }

    /// @inheritdoc ILoanRegistry
    function withdrawCollateral(uint256 loanId) external nonReentrant returns (uint256 amount) {
        Loan storage l = _loans[loanId];
        if (msg.sender != l.borrower) revert NotBorrower();
        LoanState s = l.state;
        if (s != LoanState.Repaid && s != LoanState.Cancelled && s != LoanState.Defaulted) revert WrongState(loanId, s);
        gate.requireNotSanctioned(msg.sender);
        amount = escrow.release(loanId, msg.sender);
        emit CollateralWithdrawn(loanId, amount);
    }

    // ---------------------------------------------------------------- views

    /// @inheritdoc ILoanRegistry
    function loanOf(uint256 loanId) external view returns (Loan memory) {
        return _loans[loanId];
    }

    /// @inheritdoc ILoanRegistry
    function duesOf(uint256 loanId) external view returns (Dues memory) {
        return _dues[loanId];
    }

    /// @inheritdoc ILoanRegistry
    function amountDueBy(uint256 loanId, uint256 t) public view returns (uint256) {
        Loan storage l = _loans[loanId];
        if (l.start == 0 || t < l.start) return 0;
        uint256 n = l.numInstallments;
        uint256 k = Math.mulDiv(t - l.start, n, l.term); // installments whose due time has passed
        if (k >= n) return _dues[loanId].totalDue;
        return Math.mulDiv(_dues[loanId].totalDue, k, n, Math.Rounding.Ceil);
    }

    /// @inheritdoc ILoanRegistry
    function isDefaultable(uint256 loanId) public view returns (bool) {
        if (_loans[loanId].state != LoanState.Active) return false;
        uint256 grace = params.defaultGracePeriod;
        if (block.timestamp < grace) return false;
        return _dues[loanId].repaid < amountDueBy(loanId, block.timestamp - grace);
    }

    /// @inheritdoc ILoanRegistry
    function claimable(uint256 loanId, address lender) public view returns (uint256) {
        LoanState s = _loans[loanId].state;
        if (s != LoanState.Active && s != LoanState.Repaid && s != LoanState.Defaulted) return 0;
        uint256 totalFilled = auction.auctionOf(loanId).totalFilled;
        uint256 entitled = Math.mulDiv(_dues[loanId].lenderCash, auction.positionOf(loanId, lender), totalFilled);
        return entitled - lenderClaimedBy[loanId][lender];
    }

    // ---------------------------------------------------------------- governance

    /// @inheritdoc ILoanRegistry
    function setParams(Params calldata p) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setParams(p);
    }

    // ---------------------------------------------------------------- internals

    /// @dev Amounts owed if the loan funds at `rateBps`. Dues round up (in lenders' and backers' favour).
    function _quoteDues(uint256 loanId, Loan storage l, uint16 rateBps) internal view returns (Dues memory d) {
        uint256 p = l.principal;
        d.lenderDue = p + Math.mulDiv(p * rateBps, l.term, YEAR * BPS, Math.Rounding.Ceil);
        d.coverPrincipal = vouching.coverOf(loanId).coverPrincipal;
        uint256 backing = escrow.collateralOf(loanId) + d.coverPrincipal;
        // Insurance covers principal only (security review H-1): never the interest at a rate the borrower
        // could have set against itself.
        d.insuredExposure = p > backing ? p - backing : 0;
        d.voucherPremiumDue =
            Math.mulDiv(d.coverPrincipal * params.voucherPremiumBps, l.term, YEAR * BPS, Math.Rounding.Ceil);
        uint16 insuranceRate = basket.premiumRateBps(_basketId(l));
        d.insurancePremiumDue = Math.mulDiv(d.insuredExposure * insuranceRate, l.term, YEAR * BPS, Math.Rounding.Ceil);
        d.totalDue = d.lenderDue + d.voucherPremiumDue + d.insurancePremiumDue;
    }

    /// @dev Returns the first failed condition, or zero if the loan may be funded. The score check is one of
    /// seven; passing it alone never funds a loan.
    function _fundingCheck(uint256 loanId, Loan storage l, Dues memory d) internal view returns (bytes32) {
        address b = l.borrower;
        if (!gate.isEligibleBorrower(b)) return REASON_IDENTITY;
        (Tier tier,) = gate.borrowerProfile(b);
        if (tier != l.tier) return REASON_IDENTITY;
        IScoreOracle.Consensus memory c = oracle.consensus(loanId, b);
        if (!c.ok || c.riskBand != l.riskBand) return REASON_SCORE;
        uint256 collateral = escrow.collateralOf(loanId);
        if (collateral < l.requiredCollateral) return REASON_COLLATERAL;
        if (d.coverPrincipal < l.requiredCover) return REASON_COVER;
        if (tier == Tier.C && collateral + d.coverPrincipal < l.principal) return REASON_ECONOMIC_SECURITY;
        if (credit.availableCredit(b, tier) < l.principal) return REASON_CREDIT_LIMIT;
        if (d.insuredExposure > 0 && !basket.canCover(_basketId(l), d.insuredExposure, l.country, l.sector)) {
            return REASON_INSURANCE;
        }
        return bytes32(0);
    }

    /// @dev Cumulative split of `repaid` between lenders, vouchers and insurers. Nested two-way splits keep every
    /// share monotone in `repaid` and exact when repaid == totalDue.
    function _split(Dues storage d, uint256 repaid)
        internal
        view
        returns (uint256 lender, uint256 voucher, uint256 insurance)
    {
        lender = Math.mulDiv(repaid, d.lenderDue, d.totalDue);
        uint256 others = repaid - lender;
        uint256 premiums = d.voucherPremiumDue + d.insurancePremiumDue;
        voucher = premiums == 0 ? 0 : Math.mulDiv(others, d.voucherPremiumDue, premiums);
        insurance = others - voucher;
    }

    function _cancel(uint256 loanId, Loan storage l, bytes32 reason) internal {
        vouching.cancelCover(loanId);
        l.state = LoanState.Cancelled;
        emit LoanCancelled(loanId, reason);
    }

    function _basketId(Loan storage l) internal view returns (uint256) {
        return basket.basketIdOf(l.riskBand, l.tier);
    }

    function _requireState(uint256 loanId, LoanState state) internal view returns (Loan storage l) {
        l = _loans[loanId];
        if (l.state != state) revert WrongState(loanId, l.state);
    }

    function _requireBorrowerState(uint256 loanId, LoanState state) internal view returns (Loan storage l) {
        l = _requireState(loanId, state);
        if (msg.sender != l.borrower) revert NotBorrower();
    }

    function _setParams(Params memory p) internal {
        _checkBounds(p.auctionDuration, 1 hours, 30 days);
        _checkBounds(p.drawdownWindow, 1 hours, 30 days);
        _checkBounds(p.defaultGracePeriod, 1 days, 180 days);
        _checkBounds(p.minTerm, 1 days, p.maxTerm);
        _checkBounds(p.maxTerm, p.minTerm, 1_825 days);
        _checkBounds(p.maxInstallments, 1, 120);
        _checkBounds(p.voucherPremiumBps, 0, 2_000);
        params = p;
        emit ParamsSet(p);
    }
}
