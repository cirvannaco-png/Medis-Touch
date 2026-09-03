from .models import ParameterSpec

PARAMETERS = {
    "ensemble_threshold": ParameterSpec(
        "ensemble_threshold", "int", 55, 85, 1, 62,
        max_relative_change=0.10, max_absolute_change=5,
    ),
    "smc_threshold": ParameterSpec(
        "smc_threshold", "int", 50, 85, 1, 60,
        max_relative_change=0.15, max_absolute_change=5,
    ),
    "momentum_threshold": ParameterSpec(
        "momentum_threshold", "int", 50, 85, 1, 60,
        max_relative_change=0.15, max_absolute_change=5,
    ),
    "breakout_threshold": ParameterSpec(
        "breakout_threshold", "int", 50, 85, 1, 60,
        max_relative_change=0.15, max_absolute_change=5,
    ),
    "mean_reversion_threshold": ParameterSpec(
        "mean_reversion_threshold", "int", 50, 85, 1, 60,
        max_relative_change=0.15, max_absolute_change=5,
    ),
    "key_level_threshold": ParameterSpec(
        "key_level_threshold", "int", 50, 85, 1, 60,
        max_relative_change=0.15, max_absolute_change=5,
    ),
    "fvg_proximity_atr": ParameterSpec(
        "fvg_proximity_atr", "float", 0.05, 1.00, 0.05, 0.20,
        max_relative_change=0.25, max_absolute_change=0.10,
    ),
    "contradiction_penalty": ParameterSpec(
        "contradiction_penalty", "float", 0.0, 0.50, 0.01, 0.10,
        max_relative_change=0.25, max_absolute_change=0.05,
    ),
    "freshness_bars": ParameterSpec(
        "freshness_bars", "int", 3, 30, 1, 12,
        max_relative_change=0.25, max_absolute_change=4,
    ),
}
