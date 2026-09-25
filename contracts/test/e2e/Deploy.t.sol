// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {DeployLib} from "../../script/DeployLib.sol";

contract DeployScriptTest is Test {
    // E2E-09
    function test_deployWiresAndHandsOver() public {
        Deploy d = new Deploy();
        DeployLib.System memory s = d.run();
        address deployer = vm.addr(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80);
        AccessControl[12] memory m = DeployLib.modules(s);
        for (uint256 i; i < m.length; i++) {
            assertTrue(m[i].hasRole(bytes32(0), address(s.timelock)));
            assertFalse(m[i].hasRole(bytes32(0), deployer));
        }
        assertTrue(s.escrow.hasRole(s.escrow.WATERFALL_ROLE(), address(s.waterfall)));
        assertTrue(s.vouching.hasRole(s.vouching.REGISTRY_ROLE(), address(s.registry)));
        assertTrue(s.stakeVault.hasRole(s.stakeVault.DEPOSITOR_ROLE(), address(s.vouching)));
        assertEq(address(s.reserve.loanRegistry()), address(s.registry));
        assertTrue(s.scoreOracle.isScorer(vm.addr(0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a)));
    }
}
