// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BasketFixture} from "../unit/InsuranceBasket.t.sol";
import {InsuranceBasket} from "../../src/InsuranceBasket.sol";
import {IInsuranceBasket} from "../../src/interfaces/IInsuranceBasket.sol";
import {Tranche} from "../../src/libraries/Types.sol";

contract BasketHandler is Test {
    InsuranceBasket public basket;
    uint256 public B;
    address public registry;
    address public waterfall;
    address[2] public insurers;
    uint256 public nextLoan = 1;
    uint256[] public openLoans;

    uint256 public violations; // a non-loss action moved the basket from within limits to outside them
    bool public lossHappened;

    constructor(InsuranceBasket b, uint256 id, address reg, address wf, address[2] memory ins) {
        basket = b;
        B = id;
        registry = reg;
        waterfall = wf;
        insurers = ins;
    }

    function withinLimits() public view returns (bool) {
        uint256 cap = basket.capacity(B);
        (, uint16 conc,,,) = basket.params();
        uint256 concCap = cap * conc / 10_000;
        (uint256 c, uint256 s, uint256 m) = basket.maxConcentration(B);
        return basket.exposureOf(B) <= cap && c <= concCap && s <= concCap && m <= concCap;
    }

    modifier checked() {
        bool before = withinLimits();
        _;
        if (before && !withinLimits()) violations++;
    }

    function deposit(uint256 who, bool senior, uint256 amount) external checked {
        amount = bound(amount, 1e6, 100_000e6);
        vm.prank(insurers[who % 2]);
        basket.deposit(B, senior ? Tranche.Senior : Tranche.Junior, amount);
    }

    function request(uint256 who, bool senior, uint256 frac) external checked {
        address a = insurers[who % 2];
        Tranche t = senior ? Tranche.Senior : Tranche.Junior;
        uint256 bal = basket.sharesOf(B, t, a);
        if (bal == 0) return;
        vm.prank(a);
        basket.requestWithdrawal(B, t, bound(frac, 1, bal));
    }

    function process(bool senior) external checked {
        basket.processWithdrawals(B, senior ? Tranche.Senior : Tranche.Junior, 5);
    }

    function claim(uint256 who) external checked {
        address a = insurers[who % 2];
        if (basket.claimableOf(a) == 0) return;
        vm.prank(a);
        basket.claimWithdrawals();
    }

    function assign(uint256 exposure, uint16 country, uint16 sector) external checked {
        exposure = bound(exposure, 1, 50_000e6);
        country = uint16(bound(country, 1, 6));
        sector = uint16(bound(sector, 1, 6));
        if (!basket.canCover(B, exposure, country, sector)) return;
        vm.prank(registry);
        basket.assignCover(nextLoan, B, exposure, country, sector);
        openLoans.push(nextLoan++);
    }

    function release(uint256 idx) external checked {
        if (openLoans.length == 0) return;
        idx = idx % openLoans.length;
        vm.prank(registry);
        basket.releaseCover(openLoans[idx]);
        _drop(idx);
    }

    function premium(uint256 idx, uint256 amount) external checked {
        if (openLoans.length == 0) return;
        vm.prank(registry);
        basket.addPremium(openLoans[idx % openLoans.length], bound(amount, 0, 10_000e6));
    }

    function loss(uint256 idx, uint256 amount) external {
        if (openLoans.length == 0) return;
        idx = idx % openLoans.length;
        uint256 loanId = openLoans[idx];
        IInsuranceBasket.CoverRecord memory c = basket.coverOf(loanId);
        uint256 cap0 = basket.capital(B);
        vm.prank(waterfall);
        (uint256 j, uint256 s) = basket.absorbLoss(loanId, bound(amount, 0, 2 * c.exposure), waterfall);
        assertLe(j + s, c.exposure);
        assertEq(basket.capital(B), cap0 - j - s);
        lossHappened = true;
        _drop(idx);
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1 hours, 20 days));
    }

    function _drop(uint256 idx) internal {
        openLoans[idx] = openLoans[openLoans.length - 1];
        openLoans.pop();
    }
}

/// IB-10, IB-11, INV-07.
contract InsuranceBasketInvariantTest is BasketFixture {
    BasketHandler handler;

    function setUp() public {
        _deployBasket();
        handler = new BasketHandler(basket, B, registry, waterfall, [alice, bob]);
        vm.prank(alice);
        usdc.approve(address(basket), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(basket), type(uint256).max);
        usdc.mint(registry, 1e15);
        targetContract(address(handler));
    }

    function invariant_limitsHoldOutsideLosses() public view {
        assertEq(handler.violations(), 0);
        if (!handler.lossHappened()) assertTrue(handler.withinLimits());
    }

    function invariant_cash() public view {
        assertEq(usdc.balanceOf(address(basket)), basket.capital(B) + basket.totalClaimable());
    }
}
