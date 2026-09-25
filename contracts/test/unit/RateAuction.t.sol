// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IdentityGate} from "../../src/IdentityGate.sol";
import {RateAuction} from "../../src/RateAuction.sol";
import {IRateAuction} from "../../src/interfaces/IRateAuction.sol";
import {IIdentityGate} from "../../src/interfaces/IIdentityGate.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockEAS} from "../../src/mocks/MockEAS.sol";
import {MockSanctionsOracle} from "../../src/mocks/MockSanctionsOracle.sol";

contract RateAuctionTest is Test {
    address admin = makeAddr("timelock");
    address registry = makeAddr("loanRegistry");
    address borrower = makeAddr("borrower");
    MockUSDC usdc;
    MockSanctionsOracle oracle;
    RateAuction auction;
    uint64 endTime;
    uint256 constant P = 10_000e6;
    bytes32 constant SCHEMA = keccak256("id");
    MockEAS eas;
    IdentityGate gate;

    function _verify(address who) internal {
        bytes32 uid = eas.attest(SCHEMA, who, 0, abi.encode(uint256(1), keccak256(abi.encode(who))));
        vm.prank(who);
        gate.registerIdentity(uid);
    }

    function setUp() public {
        usdc = new MockUSDC();
        oracle = new MockSanctionsOracle();
        eas = new MockEAS();
        gate = new IdentityGate(admin, address(0), eas, oracle, SCHEMA);
        vm.prank(admin);
        gate.setTrustedAttester(address(this), true);
        auction = new RateAuction(admin, address(0), usdc, gate);
        _verify(borrower);
        bytes32 role = auction.REGISTRY_ROLE();
        vm.prank(admin);
        auction.grantRole(role, registry);
        endTime = uint64(block.timestamp + 3 days);
    }

    function _lender(uint256 i) internal returns (address l) {
        l = address(uint160(0x10000 + i));
        if (usdc.balanceOf(l) == 0) {
            _verify(l);
            usdc.mint(l, 10_000_000e6);
            vm.prank(l);
            usdc.approve(address(auction), type(uint256).max);
        }
    }

    function _open(uint256 loanId, uint256 principal, uint16 maxRate) internal {
        vm.prank(registry);
        auction.openAuction(loanId, borrower, principal, maxRate, endTime);
    }

    function _bid(uint256 i, uint256 amount, uint16 rate) internal returns (uint256) {
        address l = _lender(i);
        vm.prank(l);
        return auction.placeBid(1, amount, rate);
    }

    function _settle() internal returns (bool ok, uint16 rate) {
        vm.warp(endTime);
        vm.prank(registry);
        return auction.settle(1);
    }

    // RA-01
    function test_placeBidChecks() public {
        _open(1, P, 1_200);
        _bid(0, 1_000e6, 800);
        assertEq(usdc.balanceOf(address(auction)), 1_000e6);

        address l = _lender(1);
        vm.startPrank(l);
        vm.expectRevert(abi.encodeWithSelector(IRateAuction.RateAboveMax.selector, 1_225, 1_200));
        auction.placeBid(1, 1_000e6, 1_225);
        vm.expectRevert(abi.encodeWithSelector(IRateAuction.RateNotOnTick.selector, 810));
        auction.placeBid(1, 1_000e6, 810);
        vm.expectRevert(abi.encodeWithSelector(IRateAuction.BidTooSmall.selector, 99e6, 100e6));
        auction.placeBid(1, 99e6, 800);
        vm.stopPrank();

        usdc.mint(borrower, 1_000e6);
        vm.startPrank(borrower);
        usdc.approve(address(auction), type(uint256).max);
        vm.expectRevert(IRateAuction.BorrowerCannotBid.selector);
        auction.placeBid(1, 1_000e6, 800);
        vm.stopPrank();

        oracle.setSanctioned(l, true);
        vm.prank(l);
        vm.expectRevert(abi.encodeWithSelector(IIdentityGate.Sanctioned.selector, l));
        auction.placeBid(1, 1_000e6, 800);
    }

    // RA-02
    function test_clearing() public {
        _open(1, P, 1_500);
        _bid(0, 4_000e6, 700); // fills
        _bid(1, 3_000e6, 800); // fills
        _bid(2, 5_000e6, 900); // marginal: 3_000 of 5_000
        _bid(3, 2_000e6, 1_000); // refunded
        (bool ok, uint16 rate) = _settle();
        assertTrue(ok);
        assertEq(rate, 900);
        assertEq(auction.bidOf(1, 0).filled, 4_000e6);
        assertEq(auction.bidOf(1, 1).filled, 3_000e6);
        assertEq(auction.bidOf(1, 2).filled, 3_000e6);
        assertEq(auction.bidOf(1, 3).filled, 0);
        assertEq(auction.refundable(1, 2), 2_000e6);
        assertEq(auction.refundable(1, 3), 2_000e6);
        assertEq(auction.refundable(1, 0), 0);
        assertEq(auction.auctionOf(1).totalFilled, P);
        assertEq(auction.positionOf(1, _lender(2)), 3_000e6);
    }

    // RA-03
    function test_marginalProRataRoundsUp() public {
        _open(1, P, 1_000);
        _bid(0, 3_333_333_333, 500);
        _bid(1, 3_333_333_333, 500);
        _bid(2, 3_333_333_333, 500);
        _bid(3, 3_333_333_334, 500);
        (, uint16 rate) = _settle();
        assertEq(rate, 500);
        uint256 total;
        for (uint256 i; i < 4; i++) {
            IRateAuction.Bid memory b = auction.bidOf(1, i);
            uint256 exact = b.amount * P / 13_333_333_333;
            assertGe(b.filled, exact);
            assertLe(b.filled, exact + 1);
            total += b.filled;
        }
        assertGe(total, P);
        assertLe(total, P + 4);
    }

    // RA-04
    function test_failedAuctionRefundsAll() public {
        _open(1, P, 1_000);
        _bid(0, 4_000e6, 700);
        _bid(1, 5_000e6, 900);
        (bool ok,) = _settle();
        assertFalse(ok);
        assertEq(uint8(auction.auctionOf(1).status), uint8(IRateAuction.Status.Failed));
        uint256 before = usdc.balanceOf(_lender(0));
        auction.refund(1, 0);
        assertEq(usdc.balanceOf(_lender(0)) - before, 4_000e6);
        auction.refund(1, 1);
        assertEq(usdc.balanceOf(address(auction)), 0);
    }

    // RA-05
    function test_cancelAfterClearing() public {
        _open(1, P, 1_000);
        _bid(0, 6_000e6, 700);
        _bid(1, 6_000e6, 900);
        _settle();
        auction.refund(1, 1); // unfilled part of the marginal bid first
        assertEq(usdc.balanceOf(address(auction)), P);
        vm.prank(registry);
        auction.cancel(1);
        assertEq(auction.refundable(1, 0), 6_000e6);
        assertEq(auction.refundable(1, 1), 4_000e6);
        auction.refund(1, 0);
        auction.refund(1, 1);
        assertEq(usdc.balanceOf(address(auction)), 0);
    }

    // RA-06
    function test_disburse() public {
        _open(1, P, 1_000);
        _bid(0, 6_000e6, 700);
        _bid(1, 6_000e6, 900);
        _settle();
        vm.prank(registry);
        auction.disburse(1);
        assertEq(usdc.balanceOf(registry), P);
        assertEq(auction.refundable(1, 1), 2_000e6);
        auction.refund(1, 1);
        assertEq(usdc.balanceOf(address(auction)), 0);
        vm.prank(registry);
        vm.expectRevert();
        auction.disburse(1);
        vm.prank(registry);
        vm.expectRevert();
        auction.cancel(1);
    }

    // RA-09
    function test_maxBidsAndMinBid() public {
        _open(1, P, 1_000);
        assertEq(auction.auctionOf(1).minBid, P / 100);
        for (uint256 i; i < 100; i++) _bid(i, 100e6, 1_000);
        // Full book: an equal or worse rate is refused ...
        address l = _lender(1000);
        vm.prank(l);
        vm.expectRevert(abi.encodeWithSelector(IRateAuction.TooManyBids.selector, 1));
        auction.placeBid(1, 100e6, 1_000);
        // ... a strictly better rate evicts the worst (most recent at the highest rate) bid (M-2).
        vm.prank(l);
        uint256 id = auction.placeBid(1, 100e6, 500);
        assertEq(id, 99);
        assertEq(auction.bidOf(1, 99).lender, l);
        address evicted = _lender(99);
        assertEq(auction.evictedBalanceOf(evicted), 100e6);
        uint256 before = usdc.balanceOf(evicted);
        vm.prank(evicted);
        auction.withdrawEvicted();
        assertEq(usdc.balanceOf(evicted) - before, 100e6);
        (bool ok, uint16 rate) = _settle(); // the full book always reaches the principal
        assertEq(rate, 1_000);
        assertTrue(ok);

        vm.prank(registry);
        auction.openAuction(2, borrower, 1_001, 100, uint64(block.timestamp + 1 days));
        assertEq(auction.auctionOf(2).minBid, 11); // ceil(1001 / 100)
    }

    // RA-10
    function test_noDoubleRefundAndClosedAfterEnd() public {
        _open(1, P, 1_000);
        _bid(0, 6_000e6, 700);
        _bid(1, 6_000e6, 900);
        vm.warp(endTime);
        address l = _lender(2);
        vm.prank(l);
        vm.expectRevert(abi.encodeWithSelector(IRateAuction.AuctionClosed.selector, 1));
        auction.placeBid(1, 1_000e6, 700);
        vm.prank(registry);
        auction.settle(1);
        auction.refund(1, 1);
        vm.expectRevert(IRateAuction.NothingToRefund.selector);
        auction.refund(1, 1);
        vm.expectRevert(IRateAuction.NothingToRefund.selector);
        auction.refund(1, 0);
    }

    function test_settleOnlyAfterEndAndOnlyRegistry() public {
        _open(1, P, 1_000);
        _bid(0, P, 700);
        vm.prank(registry);
        vm.expectRevert(abi.encodeWithSelector(IRateAuction.AuctionNotEnded.selector, 1));
        auction.settle(1);
        vm.warp(endTime);
        vm.expectRevert();
        auction.settle(1);
    }

    // RA-07 and RA-08
    function testFuzz_clearingAndSolvency(uint256 seed, uint8 nBids, uint256 principal, bool disburse) public {
        principal = bound(principal, 1_000e6, 1_000_000e6);
        nBids = uint8(bound(nBids, 1, 100));
        uint16 maxRate = 2_000;
        _open(1, principal, maxRate);
        uint256 minBid = auction.auctionOf(1).minBid;
        for (uint256 i; i < nBids; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 amount = bound(r, minBid, principal / 2 + minBid);
            uint16 rate = uint16(bound(r >> 128, 0, maxRate / 25) * 25);
            _bid(i % 7, amount, rate); // few lenders, several bids each
        }
        (bool ok, uint16 clearing) = _settle();
        IRateAuction.Auction memory a = auction.auctionOf(1);
        assertEq(ok, a.totalBid >= principal);
        if (ok) {
            uint256 marginal;
            for (uint256 i; i < nBids; i++) {
                IRateAuction.Bid memory b = auction.bidOf(1, i);
                if (b.filled > 0) assertLe(b.rateBps, clearing);
                if (b.rateBps < clearing) assertEq(b.filled, b.amount);
                if (b.rateBps > clearing) assertEq(b.filled, 0);
                if (b.rateBps == clearing) marginal++;
                assertLe(b.filled, b.amount);
            }
            assertGe(a.totalFilled, principal);
            assertLe(a.totalFilled, principal + marginal);
            uint256 positions;
            for (uint256 i; i < 7; i++) positions += auction.positionOf(1, _lender(i));
            assertEq(positions, a.totalFilled);
            if (disburse) {
                vm.prank(registry);
                auction.disburse(1);
            }
        }
        uint256 owed;
        for (uint256 i; i < nBids; i++) owed += auction.refundable(1, i);
        assertGe(usdc.balanceOf(address(auction)), owed);
        for (uint256 i; i < nBids; i++) {
            if (auction.refundable(1, i) > 0) auction.refund(1, i);
        }
        // Only rounding dust from marginal fills can remain.
        assertLe(usdc.balanceOf(address(auction)), ok && !disburse ? a.totalFilled : nBids);
    }
}
