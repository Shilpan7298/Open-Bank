// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ProtocolAccess} from "./libraries/ProtocolAccess.sol";
import {IRateAuction} from "./interfaces/IRateAuction.sol";
import {IIdentityGate} from "./interfaces/IIdentityGate.sol";

/// @title RateAuction
/// @notice See {IRateAuction}. Written from scratch (EasyAuction is a reference only, see
/// docs/upstream-notes/auction-and-morpho.md): rates sit on a fixed tick grid, so settlement scans at most
/// MAX_RATE_BPS / TICK_BPS buckets plus at most MAX_BIDS bids, whatever the book looks like.
///
/// Rounding: marginal fills round up, so totalFilled is in [principal, principal + marginal bids) and the
/// contract never owes more refunds than it holds (it transfers exactly `principal` at disbursement).
contract RateAuction is IRateAuction, ProtocolAccess, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant REGISTRY_ROLE = keccak256("REGISTRY_ROLE");

    uint16 public constant TICK_BPS = 25;
    uint32 public constant MAX_BIDS = 100;
    uint16 public constant MAX_RATE_BPS = 5_000;

    IERC20 public immutable asset;
    IIdentityGate public immutable gate;

    mapping(uint256 loanId => Auction) private _auctions;
    mapping(uint256 loanId => mapping(uint256 bidId => Bid)) private _bids;
    mapping(uint256 loanId => mapping(uint256 tick => uint256)) private _totalAtTick;
    mapping(uint256 loanId => mapping(address lender => uint256)) private _filledBy;

    constructor(address admin, address guardian, IERC20 asset_, IIdentityGate gate_) ProtocolAccess(admin, guardian) {
        asset = asset_;
        gate = gate_;
    }

    /// @inheritdoc IRateAuction
    function openAuction(uint256 loanId, address borrower, uint256 principal, uint16 maxRateBps, uint64 endTime)
        external
        onlyRole(REGISTRY_ROLE)
    {
        Auction storage a = _auctions[loanId];
        if (a.status != Status.None) revert WrongStatus(loanId, a.status);
        if (principal == 0 || maxRateBps > MAX_RATE_BPS || endTime <= block.timestamp) revert InvalidAuction();
        if (maxRateBps % TICK_BPS != 0) revert RateNotOnTick(maxRateBps);
        a.borrower = borrower;
        a.status = Status.Open;
        a.maxRateBps = maxRateBps;
        a.endTime = endTime;
        a.principal = principal;
        a.minBid = Math.ceilDiv(principal, MAX_BIDS);
        emit AuctionOpened(loanId, principal, maxRateBps, endTime, a.minBid);
    }

    /// @inheritdoc IRateAuction
    function placeBid(uint256 loanId, uint256 amount, uint16 rateBps)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 bidId)
    {
        Auction storage a = _auctions[loanId];
        if (a.status != Status.Open) revert WrongStatus(loanId, a.status);
        if (block.timestamp >= a.endTime) revert AuctionClosed(loanId);
        if (msg.sender == a.borrower) revert BorrowerCannotBid();
        gate.requireNotSanctioned(msg.sender);
        if (amount < a.minBid) revert BidTooSmall(amount, a.minBid);
        if (rateBps > a.maxRateBps) revert RateAboveMax(rateBps, a.maxRateBps);
        if (rateBps % TICK_BPS != 0) revert RateNotOnTick(rateBps);
        if (a.bidCount >= MAX_BIDS) revert TooManyBids(loanId);

        bidId = a.bidCount++;
        _bids[loanId][bidId] = Bid({lender: msg.sender, rateBps: rateBps, amount: amount, filled: 0, refunded: 0});
        _totalAtTick[loanId][rateBps / TICK_BPS] += amount;
        a.totalBid += amount;
        asset.safeTransferFrom(msg.sender, address(this), amount);
        emit BidPlaced(loanId, bidId, msg.sender, amount, rateBps);
    }

    /// @inheritdoc IRateAuction
    function settle(uint256 loanId)
        external
        onlyRole(REGISTRY_ROLE)
        returns (bool cleared, uint16 clearingRateBps)
    {
        Auction storage a = _auctions[loanId];
        if (a.status != Status.Open) revert WrongStatus(loanId, a.status);
        if (block.timestamp < a.endTime) revert AuctionNotEnded(loanId);
        uint256 principal = a.principal;
        if (a.totalBid < principal) {
            a.status = Status.Failed;
            emit AuctionFailed(loanId, a.totalBid);
            return (false, 0);
        }

        (uint256 clearingTick, uint256 sumBelow, uint256 atTick) = _findClearingTick(loanId, a.maxRateBps, principal);
        uint256 totalFilled = _fillBids(loanId, a.bidCount, clearingTick, principal - sumBelow, atTick);

        clearingRateBps = uint16(clearingTick * TICK_BPS);
        a.clearingRateBps = clearingRateBps;
        a.totalFilled = totalFilled;
        a.status = Status.Cleared;
        emit AuctionCleared(loanId, clearingRateBps, totalFilled);
        return (true, clearingRateBps);
    }

    /// @dev Lowest tick at which cumulative demand covers `principal`. Requires totalBid >= principal.
    function _findClearingTick(uint256 loanId, uint16 maxRateBps, uint256 principal)
        internal
        view
        returns (uint256 tick, uint256 sumBelow, uint256 atTick)
    {
        uint256 maxTick = maxRateBps / TICK_BPS;
        for (; tick <= maxTick; tick++) {
            atTick = _totalAtTick[loanId][tick];
            if (sumBelow + atTick >= principal) return (tick, sumBelow, atTick);
            sumBelow += atTick;
        }
        revert InvalidAuction(); // unreachable: every bid sits on a tick <= maxTick
    }

    /// @dev Bids below the clearing tick fill fully; bids at it share `remaining` pro rata, rounded up
    /// (0 < remaining <= atTick); bids above it are not filled.
    function _fillBids(uint256 loanId, uint256 n, uint256 clearingTick, uint256 remaining, uint256 atTick)
        internal
        returns (uint256 totalFilled)
    {
        for (uint256 i; i < n; i++) {
            Bid storage b = _bids[loanId][i];
            uint256 tick = b.rateBps / TICK_BPS;
            uint256 filled;
            if (tick < clearingTick) filled = b.amount;
            else if (tick == clearingTick) filled = Math.mulDiv(b.amount, remaining, atTick, Math.Rounding.Ceil);
            if (filled > 0) {
                b.filled = filled;
                _filledBy[loanId][b.lender] += filled;
                totalFilled += filled;
            }
        }
    }

    /// @inheritdoc IRateAuction
    function cancel(uint256 loanId) external onlyRole(REGISTRY_ROLE) {
        Auction storage a = _auctions[loanId];
        if (a.status != Status.Cleared) revert WrongStatus(loanId, a.status);
        a.status = Status.Cancelled;
        emit AuctionCancelled(loanId);
    }

    /// @inheritdoc IRateAuction
    function disburse(uint256 loanId) external onlyRole(REGISTRY_ROLE) nonReentrant {
        Auction storage a = _auctions[loanId];
        if (a.status != Status.Cleared) revert WrongStatus(loanId, a.status);
        a.status = Status.Disbursed;
        asset.safeTransfer(msg.sender, a.principal);
        emit Disbursed(loanId, msg.sender, a.principal);
    }

    /// @inheritdoc IRateAuction
    function refund(uint256 loanId, uint256 bidId) external nonReentrant returns (uint256 amount) {
        amount = refundable(loanId, bidId);
        if (amount == 0) revert NothingToRefund();
        Bid storage b = _bids[loanId][bidId];
        gate.requireNotSanctioned(b.lender);
        b.refunded += amount;
        asset.safeTransfer(b.lender, amount);
        emit Refunded(loanId, bidId, b.lender, amount);
    }

    /// @inheritdoc IRateAuction
    function refundable(uint256 loanId, uint256 bidId) public view returns (uint256) {
        Status s = _auctions[loanId].status;
        Bid storage b = _bids[loanId][bidId];
        uint256 entitled;
        if (s == Status.Failed || s == Status.Cancelled) entitled = b.amount;
        else if (s == Status.Cleared || s == Status.Disbursed) entitled = b.amount - b.filled;
        return entitled - b.refunded;
    }

    /// @inheritdoc IRateAuction
    function positionOf(uint256 loanId, address lender) external view returns (uint256) {
        return _filledBy[loanId][lender];
    }

    /// @inheritdoc IRateAuction
    function auctionOf(uint256 loanId) external view returns (Auction memory) {
        return _auctions[loanId];
    }

    /// @inheritdoc IRateAuction
    function bidOf(uint256 loanId, uint256 bidId) external view returns (Bid memory) {
        return _bids[loanId][bidId];
    }
}
