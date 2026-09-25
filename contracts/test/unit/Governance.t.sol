// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {SystemFixture} from "../utils/SystemFixture.sol";
import {DeployLib} from "../../script/DeployLib.sol";
import {ProtocolAccess} from "../../src/libraries/ProtocolAccess.sol";
import {ICreditRegistry} from "../../src/interfaces/ICreditRegistry.sol";
import {IInsuranceBasket} from "../../src/interfaces/IInsuranceBasket.sol";
import {ILoanRegistry} from "../../src/interfaces/ILoanRegistry.sol";
import {IIdentityGate} from "../../src/interfaces/IIdentityGate.sol";
import {Stage, Tier, Tranche} from "../../src/libraries/Types.sol";

contract GovernanceTest is SystemFixture {
    struct Call {
        address target;
        bytes data;
    }

    function setUp() public override {
        super.setUp();
        DeployLib.handOver(s, address(this));
    }

    function _setterCalls() internal view returns (Call[] memory c) {
        c = new Call[](19);
        c[0] = Call(address(s.gate), abi.encodeCall(s.gate.setCountryTier, (5, Tier.B)));
        c[1] = Call(address(s.gate), abi.encodeCall(s.gate.setTrustedAttester, (address(1), true)));
        c[2] = Call(address(s.gate), abi.encodeCall(s.gate.setSanctionsOracle, (address(s.sanctions))));
        c[3] = Call(address(s.gate), abi.encodeCall(s.gate.setIdentitySchema, (DeployLib.IDENTITY_SCHEMA)));
        c[4] = Call(address(s.credit), abi.encodeCall(s.credit.setRequirement, (Stage.New, Tier.A, 3_000, 6_000)));
        c[5] = Call(
            address(s.credit),
            abi.encodeCall(s.credit.setLimitParams, (Tier.A, ICreditRegistry.LimitParams(2_000e6, 2_000e6, 50_000e6)))
        );
        c[6] = Call(address(s.credit), abi.encodeCall(s.credit.setStageThresholds, (2, 4)));
        c[7] = Call(address(s.vouching), abi.encodeCall(s.vouching.setMinSlice, (10e6)));
        c[8] = Call(address(s.basket), abi.encodeCall(s.basket.setPremiumRate, (s.basket.basketIdOf(1, Tier.A), 100)));
        c[9] = Call(
            address(s.basket),
            abi.encodeCall(s.basket.setParams, (IInsuranceBasket.Params(30_000, 2_500, 30 days, 7 days, 3_000)))
        );
        c[10] = Call(address(s.reserve), abi.encodeCall(s.reserve.setParams, (150, 500, rebate)));
        c[11] = Call(address(s.scoreOracle), abi.encodeCall(s.scoreOracle.setScorer, (address(1), true)));
        c[12] = Call(address(s.scoreOracle), abi.encodeCall(s.scoreOracle.setQuorum, (2)));
        c[13] = Call(address(s.scoreOracle), abi.encodeCall(s.scoreOracle.setScoreSchema, (DeployLib.SCORE_SCHEMA)));
        c[14] = Call(
            address(s.registry),
            abi.encodeCall(
                s.registry.setParams, (ILoanRegistry.Params(3 days, 7 days, 30 days, 30 days, 730 days, 24, 400, 10, 10e6))
            )
        );
        c[15] = Call(address(s.lenderVault), abi.encodeCall(s.lenderVault.setCaps, (1_000, 9_000)));
        c[16] = Call(address(s.registry), abi.encodeCall(AccessControl.grantRole, (bytes32(0), address(1))));
        c[17] = Call(address(s.registry), abi.encodeWithSignature("unpause()"));
        c[18] = Call(address(s.basket), abi.encodeCall(AccessControl.grantRole, (s.basket.REGISTRY_ROLE(), address(1))));
    }

    // GOV-01
    function testFuzz_onlyTimelockSetsParameters(address caller) public {
        vm.assume(caller != address(s.timelock));
        Call[] memory c = _setterCalls();
        for (uint256 i; i < c.length; i++) {
            vm.prank(caller);
            (bool ok,) = c[i].target.call(c[i].data);
            assertFalse(ok, "non-timelock changed a parameter");
        }
        // The timelock itself can (unpause needs a paused module first).
        vm.prank(guardian);
        s.registry.pause();
        for (uint256 i; i < c.length; i++) {
            vm.prank(address(s.timelock));
            (bool ok,) = c[i].target.call(c[i].data);
            assertTrue(ok, "timelock call failed");
        }
    }

    // GOV-02
    function test_guardianOnlyPauses() public {
        AccessControl[12] memory m = DeployLib.modules(s);
        Call[] memory c = _setterCalls();
        for (uint256 i; i < m.length; i++) {
            vm.prank(guardian);
            ProtocolAccess(address(m[i])).pause();
            assertTrue(ProtocolAccess(address(m[i])).paused());
            vm.prank(guardian);
            vm.expectRevert();
            ProtocolAccess(address(m[i])).unpause();
        }
        for (uint256 i; i < c.length; i++) {
            vm.prank(guardian);
            (bool ok,) = c[i].target.call(c[i].data);
            assertFalse(ok, "guardian changed a parameter");
        }
        vm.prank(address(s.timelock));
        s.registry.unpause();
        assertFalse(s.registry.paused());
    }

    // GOV-03
    function test_timelockIsSoleAdmin() public view {
        AccessControl[12] memory m = DeployLib.modules(s);
        for (uint256 i; i < m.length; i++) {
            assertTrue(m[i].hasRole(bytes32(0), address(s.timelock)));
            assertFalse(m[i].hasRole(bytes32(0), address(this)));
            assertFalse(m[i].hasRole(bytes32(0), guardian));
        }
    }

    // GOV-04
    function test_changeThroughTimelock() public {
        bytes memory data = abi.encodeCall(s.scoreOracle.setQuorum, (2));
        s.timelock.schedule(address(s.scoreOracle), 0, data, 0, 0, 2 days);
        vm.expectRevert();
        s.timelock.execute(address(s.scoreOracle), 0, data, 0, 0);
        vm.warp(block.timestamp + 2 days);
        s.timelock.execute(address(s.scoreOracle), 0, data, 0, 0);
        assertEq(s.scoreOracle.quorum(), 2);
    }

    // GOV-05
    function test_pauseBlocksNewRiskNotExits() public {
        uint256 active = _activeLoan();
        uint256 open = _openLoan(borrower, P);
        AccessControl[12] memory m = DeployLib.modules(s);
        for (uint256 i; i < m.length; i++) {
            vm.prank(guardian);
            ProtocolAccess(address(m[i])).pause();
        }
        vm.prank(borrower);
        vm.expectRevert();
        s.registry.propose(P, TERM, 6, 1_500, SECTOR, 0);
        vm.prank(l3);
        vm.expectRevert();
        s.auction.placeBid(open, 100e6, 800);
        vm.prank(v1);
        vm.expectRevert();
        s.vouching.stake(open, 100e6);
        uint256 basketId = s.basket.basketIdOf(2, Tier.A);
        vm.prank(insJ);
        vm.expectRevert();
        s.basket.deposit(basketId, Tranche.Junior, 1e6);
        vm.prank(l3);
        vm.expectRevert();
        s.lenderVault.deposit(1e6, l3);

        // Exits and loss handling keep working.
        vm.prank(borrower);
        s.registry.repay(active, 50e6);
        vm.prank(l1);
        s.registry.claim(active);
        vm.warp(s.registry.loanOf(active).start + TERM + 30 days);
        s.registry.markDefault(active);
        vm.prank(borrower);
        s.registry.withdrawCollateral(active);
        vm.prank(v1);
        s.vouching.claim(active);
    }
}

