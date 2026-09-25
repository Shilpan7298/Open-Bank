// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.35;

import {Script, console} from "forge-std/Script.sol";
import {DeployLib} from "./DeployLib.sol";
import {Tier} from "../src/libraries/Types.sol";

/// @notice Local Anvil deployment of the Phase 1 system with mocks (USDC, EAS, sanctions oracle).
/// Uses Anvil's well-known default keys unless DEPLOYER_PK is set; never use these keys anywhere else.
///   anvil &
///   forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
/// Writes addresses to deployments/local.json for services/underwriter.
contract Deploy is Script {
    // Anvil default accounts 0, 1 and 2 (public test keys).
    uint256 internal constant ANVIL_PK0 = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant ANVIL_PK1 = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 internal constant ANVIL_PK2 = 0x5de4111afa1a4b94908f83103eb1d1706367c2e68ca870fc3fb9a804cdab365a;

    function run() external returns (DeployLib.System memory s) {
        uint256 pk = vm.envOr("DEPLOYER_PK", ANVIL_PK0);
        address deployer = vm.addr(pk);
        address attester = vm.envOr("KYC_ATTESTER", vm.addr(ANVIL_PK1));
        address scorer = vm.envOr("SCORER", vm.addr(ANVIL_PK2));
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;

        vm.startBroadcast(pk);
        s = DeployLib.deploy(
            DeployLib.Config({
                admin: deployer,
                guardian: deployer,
                rebateRecipient: deployer,
                timelockDelay: 2 days,
                proposers: proposers
            })
        );
        s.gate.setTrustedAttester(attester, true);
        s.gate.setCountryTier(1, Tier.A);
        s.gate.setCountryTier(2, Tier.B);
        s.scoreOracle.setScorer(scorer, true);
        DeployLib.handOver(s, deployer);
        vm.stopBroadcast();

        _write(s);
    }

    function _write(DeployLib.System memory s) internal {
        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "usdc", address(s.usdc));
        vm.serializeAddress(k, "eas", address(s.eas));
        vm.serializeAddress(k, "sanctions", address(s.sanctions));
        vm.serializeAddress(k, "timelock", address(s.timelock));
        vm.serializeAddress(k, "identityGate", address(s.gate));
        vm.serializeAddress(k, "creditRegistry", address(s.credit));
        vm.serializeAddress(k, "collateralEscrow", address(s.escrow));
        vm.serializeAddress(k, "stakeVault", address(s.stakeVault));
        vm.serializeAddress(k, "vouchingModule", address(s.vouching));
        vm.serializeAddress(k, "rateAuction", address(s.auction));
        vm.serializeAddress(k, "insuranceBasket", address(s.basket));
        vm.serializeAddress(k, "reserveVault", address(s.reserve));
        vm.serializeAddress(k, "lossWaterfall", address(s.waterfall));
        vm.serializeAddress(k, "lenderVault", address(s.lenderVault));
        vm.serializeAddress(k, "loanRegistry", address(s.registry));
        vm.serializeBytes32(k, "identitySchema", DeployLib.IDENTITY_SCHEMA);
        vm.serializeBytes32(k, "scoreSchema", DeployLib.SCORE_SCHEMA);
        string memory json = vm.serializeAddress(k, "scoreOracle", address(s.scoreOracle));
        vm.writeJson(json, string.concat(vm.projectRoot(), "/deployments/local.json"));
        console.log("LoanRegistry", address(s.registry));
        console.log("ScoreOracle", address(s.scoreOracle));
    }
}
