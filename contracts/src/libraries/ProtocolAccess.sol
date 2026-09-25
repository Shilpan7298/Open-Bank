// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.35;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title ProtocolAccess
/// @notice Shared governance base for every OBP module.
/// `DEFAULT_ADMIN_ROLE` is held by the OZ TimelockController: it alone changes risk parameters,
/// grants roles and unpauses. `GUARDIAN_ROLE` can only pause.
abstract contract ProtocolAccess is AccessControl, Pausable {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    error ZeroAddress();
    error OutOfBounds(uint256 value, uint256 min, uint256 max);

    /// @param timelock Address of the TimelockController that governs this module.
    /// @param guardian Address allowed to pause (may be zero to start without a guardian).
    constructor(address timelock, address guardian) {
        if (timelock == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, timelock);
        if (guardian != address(0)) _grantRole(GUARDIAN_ROLE, guardian);
    }

    /// @notice Pause new risk-taking entry points. Guardian only.
    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    /// @notice Unpause. Timelock only, so a compromised guardian cannot flip the switch back and forth.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function _checkBounds(uint256 value, uint256 min, uint256 max) internal pure {
        if (value < min || value > max) revert OutOfBounds(value, min, max);
    }
}
