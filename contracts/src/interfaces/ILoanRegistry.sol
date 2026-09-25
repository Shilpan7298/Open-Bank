// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.35;

import {LoanState, Tier} from "../libraries/Types.sol";

/// @title ILoanRegistry
/// @notice Loan state machine and terms. Orchestrates the other modules and holds lender cash per loan.
///
/// Lifecycle: propose -> (AI scores posted to ScoreOracle) -> open -> collateral, voucher slices and rate
/// bids during the auction window -> settle (all funding conditions re-checked; funded or cancelled) ->
/// drawdown (borrower e-signs, agreement hash stored, reserve fee taken, principal disbursed) ->
/// repay in installments -> Repaid, or markDefault -> LossWaterfall.
interface ILoanRegistry {
    struct Loan {
        address borrower;
        LoanState state;
        Tier tier;
        uint8 riskBand;
        uint16 country;
        uint16 sector;
        uint16 maxRateBps;
        uint16 rateBps; // clearing rate from the auction
        uint16 numInstallments;
        uint64 term; // seconds from drawdown to final installment
        uint64 auctionEnd;
        uint64 drawdownDeadline;
        uint64 start; // drawdown time
        uint256 principal;
        uint256 requiredCollateral;
        uint256 requiredCover;
        bytes32 purposeHash;
        bytes32 agreementHash; // hash of the signed Ricardian agreement
    }

    /// @dev Amounts fixed at funding. `totalDue` = lender + voucher premium + insurance premium. Each repayment is
    /// split pro rata between the three by cumulative amounts, so the split is exact at full repayment.
    struct Dues {
        uint256 lenderDue; // principal + interest at the clearing rate
        uint256 voucherPremiumDue;
        uint256 insurancePremiumDue;
        uint256 totalDue;
        uint256 repaid; // cumulative repayments
        uint256 lenderCash; // cumulative cash credited to lenders (repayments + waterfall)
        uint256 lenderClaimed; // cumulative cash claimed by lenders
        uint256 coverPrincipal; // locked voucher stake principal
        uint256 insuredExposure; // exposure assigned to the insurance basket
        uint256 reserveFee; // fee taken at drawdown
    }

    struct Params {
        uint64 auctionDuration;
        uint64 drawdownWindow;
        uint64 defaultGracePeriod; // an installment unpaid this long after its due time allows default
        uint64 minTerm;
        uint64 maxTerm;
        uint16 maxInstallments;
        uint16 voucherPremiumBps; // APR paid on staked voucher principal
    }

    event LoanProposed(uint256 indexed loanId, address indexed borrower, uint256 principal, uint64 term);
    event LoanOpened(uint256 indexed loanId, uint8 riskBand, uint256 requiredCollateral, uint256 requiredCover);
    event CollateralPosted(uint256 indexed loanId, uint256 amount);
    event LoanFunded(uint256 indexed loanId, uint16 rateBps, uint256 totalDue, uint256 insuredExposure);
    event LoanCancelled(uint256 indexed loanId, bytes32 reason);
    event LoanDrawn(uint256 indexed loanId, bytes32 agreementHash, uint256 reserveFee, uint256 disbursed);
    event Repaid(uint256 indexed loanId, address indexed payer, uint256 amount, uint256 totalRepaid);
    event LoanRepaid(uint256 indexed loanId);
    event LoanDefaulted(uint256 indexed loanId, uint256 loss, uint256 recovered);
    event LenderClaimed(uint256 indexed loanId, address indexed lender, uint256 amount);
    event CollateralWithdrawn(uint256 indexed loanId, uint256 amount);
    event ParamsSet(Params params);

    error WrongState(uint256 loanId, LoanState state);
    error NotBorrower();
    error InvalidTerms();
    error NoScoreConsensus(uint256 loanId);
    error AuctionNotEnded(uint256 loanId);
    error DrawdownExpired(uint256 loanId);
    error DrawdownNotExpired(uint256 loanId);
    error EmptyAgreement();
    error NotDefaultable(uint256 loanId);
    error NothingToClaim();

    /// @notice Propose a loan. The caller must pass IdentityGate and the principal must fit its credit limit.
    /// @param principal Amount to borrow (asset units).
    /// @param term Seconds from drawdown to the final installment.
    /// @param numInstallments Equal installments, due at term/numInstallments intervals.
    /// @param maxRateBps Highest lender APR the borrower accepts.
    /// @param sector Sector code of the loan purpose (used for basket concentration).
    /// @param purposeHash Hash of the off-chain proposal text.
    /// @return loanId New loan id.
    function propose(
        uint256 principal,
        uint64 term,
        uint16 numInstallments,
        uint16 maxRateBps,
        uint16 sector,
        bytes32 purposeHash
    ) external returns (uint256 loanId);

    /// @notice Open backing and bidding. Needs a score consensus from ScoreOracle, which fixes the risk band and
    /// can only raise the voucher cover requirement. Borrower only.
    function open(uint256 loanId) external;

    /// @notice Post collateral during the auction window. Borrower only; pulled by CollateralEscrow.
    function postCollateral(uint256 loanId, uint256 amount) external;

    /// @notice After the auction window, fund the loan if every condition holds, otherwise cancel it.
    /// Conditions: borrower passes IdentityGate, score consensus still valid, collateral >= requirement,
    /// voucher cover >= requirement (tier C: collateral + cover >= principal), fits credit limit, insurance
    /// basket has capacity, auction cleared. Callable by anyone.
    /// @return funded True if the loan moved to Funded.
    function settle(uint256 loanId) external returns (bool funded);

    /// @notice Sign the Ricardian agreement and draw down. Takes the reserve fee and disburses the rest.
    /// Borrower only, before the drawdown deadline.
    function drawdown(uint256 loanId, bytes32 agreementHash) external;

    /// @notice Cancel a funded loan the borrower did not draw down in time. Callable by anyone.
    function cancelExpired(uint256 loanId) external;

    /// @notice Repay up to the remaining total due. Callable by anyone. Always allowed while Active.
    function repay(uint256 loanId, uint256 amount) external;

    /// @notice Declare default when an installment is unpaid for longer than the default grace period, and run
    /// the loss waterfall. Callable by anyone.
    function markDefault(uint256 loanId) external;

    /// @notice Claim the caller's pro rata share of lender cash for `loanId`. Caller must not be sanctioned.
    /// @return amount Paid.
    function claim(uint256 loanId) external returns (uint256 amount);

    /// @notice Withdraw collateral left in escrow after repayment, cancellation or default. Borrower only,
    /// not sanctioned.
    function withdrawCollateral(uint256 loanId) external returns (uint256 amount);

    /// @notice Loan terms and state.
    function loanOf(uint256 loanId) external view returns (Loan memory);

    /// @notice Amounts due and paid.
    function duesOf(uint256 loanId) external view returns (Dues memory);

    /// @notice Cumulative amount that must have been repaid by time `t`.
    function amountDueBy(uint256 loanId, uint256 t) external view returns (uint256);

    /// @notice True if `markDefault` would succeed now.
    function isDefaultable(uint256 loanId) external view returns (bool);

    /// @notice Lender cash `lender` can claim now for `loanId`.
    function claimable(uint256 loanId, address lender) external view returns (uint256);

    /// @notice Sum of principal of all Active loans. Drives the reserve cap.
    function totalOutstandingPrincipal() external view returns (uint256);

    /// @notice Number of loans created.
    function loanCount() external view returns (uint256);

    /// @notice Set lifecycle parameters. Timelock only.
    function setParams(Params calldata params) external;
}
