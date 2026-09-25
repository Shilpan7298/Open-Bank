// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.35;

import {Attestation, IEAS} from "../interfaces/IEAS.sol";

/// @notice Minimal in-memory EAS for tests and local Anvil. `attest` records msg.sender as attester, like EAS.
contract MockEAS is IEAS {
    mapping(bytes32 => Attestation) private _attestations;
    uint256 private _nonce;

    function attest(bytes32 schema, address recipient, uint64 expirationTime, bytes calldata data)
        external
        returns (bytes32 uid)
    {
        uid = keccak256(abi.encode(schema, recipient, msg.sender, data, ++_nonce));
        _attestations[uid] = Attestation({
            uid: uid,
            schema: schema,
            time: uint64(block.timestamp),
            expirationTime: expirationTime,
            revocationTime: 0,
            refUID: bytes32(0),
            recipient: recipient,
            attester: msg.sender,
            revocable: true,
            data: data
        });
    }

    function revoke(bytes32 uid) external {
        Attestation storage a = _attestations[uid];
        require(a.attester == msg.sender, "MockEAS: not attester");
        require(a.revocationTime == 0, "MockEAS: revoked");
        a.revocationTime = uint64(block.timestamp);
    }

    function getAttestation(bytes32 uid) external view returns (Attestation memory) {
        return _attestations[uid];
    }
}
