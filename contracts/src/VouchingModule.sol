// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ProtocolAccess} from "./libraries/ProtocolAccess.sol";
import {IVouchingModule} from "./interfaces/IVouchingModule.sol";
import {IIdentityGate} from "./interfaces/IIdentityGate.sol";
import {ICreditRegistry} from "./interfaces/ICreditRegistry.sol";

/// @title VouchingModule
/// @notice See {IVouchingModule}. Design notes: docs/upstream-notes/union.md section 4 (fully funded slices per
/// loan instead of Union's trust lines; pro rata loss by construction; explicit per-loan state).
contract VouchingModule is IVouchingModule, ProtocolAccess, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant REGISTRY_ROLE = keccak256("REGISTRY_ROLE");
    bytes32 public constant WATERFALL_ROLE = keccak256("WATERFALL_ROLE");

    IERC20 public immutable asset;
    IERC4626 public immutable stakeVault;
    IIdentityGate public immutable gate;
    ICreditRegistry public immutable credit;

    uint256 public minSlice;

    mapping(uint256 loanId => Cover) private _covers;
    mapping(uint256 loanId => mapping(address voucher => Slice)) private _slices;
    mapping(address voucher => VoucherStats) private _stats;

    constructor(
        address admin,
        address guardian,
        IERC4626 stakeVault_,
        IIdentityGate gate_,
        ICreditRegistry credit_,
        uint256 minSlice_
    ) ProtocolAccess(admin, guardian) {
        stakeVault = stakeVault_;
        asset = IERC20(stakeVault_.asset());
        gate = gate_;
        credit = credit_;
        minSlice = minSlice_;
        asset.forceApprove(address(stakeVault_), type(uint256).max);
    }

    // ---------------------------------------------------------------- registry hooks

    /// @inheritdoc IVouchingModule
    function openCover(uint256 loanId, address borrower, uint256 maxCover, uint64 deadline)
        external
        onlyRole(REGISTRY_ROLE)
    {
        Cover storage c = _covers[loanId];
        if (c.state != CoverState.None) revert WrongState(loanId, c.state);
        c.borrower = borrower;
        c.state = CoverState.Open;
        c.deadline = deadline;
        c.maxCover = maxCover;
        emit CoverOpened(loanId, borrower, maxCover);
    }

    /// @inheritdoc IVouchingModule
    function lockCover(uint256 loanId) external onlyRole(REGISTRY_ROLE) returns (uint256 coverPrincipal) {
        Cover storage c = _requireState(loanId, CoverState.Open);
        c.state = CoverState.Locked;
        coverPrincipal = c.coverPrincipal;
        emit CoverLocked(loanId, coverPrincipal);
    }

    /// @inheritdoc IVouchingModule
    function cancelCover(uint256 loanId) external onlyRole(REGISTRY_ROLE) {
        Cover storage c = _covers[loanId];
        if (c.state != CoverState.Open && c.state != CoverState.Locked) revert WrongState(loanId, c.state);
        c.state = CoverState.Cancelled;
        emit CoverCancelled(loanId);
    }

    /// @inheritdoc IVouchingModule
    function releaseCover(uint256 loanId) external onlyRole(REGISTRY_ROLE) {
        _requireState(loanId, CoverState.Locked).state = CoverState.Released;
        emit CoverReleased(loanId);
    }

    /// @inheritdoc IVouchingModule
    function addPremium(uint256 loanId, uint256 amount) external onlyRole(REGISTRY_ROLE) {
        _requireState(loanId, CoverState.Locked).premium += amount;
        asset.safeTransferFrom(msg.sender, address(this), amount);
        emit PremiumAdded(loanId, amount);
    }

    /// @inheritdoc IVouchingModule
    function absorbLoss(uint256 loanId, uint256 loss, address to)
        external
        onlyRole(WATERFALL_ROLE)
        nonReentrant
        returns (uint256 absorbed)
    {
        Cover storage c = _requireState(loanId, CoverState.Locked);
        c.state = CoverState.Defaulted;
        uint256 value = stakeVault.previewRedeem(c.shares);
        absorbed = loss < value ? loss : value;
        uint256 burned;
        if (absorbed == value) {
            // Take everything: redeem all shares so no dust is left behind that could round the other way.
            if (c.shares > 0) absorbed = stakeVault.redeem(c.shares, to, address(this));
            burned = c.shares;
        } else if (absorbed > 0) {
            burned = stakeVault.withdraw(absorbed, to, address(this)); // shares rounded up: favours the loan
        }
        c.sharesAfterDefault = c.shares - burned;
        emit LossAbsorbed(loanId, loss, absorbed);
    }

    // ---------------------------------------------------------------- vouchers

    /// @inheritdoc IVouchingModule
    function stake(uint256 loanId, uint256 assets) external whenNotPaused nonReentrant {
        Cover storage c = _requireState(loanId, CoverState.Open);
        if (block.timestamp >= c.deadline) revert DeadlinePassed();
        if (msg.sender == c.borrower) revert SelfVouch();
        gate.requireNotSanctioned(msg.sender);
        if (credit.historyOf(msg.sender).defaultedLoans > 0) revert DelinquentVoucher(msg.sender);
        if (assets < minSlice) revert BelowMinSlice(assets, minSlice);
        uint256 room = c.maxCover - c.coverPrincipal;
        if (assets > room) revert CoverCapExceeded(assets, room);

        asset.safeTransferFrom(msg.sender, address(this), assets);
        uint256 shares = stakeVault.deposit(assets, address(this));

        Slice storage s = _slices[loanId][msg.sender];
        if (s.principal == 0) _stats[msg.sender].backed += 1;
        s.principal += assets;
        s.shares += shares;
        c.coverPrincipal += assets;
        c.shares += shares;
        emit Staked(loanId, msg.sender, assets, shares);
    }

    /// @inheritdoc IVouchingModule
    function unstake(uint256 loanId) external nonReentrant {
        Cover storage c = _covers[loanId];
        // Security M-1: stakes are binding like bids. Otherwise a griefer could fill all cover (blocking honest
        // vouchers) and pull it out just before the deadline so the loan cancels.
        if (c.state != CoverState.Cancelled) revert WrongState(loanId, c.state);
        gate.requireNotSanctioned(msg.sender);
        Slice storage s = _slices[loanId][msg.sender];
        uint256 shares = s.shares;
        if (shares == 0) revert NoSlice();
        c.coverPrincipal -= s.principal;
        c.shares -= shares;
        delete _slices[loanId][msg.sender];
        uint256 assets = stakeVault.redeem(shares, msg.sender, address(this));
        emit Unstaked(loanId, msg.sender, assets);
    }

    /// @inheritdoc IVouchingModule
    function claim(uint256 loanId) external nonReentrant returns (uint256 assets) {
        Cover storage c = _covers[loanId];
        bool defaulted = c.state == CoverState.Defaulted;
        if (!defaulted && c.state != CoverState.Released) revert WrongState(loanId, c.state);
        gate.requireNotSanctioned(msg.sender);
        Slice storage s = _slices[loanId][msg.sender];
        if (s.principal == 0) revert NoSlice();
        if (s.claimed) revert AlreadyClaimed();
        s.claimed = true;

        // Pro rata by shares (default) and by principal (premium); both round down, dust stays in the module.
        uint256 shares = defaulted ? Math.mulDiv(s.shares, c.sharesAfterDefault, c.shares) : s.shares;
        uint256 premiumShare = Math.mulDiv(c.premium, s.principal, c.coverPrincipal);
        uint256 stakeBack = shares > 0 ? stakeVault.redeem(shares, msg.sender, address(this)) : 0;
        if (premiumShare > 0) asset.safeTransfer(msg.sender, premiumShare);
        assets = stakeBack + premiumShare;

        VoucherStats storage st = _stats[msg.sender];
        if (defaulted) {
            st.defaulted += 1;
            if (stakeBack < s.principal) st.lost += s.principal - stakeBack;
        } else {
            st.repaid += 1;
        }
        emit Claimed(loanId, msg.sender, assets);
    }

    // ---------------------------------------------------------------- views and governance

    /// @inheritdoc IVouchingModule
    function coverOf(uint256 loanId) external view returns (Cover memory) {
        return _covers[loanId];
    }

    /// @inheritdoc IVouchingModule
    function coverValue(uint256 loanId) external view returns (uint256) {
        return stakeVault.previewRedeem(_covers[loanId].shares);
    }

    /// @inheritdoc IVouchingModule
    function sliceOf(uint256 loanId, address voucher) external view returns (Slice memory) {
        return _slices[loanId][voucher];
    }

    /// @inheritdoc IVouchingModule
    function statsOf(address voucher) external view returns (VoucherStats memory) {
        return _stats[voucher];
    }

    /// @inheritdoc IVouchingModule
    function setMinSlice(uint256 minSlice_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minSlice = minSlice_;
    }

    function _requireState(uint256 loanId, CoverState state) internal view returns (Cover storage c) {
        c = _covers[loanId];
        if (c.state != state) revert WrongState(loanId, c.state);
    }
}
