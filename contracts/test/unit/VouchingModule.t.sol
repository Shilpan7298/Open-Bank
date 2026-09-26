// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IdentityGate} from "../../src/IdentityGate.sol";
import {CreditRegistry} from "../../src/CreditRegistry.sol";
import {StakeVault} from "../../src/StakeVault.sol";
import {VouchingModule} from "../../src/VouchingModule.sol";
import {IVouchingModule} from "../../src/interfaces/IVouchingModule.sol";
import {IIdentityGate} from "../../src/interfaces/IIdentityGate.sol";
import {Tier} from "../../src/libraries/Types.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockEAS} from "../../src/mocks/MockEAS.sol";
import {MockSanctionsOracle} from "../../src/mocks/MockSanctionsOracle.sol";

contract VouchingFixture is Test {
    address admin = makeAddr("timelock");
    address registry = makeAddr("loanRegistry");
    address waterfall = makeAddr("waterfall");
    address borrower = makeAddr("borrower");
    address v1 = makeAddr("voucher1");
    address v2 = makeAddr("voucher2");
    address v3 = makeAddr("voucher3");

    MockUSDC usdc;
    MockSanctionsOracle oracle;
    CreditRegistry credit;
    StakeVault vault;
    VouchingModule vm_;

    uint64 deadline;

    function _deployVouching() internal {
        usdc = new MockUSDC();
        oracle = new MockSanctionsOracle();
        IdentityGate gate = new IdentityGate(admin, address(0), new MockEAS(), oracle, bytes32(0));
        credit = new CreditRegistry(admin, address(0));
        vault = new StakeVault(admin, address(0), usdc);
        vm_ = new VouchingModule(admin, address(0), vault, gate, credit, 10e6);
        vm.startPrank(admin);
        vault.grantRole(vault.DEPOSITOR_ROLE(), address(vm_));
        vm_.grantRole(vm_.REGISTRY_ROLE(), registry);
        vm_.grantRole(vm_.WATERFALL_ROLE(), waterfall);
        credit.grantRole(credit.REGISTRY_ROLE(), registry);
        vm.stopPrank();
        address[4] memory users = [v1, v2, v3, registry];
        for (uint256 i; i < users.length; i++) {
            usdc.mint(users[i], 1_000_000e6);
            vm.prank(users[i]);
            usdc.approve(address(vm_), type(uint256).max);
        }
        deadline = uint64(block.timestamp + 3 days);
    }

    function _open(uint256 loanId, uint256 maxCover) internal {
        vm.prank(registry);
        vm_.openCover(loanId, borrower, maxCover, deadline);
    }

    function _stake(address who, uint256 loanId, uint256 amount) internal {
        vm.prank(who);
        vm_.stake(loanId, amount);
    }
}

