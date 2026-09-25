// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.35;

import {ISanctionsOracle} from "../interfaces/ISanctionsOracle.sol";

/// @notice Settable sanctions list for tests and local Anvil.
contract MockSanctionsOracle is ISanctionsOracle {
    mapping(address => bool) public isSanctioned;

    function setSanctioned(address addr, bool sanctioned) external {
        isSanctioned[addr] = sanctioned;
    }
}
