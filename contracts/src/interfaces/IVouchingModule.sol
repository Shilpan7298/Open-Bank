// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.35;

/// @title IVouchingModule
/// @notice Vouchers stake slices against one specific loan. Stakes are held as shares of a low-risk
/// ERC-4626 stake vault, so they earn base yield while locked. Stakes backing an open loan cannot be withdrawn:
/// they are released on repayment or consumed (pro rata by slice) on default.
interface IVouchingModule {
    enum CoverState {
        None,
        Open, // collecting slices, slices withdrawable
        Locked, // loan funded, slices irrevocable
        Released, // loan repaid, vouchers claim stake + premium
        Defaulted, // loss absorbed, vouchers claim what is left + premium received before default
        Cancelled // loan never funded, vouchers withdraw
    }

    struct Cover {
        address borrower;
        CoverState state;
        uint64 deadline; // staking and unstaking close at this time (auction end)
        uint256 maxCover; // cap on total staked principal (loan principal)
        uint256 coverPrincipal; // sum of slice principals
        uint256 shares; // stake vault shares held for this loan
        uint256 sharesAfterDefault; // shares left for vouchers after the loss was absorbed
        uint256 premium; // premium received for this loan (asset units)
    }

    struct Slice {
        uint256 principal;
        uint256 shares;
        bool claimed;
    }

    struct VoucherStats {
        uint32 backed;
        uint32 repaid;
        uint32 defaulted;
        uint256 lost; // asset value of stake consumed by defaults
    }

    event CoverOpened(uint256 indexed loanId, address indexed borrower, uint256 maxCover);
    event Staked(uint256 indexed loanId, address indexed voucher, uint256 assets, uint256 shares);
    event Unstaked(uint256 indexed loanId, address indexed voucher, uint256 assets);
    event CoverLocked(uint256 indexed loanId, uint256 coverPrincipal);
    event CoverCancelled(uint256 indexed loanId);
    event CoverReleased(uint256 indexed loanId);
    event PremiumAdded(uint256 indexed loanId, uint256 amount);
    event LossAbsorbed(uint256 indexed loanId, uint256 requested, uint256 absorbed);
    event Claimed(uint256 indexed loanId, address indexed voucher, uint256 assets);

    error WrongState(uint256 loanId, CoverState state);
    error SelfVouch();
    error DelinquentVoucher(address voucher);
    error BelowMinSlice(uint256 amount, uint256 minSlice);
    error CoverCapExceeded(uint256 requested, uint256 room);
    error NoSlice();
    error AlreadyClaimed();
    error DeadlinePassed();

    /// @notice Start collecting slices for `loanId`. Loan registry only.
    /// @param maxCover Cap on total staked principal (the loan principal).
    /// @param deadline Staking and unstaking close at this time, so cover cannot be pulled between the end of
    /// the auction and settlement.
    function openCover(uint256 loanId, address borrower, uint256 maxCover, uint64 deadline) external;

    /// @notice Stake `assets` behind `loanId`. Caller must not be the borrower, sanctioned or delinquent.
    /// Adds to the caller's existing slice for this loan.
    function stake(uint256 loanId, uint256 assets) external;

    /// @notice Withdraw the caller's slice while cover is Open (before the deadline) or Cancelled.
    function unstake(uint256 loanId) external;

    /// @notice Make all slices irrevocable at loan funding. Loan registry only.
    /// @return coverPrincipal Total staked principal backing the loan.
    function lockCover(uint256 loanId) external returns (uint256 coverPrincipal);

    /// @notice Loan was never funded: slices become withdrawable. Loan registry only.
    function cancelCover(uint256 loanId) external;

    /// @notice Loan repaid: vouchers may claim stake plus premium. Loan registry only.
    function releaseCover(uint256 loanId) external;

    /// @notice Pull `amount` of premium for `loanId` from the caller. Loan registry only.
    function addPremium(uint256 loanId, uint256 amount) external;

    /// @notice Default: redeem up to `loss` of the loan's stake and send it to `to`. Loss waterfall only.
    /// @return absorbed min(loss, value of the loan's stake).
    function absorbLoss(uint256 loanId, uint256 loss, address to) external returns (uint256 absorbed);

    /// @notice Claim the caller's share after release or default: remaining stake (with yield) plus premium,
    /// pro rata by slice. Caller must not be sanctioned.
    /// @return assets Amount paid.
    function claim(uint256 loanId) external returns (uint256 assets);

    /// @notice Cover record for `loanId`.
    function coverOf(uint256 loanId) external view returns (Cover memory);

    /// @notice Current asset value of the loan's stake in the vault.
    function coverValue(uint256 loanId) external view returns (uint256);

    /// @notice Slice of `voucher` in `loanId`.
    function sliceOf(uint256 loanId, address voucher) external view returns (Slice memory);

    /// @notice Voucher reputation counters.
    function statsOf(address voucher) external view returns (VoucherStats memory);

    /// @notice Set the minimum slice size. Timelock only.
    function setMinSlice(uint256 minSlice) external;
}