contract VouchingModuleTest is VouchingFixture {
    function setUp() public {
        _deployVouching();
    }

    // VM-01
    function test_stake() public {
        _open(1, 1_000e6);
        _stake(v1, 1, 100e6);
        _stake(v1, 1, 50e6);
        _stake(v2, 1, 200e6);
        IVouchingModule.Slice memory s = vm_.sliceOf(1, v1);
        assertEq(s.principal, 150e6);
        IVouchingModule.Cover memory c = vm_.coverOf(1);
        assertEq(c.coverPrincipal, 350e6);
        assertEq(vault.balanceOf(address(vm_)), c.shares);
        assertEq(vm_.coverValue(1), 350e6);
        assertEq(usdc.balanceOf(address(vault)), 350e6);
        assertEq(vm_.statsOf(v1).backed, 1);
    }

    // VM-02
    function test_stake_forbiddenVouchers() public {
        _open(1, 1_000e6);
        usdc.mint(borrower, 100e6);
        vm.startPrank(borrower);
        usdc.approve(address(vm_), type(uint256).max);
        vm.expectRevert(IVouchingModule.SelfVouch.selector);
        vm_.stake(1, 100e6);
        vm.stopPrank();

        oracle.setSanctioned(v1, true);
        vm.prank(v1);
        vm.expectRevert(abi.encodeWithSelector(IIdentityGate.Sanctioned.selector, v1));
        vm_.stake(1, 100e6);

        vm.startPrank(registry);
        credit.onLoanFunded(v2, Tier.A, 100e6);
        credit.onLoanDefaulted(v2, 100e6);
        vm.stopPrank();
        vm.prank(v2);
        vm.expectRevert(abi.encodeWithSelector(IVouchingModule.DelinquentVoucher.selector, v2));
        vm_.stake(1, 100e6);
    }

    // VM-03
    function test_minSliceAndCap() public {
        _open(1, 300e6);
        vm.prank(v1);
        vm.expectRevert(abi.encodeWithSelector(IVouchingModule.BelowMinSlice.selector, 9e6, 10e6));
        vm_.stake(1, 9e6);
        _stake(v1, 1, 250e6);
        vm.prank(v2);
        vm.expectRevert(abi.encodeWithSelector(IVouchingModule.CoverCapExceeded.selector, 51e6, 50e6));
        vm_.stake(1, 51e6);
        _stake(v2, 1, 50e6);
    }

    // VM-04: stakes are binding while backing (security M-1) and after lock; withdrawable once cancelled.
    function test_unstakeOnlyWhenCancelled() public {
        _open(1, 1_000e6);
        uint256 before = usdc.balanceOf(v1);
        _stake(v1, 1, 100e6);
        vm.prank(v1);
        vm.expectRevert(abi.encodeWithSelector(IVouchingModule.WrongState.selector, 1, IVouchingModule.CoverState.Open));
        vm_.unstake(1);

        vm.prank(registry);
        vm_.lockCover(1);
        vm.prank(v1);
        vm.expectRevert(abi.encodeWithSelector(IVouchingModule.WrongState.selector, 1, IVouchingModule.CoverState.Locked));
        vm_.unstake(1);
        vm.prank(v1);
        vm.expectRevert();
        vm_.claim(1);

        vm.prank(registry);
        vm_.cancelCover(1); // funded loan never drawn down
        vm.prank(v1);
        vm_.unstake(1);
        assertEq(usdc.balanceOf(v1), before); // stake returned in full
        assertEq(vm_.coverOf(1).coverPrincipal, 0);
    }

    // Security M-1: a griefer cannot fill the cover and pull it out before the deadline.
    function test_coverCannotBePulledBeforeDeadline() public {
        _open(1, 600e6);
        _stake(v1, 1, 600e6); // fills the whole cap
        vm.warp(deadline - 1);
        vm.prank(v1);
        vm.expectRevert();
        vm_.unstake(1);
        assertEq(vm_.coverOf(1).coverPrincipal, 600e6);
    }

    function test_unstakeClosedAfterDeadline() public {
        _open(1, 1_000e6);
        _stake(v1, 1, 100e6);
        vm.warp(deadline);
        vm.prank(v1);
        vm.expectRevert();
        vm_.unstake(1);
    }

    // VM-05
    function test_lockCover() public {
        _open(1, 1_000e6);
        _stake(v1, 1, 100e6);
        _stake(v2, 1, 300e6);
        vm.prank(registry);
        assertEq(vm_.lockCover(1), 400e6);
        vm.prank(v3);
        vm.expectRevert(abi.encodeWithSelector(IVouchingModule.WrongState.selector, 1, IVouchingModule.CoverState.Locked));
        vm_.stake(1, 100e6);

        _open(2, 1_000e6);
        vm.warp(deadline);
        vm.prank(v3);
        vm.expectRevert(IVouchingModule.DeadlinePassed.selector);
        vm_.stake(2, 100e6);
    }

    // VM-06
    function test_releaseWithYieldAndPremium() public {
        _open(1, 1_000e6);
        _stake(v1, 1, 100e6);
        _stake(v2, 1, 300e6);
        vm.prank(registry);
        vm_.lockCover(1);
        usdc.mint(address(vault), 40e6); // base yield, 10% on 400
        vm.startPrank(registry);
        vm_.addPremium(1, 8e6);
        vm_.addPremium(1, 12e6);
        vm_.releaseCover(1);
        vm.stopPrank();

        uint256 b1 = usdc.balanceOf(v1);
        vm.prank(v1);
        uint256 got1 = vm_.claim(1);
        uint256 b2 = usdc.balanceOf(v2);
        vm.prank(v2);
        uint256 got2 = vm_.claim(1);
        assertEq(usdc.balanceOf(v1) - b1, got1);
        assertEq(usdc.balanceOf(v2) - b2, got2);
        assertApproxEqAbs(got1, 100e6 + 10e6 + 5e6, 2);
        assertApproxEqAbs(got2, 300e6 + 30e6 + 15e6, 2);
        assertLe(got1 + got2, 460e6);
        assertEq(vm_.statsOf(v1).repaid, 1);
        vm.prank(v1);
        vm.expectRevert(IVouchingModule.AlreadyClaimed.selector);
        vm_.claim(1);
    }

    // VM-07
    function test_partialLossProRata() public {
        _open(1, 1_000e6);
        _stake(v1, 1, 100e6);
        _stake(v2, 1, 300e6);
        vm.startPrank(registry);
        vm_.lockCover(1);
        vm_.addPremium(1, 4e6);
        vm.stopPrank();
        vm.prank(waterfall);
        uint256 absorbed = vm_.absorbLoss(1, 100e6, waterfall);
        assertEq(absorbed, 100e6);
        assertEq(usdc.balanceOf(waterfall), 100e6);

        vm.prank(v1);
        uint256 got1 = vm_.claim(1);
        vm.prank(v2);
        uint256 got2 = vm_.claim(1);
        assertApproxEqAbs(got1, 75e6 + 1e6, 2);
        assertApproxEqAbs(got2, 225e6 + 3e6, 2);
        assertEq(vm_.statsOf(v1).defaulted, 1);
        assertApproxEqAbs(vm_.statsOf(v2).lost, 75e6, 2);
    }

    // VM-10
    function test_stats() public {
        _open(1, 1_000e6);
        _open(2, 1_000e6);
        _stake(v1, 1, 100e6);
        _stake(v1, 2, 100e6);
        vm.startPrank(registry);
        vm_.lockCover(1);
        vm_.lockCover(2);
        vm_.releaseCover(1);
        vm.stopPrank();
        vm.prank(waterfall);
        vm_.absorbLoss(2, 1_000e6, waterfall);
        vm.startPrank(v1);
        vm_.claim(1);
        vm_.claim(2);
        vm.stopPrank();
        IVouchingModule.VoucherStats memory st = vm_.statsOf(v1);
        assertEq(st.backed, 2);
        assertEq(st.repaid, 1);
        assertEq(st.defaulted, 1);
        assertEq(st.lost, 100e6);
    }

    // VM-11
    function test_sanctionedCannotClaim() public {
        _open(1, 1_000e6);
        _stake(v1, 1, 100e6);
        vm.startPrank(registry);
        vm_.lockCover(1);
        vm_.releaseCover(1);
        vm.stopPrank();
        oracle.setSanctioned(v1, true);
        vm.prank(v1);
        vm.expectRevert(abi.encodeWithSelector(IIdentityGate.Sanctioned.selector, v1));
        vm_.claim(1);
    }

    // VM-08
    function testFuzz_absorbLoss(uint256 a1, uint256 a2, uint256 a3, uint256 yield_, uint256 loss) public {
        a1 = bound(a1, 10e6, 300_000e6);
        a2 = bound(a2, 10e6, 300_000e6);
        a3 = bound(a3, 10e6, 300_000e6);
        yield_ = bound(yield_, 0, 50_000e6);
        loss = bound(loss, 0, 1_200_000e6);
        _open(1, 900_000e6);
        _stake(v1, 1, a1);
        _stake(v2, 1, a2);
        _stake(v3, 1, a3);
        vm.prank(registry);
        vm_.lockCover(1);
        usdc.mint(address(vault), yield_);
        uint256 value = vm_.coverValue(1);

        vm.prank(waterfall);
        uint256 absorbed = vm_.absorbLoss(1, loss, waterfall);
        assertEq(absorbed, loss < value ? loss : value);
        assertEq(usdc.balanceOf(waterfall), absorbed);

        uint256 paid;
        address[3] memory vs = [v1, v2, v3];
        for (uint256 i; i < 3; i++) {
            vm.prank(vs[i]);
            paid += vm_.claim(1);
        }
        assertLe(paid + absorbed, value); // rounding never pays out more than the stake was worth
        assertApproxEqAbs(paid + absorbed, value, 3);
    }

    function test_onlyRolesCallHooks() public {
        vm.expectRevert();
        vm_.openCover(1, borrower, 1, deadline);
        _open(1, 100e6);
        vm.expectRevert();
        vm_.lockCover(1);
        vm.expectRevert();
        vm_.absorbLoss(1, 1, address(this));
    }
}

contract StakeVaultTest is Test {
    // SV-01
    function test_onlyDepositorAndYield() public {
        address admin = makeAddr("timelock");
        MockUSDC usdc = new MockUSDC();
        StakeVault vault = new StakeVault(admin, address(0), usdc);
        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(StakeVault.NotDepositor.selector, address(this)));
        vault.deposit(100e6, address(this));
        vm.expectRevert(abi.encodeWithSelector(StakeVault.NotDepositor.selector, address(this)));
        vault.mint(1e12, address(this));

        bytes32 role = vault.DEPOSITOR_ROLE();
        vm.prank(admin);
        vault.grantRole(role, address(this));
        vault.deposit(100e6, address(this));
        usdc.mint(address(vault), 10e6);
        assertApproxEqAbs(vault.previewRedeem(vault.balanceOf(address(this))), 110e6, 1);
    }
}
