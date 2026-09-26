// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {ScoreSigner} from "./ScoreSigner.sol";
import {DeployLib} from "../../script/DeployLib.sol";
import {IScoreOracle} from "../../src/interfaces/IScoreOracle.sol";
import {ILoanRegistry} from "../../src/interfaces/ILoanRegistry.sol";
import {LoanState, Tier, Tranche} from "../../src/libraries/Types.sol";

/// @notice Full protocol on a local chain with onboarded actors. The test contract is the admin (no hand-over)
/// unless a test calls DeployLib.handOver.
abstract contract SystemFixture is ScoreSigner {
    DeployLib.System s;

    address guardian = makeAddr("guardian");
    address rebate = makeAddr("rebate");
    address attester = makeAddr("kycAttester");
    uint256 scorerPk = 0x5C0E;
    address borrower = makeAddr("borrower");
    address v1 = makeAddr("voucher1");
    address v2 = makeAddr("voucher2");
    address l1 = makeAddr("lender1");
    address l2 = makeAddr("lender2");
    address l3 = makeAddr("lender3");
    address insJ = makeAddr("insurerJunior");
    address insS = makeAddr("insurerSenior");

    uint16 constant COUNTRY_A = 1;
    uint16 constant COUNTRY_B = 2;
    uint16 constant COUNTRY_C = 999; // unmapped: tier C
    uint16 constant SECTOR = 7;
    uint256 constant P = 1_000e6;
    uint64 constant TERM = 180 days;

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        address[] memory proposers = new address[](1);
        proposers[0] = address(this);
        s = DeployLib.deploy(
            DeployLib.Config({
                admin: address(this),
                guardian: guardian,
                rebateRecipient: rebate,
                timelockDelay: 2 days,
                proposers: proposers
            })
        );
        s.gate.setCountryTier(COUNTRY_A, Tier.A);
        s.gate.setCountryTier(COUNTRY_B, Tier.B);
        s.gate.setTrustedAttester(attester, true);
        s.scoreOracle.setScorer(vm.addr(scorerPk), true);

        address[9] memory actors = [borrower, v1, v2, l1, l2, l3, insJ, insS, address(this)];
        address[5] memory spenders =
            [address(s.escrow), address(s.vouching), address(s.auction), address(s.basket), address(s.registry)];
        for (uint256 i; i < actors.length; i++) {
            s.usdc.mint(actors[i], 10_000_000e6);
            for (uint256 k; k < spenders.length; k++) {
                vm.prank(actors[i]);
                s.usdc.approve(spenders[k], type(uint256).max);
            }
        }
        _onboard(borrower, COUNTRY_A);
        // Direct lenders must be verified people (see RateAuction._checkIndependentLender).
        _onboard(l1, COUNTRY_B);
        _onboard(l2, COUNTRY_B);
        _onboard(l3, COUNTRY_B);
        _seedBasket(2, Tier.A, 2_000e6, 6_000e6);
    }

    // ---------------------------------------------------------------- helpers

    function _onboard(address who, uint16 country) internal returns (bytes32 uid) {
        vm.prank(attester);
        uid = s.eas.attest(DeployLib.IDENTITY_SCHEMA, who, 0, abi.encode(uint256(country), keccak256(abi.encode("person", who))));
        vm.prank(who);
        s.gate.registerIdentity(uid);
    }

    function _seedBasket(uint8 band, Tier tier, uint256 junior, uint256 senior) internal {
        uint256 id = s.basket.basketIdOf(band, tier);
        if (junior > 0) {
            vm.prank(insJ);
            s.basket.deposit(id, Tranche.Junior, junior);
        }
        if (senior > 0) {
            vm.prank(insS);
            s.basket.deposit(id, Tranche.Senior, senior);
        }
    }

    function _propose(address who, uint256 principal) internal returns (uint256 id) {
        vm.prank(who);
        id = s.registry.propose(principal, TERM, 6, 1_500, SECTOR, keccak256("purpose"));
    }

    function _scoreLoan(uint256 id, address who, uint8 band, uint16 minCoverBps) internal {
        IScoreOracle.Score memory sc = _score(id, who, band);
        sc.minVoucherCoverBps = minCoverBps;
        vm.prank(vm.addr(scorerPk));
        bytes32 uid = s.eas.attest(DeployLib.SCORE_SCHEMA, who, 0, abi.encode(sc));
        s.scoreOracle.submitScore(uid, _sign(s.scoreOracle, scorerPk, sc));
    }

    function _open(uint256 id) internal {
        vm.prank(s.registry.loanOf(id).borrower);
        s.registry.open(id);
    }

    function _collateral(uint256 id, uint256 amount) internal {
        vm.prank(s.registry.loanOf(id).borrower);
        s.registry.postCollateral(id, amount);
    }

    function _vouch(uint256 id, address who, uint256 amount) internal {
        vm.prank(who);
        s.vouching.stake(id, amount);
    }

    function _bid(uint256 id, address who, uint256 amount, uint16 rate) internal returns (uint256) {
        vm.prank(who);
        return s.auction.placeBid(id, amount, rate);
    }

    function _settle(uint256 id) internal returns (bool) {
        vm.warp(s.registry.loanOf(id).auctionEnd);
        return s.registry.settle(id);
    }

    /// Proposed, scored (band 2) and open, with nothing posted yet.
    function _openLoan(address who, uint256 principal) internal returns (uint256 id) {
        id = _propose(who, principal);
        _scoreLoan(id, who, 2, 0);
        _open(id);
    }

    /// Default happy path for the tier-A new borrower: 30% collateral, 60% cover, clears at 9%.
    function _backAndBid(uint256 id) internal {
        _collateral(id, 300e6);
        _vouch(id, v1, 400e6);
        _vouch(id, v2, 200e6);
        _bid(id, l1, 600e6, 800);
        _bid(id, l2, 600e6, 900);
    }

    function _fundedLoan() internal returns (uint256 id) {
        id = _openLoan(borrower, P);
        _backAndBid(id);
        assertTrue(_settle(id), "settle");
    }

    function _activeLoan() internal returns (uint256 id) {
        id = _fundedLoan();
        vm.prank(borrower);
        s.registry.drawdown(id, keccak256("agreement"));
    }

    function _repayAll(uint256 id) internal {
        ILoanRegistry.Dues memory d = s.registry.duesOf(id);
        vm.prank(borrower);
        s.registry.repay(id, d.totalDue - d.repaid);
    }

    function _state(uint256 id) internal view returns (LoanState) {
        return s.registry.loanOf(id).state;
    }
}
