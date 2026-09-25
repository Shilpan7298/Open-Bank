// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IdentityGate} from "../../src/IdentityGate.sol";
import {CreditRegistry} from "../../src/CreditRegistry.sol";
import {CollateralEscrow} from "../../src/CollateralEscrow.sol";
import {StakeVault} from "../../src/StakeVault.sol";
import {VouchingModule} from "../../src/VouchingModule.sol";
import {InsuranceBasket} from "../../src/InsuranceBasket.sol";
import {ReserveVault} from "../../src/ReserveVault.sol";
import {LossWaterfall} from "../../src/LossWaterfall.sol";
import {ILossWaterfall} from "../../src/interfaces/ILossWaterfall.sol";
import {Tier, Tranche} from "../../src/libraries/Types.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockEAS} from "../../src/mocks/MockEAS.sol";
import {MockSanctionsOracle} from "../../src/mocks/MockSanctionsOracle.sol";

/// @dev Plays the loan registry: reports outstanding principal and calls every hook.
contract RegistryStub {
    uint256 public totalOutstandingPrincipal = type(uint128).max;
}

contract LossWaterfallTest is Test {
    address admin = makeAddr("timelock");
    address borrower = makeAddr("borrower");
    address voucher = makeAddr("voucher");
    address insurerJ = makeAddr("insurerJ");
    address insurerS = makeAddr("insurerS");
    MockUSDC usdc;
    CollateralEscrow escrow;
    StakeVault vault;
    VouchingModule vouching;
    InsuranceBasket basket;
    ReserveVault reserve;
    LossWaterfall waterfall;
    address registry;
    uint256 B;

    function setUp() public {
        usdc = new MockUSDC();
        IdentityGate gate = new IdentityGate(admin, address(0), new MockEAS(), new MockSanctionsOracle(), bytes32(0));
        CreditRegistry credit = new CreditRegistry(admin, address(0));
        escrow = new CollateralEscrow(admin, address(0), usdc);
        vault = new StakeVault(admin, address(0), usdc);
        vouching = new VouchingModule(admin, address(0), vault, gate, credit, 1);
        basket = new InsuranceBasket(admin, address(0), usdc, gate);
        reserve = new ReserveVault(admin, address(0), usdc, 200, 500, makeAddr("rebate"));
        waterfall = new LossWaterfall(admin, address(0), escrow, vouching, basket, reserve);
        registry = address(new RegistryStub());
        B = basket.basketIdOf(3, Tier.B);

        vm.startPrank(admin);
        reserve.setLoanRegistry(registry);
        vault.grantRole(vault.DEPOSITOR_ROLE(), address(vouching));
        escrow.grantRole(escrow.REGISTRY_ROLE(), registry);
        escrow.grantRole(escrow.WATERFALL_ROLE(), address(waterfall));
        vouching.grantRole(vouching.REGISTRY_ROLE(), registry);
        vouching.grantRole(vouching.WATERFALL_ROLE(), address(waterfall));
        basket.grantRole(basket.REGISTRY_ROLE(), registry);
        basket.grantRole(basket.WATERFALL_ROLE(), address(waterfall));
        reserve.grantRole(reserve.REGISTRY_ROLE(), registry);
        reserve.grantRole(reserve.WATERFALL_ROLE(), address(waterfall));
        waterfall.grantRole(waterfall.REGISTRY_ROLE(), registry);
        vm.stopPrank();

        address[5] memory users = [borrower, voucher, insurerJ, insurerS, registry];
        address[4] memory spenders = [address(escrow), address(vouching), address(basket), address(reserve)];
        for (uint256 i; i < users.length; i++) {
            usdc.mint(users[i], 1e15);
            for (uint256 k; k < spenders.length; k++) {
                vm.prank(users[i]);
                usdc.approve(spenders[k], type(uint256).max);
            }
        }
    }

    struct Layers {
        uint256 collateral;
        uint256 stake;
        uint256 junior;
        uint256 senior;
        uint256 exposure;
        uint256 reserve;
    }

    function _setup(uint256 loanId, Layers memory l) internal {
        vm.startPrank(registry);
        if (l.collateral > 0) escrow.deposit(loanId, borrower, l.collateral);
        vouching.openCover(loanId, borrower, type(uint128).max, uint64(block.timestamp + 1));
        vm.stopPrank();
        if (l.stake > 0) {
            vm.prank(voucher);
            vouching.stake(loanId, l.stake);
        }
        vm.prank(registry);
        vouching.lockCover(loanId);
        if (l.junior > 0) {
            vm.prank(insurerJ);
            basket.deposit(B, Tranche.Junior, l.junior);
        }
        if (l.senior > 0) {
            vm.prank(insurerS);
            basket.deposit(B, Tranche.Senior, l.senior);
        }
        if (l.exposure > 0) {
            vm.prank(registry);
            basket.assignCover(loanId, B, l.exposure, 1, 1);
        }
        if (l.reserve > 0) {
            // collect a fee large enough to seed the reserve: fee = 2% of principal
            vm.prank(registry);
            reserve.collectFee(l.reserve * 50);
        }
    }

    function _default(uint256 loanId, uint256 loss) internal returns (ILossWaterfall.Allocation memory a) {
        return _default(loanId, loss, loss); // the whole loss is unpaid principal
    }

    function _default(uint256 loanId, uint256 loss, uint256 insurable)
        internal
        returns (ILossWaterfall.Allocation memory a)
    {
        uint256 before = usdc.balanceOf(registry);
        vm.prank(registry);
        a = waterfall.executeDefault(loanId, loss, insurable);
        assertEq(usdc.balanceOf(registry) - before, loss - a.lenderLoss); // every absorbed unit reached lenders
        assertEq(
            a.collateral + a.vouchers + a.basketJunior + a.basketSenior + a.reserve + a.lenderLoss, loss
        );
    }

    // LW-01
    function test_collateralOnly() public {
        _setup(1, Layers(500e6, 300e6, 1_000e6, 1_000e6, 400e6, 100e6));
        ILossWaterfall.Allocation memory a = _default(1, 400e6);
        assertEq(a.collateral, 400e6);
        assertEq(a.vouchers + a.basketJunior + a.basketSenior + a.reserve + a.lenderLoss, 0);
        assertEq(escrow.collateralOf(1), 100e6); // remainder stays for the borrower
    }

    // LW-02
    function test_collateralThenVouchers() public {
        _setup(1, Layers(500e6, 300e6, 1_000e6, 1_000e6, 400e6, 100e6));
        ILossWaterfall.Allocation memory a = _default(1, 700e6);
        assertEq(a.collateral, 500e6);
        assertEq(a.vouchers, 200e6);
        assertEq(a.basketJunior + a.basketSenior + a.reserve + a.lenderLoss, 0);
    }

    // LW-03
    function test_basketJuniorThenSenior() public {
        _setup(1, Layers(500e6, 300e6, 100e6, 1_000e6, 400e6, 100e6));
        ILossWaterfall.Allocation memory a = _default(1, 1_150e6);
        assertEq(a.collateral, 500e6);
        assertEq(a.vouchers, 300e6);
        assertEq(a.basketJunior, 100e6);
        assertEq(a.basketSenior, 250e6);
        assertEq(a.reserve + a.lenderLoss, 0);
    }

    // LW-04
    function test_reserveAfterBasket() public {
        _setup(1, Layers(500e6, 300e6, 100e6, 1_000e6, 400e6, 100e6));
        ILossWaterfall.Allocation memory a = _default(1, 1_250e6);
        assertEq(a.basketJunior + a.basketSenior, 400e6); // capped at the loan's exposure
        assertEq(a.reserve, 50e6);
        assertEq(a.lenderLoss, 0);
    }

    // LW-05
    function test_lendersLast() public {
        _setup(1, Layers(500e6, 300e6, 100e6, 1_000e6, 400e6, 100e6));
        ILossWaterfall.Allocation memory a = _default(1, 2_000e6);
        assertEq(a.collateral, 500e6);
        assertEq(a.vouchers, 300e6);
        assertEq(a.basketJunior + a.basketSenior, 400e6);
        assertEq(a.reserve, 100e6);
        assertEq(a.lenderLoss, 700e6);
    }

    // LW-07
    function test_oncePerLoanRegistryOnly() public {
        _setup(1, Layers(500e6, 0, 0, 0, 0, 0));
        vm.expectRevert();
        waterfall.executeDefault(1, 1, 1);
        vm.prank(registry);
        waterfall.executeDefault(1, 10e6, 10e6);
        vm.prank(registry);
        vm.expectRevert(abi.encodeWithSelector(ILossWaterfall.AlreadyAllocated.selector, 1));
        waterfall.executeDefault(1, 10e6, 10e6);
        assertEq(waterfall.allocationOf(1).collateral, 10e6);
    }

    // LW-08 (security H-1): insurance and the reserve never pay interest, only unpaid principal.
    function test_interestNotInsured() public {
        _setup(1, Layers(500e6, 300e6, 1_000e6, 1_000e6, 400e6, 100e6));
        // Claim 1500, of which 1000 is unpaid principal: borrower layers take 800, insurers at most 200.
        ILossWaterfall.Allocation memory a = _default(1, 1_500e6, 1_000e6);
        assertEq(a.collateral + a.vouchers, 800e6);
        assertEq(a.basketJunior + a.basketSenior, 200e6);
        assertEq(a.reserve, 0);
        assertEq(a.lenderLoss, 500e6); // interest risk stays with lenders who chose the rate
    }

    // LW-06
    function testFuzz_strictOrder(Layers memory l, uint256 loss, uint256 insurable) public {
        l.collateral = bound(l.collateral, 0, 1_000_000e6);
        l.stake = bound(l.stake, 0, 1_000_000e6);
        l.junior = bound(l.junior, 0, 1_000_000e6);
        l.senior = bound(l.senior, 0, 1_000_000e6);
        uint256 cap = (l.junior + l.senior) * 3 / 4; // one key may use at most 25% of 3x capital
        l.exposure = bound(l.exposure, 0, cap);
        l.reserve = bound(l.reserve, 0, 100_000e6);
        loss = bound(loss, 0, 5_000_000e6);
        insurable = bound(insurable, 0, loss);
        _setup(1, l);
        uint256 stakeValue = vouching.coverValue(1);
        uint256 reserveAssets = reserve.reserveAssets();

        ILossWaterfall.Allocation memory a = _default(1, loss, insurable);

        uint256 rem = loss;
        assertEq(a.collateral, _min(rem, l.collateral));
        rem -= a.collateral;
        assertEq(a.vouchers, _min(rem, stakeValue));
        rem -= a.vouchers;
        uint256 borrowerSide = a.collateral + a.vouchers;
        uint256 insLeft = insurable > borrowerSide ? insurable - borrowerSide : 0;
        uint256 basketCap = _min(_min(l.exposure, l.junior + l.senior), insLeft);
        assertEq(a.basketJunior + a.basketSenior, _min(rem, basketCap));
        assertEq(a.basketJunior, _min(a.basketJunior + a.basketSenior, l.junior)); // junior before senior
        rem -= a.basketJunior + a.basketSenior;
        insLeft -= a.basketJunior + a.basketSenior;
        assertEq(a.reserve, _min(insLeft, reserveAssets));
        rem -= a.reserve;
        assertEq(a.lenderLoss, rem);
        if (a.lenderLoss > 0) {
            // Lenders lose only after every layer is exhausted up to its limit for this loan.
            assertEq(a.collateral, l.collateral);
            assertEq(a.vouchers, stakeValue);
            assertEq(a.basketJunior + a.basketSenior, basketCap);
            assertTrue(a.reserve == reserveAssets || a.reserve == insLeft); // reserve or insurable cap exhausted
        }
        assertLe(a.basketJunior + a.basketSenior + a.reserve, insurable); // insurers never pay interest
    }

    function _min(uint256 x, uint256 y) internal pure returns (uint256) {
        return x < y ? x : y;
    }
}