contract SanctionsTest is SystemFixture {
    // SAN-01: a sanctioned address cannot open, fund, vouch, insure, deposit or receive any payout.
    function testFuzz_sanctionedBlockedEverywhere(uint8 action) public {
        action = uint8(bound(action, 0, 9));
        uint256 id = _activeLoan();
        _repayAll(id);
        uint256 bid = s.basket.basketIdOf(2, Tier.A);
        vm.prank(insJ);
        s.basket.requestWithdrawal(bid, Tranche.Junior, 1e6);
        vm.warp(block.timestamp + 40 days);
        s.basket.processWithdrawals(bid, Tranche.Junior, 1);
        uint256 open = _openLoan(borrower, P);
        uint256 proposed = _propose(borrower, P);
        _scoreLoan(proposed, borrower, 2, 0);

        address[10] memory who = [borrower, l3, v1, insJ, l3, l1, v1, insJ, borrower, borrower];
        address actor = who[action];
        s.sanctions.setSanctioned(actor, true);
        vm.startPrank(actor);
        vm.expectRevert(abi.encodeWithSelector(IIdentityGate.Sanctioned.selector, actor));
        if (action == 0) s.registry.propose(P, TERM, 6, 1_500, SECTOR, 0); // open
        else if (action == 1) s.auction.placeBid(open, 100e6, 800); // fund directly
        else if (action == 2) s.vouching.stake(open, 100e6); // vouch
        else if (action == 3) s.basket.deposit(bid, Tranche.Senior, 1e6); // insure
        else if (action == 4) s.lenderVault.deposit(1e6, actor); // fund via vault
        else if (action == 5) s.registry.claim(id); // lender payout
        else if (action == 6) s.vouching.claim(id); // voucher payout
        else if (action == 7) s.basket.claimWithdrawals(); // insurer payout
        else if (action == 8) s.registry.withdrawCollateral(id); // borrower payout
        else s.registry.open(proposed); // open backing
        vm.stopPrank();
    }
}
