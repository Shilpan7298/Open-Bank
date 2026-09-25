// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.35;

/// @dev Basis-point denominator used for every ratio in the protocol.
uint256 constant BPS = 10_000;
/// @dev Day-count basis for simple interest and premiums.
uint256 constant YEAR = 365 days;

/// @notice Jurisdiction tier of a borrower, derived from the country in their identity attestation.
/// @dev `None` means no valid identity. Countries without an explicit mapping are treated as tier C.
enum Tier {
    None,
    A,
    B,
    C,
    Blocked
}

/// @notice Borrower stage from repayment history (CLAUDE.md stage table).
enum Stage {
    New,
    Established,
    Proven
}

/// @notice Loan state machine.
/// Proposed -> Open -> Funded -> Active -> Repaid | Defaulted.
/// Proposed, Open and Funded can end in Cancelled.
enum LoanState {
    None,
    Proposed,
    Open,
    Funded,
    Active,
    Repaid,
    Defaulted,
    Cancelled
}

/// @notice Insurance basket tranche. Junior absorbs losses before senior.
enum Tranche {
    Junior,
    Senior
}
