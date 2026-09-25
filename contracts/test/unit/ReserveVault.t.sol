// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReserveVault} from "../../src/ReserveVault.sol";
import {IReserveVault} from "../../src/interfaces/IReserveVault.sol";
import {ProtocolAccess} from "../../src/libraries/ProtocolAccess.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";

/// @dev Stands in for LoanRegistry: reports outstanding principal and pays fees.
contract OutstandingStub {
    uint256 public totalOutstandingPrincipal;

    function set(uint256 v) external {
        totalOutstandingPrincipal = v;
    }
}

contract ReserveVaultTest is Test {
    address admin = makeAddr("timelock");
    address waterfall = makeAddr("waterfall");
    address rebate = makeAddr("rebate");
    MockUSDC usdc;
    ReserveVault reserve;
    OutstandingStub registry;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new OutstandingStub();
        reserve = new ReserveVault(admin, address(0), usdc, 150, 500, rebate);
        vm.startPrank(admin);
        reserve.setLoanRegistry(address(registry));
        reserve.grantRole(reserve.REGISTRY_ROLE(), address(registry));
        reserve.grantRole(reserve.WATERFALL_ROLE(), waterfall);
        vm.stopPrank();
        usdc.mint(address(registry), 100_000_000e6);
        vm.prank(address(registry));
        usdc.approve(address(reserve), type(uint256).max);
    }

    function _fund(uint256 principal) internal returns (uint256 fee) {
        registry.set(registry.totalOutstandingPrincipal() + principal);
        vm.prank(address(registry));
        fee = reserve.collectFee(principal);
    }

    // RV-01
    function test_fullFeeBelowCap() public {
        assertEq(_fund(10_000e6), 150e6);
        assertEq(reserve.reserveAssets(), 150e6);
        assertEq(usdc.balanceOf(address(reserve)), 150e6);
    }

    // RV-02
    function test_feeReducedAtCap() public {
        vm.prank(admin);
        reserve.setParams(200, 100, rebate); // cap 1%, fee 2%
        assertEq(_fund(10_000e6), 100e6); // cap = 100
        assertEq(_fund(10_000e6), 100e6); // cap = 200
        assertEq(reserve.reserveAssets(), 200e6);
        assertEq(reserve.quoteFee(1_000e6), 0);
    }

    // RV-03
    function test_syncRebatesExcess() public {
        _fund(10_000e6);
        _fund(10_000e6); // 300 held, cap 1000
        registry.set(4_000e6); // loans repaid: cap 200
        assertEq(reserve.sync(), 100e6);
        assertEq(usdc.balanceOf(rebate), 100e6);
        assertEq(reserve.reserveAssets(), 200e6);
        assertEq(reserve.sync(), 0);
    }

    // RV-04
    function test_coverLoss() public {
        _fund(10_000e6);
        vm.prank(waterfall);
        assertEq(reserve.coverLoss(100e6, waterfall), 100e6);
        vm.prank(waterfall);
        assertEq(reserve.coverLoss(100e6, waterfall), 50e6);
        assertEq(reserve.reserveAssets(), 0);
        assertEq(usdc.balanceOf(waterfall), 150e6);
        vm.expectRevert();
        reserve.coverLoss(1, address(this));
    }

    // RV-05
    function testFuzz_neverAboveCap(uint256[10] memory ops, uint256 seed) public {
        vm.prank(admin);
        reserve.setParams(200, 300, rebate);
        for (uint256 i; i < ops.length; i++) {
            uint256 kind = uint256(keccak256(abi.encode(seed, i))) % 3;
            if (kind == 0) {
                _fund(bound(ops[i], 1e6, 1_000_000e6));
            } else if (kind == 1) {
                uint256 out = registry.totalOutstandingPrincipal();
                registry.set(out - bound(ops[i], 0, out));
                reserve.sync();
            } else {
                vm.prank(waterfall);
                reserve.coverLoss(bound(ops[i], 0, 100_000e6), waterfall);
            }
            assertLe(reserve.reserveAssets(), reserve.cap());
            assertEq(usdc.balanceOf(address(reserve)), reserve.reserveAssets());
        }
    }

    // RV-06
    function test_paramBounds() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(ProtocolAccess.OutOfBounds.selector, 99, 100, 200));
        reserve.setParams(99, 500, rebate);
        vm.expectRevert(abi.encodeWithSelector(ProtocolAccess.OutOfBounds.selector, 201, 100, 200));
        reserve.setParams(201, 500, rebate);
        vm.expectRevert(abi.encodeWithSelector(ProtocolAccess.OutOfBounds.selector, 501, 0, 500));
        reserve.setParams(150, 501, rebate);
        vm.expectRevert(ProtocolAccess.ZeroAddress.selector);
        reserve.setParams(150, 500, address(0));
        vm.expectRevert(IReserveVault.RegistryAlreadySet.selector);
        reserve.setLoanRegistry(address(1));
        vm.stopPrank();
    }
}
