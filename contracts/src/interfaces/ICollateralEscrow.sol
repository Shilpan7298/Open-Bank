// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.35;

/// @title ICollateralEscrow
/// @notice Holds borrower collateral per loan, in the loan asset (Phase 1 has no price oracle).
interface ICollateralEscrow {
    event Deposited(uint256 indexed loanId, address indexed from, uint256 amount);
    event Released(uint256 indexed loanId, address indexed to, uint256 amount);
    event Seized(uint256 indexed loanId, uint256 seized, address indexed to, uint256 returned, address returnedTo);

    /// @notice Pull `amount` of the asset from `from` as collateral for `loanId`. Loan registry only.
    function deposit(uint256 loanId, address from, uint256 amount) external;

    /// @notice Return all collateral of `loanId` to `to` (repaid or cancelled loan). Loan registry only.
    /// @return amount Collateral released.
    function release(uint256 loanId, address to) external returns (uint256 amount);

    /// @notice Default path: send up to `loss` to `to` and return any excess collateral to `remainderTo`.
    /// Loss waterfall only.
    /// @return seized Amount sent to `to` (= min(loss, collateral)).
    function seize(uint256 loanId, uint256 loss, address to, address remainderTo) external returns (uint256 seized);

    /// @notice Collateral currently held for `loanId`.
    function collateralOf(uint256 loanId) external view returns (uint256);
}
