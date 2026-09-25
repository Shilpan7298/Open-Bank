// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.35;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ProtocolAccess} from "./libraries/ProtocolAccess.sol";
import {BPS} from "./libraries/Types.sol";
import {Attestation, IEAS} from "./interfaces/IEAS.sol";
import {IScoreOracle} from "./interfaces/IScoreOracle.sol";

/// @title ScoreOracle
/// @notice See {IScoreOracle}. The EAS attestation publishes the score; the EIP-712 signature binds it to this
/// chain and this oracle and to a registered scorer key. Consensus re-checks registration, expiry and
/// revocation at read time, so removing a scorer or revoking an attestation takes effect immediately.
contract ScoreOracle is IScoreOracle, ProtocolAccess, EIP712 {
    bytes32 public constant SCORE_TYPEHASH = keccak256(
        "Score(uint256 loanId,address borrower,uint8 riskBand,uint16 pdBps,uint16 minVoucherCoverBps,uint64 expiry,bytes32 rationaleHash,bytes32 modelId)"
    );
    uint8 public constant MIN_BAND = 1;
    uint8 public constant MAX_BAND = 5;
    uint256 public constant MAX_SCORES = 10;

    struct Stored {
        address scorer;
        bytes32 uid;
        uint64 attestedAt;
        Score score;
    }

    IEAS public immutable eas;
    bytes32 public scoreSchema;
    uint8 public quorum;
    mapping(address => bool) public isScorer;

    mapping(bytes32 key => Stored[]) private _scores;

    constructor(address admin, address guardian, IEAS eas_, bytes32 schema, uint8 quorum_)
        ProtocolAccess(admin, guardian)
        EIP712("OBP ScoreOracle", "1")
    {
        if (address(eas_) == address(0)) revert ZeroAddress();
        eas = eas_;
        scoreSchema = schema;
        _setQuorum(quorum_);
    }

    /// @inheritdoc IScoreOracle
    function submitScore(bytes32 attestationUid, bytes calldata signature) external {
        Attestation memory a = eas.getAttestation(attestationUid);
        if (!_liveAttestation(a, attestationUid) || a.data.length != 256) revert InvalidAttestation(attestationUid);
        Score memory s = abi.decode(a.data, (Score));
        if (a.recipient != s.borrower) revert InvalidAttestation(attestationUid);
        if (s.riskBand < MIN_BAND || s.riskBand > MAX_BAND) revert InvalidBand(s.riskBand);
        if (s.pdBps > BPS || s.minVoucherCoverBps > BPS) revert InvalidScore();
        if (s.expiry <= block.timestamp) revert ScoreExpired();

        address signer = ECDSA.recover(_hashTypedDataV4(_structHash(s)), signature);
        if (!isScorer[signer]) revert UnregisteredScorer(signer);

        Stored[] storage list = _scores[_key(s.loanId, s.borrower)];
        Stored memory entry = Stored(signer, attestationUid, a.time, s);
        uint256 n = list.length;
        for (uint256 i; i < n; i++) {
            if (list[i].scorer == signer) {
                if (a.time <= list[i].attestedAt) revert StaleScore(signer);
                list[i] = entry;
                emit ScoreSubmitted(s.loanId, s.borrower, signer, attestationUid, s.riskBand);
                return;
            }
        }
        if (n >= MAX_SCORES) revert TooManyScores();
        list.push(entry);
        emit ScoreSubmitted(s.loanId, s.borrower, signer, attestationUid, s.riskBand);
    }

    /// @inheritdoc IScoreOracle
    function consensus(uint256 loanId, address borrower) external view returns (Consensus memory c) {
        Stored[] storage list = _scores[_key(loanId, borrower)];
        uint256 n = list.length;
        for (uint256 i; i < n; i++) {
            Stored storage st = list[i];
            if (!isScorer[st.scorer] || st.score.expiry <= block.timestamp) continue;
            if (!_liveAttestation(eas.getAttestation(st.uid), st.uid)) continue;
            c.count++;
            if (st.score.riskBand > c.riskBand) c.riskBand = st.score.riskBand;
            if (st.score.pdBps > c.pdBps) c.pdBps = st.score.pdBps;
            if (st.score.minVoucherCoverBps > c.minVoucherCoverBps) c.minVoucherCoverBps = st.score.minVoucherCoverBps;
        }
        c.ok = c.count >= quorum;
    }

    /// @inheritdoc IScoreOracle
    function scoreDigest(Score calldata score) external view returns (bytes32) {
        return _hashTypedDataV4(_structHash(score));
    }

    /// @inheritdoc IScoreOracle
    function setScorer(address scorer, bool registered) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (scorer == address(0)) revert ZeroAddress();
        isScorer[scorer] = registered;
        emit ScorerSet(scorer, registered);
    }

    /// @inheritdoc IScoreOracle
    function setQuorum(uint8 quorum_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setQuorum(quorum_);
    }

    /// @inheritdoc IScoreOracle
    function setScoreSchema(bytes32 schema) external onlyRole(DEFAULT_ADMIN_ROLE) {
        scoreSchema = schema;
        emit ScoreSchemaSet(schema);
    }

    function _setQuorum(uint8 quorum_) internal {
        _checkBounds(quorum_, 1, MAX_SCORES);
        quorum = quorum_;
        emit QuorumSet(quorum_);
    }

    function _liveAttestation(Attestation memory a, bytes32 uid) internal view returns (bool) {
        return a.uid == uid && uid != bytes32(0) && a.schema == scoreSchema && a.revocationTime == 0
            && (a.expirationTime == 0 || a.expirationTime > block.timestamp);
    }

    function _structHash(Score memory s) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                SCORE_TYPEHASH,
                s.loanId,
                s.borrower,
                s.riskBand,
                s.pdBps,
                s.minVoucherCoverBps,
                s.expiry,
                s.rationaleHash,
                s.modelId
            )
        );
    }

    function _key(uint256 loanId, address borrower) internal pure returns (bytes32) {
        return keccak256(abi.encode(loanId, borrower));
    }
}
