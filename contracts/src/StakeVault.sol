// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.35;

import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ProtocolAccess} from "./libraries/ProtocolAccess.sol";

/// @title StakeVault
/// @notice Low-risk ERC-4626 vault holding locked voucher stakes so they earn base yield while locked.
/// Phase 1 holds the asset idle; yield arrives as transfers to the vault (a strategy such as tokenized T-bills
/// is a later phase). Only protocol modules may deposit.
contract StakeVault is ERC4626, ProtocolAccess {
    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

    error NotDepositor(address caller);

    constructor(address admin, address guardian, IERC20Metadata asset_)
        ERC20("OBP Stake Vault", "obpSTAKE")
        ERC4626(asset_)
        ProtocolAccess(admin, guardian)
    {}

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (!hasRole(DEPOSITOR_ROLE, caller)) revert NotDepositor(caller);
        super._deposit(caller, receiver, assets, shares);
    }

    /// @dev Virtual shares against first-depositor share inflation (6-decimal assets -> 12-decimal shares).
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }
}
