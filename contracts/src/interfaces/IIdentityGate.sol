// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.35;

import {Tier} from "../libraries/Types.sol";

/// @title IIdentityGate
/// @notice Borrower identity from EAS attestations (KYC done off-chain by the legal entity) and wallet-level
/// sanctions screening for every participant.
interface IIdentityGate {
    event IdentityRegistered(address indexed account, bytes32 indexed uid, uint16 country);
    event CountryTierSet(uint16 indexed country, Tier tier);
    event AttesterSet(address indexed attester, bool trusted);
    event SanctionsOracleSet(address indexed oracle);
    event IdentitySchemaSet(bytes32 indexed schema);

    error Sanctioned(address account);
    error NotVerified(address account);
    error JurisdictionBlocked(address account, uint16 country);
    error InvalidAttestation(bytes32 uid);

    /// @notice Link the caller to an identity attestation. The attestation must use the identity schema,
    /// be issued by a trusted attester to the caller, and be neither revoked nor expired.
    /// @param uid EAS attestation UID. Data is `abi.encode(uint16 country)`.
    function registerIdentity(bytes32 uid) external;

    /// @notice True if the sanctions oracle lists `account`.
    function isSanctioned(address account) external view returns (bool);

    /// @notice Revert with `Sanctioned` if `account` is on the sanctions list. Used by every module on open,
    /// fund, vouch, insure and payout paths.
    function requireNotSanctioned(address account) external view;

    /// @notice Revert unless `account` holds a currently valid identity, is not sanctioned and is not in a
    /// blocked jurisdiction.
    /// @return tier Effective jurisdiction tier (A, B or C).
    /// @return country Country code from the identity attestation.
    function borrowerProfile(address account) external view returns (Tier tier, uint16 country);

    /// @notice Non-reverting form of `borrowerProfile`: true if `account` could borrow right now.
    function isEligibleBorrower(address account) external view returns (bool);

    /// @notice Effective tier for a country code: the governed mapping, or tier C if unset.
    function tierOf(uint16 country) external view returns (Tier);

    /// @notice Set a country's tier (A, B, C or Blocked). Timelock only.
    function setCountryTier(uint16 country, Tier tier) external;

    /// @notice Add or remove a trusted identity attester. Timelock only.
    function setTrustedAttester(address attester, bool trusted) external;

    /// @notice Replace the sanctions oracle. Timelock only.
    function setSanctionsOracle(address oracle) external;

    /// @notice Set the EAS schema UID for identity attestations. Timelock only.
    function setIdentitySchema(bytes32 schema) external;
}
