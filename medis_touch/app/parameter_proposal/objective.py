from .models import Evaluation


def objective(expectancy_r, max_drawdown_r, expected_shortfall_r, turnover):
    return expectancy_r - 0.08 * max_drawdown_r - 0.12 * abs(expected_shortfall_r) - 0.01 * turnover


def score_evaluation(
    *,
    trades,
    expectancy_r,
    profit_factor,
    max_drawdown_r,
    expected_shortfall_r,
    win_rate,
    turnover,
    by_regime,
    by_session,
    by_symbol,
):
    return Evaluation(
        trades,
        expectancy_r,
        profit_factor,
        max_drawdown_r,
        expected_shortfall_r,
        win_rate,
        turnover,
        objective(expectancy_r, max_drawdown_r, expected_shortfall_r, turnover),
        by_regime,
        by_session,
        by_symbol,
    )
