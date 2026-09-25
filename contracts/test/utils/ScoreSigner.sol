// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ScoreOracle} from "../../src/ScoreOracle.sol";
import {IScoreOracle} from "../../src/interfaces/IScoreOracle.sol";
import {MockEAS} from "../../src/mocks/MockEAS.sol";

/// @notice Helpers to attest and sign AI scores in tests, the way services/underwriter does off-chain.
abstract contract ScoreSigner is Test {
    bytes32 constant SCORE_SCHEMA = keccak256("OBP.score.v1");

    function _score(uint256 loanId, address borrower, uint8 band) internal view returns (IScoreOracle.Score memory) {
        return IScoreOracle.Score({
            loanId: loanId,
            borrower: borrower,
            riskBand: band,
            pdBps: 300,
            minVoucherCoverBps: 0,
            expiry: uint64(block.timestamp + 30 days),
            rationaleHash: keccak256("rationale"),
            modelId: keccak256("mock-v1")
        });
    }

    function _sign(ScoreOracle oracle, uint256 pk, IScoreOracle.Score memory s) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 sig) = vm.sign(pk, oracle.scoreDigest(s));
        return abi.encodePacked(r, sig, v);
    }

    function _attestScore(MockEAS eas, address attester, IScoreOracle.Score memory s) internal returns (bytes32 uid) {
        vm.prank(attester);
        uid = eas.attest(SCORE_SCHEMA, s.borrower, 0, abi.encode(s));
    }

    function _submit(ScoreOracle oracle, MockEAS eas, uint256 pk, IScoreOracle.Score memory s) internal returns (bytes32 uid) {
        uid = _attestScore(eas, vm.addr(pk), s);
        oracle.submitScore(uid, _sign(oracle, pk, s));
    }
}
