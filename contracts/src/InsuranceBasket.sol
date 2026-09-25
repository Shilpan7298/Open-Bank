// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ProtocolAccess} from "./libraries/ProtocolAccess.sol";
import {BPS, Tier, Tranche} from "./libraries/Types.sol";
import {IInsuranceBasket} from "./interfaces/IInsuranceBasket.sol";
import {IIdentityGate} from "./interfaces/IIdentityGate.sol";

/// @title InsuranceBasket
/// @notice See {IInsuranceBasket}. Written from the designs in docs/upstream-notes/huma.md and nexus.md (no code
/// copied): two-tranche NAV held as internal accounting, queued shares that stay in supply until settled,
/// event-driven exposure (removed only on repayment or default settlement, never on a date), and a
/// concentration cap measured against capacity so a young basket can take its first loans.
contract InsuranceBasket is IInsuranceBasket, ProtocolAccess, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant REGISTRY_ROLE = keccak256("REGISTRY_ROLE");
    bytes32 public constant WATERFALL_ROLE = keccak256("WATERFALL_ROLE");

    uint8 public constant MIN_BAND = 1;
    uint8 public constant MAX_BAND = 5;
    uint8 internal constant DIMENSIONS = 3; // 0 country, 1 sector, 2 origination month
    uint256 internal constant VIRTUAL_SHARES = 1e6; // inflation protection, as OZ ERC4626 decimals offset 6
    uint256 internal constant VIRTUAL_ASSETS = 1;
    uint256 public constant MONTH = 30 days;

    IERC20 public immutable asset;
    IIdentityGate public immutable gate;
    Params public params;

    struct Basket {
        TrancheState[2] tranches;
        uint256 exposure;
    }

    mapping(uint256 basketId => Basket) private _baskets;
    mapping(uint256 basketId => uint16) public premiumRateBps;
    mapping(uint256 basketId => mapping(Tranche => mapping(address => uint256))) private _shares;
    mapping(uint256 loanId => CoverRecord) private _covers;
    mapping(uint256 basketId => mapping(uint8 dim => mapping(uint256 key => uint256))) private _exposureBy;
    mapping(uint256 basketId => mapping(uint8 dim => uint256[])) private _keys;
    mapping(uint256 basketId => mapping(uint8 dim => mapping(uint256 key => uint256))) private _keyIndexPlusOne;
    mapping(uint256 basketId => mapping(Tranche => WithdrawalRequest[])) private _queues;
    mapping(uint256 basketId => mapping(Tranche => uint256)) private _heads;
    mapping(address owner => uint256) private _claimable;
    uint256 public totalClaimable;

    constructor(address admin, address guardian, IERC20 asset_, IIdentityGate gate_) ProtocolAccess(admin, guardian) {
        asset = asset_;
        gate = gate_;
        _setParams(
            Params({
                leverageBps: 30_000,
                concentrationBps: 2_500,
                noticePeriod: 30 days,
                epochLength: 7 days,
                seniorPremiumHaircutBps: 3_000
            })
        );
        // Launch premium rates: 1% APR for band 1 up to 5% for band 5, +0.5% per tier step (tune in sim/).
        for (uint8 band = MIN_BAND; band <= MAX_BAND; band++) {
            for (uint8 t = uint8(Tier.A); t <= uint8(Tier.C); t++) {
                uint256 id = basketIdOf(band, Tier(t));
                uint16 rate = uint16(uint256(band) * 100 + (t - uint8(Tier.A)) * 50);
                premiumRateBps[id] = rate;
                emit PremiumRateSet(id, rate);
            }
        }
    }

    // ---------------------------------------------------------------- insurers

    /// @inheritdoc IInsuranceBasket
    function deposit(uint256 basketId, Tranche tranche, uint256 assets)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        _validBasket(basketId);
        gate.requireNotSanctioned(msg.sender);
        TrancheState storage t = _baskets[basketId].tranches[uint8(tranche)];
        shares = Math.mulDiv(assets, t.shares + VIRTUAL_SHARES, t.assets + VIRTUAL_ASSETS);
        if (shares == 0) revert ZeroShares();
        t.assets += assets;
        t.shares += shares;
        _shares[basketId][tranche][msg.sender] += shares;
        asset.safeTransferFrom(msg.sender, address(this), assets);
        emit Deposited(basketId, tranche, msg.sender, assets, shares);
    }

    /// @inheritdoc IInsuranceBasket
    function requestWithdrawal(uint256 basketId, Tranche tranche, uint256 shares) external returns (uint256 requestId) {
        mapping(address => uint256) storage bal = _shares[basketId][tranche];
        if (shares == 0 || shares > bal[msg.sender]) revert InsufficientShares();
        bal[msg.sender] -= shares;
        uint256 e = params.epochLength;
        uint64 eligibleAt = uint64(Math.ceilDiv(block.timestamp + params.noticePeriod, e) * e);
        WithdrawalRequest[] storage q = _queues[basketId][tranche];
        requestId = q.length;
        q.push(WithdrawalRequest({owner: msg.sender, eligibleAt: eligibleAt, shares: shares}));
        emit WithdrawalRequested(basketId, tranche, requestId, msg.sender, shares, eligibleAt);
    }

    /// @inheritdoc IInsuranceBasket
    function processWithdrawals(uint256 basketId, Tranche tranche, uint256 maxRequests)
        external
        nonReentrant
        returns (uint256 processed)
    {
        WithdrawalRequest[] storage q = _queues[basketId][tranche];
        TrancheState storage t = _baskets[basketId].tranches[uint8(tranche)];
        uint256 head = _heads[basketId][tranche];
        while (processed < maxRequests && head < q.length) {
            WithdrawalRequest storage r = q[head];
            if (r.eligibleAt > block.timestamp) break;
            uint256 value = Math.mulDiv(r.shares, t.assets + VIRTUAL_ASSETS, t.shares + VIRTUAL_SHARES);
            uint256 free = freeCapital(basketId);
            if (free > t.assets) free = t.assets;
            uint256 out;
            uint256 burned;
            if (value <= free) {
                (out, burned) = (value, r.shares);
            } else {
                if (free == 0) break;
                // Partial fill: burn shares rounded up so the leaving insurer never takes more than its share.
                out = free;
                burned = Math.mulDiv(free, t.shares + VIRTUAL_SHARES, t.assets + VIRTUAL_ASSETS, Math.Rounding.Ceil);
                if (burned > r.shares) burned = r.shares;
            }
            t.assets -= out;
            t.shares -= burned;
            r.shares -= burned;
            _claimable[r.owner] += out;
            totalClaimable += out;
            emit WithdrawalProcessed(basketId, tranche, head, burned, out);
            if (r.shares > 0) break;
            head++;
            processed++;
        }
        _heads[basketId][tranche] = head;
    }

    /// @inheritdoc IInsuranceBasket
    function claimWithdrawals() external nonReentrant returns (uint256 assets) {
        gate.requireNotSanctioned(msg.sender);
        assets = _claimable[msg.sender];
        if (assets == 0) revert NothingToClaim();
        _claimable[msg.sender] = 0;
        totalClaimable -= assets;
        asset.safeTransfer(msg.sender, assets);
        emit WithdrawalClaimed(msg.sender, assets);
    }

    // ---------------------------------------------------------------- loan hooks

    /// @inheritdoc IInsuranceBasket
    function canCover(uint256 basketId, uint256 exposure, uint16 country, uint16 sector) public view returns (bool) {
        if (!_isValidBasket(basketId)) return false;
        uint256 cap = capacity(basketId);
        if (_baskets[basketId].exposure + exposure > cap) return false;
        uint256 concCap = Math.mulDiv(cap, params.concentrationBps, BPS);
        uint256[3] memory keys = [uint256(country), uint256(sector), _month()];
        for (uint8 d; d < DIMENSIONS; d++) {
            if (_exposureBy[basketId][d][keys[d]] + exposure > concCap) return false;
        }
        return true;
    }

    /// @inheritdoc IInsuranceBasket
    function assignCover(uint256 loanId, uint256 basketId, uint256 exposure, uint16 country, uint16 sector)
        external
        onlyRole(REGISTRY_ROLE)
    {
        _validBasket(basketId);
        if (_covers[loanId].exposure != 0) revert AlreadyCovered(loanId);
        Basket storage b = _baskets[basketId];
        uint256 cap = capacity(basketId);
        if (exposure == 0 || b.exposure + exposure > cap) revert NoCapacity(basketId, exposure);
        uint256 concCap = Math.mulDiv(cap, params.concentrationBps, BPS);
        uint32 month = uint32(_month());
        uint256[3] memory keys = [uint256(country), uint256(sector), uint256(month)];
        for (uint8 d; d < DIMENSIONS; d++) {
            if (_exposureBy[basketId][d][keys[d]] + exposure > concCap) revert ConcentrationExceeded(basketId, d);
            _addKey(basketId, d, keys[d], exposure);
        }
        b.exposure += exposure;
        _covers[loanId] = CoverRecord(basketId, exposure, country, sector, month);
        emit CoverAssigned(loanId, basketId, exposure);
    }

    /// @inheritdoc IInsuranceBasket
    function releaseCover(uint256 loanId) external onlyRole(REGISTRY_ROLE) {
        uint256 exposure = _removeCover(loanId);
        emit CoverReleased(loanId, exposure);
    }

    /// @inheritdoc IInsuranceBasket
    function addPremium(uint256 loanId, uint256 amount) external onlyRole(REGISTRY_ROLE) {
        CoverRecord storage c = _covers[loanId];
        if (c.exposure == 0) revert InvalidBasket(0);
        TrancheState[2] storage ts = _baskets[c.basketId].tranches;
        uint256 j = ts[uint8(Tranche.Junior)].assets;
        uint256 s = ts[uint8(Tranche.Senior)].assets;
        uint256 toSenior;
        if (j + s > 0) {
            toSenior = Math.mulDiv(amount, s * (BPS - params.seniorPremiumHaircutBps), (j + s) * BPS);
        }
        uint256 toJunior = amount - toSenior;
        ts[uint8(Tranche.Senior)].assets = s + toSenior;
        ts[uint8(Tranche.Junior)].assets = j + toJunior;
        asset.safeTransferFrom(msg.sender, address(this), amount);
        emit PremiumAdded(loanId, toJunior, toSenior);
    }

    /// @inheritdoc IInsuranceBasket
    function absorbLoss(uint256 loanId, uint256 loss, address to)
        external
        onlyRole(WATERFALL_ROLE)
        nonReentrant
        returns (uint256 junior, uint256 senior)
    {
        CoverRecord memory c = _covers[loanId];
        if (c.exposure == 0) return (0, 0);
        _removeCover(loanId);
        uint256 hit = loss < c.exposure ? loss : c.exposure;
        TrancheState[2] storage ts = _baskets[c.basketId].tranches;
        uint256 j = ts[uint8(Tranche.Junior)].assets;
        junior = hit < j ? hit : j;
        ts[uint8(Tranche.Junior)].assets = j - junior;
        uint256 s = ts[uint8(Tranche.Senior)].assets;
        senior = hit - junior < s ? hit - junior : s;
        ts[uint8(Tranche.Senior)].assets = s - senior;
        if (junior + senior > 0) asset.safeTransfer(to, junior + senior);
        emit LossAbsorbed(loanId, junior, senior);
    }

    // ---------------------------------------------------------------- views

    /// @inheritdoc IInsuranceBasket
    function basketIdOf(uint8 riskBand, Tier tier) public pure returns (uint256) {
        return uint256(riskBand) * 8 + uint256(tier);
    }

    /// @inheritdoc IInsuranceBasket
    function capital(uint256 basketId) public view returns (uint256) {
        TrancheState[2] storage ts = _baskets[basketId].tranches;
        return ts[0].assets + ts[1].assets;
    }

    /// @inheritdoc IInsuranceBasket
    function capacity(uint256 basketId) public view returns (uint256) {
        return Math.mulDiv(capital(basketId), params.leverageBps, BPS);
    }

    /// @inheritdoc IInsuranceBasket
    function exposureOf(uint256 basketId) external view returns (uint256) {
        return _baskets[basketId].exposure;
    }

    /// @inheritdoc IInsuranceBasket
    function trancheOf(uint256 basketId, Tranche tranche) external view returns (TrancheState memory) {
        return _baskets[basketId].tranches[uint8(tranche)];
    }

    /// @inheritdoc IInsuranceBasket
    function sharesOf(uint256 basketId, Tranche tranche, address owner) external view returns (uint256) {
        return _shares[basketId][tranche][owner];
    }

    /// @inheritdoc IInsuranceBasket
    function maxConcentration(uint256 basketId) public view returns (uint256 country, uint256 sector, uint256 month) {
        return (_maxOf(basketId, 0), _maxOf(basketId, 1), _maxOf(basketId, 2));
    }

    /// @inheritdoc IInsuranceBasket
    function coverOf(uint256 loanId) external view returns (CoverRecord memory) {
        return _covers[loanId];
    }

    /// @inheritdoc IInsuranceBasket
    function requestOf(uint256 basketId, Tranche tranche, uint256 requestId)
        external
        view
        returns (WithdrawalRequest memory)
    {
        return _queues[basketId][tranche][requestId];
    }

    /// @inheritdoc IInsuranceBasket
    function queueOf(uint256 basketId, Tranche tranche) external view returns (uint256 head, uint256 length) {
        return (_heads[basketId][tranche], _queues[basketId][tranche].length);
    }

    /// @inheritdoc IInsuranceBasket
    function claimableOf(address owner) external view returns (uint256) {
        return _claimable[owner];
    }

    /// @inheritdoc IInsuranceBasket
    function freeCapital(uint256 basketId) public view returns (uint256) {
        uint256 cap = capital(basketId);
        // Capital needed so that exposure <= capital x leverage ...
        uint256 need = Math.mulDiv(_baskets[basketId].exposure, BPS, params.leverageBps, Math.Rounding.Ceil);
        // ... and every per-key exposure <= capital x leverage x concentration.
        (uint256 c, uint256 s, uint256 m) = maxConcentration(basketId);
        uint256 maxKey = Math.max(c, Math.max(s, m));
        uint256 needConc = Math.mulDiv(
            maxKey, BPS * BPS, uint256(params.leverageBps) * params.concentrationBps, Math.Rounding.Ceil
        );
        if (needConc > need) need = needConc;
        return cap > need ? cap - need : 0;
    }

    // ---------------------------------------------------------------- governance

    /// @inheritdoc IInsuranceBasket
    function setPremiumRate(uint256 basketId, uint16 rateBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _validBasket(basketId);
        _checkBounds(rateBps, 0, 2_000);
        premiumRateBps[basketId] = rateBps;
        emit PremiumRateSet(basketId, rateBps);
    }

    /// @inheritdoc IInsuranceBasket
    function setParams(Params calldata p) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setParams(p);
    }

    // ---------------------------------------------------------------- internals

    function _setParams(Params memory p) internal {
        _checkBounds(p.leverageBps, BPS, 30_000); // at most 3x at launch (CLAUDE.md)
        _checkBounds(p.concentrationBps, 500, 2_500); // at most 25% (CLAUDE.md)
        _checkBounds(p.noticePeriod, 30 days, 90 days);
        _checkBounds(p.epochLength, 1 days, 30 days);
        _checkBounds(p.seniorPremiumHaircutBps, 0, BPS);
        params = p;
        emit ParamsSet(p);
    }

    function _removeCover(uint256 loanId) internal returns (uint256 exposure) {
        CoverRecord memory c = _covers[loanId];
        exposure = c.exposure;
        if (exposure == 0) return 0;
        uint256[3] memory keys = [uint256(c.country), uint256(c.sector), uint256(c.month)];
        for (uint8 d; d < DIMENSIONS; d++) {
            _subKey(c.basketId, d, keys[d], exposure);
        }
        _baskets[c.basketId].exposure -= exposure;
        delete _covers[loanId];
    }

    function _addKey(uint256 basketId, uint8 d, uint256 key, uint256 amount) internal {
        mapping(uint256 => uint256) storage by = _exposureBy[basketId][d];
        if (by[key] == 0) {
            _keys[basketId][d].push(key);
            _keyIndexPlusOne[basketId][d][key] = _keys[basketId][d].length;
        }
        by[key] += amount;
    }

    function _subKey(uint256 basketId, uint8 d, uint256 key, uint256 amount) internal {
        mapping(uint256 => uint256) storage by = _exposureBy[basketId][d];
        by[key] -= amount;
        if (by[key] == 0) {
            uint256[] storage keys = _keys[basketId][d];
            uint256 idx = _keyIndexPlusOne[basketId][d][key] - 1;
            uint256 last = keys[keys.length - 1];
            keys[idx] = last;
            _keyIndexPlusOne[basketId][d][last] = idx + 1;
            keys.pop();
            delete _keyIndexPlusOne[basketId][d][key];
        }
    }

    /// @dev Loops over keys with non-zero exposure only (bounded by the basket's open loans).
    function _maxOf(uint256 basketId, uint8 d) internal view returns (uint256 max) {
        uint256[] storage keys = _keys[basketId][d];
        uint256 n = keys.length;
        for (uint256 i; i < n; i++) {
            uint256 v = _exposureBy[basketId][d][keys[i]];
            if (v > max) max = v;
        }
    }

    function _month() internal view returns (uint256) {
        return block.timestamp / MONTH;
    }

    function _isValidBasket(uint256 basketId) internal pure returns (bool) {
        uint256 band = basketId / 8;
        uint256 tier = basketId % 8;
        return band >= MIN_BAND && band <= MAX_BAND && tier >= uint256(Tier.A) && tier <= uint256(Tier.C);
    }

    function _validBasket(uint256 basketId) internal pure {
        if (!_isValidBasket(basketId)) revert InvalidBasket(basketId);
    }
}
