// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.35;

import {Stage, Tier} from "../libraries/Types.sol";

/// @title ICreditRegistry
/// @notice Borrower credit limits, repayment history, stage and the per-stage/per-tier backing requirements.
interface ICreditRegistry {
    struct History {
        uint32 repaidLoans;
        uint32 defaultedLoans;
        uint256 outstandingPrincipal;
    }

    struct LimitParams {
        uint256 base; // limit for a borrower with no repaid loans
        uint256 step; // added per repaid loan
        uint256 max; // hard cap for the tier
    }

    event LoanFunded(address indexed borrower, uint256 principal);
    event LoanCancelled(address indexed borrower, uint256 principal);
    event LoanRepaid(address indexed borrower, uint256 principal);
    event LoanDefaulted(address indexed borrower, uint256 principal);
    event RequirementSet(Stage stage, Tier tier, uint16 collateralBps, uint16 voucherCoverBps);
    event LimitParamsSet(Tier tier, uint256 base, uint256 step, uint256 max);
    event StageThresholdsSet(uint32 establishedAfter, uint32 provenAfter);

    error CreditLimitExceeded(address borrower, uint256 requested, uint256 available);

    /// @notice Stage of `borrower` from its number of repaid loans.
    function stageOf(address borrower) external view returns (Stage);

    /// @notice Total principal `borrower` may have outstanding in `tier`. Zero after any default.
    function creditLimit(address borrower, Tier tier) external view returns (uint256);

    /// @notice Credit limit minus outstanding principal.
    function availableCredit(address borrower, Tier tier) external view returns (uint256);

    /// @notice Repayment history and outstanding principal of `borrower`.
    function historyOf(address borrower) external view returns (History memory);

    /// @notice Minimum collateral and required voucher cover, in bps of principal, for `borrower` in `tier`.
    function requirementsFor(address borrower, Tier tier)
        external
        view
        returns (uint16 collateralBps, uint16 voucherCoverBps);

    /// @notice Record a funded loan. Reverts if it does not fit the available credit. Loan registry only.
    function onLoanFunded(address borrower, Tier tier, uint256 principal) external;

    /// @notice Release the credit reserved by `onLoanFunded` for a loan cancelled before drawdown. Loan registry only.
    function onLoanCancelled(address borrower, uint256 principal) external;

    /// @notice Record a fully repaid loan: outstanding falls, repaid count (and so the limit) rises. Loan registry only.
    function onLoanRepaid(address borrower, uint256 principal) external;

    /// @notice Record a defaulted loan: outstanding falls, credit limit drops to zero. Loan registry only.
    function onLoanDefaulted(address borrower, uint256 principal) external;

    /// @notice Set minimum collateral (>= 20%) and voucher cover for a stage and tier. Timelock only.
    function setRequirement(Stage stage, Tier tier, uint16 collateralBps, uint16 voucherCoverBps) external;

    /// @notice Set credit limit parameters for a tier. Timelock only.
    function setLimitParams(Tier tier, LimitParams calldata params) external;

    /// @notice Set the repaid-loan counts at which a borrower becomes Established and Proven. Timelock only.
    function setStageThresholds(uint32 establishedAfter, uint32 provenAfter) external;
}
