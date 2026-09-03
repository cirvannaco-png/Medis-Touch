import random


def bootstrap_mean_ci(returns, iterations=5000, confidence=0.95, seed=42):
    if len(returns) < 2:
        raise ValueError("at least two observations required")
    rng = random.Random(seed)  # nosec B311 - deterministic bootstrap, not security use
    n = len(returns)
    means = []
    for _ in range(iterations):
        means.append(sum(returns[rng.randrange(n)] for _ in range(n)) / n)
    means.sort()
    alpha = (1 - confidence) / 2
    return (
        sum(returns) / n,
        means[int(alpha * len(means))],
        means[int((1 - alpha) * len(means)) - 1],
    )
