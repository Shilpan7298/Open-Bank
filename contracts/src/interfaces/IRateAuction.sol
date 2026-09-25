// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.35;

/// @title IRateAuction
/// @notice Uniform-price batch auction on interest rate, one per loan. Lenders escrow `amount` with a minimum
/// acceptable rate. The clearing rate is the lowest rate tick at which cumulative bids cover the principal;
/// every filled lender earns the clearing rate. Bids at the clearing tick fill pro rata (rounded up),
/// bids above it are refunded. Funding is all-or-nothing: if bids up to the borrower's max rate do not cover
/// the principal, the auction fails and every bid is refunded.
interface IRateAuction {
    enum Status {
        None,
        Open,
        Cleared, // clearing rate found, principal escrowed until drawdown or cancel
        Disbursed, // principal sent to the loan registry at drawdown
        Failed, // not enough bids, all refundable
        Cancelled // cleared but the loan was cancelled before drawdown, all refundable
    }

    struct Auction {
        address borrower;
        Status status;
        uint16 maxRateBps;
        uint16 clearingRateBps;
        uint64 endTime;
        uint32 bidCount;
        uint256 principal;
        uint256 minBid;
        uint256 totalBid;
        uint256 totalFilled;
    }

    struct Bid {
        address lender;
        uint16 rateBps;
        uint256 amount;
        uint256 filled;
        uint256 refunded; // cumulative amount refunded
    }

    event AuctionOpened(uint256 indexed loanId, uint256 principal, uint16 maxRateBps, uint64 endTime, uint256 minBid);
    event BidPlaced(uint256 indexed loanId, uint256 indexed bidId, address indexed lender, uint256 amount, uint16 rateBps);
    event AuctionCleared(uint256 indexed loanId, uint16 clearingRateBps, uint256 totalFilled);
    event AuctionFailed(uint256 indexed loanId, uint256 totalBid);
    event AuctionCancelled(uint256 indexed loanId);
    event Disbursed(uint256 indexed loanId, address indexed to, uint256 amount);
    event Refunded(uint256 indexed loanId, uint256 indexed bidId, address indexed lender, uint256 amount);

    error WrongStatus(uint256 loanId, Status status);
    error AuctionClosed(uint256 loanId);
    error AuctionNotEnded(uint256 loanId);
    error RateAboveMax(uint16 rateBps, uint16 maxRateBps);
    error RateNotOnTick(uint16 rateBps);
    error BidTooSmall(uint256 amount, uint256 minBid);
    error TooManyBids(uint256 loanId);
    error BorrowerCannotBid();
    error NothingToRefund();
    error InvalidAuction();

    /// @notice Open the auction for `loanId`. Loan registry only.
    function openAuction(uint256 loanId, address borrower, uint256 principal, uint16 maxRateBps, uint64 endTime)
        external;

    /// @notice Escrow a bid of `amount` at minimum rate `rateBps` (a multiple of the tick, <= max rate).
    /// Bids are binding: there is no cancellation. Caller must not be sanctioned or the borrower.
    /// @return bidId Index of the bid within the loan's auction.
    function placeBid(uint256 loanId, uint256 amount, uint16 rateBps) external returns (uint256 bidId);

    /// @notice Compute the clearing rate after `endTime`. Loan registry only.
    /// @return cleared True if bids covered the principal.
    /// @return clearingRateBps Uniform rate paid to all filled lenders (0 if not cleared).
    function settle(uint256 loanId) external returns (bool cleared, uint16 clearingRateBps);

    /// @notice Cancel a cleared auction before drawdown: every bid becomes fully refundable. Loan registry only.
    function cancel(uint256 loanId) external;

    /// @notice Send the principal to the loan registry at drawdown. Loan registry only.
    function disburse(uint256 loanId) external;

    /// @notice Refund the unfilled part of a bid (all of it if the auction failed or was cancelled).
    /// Paid to the bid's lender, who must not be sanctioned. Callable by anyone once refundable.
    /// @return amount Refunded.
    function refund(uint256 loanId, uint256 bidId) external returns (uint256 amount);

    /// @notice Refundable amount of a bid right now.
    function refundable(uint256 loanId, uint256 bidId) external view returns (uint256);

    /// @notice Total filled amount of `lender` in `loanId` (its claim weight on repayments).
    function positionOf(uint256 loanId, address lender) external view returns (uint256);

    /// @notice Auction record.
    function auctionOf(uint256 loanId) external view returns (Auction memory);

    /// @notice Bid record.
    function bidOf(uint256 loanId, uint256 bidId) external view returns (Bid memory);

    /// @notice Rate tick size in bps. Bids must be multiples of it.
    function TICK_BPS() external view returns (uint16);

    /// @notice Maximum bids per auction. The minimum bid is ceil(principal / MAX_BIDS), so the book can always
    /// reach the principal.
    function MAX_BIDS() external view returns (uint32);
}
