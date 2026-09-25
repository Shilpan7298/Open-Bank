// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.35;

/// @title IReserveVault
/// @notice Protocol reserve, the reinsurer after the insurance basket. Funded by a fee of 1-2% of principal
/// taken at drawdown. Holdings are capped at `capBps` of total outstanding principal: the fee is reduced so
/// intake never exceeds the cap, and any excess (after loans close) is rebated to the rebate recipient.
interface IReserveVault {
    event FeeCollected(uint256 principal, uint256 fee, uint256 fullFee);
    event LossCovered(uint256 requested, uint256 paid, address indexed to);
    event ExcessRebated(address indexed to, uint256 amount);
    event ParamsSet(uint16 feeBps, uint16 capBps, address rebateRecipient);
    event LoanRegistrySet(address registry);

    error RegistryAlreadySet();

    /// @notice Take the reserve fee for a loan of `principal` from the caller, reduced so reserve assets stay
    /// within the cap (outstanding principal must already include this loan). Loan registry only.
    /// @return fee Amount pulled.
    function collectFee(uint256 principal) external returns (uint256 fee);

    /// @notice Pay up to `amount` of a default loss to `to`. Loss waterfall only.
    /// @return paid min(amount, reserve assets).
    function coverLoss(uint256 amount, address to) external returns (uint256 paid);

    /// @notice Rebate reserve assets above the cap to the rebate recipient. Callable by anyone; the loan
    /// registry calls it whenever outstanding principal falls.
    /// @return rebated Amount sent.
    function sync() external returns (uint256 rebated);

    /// @notice Fee that `collectFee(principal)` would take now.
    function quoteFee(uint256 principal) external view returns (uint256);

    /// @notice Current cap: capBps x total outstanding principal.
    function cap() external view returns (uint256);

    /// @notice Reserve assets (internal accounting; direct transfers are ignored).
    function reserveAssets() external view returns (uint256);

    /// @notice Set fee (100-200 bps), cap (<= 500 bps) and rebate recipient. Timelock only.
    function setParams(uint16 feeBps, uint16 capBps, address rebateRecipient) external;

    /// @notice Set the loan registry that reports outstanding principal. Timelock only, once.
    function setLoanRegistry(address registry) external;
}
