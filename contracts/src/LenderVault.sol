// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.35;

import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ProtocolAccess} from "./libraries/ProtocolAccess.sol";
import {BPS, LoanState} from "./libraries/Types.sol";
import {ILenderVault} from "./interfaces/ILenderVault.sol";
import {ILoanRegistry} from "./interfaces/ILoanRegistry.sol";
import {IRateAuction} from "./interfaces/IRateAuction.sol";
import {IIdentityGate} from "./interfaces/IIdentityGate.sol";

/// @title LenderVault
/// @notice See {ILenderVault}. Positions are valued conservatively: a live loan counts at cost minus cash already
/// received (interest is recognised when it arrives); a finished loan counts at exactly the cash still claimable,
/// so a default shows up in the share price in the same block. Cash is tracked internally, so donations are inert
/// and cannot inflate the share price.
contract LenderVault is ILenderVault, ERC4626, ProtocolAccess, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");
    uint256 public constant MAX_POSITIONS = 50;
    uint256 public constant MAX_BIDS_PER_LOAN = 4;

    ILoanRegistry public immutable registry;
    IRateAuction public immutable auction;
    IIdentityGate public immutable gate;
    uint8 public immutable riskBand;

    uint16 public maxPerBorrowerBps;
    uint16 public maxDeployedBps;

    uint256 private _idle;
    uint256[] private _open;
    mapping(uint256 loanId => Position) private _positions;
    mapping(uint256 loanId => uint256[]) private _bidIds;
    mapping(address borrower => uint256) public borrowerExposure;

    constructor(
        address admin,
        address guardian,
        IERC20Metadata asset_,
        ILoanRegistry registry_,
        IRateAuction auction_,
        IIdentityGate gate_,
        uint8 riskBand_,
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) ERC4626(asset_) ProtocolAccess(admin, guardian) {
        registry = registry_;
        auction = auction_;
        gate = gate_;
        riskBand = riskBand_;
        _setCaps(1_000, 9_000);
        IERC20(address(asset_)).forceApprove(address(auction_), type(uint256).max);
    }

    // ---------------------------------------------------------------- allocation

    /// @inheritdoc ILenderVault
    function bid(uint256 loanId, uint256 amount, uint16 rateBps)
        external
        onlyRole(ALLOCATOR_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint256 bidId)
    {
        ILoanRegistry.Loan memory l = registry.loanOf(loanId);
        if (l.state != LoanState.Open) revert LoanNotOpen(loanId);
        if (l.riskBand != riskBand) revert WrongBand(l.riskBand, riskBand);
        if (amount > _idle) revert InsufficientIdle(amount, _idle);
        uint256 total = totalAssets();
        if (borrowerExposure[l.borrower] + amount > Math.mulDiv(total, maxPerBorrowerBps, BPS)) {
            revert BorrowerCapExceeded(l.borrower);
        }
        if (total - _idle + amount > Math.mulDiv(total, maxDeployedBps, BPS)) revert DeployedCapExceeded();
        uint256[] storage ids = _bidIds[loanId];
        if (ids.length == 0) {
            if (_open.length >= MAX_POSITIONS) revert TooManyPositions();
            _open.push(loanId);
        } else if (ids.length >= MAX_BIDS_PER_LOAN) {
            revert TooManyPositions();
        }

        _idle -= amount;
        borrowerExposure[l.borrower] += amount;
        _positions[loanId].bid += amount;
        bidId = auction.placeBid(loanId, amount, rateBps);
        ids.push(bidId);
        emit BidPlaced(loanId, amount, rateBps, bidId);
    }

    /// @inheritdoc ILenderVault
    function harvest(uint256 loanId) external nonReentrant returns (uint256 amount) {
        Position storage p = _positions[loanId];
        if (p.bid == 0 || p.closed) return 0;
        uint256[] storage ids = _bidIds[loanId];
        for (uint256 i; i < ids.length; i++) {
            if (auction.refundable(loanId, ids[i]) > 0) amount += auction.refund(loanId, ids[i]);
        }
        ILoanRegistry.Loan memory l = registry.loanOf(loanId);
        if (registry.claimable(loanId, address(this)) > 0) amount += registry.claim(loanId);

        uint256 bookBefore = _book(p);
        p.received += amount;
        _idle += amount;
        uint256 bookAfter = _book(p);
        borrowerExposure[l.borrower] -= bookBefore - bookAfter;

        bool finished = l.state == LoanState.Repaid || l.state == LoanState.Defaulted || l.state == LoanState.Cancelled;
        if (finished && _remaining(loanId) == 0) {
            p.closed = true;
            borrowerExposure[l.borrower] -= bookAfter; // realised loss, if any
            _removeOpen(loanId);
        }
        emit Harvested(loanId, amount, p.closed);
    }

    // ---------------------------------------------------------------- ERC-4626

    /// @notice Idle cash plus the value of every open position.
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256 total) {
        total = _idle;
        for (uint256 i; i < _open.length; i++) {
            total += _positionValue(_open[i]);
        }
    }

    /// @notice Loans are illiquid: exits are limited to idle cash.
    function maxWithdraw(address owner) public view override(ERC4626, IERC4626) returns (uint256) {
        return Math.min(super.maxWithdraw(owner), _idle);
    }

    /// @notice Loans are illiquid: exits are limited to idle cash.
    function maxRedeem(address owner) public view override(ERC4626, IERC4626) returns (uint256) {
        return Math.min(super.maxRedeem(owner), _convertToShares(_idle, Math.Rounding.Floor));
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        whenNotPaused
    {
        gate.requireNotSanctioned(caller);
        gate.requireNotSanctioned(receiver);
        super._deposit(caller, receiver, assets, shares);
        _idle += assets;
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        gate.requireNotSanctioned(owner);
        gate.requireNotSanctioned(receiver);
        _idle -= assets;
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    // ---------------------------------------------------------------- views and governance

    /// @inheritdoc ILenderVault
    function idle() external view returns (uint256) {
        return _idle;
    }

    /// @inheritdoc ILenderVault
    function positionOf(uint256 loanId) external view returns (Position memory) {
        return _positions[loanId];
    }

    /// @inheritdoc ILenderVault
    function openPositions() external view returns (uint256[] memory) {
        return _open;
    }

    /// @notice Current value of the position in `loanId`.
    function positionValue(uint256 loanId) external view returns (uint256) {
        return _positions[loanId].closed ? 0 : _positionValue(loanId);
    }

    /// @inheritdoc ILenderVault
    function setCaps(uint16 maxPerBorrowerBps_, uint16 maxDeployedBps_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setCaps(maxPerBorrowerBps_, maxDeployedBps_);
    }

    function _setCaps(uint16 perBorrower, uint16 deployed) internal {
        _checkBounds(perBorrower, 1, BPS);
        _checkBounds(deployed, 1, BPS);
        maxPerBorrowerBps = perBorrower;
        maxDeployedBps = deployed;
        emit CapsSet(perBorrower, deployed);
    }

    function _positionValue(uint256 loanId) internal view returns (uint256) {
        LoanState s = registry.loanOf(loanId).state;
        if (s == LoanState.Repaid || s == LoanState.Defaulted || s == LoanState.Cancelled) return _remaining(loanId);
        return _book(_positions[loanId]);
    }

    /// @dev Cash still to come from a finished loan: refunds plus lender cash.
    function _remaining(uint256 loanId) internal view returns (uint256 r) {
        uint256[] storage ids = _bidIds[loanId];
        for (uint256 i; i < ids.length; i++) {
            r += auction.refundable(loanId, ids[i]);
        }
        r += registry.claimable(loanId, address(this));
    }

    function _book(Position storage p) internal view returns (uint256) {
        return p.bid > p.received ? p.bid - p.received : 0;
    }

    function _removeOpen(uint256 loanId) internal {
        uint256 n = _open.length;
        for (uint256 i; i < n; i++) {
            if (_open[i] == loanId) {
                _open[i] = _open[n - 1];
                _open.pop();
                return;
            }
        }
    }
}
