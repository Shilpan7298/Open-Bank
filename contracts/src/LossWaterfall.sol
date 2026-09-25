// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.35;

import {ProtocolAccess} from "./libraries/ProtocolAccess.sol";
import {ILossWaterfall} from "./interfaces/ILossWaterfall.sol";
import {ICollateralEscrow} from "./interfaces/ICollateralEscrow.sol";
import {IVouchingModule} from "./interfaces/IVouchingModule.sol";
import {IInsuranceBasket} from "./interfaces/IInsuranceBasket.sol";
import {IReserveVault} from "./interfaces/IReserveVault.sol";

/// @title LossWaterfall
/// @notice See {ILossWaterfall}. Holds no funds: each layer pays what it absorbs straight to the loan registry.
/// Every layer is called in order and takes min(remaining loss, its capacity for this loan), so a lower layer
/// only sees what the layers above could not cover. The vouching and basket layers are always called, even with
/// zero remaining loss, so their per-loan state settles (stakes claimable, exposure removed).
contract LossWaterfall is ILossWaterfall, ProtocolAccess {
    bytes32 public constant REGISTRY_ROLE = keccak256("REGISTRY_ROLE");

    ICollateralEscrow public immutable escrow;
    IVouchingModule public immutable vouching;
    IInsuranceBasket public immutable basket;
    IReserveVault public immutable reserve;

    mapping(uint256 loanId => bool) public allocated;
    mapping(uint256 loanId => Allocation) private _allocations;

    constructor(
        address admin,
        address guardian,
        ICollateralEscrow escrow_,
        IVouchingModule vouching_,
        IInsuranceBasket basket_,
        IReserveVault reserve_
    ) ProtocolAccess(admin, guardian) {
        escrow = escrow_;
        vouching = vouching_;
        basket = basket_;
        reserve = reserve_;
    }

    /// @inheritdoc ILossWaterfall
    function executeDefault(uint256 loanId, uint256 loss)
        external
        onlyRole(REGISTRY_ROLE)
        returns (Allocation memory a)
    {
        if (allocated[loanId]) revert AlreadyAllocated(loanId);
        allocated[loanId] = true;
        address to = msg.sender;
        a.loss = loss;
        uint256 remaining = loss;

        a.collateral = escrow.seize(loanId, remaining, to); // 1. borrower collateral
        remaining -= a.collateral;

        a.vouchers = vouching.absorbLoss(loanId, remaining, to); // 2. voucher stakes of this loan
        remaining -= a.vouchers;

        (a.basketJunior, a.basketSenior) = basket.absorbLoss(loanId, remaining, to); // 3. basket junior, senior
        remaining -= a.basketJunior + a.basketSenior;

        if (remaining > 0) {
            a.reserve = reserve.coverLoss(remaining, to); // 4. protocol reserve
            remaining -= a.reserve;
        }

        a.lenderLoss = remaining; // 5. senior lenders
        _allocations[loanId] = a;
        emit LossAllocated(loanId, a);
    }

    /// @inheritdoc ILossWaterfall
    function allocationOf(uint256 loanId) external view returns (Allocation memory) {
        return _allocations[loanId];
    }
}
