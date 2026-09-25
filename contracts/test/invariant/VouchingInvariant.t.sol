// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VouchingFixture} from "../unit/VouchingModule.t.sol";
import {VouchingModule} from "../../src/VouchingModule.sol";
import {StakeVault} from "../../src/StakeVault.sol";
import {IVouchingModule} from "../../src/interfaces/IVouchingModule.sol";

contract VouchingHandler is Test {
    VouchingModule public vm_;
    StakeVault public vault;
    address public registry;
    address[3] public vouchers;
    uint256 constant LOAN = 1;

    bool public locked;
    uint256 public lockedShares;
    uint256 public lockedPrincipal;
    uint256 public leaks; // successful unstake/claim while locked

    constructor(VouchingModule m, StakeVault v, address reg, address[3] memory vs) {
        vm_ = m;
        vault = v;
        registry = reg;
        vouchers = vs;
    }

    function stake(uint256 who, uint256 amount) external {
        address v = vouchers[who % 3];
        amount = bound(amount, 10e6, 50_000e6);
        vm.prank(v);
        try vm_.stake(LOAN, amount) {} catch {}
    }

    function unstake(uint256 who) external {
        address v = vouchers[who % 3];
        vm.prank(v);
        try vm_.unstake(LOAN) {
            if (locked) leaks++;
        } catch {}
    }

    function claim(uint256 who) external {
        address v = vouchers[who % 3];
        vm.prank(v);
        try vm_.claim(LOAN) {
            if (locked) leaks++;
        } catch {}
    }

    function lock() external {
        if (locked) return;
        vm.prank(registry);
        vm_.lockCover(LOAN);
        locked = true;
        IVouchingModule.Cover memory c = vm_.coverOf(LOAN);
        lockedShares = c.shares;
        lockedPrincipal = c.coverPrincipal;
    }

    function addYield(uint256 amount) external {
        amount = bound(amount, 0, 1_000e6);
        deal(address(vault.asset()), address(vault), vault.totalAssets() + amount);
    }
}

/// VM-09 / INV-03: stakes backing a Locked loan can never be withdrawn or claimed.
contract VouchingInvariantTest is VouchingFixture {
    VouchingHandler handler;

    function setUp() public {
        _deployVouching();
        _open(1, 1_000_000e6);
        handler = new VouchingHandler(vm_, vault, registry, [v1, v2, v3]);
        address[3] memory vs = [v1, v2, v3];
        for (uint256 i; i < 3; i++) {
            vm.prank(vs[i]);
            usdc.approve(address(vm_), type(uint256).max);
        }
        targetContract(address(handler));
    }

    function invariant_lockedStakeStays() public view {
        assertEq(handler.leaks(), 0);
        if (handler.locked()) {
            IVouchingModule.Cover memory c = vm_.coverOf(1);
            assertEq(uint8(c.state), uint8(IVouchingModule.CoverState.Locked));
            assertEq(c.shares, handler.lockedShares());
            assertEq(c.coverPrincipal, handler.lockedPrincipal());
            assertGe(vault.balanceOf(address(vm_)), handler.lockedShares());
        }
    }

    function invariant_sharesAccounted() public view {
        IVouchingModule.Cover memory c = vm_.coverOf(1);
        assertEq(vault.balanceOf(address(vm_)), c.shares);
        uint256 sum;
        address[3] memory vs = [v1, v2, v3];
        for (uint256 i; i < 3; i++) sum += vm_.sliceOf(1, vs[i]).shares;
        assertEq(sum, c.shares);
    }
}
