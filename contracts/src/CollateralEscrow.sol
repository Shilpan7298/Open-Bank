// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ProtocolAccess} from "./libraries/ProtocolAccess.sol";
import {ICollateralEscrow} from "./interfaces/ICollateralEscrow.sol";

/// @title CollateralEscrow
/// @notice See {ICollateralEscrow}. Holds only collateral; balances are internal so direct transfers are inert.
contract CollateralEscrow is ICollateralEscrow, ProtocolAccess {
    using SafeERC20 for IERC20;

    bytes32 public constant REGISTRY_ROLE = keccak256("REGISTRY_ROLE");
    bytes32 public constant WATERFALL_ROLE = keccak256("WATERFALL_ROLE");

    IERC20 public immutable asset;
    mapping(uint256 loanId => uint256) public collateralOf;

    constructor(address admin, address guardian, IERC20 asset_) ProtocolAccess(admin, guardian) {
        if (address(asset_) == address(0)) revert ZeroAddress();
        asset = asset_;
    }

    /// @inheritdoc ICollateralEscrow
    function deposit(uint256 loanId, address from, uint256 amount) external onlyRole(REGISTRY_ROLE) {
        collateralOf[loanId] += amount;
        asset.safeTransferFrom(from, address(this), amount);
        emit Deposited(loanId, from, amount);
    }

    /// @inheritdoc ICollateralEscrow
    function release(uint256 loanId, address to) external onlyRole(REGISTRY_ROLE) returns (uint256 amount) {
        amount = collateralOf[loanId];
        collateralOf[loanId] = 0;
        if (amount > 0) asset.safeTransfer(to, amount);
        emit Released(loanId, to, amount);
    }

    /// @inheritdoc ICollateralEscrow
    function seize(uint256 loanId, uint256 loss, address to) external onlyRole(WATERFALL_ROLE) returns (uint256 seized) {
        uint256 held = collateralOf[loanId];
        seized = loss < held ? loss : held;
        collateralOf[loanId] = held - seized;
        if (seized > 0) asset.safeTransfer(to, seized);
        emit Seized(loanId, seized, to);
    }
}
