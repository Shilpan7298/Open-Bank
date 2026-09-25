// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.35;

import {Tier, Tranche} from "../libraries/Types.sol";

/// @title IInsuranceBasket
/// @notice Tranched insurance pools, one basket per (risk band, jurisdiction tier). Insurers deposit into the
/// junior or senior tranche. A basket insures the part of each loan left after collateral and voucher cover.
/// Junior absorbs losses before senior. Covered exposure <= leverage x capital; exposure from one country,
/// sector or origination month <= concentration cap x capacity. Withdrawals need notice, are processed FIFO,
/// and queued shares keep absorbing losses (and earning premium) until they settle.
interface IInsuranceBasket {
    struct TrancheState {
        uint256 assets;
        uint256 shares;
    }

    struct CoverRecord {
        uint256 basketId;
        uint256 exposure;
        uint16 country;
        uint16 sector;
        uint32 month; // origination month index = timestamp / 30 days
    }

    struct WithdrawalRequest {
        address owner;
        uint64 eligibleAt;
        uint256 shares; // shares still queued
    }

    struct Params {
        uint16 leverageBps; // 30000 = 3x
        uint16 concentrationBps; // 2500 = 25% of capacity
        uint64 noticePeriod; // 30 to 90 days
        uint64 epochLength; // eligibility rounds up to an epoch boundary
        uint16 seniorPremiumHaircutBps; // senior gets its pro rata premium share minus this haircut
    }

    event Deposited(uint256 indexed basketId, Tranche tranche, address indexed owner, uint256 assets, uint256 shares);
    event WithdrawalRequested(uint256 indexed basketId, Tranche tranche, uint256 indexed requestId, address indexed owner, uint256 shares, uint64 eligibleAt);
    event WithdrawalProcessed(uint256 indexed basketId, Tranche tranche, uint256 indexed requestId, uint256 shares, uint256 assets);
    event WithdrawalClaimed(address indexed owner, uint256 assets);
    event CoverAssigned(uint256 indexed loanId, uint256 indexed basketId, uint256 exposure);
    event CoverReleased(uint256 indexed loanId, uint256 exposure);
    event PremiumAdded(uint256 indexed loanId, uint256 juniorAmount, uint256 seniorAmount);
    event LossAbsorbed(uint256 indexed loanId, uint256 junior, uint256 senior);
    event PremiumRateSet(uint256 indexed basketId, uint16 rateBps);
    event ParamsSet(Params params);

    error InvalidBasket(uint256 basketId);
    error ZeroShares();
    error InsufficientShares();
    error NoCapacity(uint256 basketId, uint256 exposure);
    error ConcentrationExceeded(uint256 basketId, uint8 dimension);
    error AlreadyCovered(uint256 loanId);
    error NothingToClaim();

    /// @notice Basket id for a risk band (1-5) and tier (A, B or C).
    function basketIdOf(uint8 riskBand, Tier tier) external pure returns (uint256);

    /// @notice Deposit `assets` into a tranche. Caller must not be sanctioned.
    /// @return shares Minted (non-transferable, internal).
    function deposit(uint256 basketId, Tranche tranche, uint256 assets) external returns (uint256 shares);

    /// @notice Queue `shares` for withdrawal. They stay at risk until processed, at the first epoch boundary
    /// at least `noticePeriod` from now. No cancellation.
    /// @return requestId Queue position.
    function requestWithdrawal(uint256 basketId, Tranche tranche, uint256 shares) external returns (uint256 requestId);

    /// @notice Process up to `maxRequests` eligible requests from the head of the queue, pricing shares at the
    /// current NAV and paying out only capital not needed to keep leverage and concentration within limits.
    /// Callable by anyone.
    /// @return processed Number of requests fully settled.
    function processWithdrawals(uint256 basketId, Tranche tranche, uint256 maxRequests) external returns (uint256 processed);

    /// @notice Pay the caller's settled withdrawals. Caller must not be sanctioned.
    function claimWithdrawals() external returns (uint256 assets);

    /// @notice True if assigning `exposure` with these attributes would respect capacity and concentration.
    function canCover(uint256 basketId, uint256 exposure, uint16 country, uint16 sector) external view returns (bool);

    /// @notice Record cover for a funded loan. Reverts if capacity or concentration would be exceeded.
    /// Loan registry only.
    function assignCover(uint256 loanId, uint256 basketId, uint256 exposure, uint16 country, uint16 sector) external;

    /// @notice Remove a loan's cover (repaid or cancelled). Loan registry only.
    function releaseCover(uint256 loanId) external;

    /// @notice Pull `amount` of premium for `loanId` and split it between tranches. Loan registry only.
    function addPremium(uint256 loanId, uint256 amount) external;

    /// @notice Default: pay up to min(loss, loan exposure) from junior, then senior, to `to`, and remove the
    /// loan's cover. Loss waterfall only. Returns zeros for a loan without cover.
    function absorbLoss(uint256 loanId, uint256 loss, address to) external returns (uint256 junior, uint256 senior);

    /// @notice Annual premium rate in bps on insured exposure for a basket.
    function premiumRateBps(uint256 basketId) external view returns (uint16);

    /// @notice Junior + senior assets (includes shares queued for withdrawal).
    function capital(uint256 basketId) external view returns (uint256);

    /// @notice Maximum covered exposure: capital x leverage.
    function capacity(uint256 basketId) external view returns (uint256);

    /// @notice Total covered exposure.
    function exposureOf(uint256 basketId) external view returns (uint256);

    /// @notice Tranche assets and shares.
    function trancheOf(uint256 basketId, Tranche tranche) external view returns (TrancheState memory);

    /// @notice Unqueued shares of `owner`.
    function sharesOf(uint256 basketId, Tranche tranche, address owner) external view returns (uint256);

    /// @notice Largest per-key exposure in each dimension (0 country, 1 sector, 2 month).
    function maxConcentration(uint256 basketId) external view returns (uint256 country, uint256 sector, uint256 month);

    /// @notice Cover record for a loan.
    function coverOf(uint256 loanId) external view returns (CoverRecord memory);

    /// @notice Withdrawal request by queue position.
    function requestOf(uint256 basketId, Tranche tranche, uint256 requestId)
        external
        view
        returns (WithdrawalRequest memory);

    /// @notice Queue head (next request to process) and length.
    function queueOf(uint256 basketId, Tranche tranche) external view returns (uint256 head, uint256 length);

    /// @notice Settled withdrawals `owner` can claim.
    function claimableOf(address owner) external view returns (uint256);

    /// @notice Capital that could leave the basket now without breaking leverage or concentration limits.
    function freeCapital(uint256 basketId) external view returns (uint256);

    /// @notice Set a basket's premium rate. Timelock only.
    function setPremiumRate(uint256 basketId, uint16 rateBps) external;

    /// @notice Set basket parameters. Timelock only.
    function setParams(Params calldata params) external;
}
