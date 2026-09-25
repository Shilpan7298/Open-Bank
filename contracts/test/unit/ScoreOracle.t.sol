// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {ScoreSigner} from "../utils/ScoreSigner.sol";
import {ScoreOracle} from "../../src/ScoreOracle.sol";
import {IScoreOracle} from "../../src/interfaces/IScoreOracle.sol";
import {MockEAS} from "../../src/mocks/MockEAS.sol";

contract ScoreOracleTest is ScoreSigner {
    address admin = makeAddr("timelock");
    address borrower = makeAddr("borrower");
    uint256 pk1 = 0xA11CE;
    uint256 pk2 = 0xB0B;
    uint256 pk3 = 0xC0C;
    MockEAS eas;
    ScoreOracle oracle;

    function setUp() public {
        eas = new MockEAS();
        oracle = new ScoreOracle(admin, address(0), eas, SCORE_SCHEMA, 1);
        vm.startPrank(admin);
        oracle.setScorer(vm.addr(pk1), true);
        oracle.setScorer(vm.addr(pk2), true);
        vm.stopPrank();
    }

    // SO-01
    function test_acceptsValidScore() public {
        _submit(oracle, eas, pk1, _score(1, borrower, 2));
        IScoreOracle.Consensus memory c = oracle.consensus(1, borrower);
        assertTrue(c.ok);
        assertEq(c.riskBand, 2);
        assertEq(c.pdBps, 300);
        assertEq(c.count, 1);
        assertFalse(oracle.consensus(1, makeAddr("other")).ok);
        assertFalse(oracle.consensus(2, borrower).ok);
    }

    // SO-02
    function test_rejectsUnregisteredSigner() public {
        IScoreOracle.Score memory s = _score(1, borrower, 2);
        bytes32 uid = _attestScore(eas, vm.addr(pk3), s);
        bytes memory sig = _sign(oracle, pk3, s);
        vm.expectRevert(abi.encodeWithSelector(IScoreOracle.UnregisteredScorer.selector, vm.addr(pk3)));
        oracle.submitScore(uid, sig);
    }

    // SO-03
    function test_rejectsBadAttestations() public {
        IScoreOracle.Score memory s = _score(1, borrower, 2);
        bytes memory sig = _sign(oracle, pk1, s);

        vm.prank(vm.addr(pk1));
        bytes32 wrongSchema = eas.attest(keccak256("other"), borrower, 0, abi.encode(s));
        vm.expectRevert(abi.encodeWithSelector(IScoreOracle.InvalidAttestation.selector, wrongSchema));
        oracle.submitScore(wrongSchema, sig);

        vm.prank(vm.addr(pk1));
        bytes32 wrongRecipient = eas.attest(SCORE_SCHEMA, makeAddr("x"), 0, abi.encode(s));
        vm.expectRevert(abi.encodeWithSelector(IScoreOracle.InvalidAttestation.selector, wrongRecipient));
        oracle.submitScore(wrongRecipient, sig);

        bytes32 revoked = _attestScore(eas, vm.addr(pk1), s);
        vm.prank(vm.addr(pk1));
        eas.revoke(revoked);
        vm.expectRevert(abi.encodeWithSelector(IScoreOracle.InvalidAttestation.selector, revoked));
        oracle.submitScore(revoked, sig);

        // Revoking after submission removes it from consensus.
        bytes32 uid = _attestScore(eas, vm.addr(pk1), s);
        oracle.submitScore(uid, sig);
        assertTrue(oracle.consensus(1, borrower).ok);
        vm.prank(vm.addr(pk1));
        eas.revoke(uid);
        assertFalse(oracle.consensus(1, borrower).ok);

        // Signature over different data than the attestation.
        IScoreOracle.Score memory other = _score(1, borrower, 1);
        bytes32 uid2 = _attestScore(eas, vm.addr(pk1), s);
        bytes memory otherSig = _sign(oracle, pk1, other);
        vm.expectRevert(); // recovers a different, unregistered address
        oracle.submitScore(uid2, otherSig);
    }

    // SO-04
    function test_expiry() public {
        IScoreOracle.Score memory s = _score(1, borrower, 2);
        s.expiry = uint64(block.timestamp + 1 days);
        _submit(oracle, eas, pk1, s);
        assertTrue(oracle.consensus(1, borrower).ok);
        vm.warp(block.timestamp + 1 days);
        assertFalse(oracle.consensus(1, borrower).ok);
        IScoreOracle.Score memory late = _score(2, borrower, 2);
        late.expiry = uint64(block.timestamp);
        bytes32 uid = _attestScore(eas, vm.addr(pk1), late);
        bytes memory sig = _sign(oracle, pk1, late);
        vm.expectRevert(IScoreOracle.ScoreExpired.selector);
        oracle.submitScore(uid, sig);
    }

    // SO-05
    function test_quorumCountsEachScorerOnce() public {
        vm.prank(admin);
        oracle.setQuorum(2);
        _submit(oracle, eas, pk1, _score(1, borrower, 2));
        vm.warp(block.timestamp + 1);
        _submit(oracle, eas, pk1, _score(1, borrower, 3)); // replaces, still one scorer
        IScoreOracle.Consensus memory c = oracle.consensus(1, borrower);
        assertFalse(c.ok);
        assertEq(c.count, 1);
        assertEq(c.riskBand, 3);
        _submit(oracle, eas, pk2, _score(1, borrower, 2));
        c = oracle.consensus(1, borrower);
        assertTrue(c.ok);
        assertEq(c.count, 2);
    }

    function test_olderAttestationCannotReplaceNewer() public {
        IScoreOracle.Score memory s = _score(1, borrower, 2);
        bytes32 older = _attestScore(eas, vm.addr(pk1), s);
        bytes memory sig = _sign(oracle, pk1, s);
        vm.warp(block.timestamp + 1);
        IScoreOracle.Score memory s2 = _score(1, borrower, 4);
        _submit(oracle, eas, pk1, s2);
        vm.expectRevert(abi.encodeWithSelector(IScoreOracle.StaleScore.selector, vm.addr(pk1)));
        oracle.submitScore(older, sig);
        assertEq(oracle.consensus(1, borrower).riskBand, 4);
    }

    // SO-06
    function test_consensusMostConservative() public {
        IScoreOracle.Score memory a = _score(1, borrower, 2);
        a.pdBps = 900;
        a.minVoucherCoverBps = 1_000;
        IScoreOracle.Score memory b = _score(1, borrower, 4);
        b.pdBps = 400;
        b.minVoucherCoverBps = 7_000;
        _submit(oracle, eas, pk1, a);
        _submit(oracle, eas, pk2, b);
        IScoreOracle.Consensus memory c = oracle.consensus(1, borrower);
        assertEq(c.riskBand, 4);
        assertEq(c.pdBps, 900);
        assertEq(c.minVoucherCoverBps, 7_000);
    }

    // SO-07
    function test_domainSeparation() public {
        IScoreOracle.Score memory s = _score(1, borrower, 2);
        ScoreOracle other = new ScoreOracle(admin, address(0), eas, SCORE_SCHEMA, 1);
        bytes memory sigOther = _sign(other, pk1, s);
        bytes32 uid = _attestScore(eas, vm.addr(pk1), s);
        vm.expectRevert();
        oracle.submitScore(uid, sigOther);

        uint256 chain = block.chainid;
        vm.chainId(chain + 1);
        bytes memory sigOtherChain = _sign(oracle, pk1, s);
        vm.chainId(chain);
        vm.expectRevert();
        oracle.submitScore(uid, sigOtherChain);

        oracle.submitScore(uid, _sign(oracle, pk1, s));
    }

    // SO-08
    function test_deregisteredScorerStopsCounting() public {
        _submit(oracle, eas, pk1, _score(1, borrower, 2));
        vm.prank(admin);
        oracle.setScorer(vm.addr(pk1), false);
        assertFalse(oracle.consensus(1, borrower).ok);
    }

    // SO-09
    function testFuzz_bandRange(uint8 band) public {
        IScoreOracle.Score memory s = _score(1, borrower, band);
        bytes32 uid = _attestScore(eas, vm.addr(pk1), s);
        bytes memory sig = _sign(oracle, pk1, s);
        if (band < 1 || band > 5) vm.expectRevert(abi.encodeWithSelector(IScoreOracle.InvalidBand.selector, band));
        oracle.submitScore(uid, sig);
    }

    function test_quorumBounds() public {
        vm.startPrank(admin);
        vm.expectRevert();
        oracle.setQuorum(0);
        vm.expectRevert();
        oracle.setQuorum(11);
        vm.stopPrank();
    }
}
