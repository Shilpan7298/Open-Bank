// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {CreditRegistry} from "../../src/CreditRegistry.sol";
import {ICreditRegistry} from "../../src/interfaces/ICreditRegistry.sol";
import {ProtocolAccess} from "../../src/libraries/ProtocolAccess.sol";
import {Stage, Tier} from "../../src/libraries/Types.sol";

contract CreditRegistryTest is Test {
    address admin = makeAddr("timelock");
    address registry = makeAddr("loanRegistry");
    address alice = makeAddr("alice");
    CreditRegistry cr;

    function setUp() public {
        cr = new CreditRegistry(admin, makeAddr("guardian"));
        bytes32 role = cr.REGISTRY_ROLE();
        vm.prank(admin);
        cr.grantRole(role, registry);
    }

    function _repayLoan(address who, uint256 p) internal {
        vm.startPrank(registry);
        cr.onLoanFunded(who, Tier.A, p);
        cr.onLoanRepaid(who, p);
        vm.stopPrank();
    }

    // CR-01
    function test_newBorrower() public view {
        assertEq(uint8(cr.stageOf(alice)), uint8(Stage.New));
        assertEq(cr.creditLimit(alice, Tier.A), 2_000e6);
        assertEq(cr.creditLimit(alice, Tier.B), 1_000e6);
        assertEq(cr.creditLimit(alice, Tier.C), 500e6);
        assertEq(cr.availableCredit(alice, Tier.A), 2_000e6);
    }

    // CR-02
    function test_limitStepsUpAndStages() public {
        _repayLoan(alice, 1_000e6);
        assertEq(uint8(cr.stageOf(alice)), uint8(Stage.New));
        assertEq(cr.creditLimit(alice, Tier.A), 4_000e6);
        _repayLoan(alice, 1_000e6);
        assertEq(uint8(cr.stageOf(alice)), uint8(Stage.Established));
        _repayLoan(alice, 1_000e6);
        _repayLoan(alice, 1_000e6);
        assertEq(uint8(cr.stageOf(alice)), uint8(Stage.Proven));
        for (uint256 i; i < 40; i++) _repayLoan(alice, 1e6);
        assertEq(cr.creditLimit(alice, Tier.A), 50_000e6); // capped
        assertEq(cr.creditLimit(alice, Tier.C), 5_000e6);
    }

    // CR-03
    function test_defaultZeroesLimit() public {
        _repayLoan(alice, 1_000e6);
        vm.startPrank(registry);
        cr.onLoanFunded(alice, Tier.A, 1_000e6);
        cr.onLoanDefaulted(alice, 1_000e6);
        vm.stopPrank();
        assertEq(cr.creditLimit(alice, Tier.A), 0);
        assertEq(cr.availableCredit(alice, Tier.A), 0);
        ICreditRegistry.History memory h = cr.historyOf(alice);
        assertEq(h.defaultedLoans, 1);
        assertEq(h.outstandingPrincipal, 0);
    }

    // CR-04
    function test_fundedReservesAndReleases() public {
        vm.startPrank(registry);
        cr.onLoanFunded(alice, Tier.A, 1_500e6);
        assertEq(cr.availableCredit(alice, Tier.A), 500e6);
        vm.expectRevert(
            abi.encodeWithSelector(ICreditRegistry.CreditLimitExceeded.selector, alice, 501e6, 500e6)
        );
        cr.onLoanFunded(alice, Tier.A, 501e6);
        cr.onLoanCancelled(alice, 1_500e6);
        assertEq(cr.availableCredit(alice, Tier.A), 2_000e6);
        cr.onLoanFunded(alice, Tier.A, 2_000e6);
        cr.onLoanRepaid(alice, 2_000e6);
        vm.stopPrank();
        assertEq(cr.availableCredit(alice, Tier.A), 4_000e6);
    }

    // CR-05
    function test_requirementsTable() public {
        (uint16 c, uint16 v) = cr.requirementsFor(alice, Tier.A);
        assertEq(c, 3_000);
        assertEq(v, 6_000);
        (c, v) = cr.requirementsFor(alice, Tier.C);
        assertEq(c, 4_000);
        assertEq(v, 9_000);
        for (uint256 i; i < 4; i++) _repayLoan(alice, 1e6);
        (c, v) = cr.requirementsFor(alice, Tier.A);
        assertEq(c, 2_000);
        assertEq(v, 1_000);
        vm.expectRevert();
        cr.requirementsFor(alice, Tier.Blocked);
    }

    // CR-06
    function test_setRequirementBounds() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(ProtocolAccess.OutOfBounds.selector, 1_999, 2_000, 10_000));
        cr.setRequirement(Stage.Proven, Tier.A, 1_999, 1_000);
        vm.expectRevert(abi.encodeWithSelector(ProtocolAccess.OutOfBounds.selector, 9_001, 0, 9_000));
        cr.setRequirement(Stage.Proven, Tier.A, 2_000, 9_001);
        cr.setRequirement(Stage.Proven, Tier.A, 2_000, 0);
        vm.stopPrank();
    }

    // CR-07
    function testFuzz_outstandingWithinLimit(uint256[8] memory amounts, uint8 repayMask) public {
        vm.startPrank(registry);
        uint256[8] memory funded;
        for (uint256 i; i < amounts.length; i++) {
            uint256 p = bound(amounts[i], 1, 10_000e6);
            uint256 avail = cr.availableCredit(alice, Tier.B);
            if (p > avail) {
                vm.expectRevert();
                cr.onLoanFunded(alice, Tier.B, p);
            } else {
                cr.onLoanFunded(alice, Tier.B, p);
                funded[i] = p;
            }
            assertLe(cr.historyOf(alice).outstandingPrincipal, cr.creditLimit(alice, Tier.B));
            if (funded[i] > 0 && (repayMask >> i) & 1 == 1) cr.onLoanRepaid(alice, funded[i]);
        }
        vm.stopPrank();
    }

    // CR-08
    function test_onlyRegistry(address caller) public {
        vm.assume(caller != registry);
        vm.startPrank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, cr.REGISTRY_ROLE())
        );
        cr.onLoanFunded(alice, Tier.A, 1);
        vm.expectRevert();
        cr.onLoanRepaid(alice, 0);
        vm.expectRevert();
        cr.onLoanDefaulted(alice, 0);
        vm.expectRevert();
        cr.onLoanCancelled(alice, 0);
        vm.stopPrank();
    }
}
