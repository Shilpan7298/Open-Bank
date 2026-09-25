// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.35;

/// @notice Chainalysis sanctions oracle interface (external contract, no code copied).
interface ISanctionsOracle {
    /// @notice True if `addr` is on the sanctions list.
    function isSanctioned(address addr) external view returns (bool);
}
