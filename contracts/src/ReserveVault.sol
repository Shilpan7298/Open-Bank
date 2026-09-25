// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ProtocolAccess} from "./libraries/ProtocolAccess.sol";
import {BPS} from "./libraries/Types.sol";
import {IReserveVault} from "./interfaces/IReserveVault.sol";
import {ILoanRegistry} from "./interfaces/ILoanRegistry.sol";

/// @title ReserveVault
/// @notice See {IReserveVault}. Phase 1 holds the single loan asset; the multi-asset reserve (stablecoins,
/// tokenized T-bills, gold <= 20%) is a later phase.
contract ReserveVault is IReserveVault, ProtocolAccess {
    using SafeERC20 for IERC20;

    bytes32 public constant REGISTRY_ROLE = keccak256("REGISTRY_ROLE");
    bytes32 public constant WATERFALL_ROLE = keccak256("WATERFALL_ROLE");

    uint16 public constant MIN_FEE_BPS = 100;
    uint16 public constant MAX_FEE_BPS = 200;
    uint16 public constant MAX_CAP_BPS = 500;

    IERC20 public immutable asset;
    ILoanRegistry public loanRegistry;
    uint16 public feeBps;
    uint16 public capBps;
    address public rebateRecipient;
    uint256 public reserveAssets;

    constructor(address admin, address guardian, IERC20 asset_, uint16 feeBps_, uint16 capBps_, address rebateRecipient_)
        ProtocolAccess(admin, guardian)
    {
        asset = asset_;
        _setParams(feeBps_, capBps_, rebateRecipient_);
    }

    /// @inheritdoc IReserveVault
    function collectFee(uint256 principal) external onlyRole(REGISTRY_ROLE) returns (uint256 fee) {
        uint256 full;
        (fee, full) = _quote(principal);
        reserveAssets += fee;
        if (fee > 0) asset.safeTransferFrom(msg.sender, address(this), fee);
        emit FeeCollected(principal, fee, full);
    }

    /// @inheritdoc IReserveVault
    function coverLoss(uint256 amount, address to) external onlyRole(WATERFALL_ROLE) returns (uint256 paid) {
        paid = amount < reserveAssets ? amount : reserveAssets;
        reserveAssets -= paid;
        if (paid > 0) asset.safeTransfer(to, paid);
        emit LossCovered(amount, paid, to);
    }

    /// @inheritdoc IReserveVault
    function sync() public returns (uint256 rebated) {
        uint256 c = cap();
        if (reserveAssets <= c) return 0;
        rebated = reserveAssets - c;
        reserveAssets = c;
        asset.safeTransfer(rebateRecipient, rebated);
        emit ExcessRebated(rebateRecipient, rebated);
    }

    /// @inheritdoc IReserveVault
    function quoteFee(uint256 principal) external view returns (uint256 fee) {
        (fee,) = _quote(principal);
    }

    /// @inheritdoc IReserveVault
    function cap() public view returns (uint256) {
        if (address(loanRegistry) == address(0)) return 0;
        return Math.mulDiv(loanRegistry.totalOutstandingPrincipal(), capBps, BPS);
    }

    /// @inheritdoc IReserveVault
    function setParams(uint16 feeBps_, uint16 capBps_, address rebateRecipient_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setParams(feeBps_, capBps_, rebateRecipient_);
    }

    /// @inheritdoc IReserveVault
    function setLoanRegistry(address registry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(loanRegistry) != address(0)) revert RegistryAlreadySet();
        if (registry == address(0)) revert ZeroAddress();
        loanRegistry = ILoanRegistry(registry);
        emit LoanRegistrySet(registry);
    }

    /// @dev Fee is reduced so reserve assets never exceed the cap at intake.
    function _quote(uint256 principal) internal view returns (uint256 fee, uint256 full) {
        full = Math.mulDiv(principal, feeBps, BPS);
        uint256 c = cap();
        uint256 room = c > reserveAssets ? c - reserveAssets : 0;
        fee = full < room ? full : room;
    }

    function _setParams(uint16 feeBps_, uint16 capBps_, address rebateRecipient_) internal {
        _checkBounds(feeBps_, MIN_FEE_BPS, MAX_FEE_BPS);
        _checkBounds(capBps_, 0, MAX_CAP_BPS);
        if (rebateRecipient_ == address(0)) revert ZeroAddress(); // excess above the cap must always have a home
        feeBps = feeBps_;
        capBps = capBps_;
        rebateRecipient = rebateRecipient_;
        emit ParamsSet(feeBps_, capBps_, rebateRecipient_);
    }
}
