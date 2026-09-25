"""Launch-default protocol parameters, mirrored from CLAUDE.md.

Fractions are plain floats (0.2 == 20%). Keep in sync with CLAUDE.md and the
on-chain defaults in contracts/src; the simulation sweeps around these values.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class Params:
    min_collateral: float = 0.20
    voucher_cover_min: float = 0.10
    voucher_cover_max: float = 0.90
    basket_leverage: float = 3.0
    withdrawal_notice_days_min: int = 30
    withdrawal_notice_days_max: int = 90
    concentration_cap: float = 0.25
    reserve_fee_min: float = 0.01
    reserve_fee_max: float = 0.02
    reserve_cap: float = 0.05
    reserve_gold_max: float = 0.20
    target_apr_min: float = 0.09
    target_apr_max: float = 0.13


LAUNCH = Params()
