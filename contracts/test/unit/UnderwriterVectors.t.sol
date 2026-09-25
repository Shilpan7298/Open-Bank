// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ScoreOracle} from "../../src/ScoreOracle.sol";
import {IScoreOracle} from "../../src/interfaces/IScoreOracle.sol";
import {MockEAS} from "../../src/mocks/MockEAS.sol";

/// Shared vectors with services/underwriter/test/vectors.test.ts: if either side changes the struct, domain or
/// encoding, both tests fail.
contract UnderwriterVectorsTest is Test {
    address constant ORACLE = 0x1000000000000000000000000000000000000001;
    bytes32 constant DIGEST = 0xcefcfff942a15586bb5a318193c7d3f9f88f6ea8688b976b4f2f7643e6bc93ba;
    bytes constant SIG =
        hex"3bc570a96f1878cd92b538839a6953be01f9336a92ce6c84747c2eaf329e10bc2264a6ac430a77705e4212d33ea19df8017e0750a50f1cb89b099a49dce7e06e1b";
    bytes constant DATA =
        hex"000000000000000000000000000000000000000000000000000000000000002a00000000000000000000000000000000000000000000000000000000000000b0000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000002580000000000000000000000000000000000000000000000000000000000001770000000000000000000000000000000000000000000000000000000007735940011111111111111111111111111111111111111111111111111111111111111112222222222222222222222222222222222222222222222222222222222222222";

    function _vector() internal pure returns (IScoreOracle.Score memory) {
        return IScoreOracle.Score({
            loanId: 42,
            borrower: address(0xB0),
            riskBand: 3,
            pdBps: 600,
            minVoucherCoverBps: 6_000,
            expiry: 2_000_000_000,
            rationaleHash: bytes32(uint256(0x1111111111111111111111111111111111111111111111111111111111111111)),
            modelId: bytes32(uint256(0x2222222222222222222222222222222222222222222222222222222222222222))
        });
    }

    // UW-04
    function test_eip712DigestAndSignatureMatchService() public {
        assertEq(block.chainid, 31337);
        deployCodeTo("ScoreOracle.sol", abi.encode(address(this), address(0), new MockEAS(), bytes32(0), uint8(1)), ORACLE);
        assertEq(ScoreOracle(ORACLE).scoreDigest(_vector()), DIGEST);
        assertEq(ECDSA.recover(DIGEST, SIG), 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC); // Anvil account 2
    }

    // UW-05
    function test_attestationDataMatchesService() public pure {
        assertEq(abi.encode(_vector()), DATA);
        IScoreOracle.Score memory s = abi.decode(DATA, (IScoreOracle.Score));
        assertEq(s.loanId, 42);
        assertEq(s.minVoucherCoverBps, 6_000);
    }
}
