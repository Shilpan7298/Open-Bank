// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.35;

import {ProtocolAccess} from "./libraries/ProtocolAccess.sol";
import {BPS, Stage, Tier} from "./libraries/Types.sol";
import {ICreditRegistry} from "./interfaces/ICreditRegistry.sol";

/// @title CreditRegistry
/// @notice See {ICreditRegistry}. Limits start small per tier and step up after each repaid loan; any default
/// drops the limit to zero. Backing requirements come from a stage x tier table (launch defaults below, tuned
/// in sim/).
contract CreditRegistry is ICreditRegistry, ProtocolAccess {
    bytes32 public constant REGISTRY_ROLE = keccak256("REGISTRY_ROLE");

    /// @dev CLAUDE.md: borrower collateral is never below 20%.
    uint16 public constant MIN_COLLATERAL_BPS = 2_000;
    /// @dev CLAUDE.md: voucher cover ranges up to 90% of principal.
    uint16 public constant MAX_VOUCHER_COVER_BPS = 9_000;

    struct Requirement {
        uint16 collateralBps;
        uint16 voucherCoverBps;
    }

    uint32 public establishedAfter;
    uint32 public provenAfter;

    mapping(address borrower => History) private _history;
    mapping(Stage => mapping(Tier => Requirement)) private _requirements;
    mapping(Tier => LimitParams) private _limits;

    constructor(address admin, address guardian) ProtocolAccess(admin, guardian) {
        _setStageThresholds(2, 4);
        // Launch defaults (collateral bps, voucher cover bps). Stage table in CLAUDE.md:
        // New 60-90% cover, 2-3 loans repaid 20-40%, Proven 0-10%. Tier B/C and new borrowers post more collateral.
        _setRequirement(Stage.New, Tier.A, 3_000, 6_000);
        _setRequirement(Stage.New, Tier.B, 3_500, 7_500);
        _setRequirement(Stage.New, Tier.C, 4_000, 9_000);
        _setRequirement(Stage.Established, Tier.A, 2_500, 2_000);
        _setRequirement(Stage.Established, Tier.B, 3_000, 3_000);
        _setRequirement(Stage.Established, Tier.C, 3_500, 4_000);
        _setRequirement(Stage.Proven, Tier.A, 2_000, 1_000);
        _setRequirement(Stage.Proven, Tier.B, 2_500, 1_000);
        _setRequirement(Stage.Proven, Tier.C, 3_000, 1_000);
        // Credit limits in 6-decimal stablecoin units.
        _setLimitParams(Tier.A, LimitParams(2_000e6, 2_000e6, 50_000e6));
        _setLimitParams(Tier.B, LimitParams(1_000e6, 1_000e6, 20_000e6));
        _setLimitParams(Tier.C, LimitParams(500e6, 500e6, 5_000e6));
    }

    /// @inheritdoc ICreditRegistry
    function stageOf(address borrower) public view returns (Stage) {
        uint32 repaid = _history[borrower].repaidLoans;
        if (repaid >= provenAfter) return Stage.Proven;
        if (repaid >= establishedAfter) return Stage.Established;
        return Stage.New;
    }

    /// @inheritdoc ICreditRegistry
    function creditLimit(address borrower, Tier tier) public view returns (uint256) {
        History storage h = _history[borrower];
        if (h.defaultedLoans > 0) return 0;
        LimitParams storage p = _limits[_validTier(tier)];
        uint256 limit = p.base + p.step * h.repaidLoans;
        return limit > p.max ? p.max : limit;
    }

    /// @inheritdoc ICreditRegistry
    function availableCredit(address borrower, Tier tier) public view returns (uint256) {
        uint256 limit = creditLimit(borrower, tier);
        uint256 outstanding = _history[borrower].outstandingPrincipal;
        return limit > outstanding ? limit - outstanding : 0;
    }

    /// @inheritdoc ICreditRegistry
    function historyOf(address borrower) external view returns (History memory) {
        return _history[borrower];
    }

    /// @inheritdoc ICreditRegistry
    function requirementsFor(address borrower, Tier tier)
        external
        view
        returns (uint16 collateralBps, uint16 voucherCoverBps)
    {
        Requirement storage r = _requirements[stageOf(borrower)][_validTier(tier)];
        return (r.collateralBps, r.voucherCoverBps);
    }

    /// @notice Limit parameters for a tier.
    function limitParams(Tier tier) external view returns (LimitParams memory) {
        return _limits[tier];
    }

    /// @inheritdoc ICreditRegistry
    function onLoanFunded(address borrower, Tier tier, uint256 principal) external onlyRole(REGISTRY_ROLE) {
        uint256 available = availableCredit(borrower, tier);
        if (principal > available) revert CreditLimitExceeded(borrower, principal, available);
        _history[borrower].outstandingPrincipal += principal;
        emit LoanFunded(borrower, principal);
    }

    /// @inheritdoc ICreditRegistry
    function onLoanCancelled(address borrower, uint256 principal) external onlyRole(REGISTRY_ROLE) {
        _history[borrower].outstandingPrincipal -= principal;
        emit LoanCancelled(borrower, principal);
    }

    /// @inheritdoc ICreditRegistry
    function onLoanRepaid(address borrower, uint256 principal) external onlyRole(REGISTRY_ROLE) {
        History storage h = _history[borrower];
        h.outstandingPrincipal -= principal;
        h.repaidLoans += 1;
        emit LoanRepaid(borrower, principal);
    }

    /// @inheritdoc ICreditRegistry
    function onLoanDefaulted(address borrower, uint256 principal) external onlyRole(REGISTRY_ROLE) {
        History storage h = _history[borrower];
        h.outstandingPrincipal -= principal;
        h.defaultedLoans += 1;
        emit LoanDefaulted(borrower, principal);
    }

    /// @inheritdoc ICreditRegistry
    function setRequirement(Stage stage, Tier tier, uint16 collateralBps, uint16 voucherCoverBps)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _setRequirement(stage, _validTier(tier), collateralBps, voucherCoverBps);
    }

    /// @inheritdoc ICreditRegistry
    function setLimitParams(Tier tier, LimitParams calldata params) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setLimitParams(_validTier(tier), params);
    }

    /// @inheritdoc ICreditRegistry
    function setStageThresholds(uint32 establishedAfter_, uint32 provenAfter_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setStageThresholds(establishedAfter_, provenAfter_);
    }

    function _setRequirement(Stage stage, Tier tier, uint16 collateralBps, uint16 voucherCoverBps) internal {
        _checkBounds(collateralBps, MIN_COLLATERAL_BPS, BPS);
        _checkBounds(voucherCoverBps, 0, MAX_VOUCHER_COVER_BPS);
        _requirements[stage][tier] = Requirement(collateralBps, voucherCoverBps);
        emit RequirementSet(stage, tier, collateralBps, voucherCoverBps);
    }

    function _setLimitParams(Tier tier, LimitParams memory p) internal {
        _checkBounds(p.base, 1, p.max);
        _limits[tier] = p;
        emit LimitParamsSet(tier, p.base, p.step, p.max);
    }

    function _setStageThresholds(uint32 established, uint32 proven) internal {
        _checkBounds(established, 1, proven);
        establishedAfter = established;
        provenAfter = proven;
        emit StageThresholdsSet(established, proven);
    }

    function _validTier(Tier tier) internal pure returns (Tier) {
        if (tier != Tier.A && tier != Tier.B && tier != Tier.C) {
            revert OutOfBounds(uint256(tier), uint256(Tier.A), uint256(Tier.C));
        }
        return tier;
    }
}
