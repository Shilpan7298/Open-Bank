// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.35;

/// @title IScoreOracle
/// @notice Verifies AI underwriter scores. A score is an EAS attestation whose data is `abi.encode(Score)`,
/// accompanied by an EIP-712 signature over the same Score by a registered scorer key. Scores are advisory:
/// they set the risk band and can raise (never lower) the voucher cover requirement; they never fund a loan.
interface IScoreOracle {
    struct Score {
        uint256 loanId;
        address borrower;
        uint8 riskBand; // 1 (lowest risk) to 5
        uint16 pdBps; // probability of default
        uint16 minVoucherCoverBps; // suggested minimum voucher cover
        uint64 expiry; // score invalid after this time
        bytes32 rationaleHash; // keccak256 of the published rationale
        bytes32 modelId; // keccak256 of the model identifier
    }

    struct Consensus {
        bool ok; // quorum of valid scores reached
        uint8 riskBand; // most conservative (highest) band
        uint16 pdBps; // highest PD
        uint16 minVoucherCoverBps; // highest suggested cover
        uint256 count; // valid scores counted
    }

    event ScoreSubmitted(uint256 indexed loanId, address indexed borrower, address indexed scorer, bytes32 uid, uint8 riskBand);
    event ScorerSet(address indexed scorer, bool registered);
    event QuorumSet(uint8 quorum);
    event ScoreSchemaSet(bytes32 schema);

    error InvalidAttestation(bytes32 uid);
    error UnregisteredScorer(address signer);
    error ScoreExpired();
    error InvalidBand(uint8 band);
    error StaleScore(address scorer);
    error TooManyScores();
    error InvalidScore();

    /// @notice Submit a score attestation and the scorer's EIP-712 signature over its Score. Callable by anyone
    /// (e.g. a relayer); the signer must be a registered scorer. Each scorer holds one score per loan: a newer
    /// attestation replaces an older one, an older one reverts.
    function submitScore(bytes32 attestationUid, bytes calldata signature) external;

    /// @notice Aggregate currently valid scores for (`loanId`, `borrower`). Scores from deregistered scorers
    /// or past expiry do not count.
    function consensus(uint256 loanId, address borrower) external view returns (Consensus memory);

    /// @notice EIP-712 digest the scorer signs for `score`.
    function scoreDigest(Score calldata score) external view returns (bytes32);

    /// @notice Register or remove a scorer key. Timelock only.
    function setScorer(address scorer, bool registered) external;

    /// @notice Number of independent scorers required. Timelock only.
    function setQuorum(uint8 quorum) external;

    /// @notice EAS schema UID for score attestations. Timelock only.
    function setScoreSchema(bytes32 schema) external;
}
