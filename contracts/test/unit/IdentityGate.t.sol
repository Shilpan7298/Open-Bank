// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IdentityGate} from "../../src/IdentityGate.sol";
import {IIdentityGate} from "../../src/interfaces/IIdentityGate.sol";
import {Tier} from "../../src/libraries/Types.sol";
import {MockEAS} from "../../src/mocks/MockEAS.sol";
import {MockSanctionsOracle} from "../../src/mocks/MockSanctionsOracle.sol";

contract IdentityGateTest is Test {
    bytes32 constant SCHEMA = keccak256("OBP.identity.v1");
    address admin = makeAddr("timelock");
    address guardian = makeAddr("guardian");
    address attester = makeAddr("attester");
    address alice = makeAddr("alice");

    MockEAS eas;
    MockSanctionsOracle oracle;
    IdentityGate gate;

    function setUp() public {
        eas = new MockEAS();
        oracle = new MockSanctionsOracle();
        gate = new IdentityGate(admin, guardian, eas, oracle, SCHEMA);
        vm.prank(admin);
        gate.setTrustedAttester(attester, true);
    }

    function _attest(address from, bytes32 schema, address to, uint64 expiry, uint16 country) internal returns (bytes32) {
        vm.prank(from);
        return eas.attest(schema, to, expiry, abi.encode(uint256(country), keccak256(abi.encode("person", to))));
    }

    function _register(address who, uint16 country) internal returns (bytes32 uid) {
        uid = _attest(attester, SCHEMA, who, 0, country);
        vm.prank(who);
        gate.registerIdentity(uid);
    }

    // IG-01
    function test_registerIdentity_valid() public {
        bytes32 uid = _register(alice, 840);
        assertEq(gate.identityOf(alice), uid);
        (Tier tier, uint16 country) = gate.borrowerProfile(alice);
        assertEq(country, 840);
        assertEq(uint8(tier), uint8(Tier.C)); // unmapped country defaults to C
        assertTrue(gate.isEligibleBorrower(alice));
    }

    // IG-02
    function test_registerIdentity_rejectsInvalid() public {
        bytes32 wrongSchema = _attest(attester, keccak256("other"), alice, 0, 1);
        bytes32 untrusted = _attest(makeAddr("mallory"), SCHEMA, alice, 0, 1);
        bytes32 otherRecipient = _attest(attester, SCHEMA, makeAddr("bob"), 0, 1);
        bytes32 expired = _attest(attester, SCHEMA, alice, uint64(block.timestamp + 1), 1);
        bytes32 revoked = _attest(attester, SCHEMA, alice, 0, 1);
        vm.prank(attester);
        eas.revoke(revoked);
        vm.warp(block.timestamp + 2);

        bytes32[5] memory bad = [wrongSchema, untrusted, otherRecipient, expired, revoked];
        for (uint256 i; i < bad.length; i++) {
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(IIdentityGate.InvalidAttestation.selector, bad[i]));
            gate.registerIdentity(bad[i]);
        }
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IIdentityGate.InvalidAttestation.selector, bytes32(uint256(123))));
        gate.registerIdentity(bytes32(uint256(123)));
    }

    // IG-03
    function test_borrowerProfile_revokedOrUntrusted() public {
        bytes32 uid = _register(alice, 1);
        vm.prank(attester);
        eas.revoke(uid);
        vm.expectRevert(abi.encodeWithSelector(IIdentityGate.NotVerified.selector, alice));
        gate.borrowerProfile(alice);
        assertFalse(gate.isEligibleBorrower(alice));

        address bob = makeAddr("bob");
        _register(bob, 1);
        vm.prank(admin);
        gate.setTrustedAttester(attester, false);
        vm.expectRevert(abi.encodeWithSelector(IIdentityGate.NotVerified.selector, bob));
        gate.borrowerProfile(bob);
    }

    // IG-04
    function test_tiers() public {
        vm.startPrank(admin);
        gate.setCountryTier(1, Tier.A);
        gate.setCountryTier(2, Tier.B);
        gate.setCountryTier(3, Tier.Blocked);
        vm.stopPrank();
        assertEq(uint8(gate.tierOf(1)), uint8(Tier.A));
        assertEq(uint8(gate.tierOf(2)), uint8(Tier.B));
        assertEq(uint8(gate.tierOf(99)), uint8(Tier.C));

        _register(alice, 3);
        vm.expectRevert(abi.encodeWithSelector(IIdentityGate.JurisdictionBlocked.selector, alice, uint16(3)));
        gate.borrowerProfile(alice);
        assertFalse(gate.isEligibleBorrower(alice));
    }

    // IG-05
    function test_sanctioned() public {
        _register(alice, 1);
        oracle.setSanctioned(alice, true);
        vm.expectRevert(abi.encodeWithSelector(IIdentityGate.Sanctioned.selector, alice));
        gate.borrowerProfile(alice);
        vm.expectRevert(abi.encodeWithSelector(IIdentityGate.Sanctioned.selector, alice));
        gate.requireNotSanctioned(alice);
        assertFalse(gate.isEligibleBorrower(alice));

        address bob = makeAddr("bob");
        bytes32 uid = _attest(attester, SCHEMA, bob, 0, 1);
        oracle.setSanctioned(bob, true);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IIdentityGate.Sanctioned.selector, bob));
        gate.registerIdentity(uid);
    }

    // IG-06
    function testFuzz_requireNotSanctioned(address who, bool listed) public {
        oracle.setSanctioned(who, listed);
        if (listed) vm.expectRevert(abi.encodeWithSelector(IIdentityGate.Sanctioned.selector, who));
        gate.requireNotSanctioned(who);
        assertEq(gate.isSanctioned(who), listed);
    }

    // IG-07
    function test_blockedCountryReopens() public {
        vm.prank(admin);
        gate.setCountryTier(7, Tier.Blocked);
        _register(alice, 7);
        assertFalse(gate.isEligibleBorrower(alice));
        vm.prank(admin);
        gate.setCountryTier(7, Tier.B);
        (Tier tier,) = gate.borrowerProfile(alice);
        assertEq(uint8(tier), uint8(Tier.B));
    }

    function test_setCountryTier_rejectsNone() public {
        vm.prank(admin);
        vm.expectRevert();
        gate.setCountryTier(1, Tier.None);
    }
}
