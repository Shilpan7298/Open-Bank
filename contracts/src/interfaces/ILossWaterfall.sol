// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.35;

/// @title ILossWaterfall
/// @notice The single place where default losses are allocated, in strict order:
/// 1. borrower collateral, 2. voucher stakes of the loan, 3. insurance basket (junior then senior),
/// 4. protocol reserve, 5. senior lenders. A lower layer never absorbs loss while a higher layer still has
/// capacity for that loan.
interface ILossWaterfall {
    struct Allocation {
        uint256 loss; // lender claim outstanding at default
        uint256 collateral;
        uint256 vouchers;
        uint256 basketJunior;
        uint256 basketSenior;
        uint256 reserve;
        uint256 lenderLoss; // what senior lenders bear
    }

    event LossAllocated(uint256 indexed loanId, Allocation allocation);

    error AlreadyAllocated(uint256 loanId);

    /// @notice Allocate `loss` for a defaulted loan. Every layer sends what it absorbs to the caller (the loan
    /// registry, which credits lenders). Loan registry only, once per loan.
    function executeDefault(uint256 loanId, uint256 loss) external returns (Allocation memory allocation);

    /// @notice Allocation recorded for `loanId`.
    function allocationOf(uint256 loanId) external view returns (Allocation memory);
}
