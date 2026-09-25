// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.35;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title ILenderVault
/// @notice ERC-4626 vault that lends into loans of one risk band through the rate auction. A human allocator
/// places bids (the AI band only filters which loans are eligible), within per-borrower and total deployment
/// caps. Withdrawals are limited to idle cash, since loans are illiquid.
interface ILenderVault is IERC4626 {
    struct Position {
        uint256 bid; // total escrowed in bids
        uint256 received; // cash received back (refunds + lender claims)
        bool closed;
    }

    event BidPlaced(uint256 indexed loanId, uint256 amount, uint16 rateBps, uint256 bidId);
    event Harvested(uint256 indexed loanId, uint256 amount, bool closed);
    event CapsSet(uint16 maxPerBorrowerBps, uint16 maxDeployedBps);
    event MinRateSet(uint16 minRateBps);

    error WrongBand(uint8 loanBand, uint8 vaultBand);
    error LoanNotOpen(uint256 loanId);
    error InsufficientIdle(uint256 amount, uint256 idle);
    error BorrowerCapExceeded(address borrower);
    error DeployedCapExceeded();
    error TooManyPositions();
    error RateBelowFloor(uint16 rateBps, uint16 floorBps);

    /// @notice Risk band this vault lends into.
    function riskBand() external view returns (uint8);

    /// @notice Bid `amount` of idle cash on `loanId` at `rateBps`. Allocator only. The loan must be Open and in
    /// the vault's band; caps are checked against total assets.
    function bid(uint256 loanId, uint256 amount, uint16 rateBps) external returns (uint256 bidId);

    /// @notice Collect refunds and lender cash for `loanId`; closes the position when the loan is finished.
    /// Callable by anyone.
    function harvest(uint256 loanId) external returns (uint256 amount);

    /// @notice Cash held by the vault and not deployed (internal accounting).
    function idle() external view returns (uint256);

    /// @notice Position in `loanId`.
    function positionOf(uint256 loanId) external view returns (Position memory);

    /// @notice Open position loan ids.
    function openPositions() external view returns (uint256[] memory);

    /// @notice Lowest rate the allocator may bid, protecting depositors from below-market lending. Timelock only.
    function setMinRate(uint16 minRateBps) external;

    /// @notice Set exposure caps in bps of total assets. Timelock only.
    function setCaps(uint16 maxPerBorrowerBps, uint16 maxDeployedBps) external;
}
