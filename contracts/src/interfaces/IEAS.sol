// SPDX-License-Identifier: MIT
// Adapted from ethereum-attestation-service/eas-contracts @ e6e970286f, contracts/Common.sol and contracts/IEAS.sol.
// Only the Attestation struct and the read function OBP needs are kept. See NOTICE.md.
pragma solidity ^0.8.0;

/// @notice A struct representing a single attestation.
struct Attestation {
    bytes32 uid; // A unique identifier of the attestation.
    bytes32 schema; // The unique identifier of the schema.
    uint64 time; // The time when the attestation was created (Unix timestamp).
    uint64 expirationTime; // The time when the attestation expires (Unix timestamp).
    uint64 revocationTime; // The time when the attestation was revoked (Unix timestamp).
    bytes32 refUID; // The UID of the related attestation.
    address recipient; // The recipient of the attestation.
    address attester; // The attester/sender of the attestation.
    bool revocable; // Whether the attestation is revocable.
    bytes data; // Custom attestation data.
}

/// @notice Read-only subset of the EAS interface used by IdentityGate and ScoreOracle.
interface IEAS {
    /// @notice Returns an existing attestation by UID (all-zero struct if it does not exist).
    /// @param uid The UID of the attestation to retrieve.
    function getAttestation(bytes32 uid) external view returns (Attestation memory);
}
