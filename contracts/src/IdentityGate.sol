// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.35;

import {ProtocolAccess} from "./libraries/ProtocolAccess.sol";
import {Tier} from "./libraries/Types.sol";
import {Attestation, IEAS} from "./interfaces/IEAS.sol";
import {IIdentityGate} from "./interfaces/IIdentityGate.sol";
import {ISanctionsOracle} from "./interfaces/ISanctionsOracle.sol";

/// @title IdentityGate
/// @notice See {IIdentityGate}. The identity attestation is re-validated on every check, so revoking it (or
/// untrusting its attester) takes effect immediately.
contract IdentityGate is IIdentityGate, ProtocolAccess {
    IEAS public immutable eas;
    ISanctionsOracle public sanctionsOracle;
    bytes32 public identitySchema;

    mapping(address attester => bool) public trustedAttester;
    mapping(uint16 country => Tier) private _countryTier;
    mapping(address account => bytes32 uid) public identityOf;

    constructor(address admin, address guardian, IEAS eas_, ISanctionsOracle oracle, bytes32 schema)
        ProtocolAccess(admin, guardian)
    {
        if (address(eas_) == address(0) || address(oracle) == address(0)) revert ZeroAddress();
        eas = eas_;
        sanctionsOracle = oracle;
        identitySchema = schema;
    }

    /// @inheritdoc IIdentityGate
    function registerIdentity(bytes32 uid) external {
        requireNotSanctioned(msg.sender);
        (bool valid, uint16 country) = _validIdentity(uid, msg.sender);
        if (!valid) revert InvalidAttestation(uid);
        identityOf[msg.sender] = uid;
        emit IdentityRegistered(msg.sender, uid, country);
    }

    /// @inheritdoc IIdentityGate
    function isSanctioned(address account) public view returns (bool) {
        return sanctionsOracle.isSanctioned(account);
    }

    /// @inheritdoc IIdentityGate
    function requireNotSanctioned(address account) public view {
        if (isSanctioned(account)) revert Sanctioned(account);
    }

    /// @inheritdoc IIdentityGate
    function borrowerProfile(address account) public view returns (Tier tier, uint16 country) {
        requireNotSanctioned(account);
        bool valid;
        (valid, country) = _validIdentity(identityOf[account], account);
        if (!valid) revert NotVerified(account);
        tier = tierOf(country);
        if (tier == Tier.Blocked) revert JurisdictionBlocked(account, country);
    }

    /// @inheritdoc IIdentityGate
    function isEligibleBorrower(address account) external view returns (bool) {
        if (isSanctioned(account)) return false;
        (bool valid, uint16 country) = _validIdentity(identityOf[account], account);
        return valid && tierOf(country) != Tier.Blocked;
    }

    /// @inheritdoc IIdentityGate
    function tierOf(uint16 country) public view returns (Tier) {
        Tier t = _countryTier[country];
        return t == Tier.None ? Tier.C : t;
    }

    /// @inheritdoc IIdentityGate
    function setCountryTier(uint16 country, Tier tier) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (tier == Tier.None) revert OutOfBounds(uint256(tier), uint256(Tier.A), uint256(Tier.Blocked));
        _countryTier[country] = tier;
        emit CountryTierSet(country, tier);
    }

    /// @inheritdoc IIdentityGate
    function setTrustedAttester(address attester, bool trusted) external onlyRole(DEFAULT_ADMIN_ROLE) {
        trustedAttester[attester] = trusted;
        emit AttesterSet(attester, trusted);
    }

    /// @inheritdoc IIdentityGate
    function setSanctionsOracle(address oracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (oracle == address(0)) revert ZeroAddress();
        sanctionsOracle = ISanctionsOracle(oracle);
        emit SanctionsOracleSet(oracle);
    }

    /// @inheritdoc IIdentityGate
    function setIdentitySchema(bytes32 schema) external onlyRole(DEFAULT_ADMIN_ROLE) {
        identitySchema = schema;
        emit IdentitySchemaSet(schema);
    }

    /// @dev Valid = exists, identity schema, trusted attester, issued to `account`, not revoked, not expired,
    /// and data decodes to a country code.
    function _validIdentity(bytes32 uid, address account) internal view returns (bool valid, uint16 country) {
        if (uid == bytes32(0)) return (false, 0);
        Attestation memory a = eas.getAttestation(uid);
        if (a.uid != uid || a.schema != identitySchema || a.recipient != account) return (false, 0);
        if (!trustedAttester[a.attester] || a.revocationTime != 0) return (false, 0);
        if (a.expirationTime != 0 && a.expirationTime <= block.timestamp) return (false, 0);
        if (a.data.length != 32) return (false, 0);
        uint256 raw = abi.decode(a.data, (uint256));
        if (raw > type(uint16).max) return (false, 0);
        return (true, uint16(raw));
    }
}
