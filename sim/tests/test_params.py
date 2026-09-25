from obp_sim.params import LAUNCH


def test_launch_params_are_consistent():
    p = LAUNCH
    assert p.min_collateral >= 0.20
    assert 0 < p.voucher_cover_min < p.voucher_cover_max <= 0.90
    assert p.basket_leverage <= 3.0
    assert 30 <= p.withdrawal_notice_days_min <= p.withdrawal_notice_days_max <= 90
    assert p.concentration_cap <= 0.25
    assert 0.01 <= p.reserve_fee_min <= p.reserve_fee_max <= 0.02
    assert p.reserve_cap == 0.05
    assert p.reserve_gold_max <= 0.20
