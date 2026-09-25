// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CollateralEscrow} from "../../src/CollateralEscrow.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";

contract CollateralEscrowTest is Test {
    address admin = makeAddr("timelock");
    address registry = makeAddr("loanRegistry");
    address waterfall = makeAddr("waterfall");
    address borrower = makeAddr("borrower");
    MockUSDC usdc;
    CollateralEscrow escrow;

    function setUp() public {
        usdc = new MockUSDC();
        escrow = new CollateralEscrow(admin, address(0), usdc);
        vm.startPrank(admin);
        escrow.grantRole(escrow.REGISTRY_ROLE(), registry);
        escrow.grantRole(escrow.WATERFALL_ROLE(), waterfall);
        vm.stopPrank();
        usdc.mint(borrower, 1_000_000e6);
        vm.prank(borrower);
        usdc.approve(address(escrow), type(uint256).max);
    }

    // CE-01
    function test_deposit() public {
        vm.prank(registry);
        escrow.deposit(1, borrower, 300e6);
        vm.prank(registry);
        escrow.deposit(1, borrower, 200e6);
        assertEq(escrow.collateralOf(1), 500e6);
        assertEq(usdc.balanceOf(address(escrow)), 500e6);
        vm.expectRevert();
        escrow.deposit(1, borrower, 1);
    }

    // CE-02
    function test_release() public {
        vm.prank(registry);
        escrow.deposit(1, borrower, 300e6);
        vm.expectRevert();
        escrow.release(1, borrower);
        uint256 before = usdc.balanceOf(borrower);
        vm.prank(registry);
        assertEq(escrow.release(1, borrower), 300e6);
        assertEq(usdc.balanceOf(borrower) - before, 300e6);
        assertEq(escrow.collateralOf(1), 0);
    }

    // CE-03
    function testFuzz_seize(uint256 collateral, uint256 loss) public {
        collateral = bound(collateral, 0, 1_000_000e6);
        loss = bound(loss, 0, 2_000_000e6);
        vm.prank(registry);
        escrow.deposit(7, borrower, collateral);
        vm.prank(registry);
        vm.expectRevert();
        escrow.seize(7, loss, registry);
        vm.prank(waterfall);
        uint256 seized = escrow.seize(7, loss, registry);
        uint256 expected = loss < collateral ? loss : collateral;
        assertEq(seized, expected);
        assertEq(usdc.balanceOf(registry), expected);
        assertEq(escrow.collateralOf(7), collateral - expected);
        vm.prank(registry);
        assertEq(escrow.release(7, borrower), collateral - expected);
    }

    // CE-04
    function testFuzz_balanceMatchesSum(uint96[6] memory amounts, uint8 releaseMask, uint96 loss) public {
        uint256 sum;
        for (uint256 i; i < amounts.length; i++) {
            vm.prank(registry);
            escrow.deposit(i % 3, borrower, uint256(amounts[i]) % 100_000e6);
        }
        vm.prank(waterfall);
        escrow.seize(1, uint256(loss) % 200_000e6, waterfall);
        for (uint256 id; id < 3; id++) {
            if ((releaseMask >> id) & 1 == 1) {
                vm.prank(registry);
                escrow.release(id, borrower);
            }
            sum += escrow.collateralOf(id);
        }
        usdc.mint(address(escrow), 5); // donations are inert
        assertEq(usdc.balanceOf(address(escrow)) - 5, sum);
    }
}
