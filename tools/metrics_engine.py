"""
tools/metrics_engine.py — Step 2 of the trade-tagging system: the
two-track metrics engine.

Queries `signal_outcomes` (see telegram-bridge/app/models.py, migration
0005) and reports coverage and expectancy as two SEPARATE tracks, never
blended into one number. This is deliberate: a recalibration cycle can
raise coverage (more signals, better regime spread) while expectancy
(win rate, avg R) quietly gets worse underneath it, or vice versa — a
single blended score hides exactly that split.

  COVERAGE  — is the EA generating signals where/how it should, and are
              they getting a chance to prove themselves? Counts EVERY
              row, including no_fill/ambiguous, broken down by tag.
  EXPECTANCY — of the signals that actually got a chance (filled,
              resolved to win/loss/scratch), how good were they? Never
              includes no_fill/ambiguous rows — there's no realized R to
              average there.

USAGE
    cd telegram-bridge && python ../tools/metrics_engine.py
    python tools/metrics_engine.py --since 2026-08-01
    python tools/metrics_engine.py --weight-version v2.10-baseline
    python tools/metrics_engine.py --json   # machine-readable, for the
                                             # future gating layer (step 4)
                                             # to consume instead of
                                             # re-deriving this by hand

Runs against the same DATABASE_URL the bridge itself uses (app.config)
via the bridge's own async engine — this tool is meant to run FROM the
telegram-bridge checkout, not standalone, since it deliberately doesn't
duplicate the schema or the DB connection logic. If `app` doesn't import,
run from the telegram-bridge/ directory or set PYTHONPATH to it.

HONEST LIMITATIONS — read before trusting a report from this:
  1. "Missed-long rate" here means "rate of BUY signals that resolved
     no_fill", NOT "regimes where a long should have fired but didn't" —
     this tool only ever sees signals the EA actually generated. A
     structural bias where the EA fails to generate BUY setups at all in
     some regime is invisible to a query over signal_outcomes; it would
     show up as a suspiciously low BUY count in a regime/session bucket,
     which the coverage report surfaces, but this tool doesn't diagnose
     WHY that count is low.
  2. Every row here is tagged by the WEIGHT VERSION active when the
     signal was generated (Signal.weight_version / InpWeightSetVersion),
     which today is a hand-bumped string, not an automatically versioned
     artifact — see EA/MedisTouch_v2.8.mq5 InpWeightSetVersion comment.
     If nobody bumped it across a scoring-formula change, this tool has
     no way to tell two different formulas apart and will silently pool
     them under one label. Steps 4-6 (gating/promotion/scheduler) are
     what eventually make this automatic and enforced.
  3. Confidence-vs-realized-R is reported as a simple decile bucket
     table, not a correlation coefficient or AUC with a confidence
     interval — that's step 4 (Statistical gating layer), which needs a
     stable backtest/report output format to exist first (this one) to
     build on top of.
  4. No calibration adjustment: realized_r here is exactly what
     OutcomeTracker's simulator computed (see its own extensive header
     comment in EA/includes/Trading/OutcomeTracker.mqh for the
     assumptions baked into THAT number — same-bar collision handling,
     one-position-at-a-time sizing, no portfolio-level exposure caps).
     This tool reports what's in signal_outcomes; it doesn't re-derive it.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone

# Allow running as `python tools/metrics_engine.py` from the repo root OR
# from telegram-bridge/, and being *imported* from app/calibration.py
# inside the deployed container — see tools/_pathutil.py for why this
# isn't a single hardcoded relative path.
_TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
if _TOOLS_DIR not in sys.path:
    sys.path.insert(0, _TOOLS_DIR)
from _pathutil import ensure_bridge_importable  # noqa: E402
ensure_bridge_importable(__file__)

try:
    from sqlalchemy import select

    from app.database import async_session
    from app.models import SignalOutcome
except ImportError as exc:  # pragma: no cover - operator-facing message, not a test path
    print(
        "metrics_engine: couldn't import the bridge's `app` package "
        f"({exc}). Run this from telegram-bridge/, or with telegram-bridge/ "
        "on PYTHONPATH — it deliberately reuses the bridge's own DB "
        "connection/settings rather than duplicating them.",
        file=sys.stderr,
    )
    sys.exit(1)

from stats import auc_with_ci, pearson_ci, wilson_ci

RESOLVED_OUTCOMES = {"win", "loss", "scratch"}  # expectancy track only counts these
CONFIDENCE_BUCKET_WIDTH = 10.0  # 0-100 confidence score -> deciles


@dataclass
class TagBreakdown:
    """One tag's worth of coverage + expectancy numbers, e.g. one row per regime."""
    tag_value: str
    total: int = 0
    by_outcome: dict = field(default_factory=lambda: defaultdict(int))
    by_direction: dict = field(default_factory=lambda: defaultdict(int))
    realized_r_sum: float = 0.0
    realized_r_count: int = 0

    @property
    def resolved_count(self) -> int:
        return sum(self.by_outcome.get(o, 0) for o in RESOLVED_OUTCOMES)

    @property
    def win_rate(self) -> float | None:
        if self.resolved_count == 0:
            return None
        return self.by_outcome.get("win", 0) / self.resolved_count

    @property
    def avg_r(self) -> float | None:
        if self.realized_r_count == 0:
            return None
        return self.realized_r_sum / self.realized_r_count

    @property
    def no_fill_rate(self) -> float | None:
        if self.total == 0:
            return None
        return self.by_outcome.get("no_fill", 0) / self.total


def _group_by(rows, keyfn):
    out: dict[str, list] = defaultdict(list)
    for r in rows:
        out[keyfn(r) or "(untagged)"].append(r)
    return dict(out)


def _bucket(rows, keyfn):
    out: dict[str, TagBreakdown] = {}
    for r in rows:
        key = keyfn(r) or "(untagged)"
        tb = out.setdefault(key, TagBreakdown(tag_value=key))
        tb.total += 1
        tb.by_outcome[r.outcome] += 1
        tb.by_direction[r.direction] += 1
        if r.outcome in RESOLVED_OUTCOMES and r.realized_r is not None:
            tb.realized_r_sum += r.realized_r
            tb.realized_r_count += 1
    return dict(sorted(out.items(), key=lambda kv: -kv[1].total))


def _resolved_stats(rows) -> dict:
    """
    The three CI-bearing statistics step 4's gating layer actually
    consumes: win-rate CI (Wilson), confidence's AUC for win-vs-loss
    (Hanley-McNeil CI), and confidence-vs-realized-R correlation (Fisher
    z CI). Computed over whatever `rows` it's given — callers pass either
    all resolved rows (overall) or a single weight_version's subset.
    """
    resolved = [r for r in rows if r.outcome in RESOLVED_OUTCOMES]
    win_scores = [r.confidence_at_signal for r in resolved if r.outcome == "win" and r.confidence_at_signal is not None]
    loss_scores = [r.confidence_at_signal for r in resolved if r.outcome == "loss" and r.confidence_at_signal is not None]
    pairs = [
        (r.confidence_at_signal, r.realized_r)
        for r in resolved
        if r.confidence_at_signal is not None and r.realized_r is not None
    ]
    wins = sum(1 for r in resolved if r.outcome == "win")

    return {
        "win_rate": wilson_ci(wins, len(resolved)).to_dict(),
        "confidence_auc": auc_with_ci(win_scores, loss_scores).to_dict(),
        "confidence_r_correlation": pearson_ci(pairs).to_dict(),
    }


def compute_report(rows) -> dict:
    total = len(rows)
    resolved = [r for r in rows if r.outcome in RESOLVED_OUTCOMES]
    no_fill = [r for r in rows if r.outcome == "no_fill"]
    ambiguous = [r for r in rows if r.outcome == "ambiguous"]

    by_direction_total = defaultdict(int)
    by_direction_no_fill = defaultdict(int)
    for r in rows:
        by_direction_total[r.direction] += 1
        if r.outcome == "no_fill":
            by_direction_no_fill[r.direction] += 1

    coverage = {
        "total_signals": total,
        "no_fill_count": len(no_fill),
        "no_fill_rate": (len(no_fill) / total) if total else None,
        "ambiguous_count": len(ambiguous),
        "directional_bias": {
            d: {
                "count": by_direction_total[d],
                "share": by_direction_total[d] / total if total else None,
                "no_fill_rate": (
                    by_direction_no_fill[d] / by_direction_total[d]
                    if by_direction_total[d] else None
                ),
            }
            for d in by_direction_total
        },
        "by_regime": {k: _tb_to_coverage_dict(v) for k, v in _bucket(rows, lambda r: r.regime).items()},
        "by_session": {k: _tb_to_coverage_dict(v) for k, v in _bucket(rows, lambda r: r.session).items()},
        "by_weight_version": {
            k: _tb_to_coverage_dict(v) for k, v in _bucket(rows, lambda r: r.weight_version).items()
        },
    }

    expectancy = {
        "resolved_count": len(resolved),
        "overall_win_rate": (
            sum(1 for r in resolved if r.outcome == "win") / len(resolved) if resolved else None
        ),
        "overall_avg_r": (
            sum(r.realized_r for r in resolved if r.realized_r is not None) / len(resolved)
            if resolved else None
        ),
        # v2.11 step 4 — CI-bearing stats, not point estimates. Computed
        # once overall and once per weight_version (the comparison unit
        # the gating layer actually promotes/rejects on).
        "overall_stats": _resolved_stats(rows),
        "by_weight_version_stats": {
            wv: _resolved_stats(group_rows)
            for wv, group_rows in _group_by(rows, lambda r: r.weight_version).items()
        },
        "by_regime": {k: _tb_to_expectancy_dict(v) for k, v in _bucket(rows, lambda r: r.regime).items()},
        "by_session": {k: _tb_to_expectancy_dict(v) for k, v in _bucket(rows, lambda r: r.session).items()},
        "by_sweep_grade": {
            k: _tb_to_expectancy_dict(v) for k, v in _bucket(rows, lambda r: r.sweep_grade).items()
        },
        "by_htf_ob_aligned": {
            k: _tb_to_expectancy_dict(v)
            for k, v in _bucket(rows, lambda r: "aligned" if r.htf_ob_aligned else "not_aligned").items()
        },
        "by_weight_version": {
            k: _tb_to_expectancy_dict(v) for k, v in _bucket(rows, lambda r: r.weight_version).items()
        },
        "realized_r_by_confidence_decile": _confidence_deciles(resolved),
    }

    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "coverage": coverage,
        "expectancy": expectancy,
    }


def _tb_to_coverage_dict(tb: TagBreakdown) -> dict:
    return {
        "total": tb.total,
        "no_fill_rate": tb.no_fill_rate,
        "buy_count": tb.by_direction.get("BUY", 0),
        "sell_count": tb.by_direction.get("SELL", 0),
    }


def _tb_to_expectancy_dict(tb: TagBreakdown) -> dict:
    return {
        "resolved_count": tb.resolved_count,
        "win_rate": tb.win_rate,
        "avg_r": tb.avg_r,
    }


def _confidence_deciles(resolved_rows) -> dict:
    buckets: dict[str, list[float]] = defaultdict(list)
    for r in resolved_rows:
        if r.confidence_at_signal is None or r.realized_r is None:
            continue
        lo = int(r.confidence_at_signal // CONFIDENCE_BUCKET_WIDTH) * int(CONFIDENCE_BUCKET_WIDTH)
        hi = lo + int(CONFIDENCE_BUCKET_WIDTH)
        buckets[f"{lo}-{hi}"].append(r.realized_r)
    return {
        k: {"n": len(v), "avg_r": sum(v) / len(v)}
        for k, v in sorted(buckets.items(), key=lambda kv: int(kv[0].split("-")[0]))
    }


def compute_regime_matrix(rows) -> list[dict]:
    """
    Symbol x Session x Regime cross-tab: Trades, Win%, Avg R, Profit
    Factor, and max drawdown (in R) — the exact table shape requested:
    "that will expose where Medis Touch actually [works]." Only resolved
    rows (win/loss/scratch) count here; coverage (no_fill/ambiguous) is
    metrics_engine's other report, not this one — mixing them would
    understate win rate for buckets with a lot of no-fills for reasons
    that have nothing to do with trade quality.

    PF = sum(positive R) / abs(sum(negative R)). Undefined (None) if
    there are no losses — reported as None, not a fabricated large
    number or infinity, since "no losses yet" and "PF isn't meaningful
    at this sample size" are the same problem in practice.

    Max drawdown is computed on the CUMULATIVE REALIZED-R CURVE for that
    bucket specifically, ordered by received_at — i.e. "if these trades
    were the only thing you took, in this order, how far underwater did
    the R-equity curve get." It is NOT a portfolio-level drawdown (other
    symbols/buckets trading concurrently isn't modeled here) — see the
    honest-limitations note in the module docstring.
    """
    buckets: dict[tuple, list] = defaultdict(list)
    for r in rows:
        if r.outcome not in RESOLVED_OUTCOMES:
            continue
        key = (r.symbol, r.session or "(untagged)", r.regime or "(untagged)")
        buckets[key].append(r)

    out = []
    for (symbol, session_tag, regime), bucket_rows in buckets.items():
        bucket_rows.sort(key=lambda r: r.received_at or datetime.min.replace(tzinfo=timezone.utc))
        n = len(bucket_rows)
        wins = sum(1 for r in bucket_rows if r.outcome == "win")
        r_values = [r.realized_r for r in bucket_rows if r.realized_r is not None]

        gains = sum(v for v in r_values if v > 0)
        losses_abs = abs(sum(v for v in r_values if v < 0))
        pf = (gains / losses_abs) if losses_abs > 0 else None

        cum, peak, max_dd = 0.0, 0.0, 0.0
        for v in r_values:
            cum += v
            peak = max(peak, cum)
            max_dd = max(max_dd, peak - cum)

        out.append({
            "symbol": symbol,
            "session": session_tag,
            "regime": regime,
            "trades": n,
            "win_rate": (wins / n) if n else None,
            "avg_r": (sum(r_values) / len(r_values)) if r_values else None,
            "profit_factor": pf,
            "max_drawdown_r": max_dd,
        })

    out.sort(key=lambda d: -d["trades"])
    return out


def print_regime_matrix(matrix: list[dict]) -> None:
    print("=" * 96)
    print("REGIME MATRIX — Symbol x Session x Volatility (resolved trades only)")
    print("=" * 96)
    header = f"{'Symbol':10s} {'Session':10s} {'Volatility':10s} {'Trades':>7s} {'Win %':>8s} {'Avg R':>8s} {'PF':>6s} {'MaxDD(R)':>9s}"
    print(header)
    print("-" * len(header))
    for row in matrix:
        win_pct = f"{row['win_rate'] * 100:.1f}%" if row["win_rate"] is not None else "n/a"
        avg_r = f"{row['avg_r']:+.2f}" if row["avg_r"] is not None else "n/a"
        pf = f"{row['profit_factor']:.2f}" if row["profit_factor"] is not None else "n/a"
        print(
            f"{row['symbol']:10s} {row['session']:10s} {row['regime']:10s} "
            f"{row['trades']:7d} {win_pct:>8s} {avg_r:>8s} {pf:>6s} {row['max_drawdown_r']:9.2f}"
        )
    print()


def _fmt_pct(x):
    return f"{x * 100:.1f}%" if x is not None else "n/a"


def _fmt_r(x):
    return f"{x:+.2f}R" if x is not None else "n/a"


def _fmt_ci(stat_dict: dict, pct: bool = False) -> str:
    v, lo, hi, n = stat_dict.get("value"), stat_dict.get("ci_low"), stat_dict.get("ci_high"), stat_dict.get("n", 0)
    if v is None:
        return f"n/a (n={n}, not enough data)"
    if pct:
        return f"{v * 100:.1f}% [{lo * 100:.1f}%, {hi * 100:.1f}%]  (n={n})"
    return f"{v:.3f} [{lo:.3f}, {hi:.3f}]  (n={n})"


def print_report(report: dict) -> None:
    cov, exp = report["coverage"], report["expectancy"]

    print("=" * 72)
    print(f"TWO-TRACK METRICS REPORT — {report['generated_at']}")
    print("=" * 72)

    print("\n--- COVERAGE (every signal, including no-fill/ambiguous) ---")
    print(f"Total signals:      {cov['total_signals']}")
    print(f"No-fill rate:       {_fmt_pct(cov['no_fill_rate'])} ({cov['no_fill_count']} signals)")
    print(f"Ambiguous count:    {cov['ambiguous_count']}")
    print("\nDirectional bias:")
    for d, v in cov["directional_bias"].items():
        print(f"  {d:5s} count={v['count']:5d}  share={_fmt_pct(v['share'])}  no_fill_rate={_fmt_pct(v['no_fill_rate'])}")
    print("\nSignal frequency by regime:")
    for k, v in cov["by_regime"].items():
        print(f"  {k:14s} total={v['total']:5d}  no_fill_rate={_fmt_pct(v['no_fill_rate'])}  buy={v['buy_count']} sell={v['sell_count']}")
    print("\nSignal frequency by session:")
    for k, v in cov["by_session"].items():
        print(f"  {k:14s} total={v['total']:5d}  no_fill_rate={_fmt_pct(v['no_fill_rate'])}  buy={v['buy_count']} sell={v['sell_count']}")
    print("\nSignal frequency by weight version:")
    for k, v in cov["by_weight_version"].items():
        print(f"  {k:20s} total={v['total']:5d}  no_fill_rate={_fmt_pct(v['no_fill_rate'])}")

    print("\n--- EXPECTANCY (resolved trades only: win/loss/scratch) ---")
    print(f"Resolved count:     {exp['resolved_count']}")
    print(f"Overall win rate:   {_fmt_pct(exp['overall_win_rate'])}")
    print(f"Overall avg R:      {_fmt_r(exp['overall_avg_r'])}")
    st = exp["overall_stats"]
    print("\nOverall statistics (CIs, not point estimates):")
    print(f"  win_rate:              {_fmt_ci(st['win_rate'], pct=True)}")
    print(f"  confidence AUC:        {_fmt_ci(st['confidence_auc'])}")
    print(f"  confidence-R corr.:    {_fmt_ci(st['confidence_r_correlation'])}")
    print("\nBy weight version (CIs):")
    for wv, s in exp["by_weight_version_stats"].items():
        print(f"  {wv}")
        print(f"    win_rate:            {_fmt_ci(s['win_rate'], pct=True)}")
        print(f"    confidence AUC:      {_fmt_ci(s['confidence_auc'])}")
        print(f"    confidence-R corr.:  {_fmt_ci(s['confidence_r_correlation'])}")
    print("\nBy regime:")
    for k, v in exp["by_regime"].items():
        print(f"  {k:14s} n={v['resolved_count']:5d}  win_rate={_fmt_pct(v['win_rate'])}  avg_r={_fmt_r(v['avg_r'])}")
    print("\nBy session:")
    for k, v in exp["by_session"].items():
        print(f"  {k:14s} n={v['resolved_count']:5d}  win_rate={_fmt_pct(v['win_rate'])}  avg_r={_fmt_r(v['avg_r'])}")
    print("\nBy sweep grade:")
    for k, v in exp["by_sweep_grade"].items():
        print(f"  {k:14s} n={v['resolved_count']:5d}  win_rate={_fmt_pct(v['win_rate'])}  avg_r={_fmt_r(v['avg_r'])}")
    print("\nBy HTF OB alignment:")
    for k, v in exp["by_htf_ob_aligned"].items():
        print(f"  {k:14s} n={v['resolved_count']:5d}  win_rate={_fmt_pct(v['win_rate'])}  avg_r={_fmt_r(v['avg_r'])}")
    print("\nBy weight version:")
    for k, v in exp["by_weight_version"].items():
        print(f"  {k:20s} n={v['resolved_count']:5d}  win_rate={_fmt_pct(v['win_rate'])}  avg_r={_fmt_r(v['avg_r'])}")
    print("\nRealized R by confidence decile (resolved trades only):")
    for k, v in exp["realized_r_by_confidence_decile"].items():
        print(f"  confidence {k:8s} n={v['n']:5d}  avg_r={_fmt_r(v['avg_r'])}")
    print()


async def fetch_rows(since: datetime | None, weight_version: str | None):
    async with async_session() as session:
        stmt = select(SignalOutcome)
        if since is not None:
            stmt = stmt.where(SignalOutcome.received_at >= since)
        if weight_version is not None:
            stmt = stmt.where(SignalOutcome.weight_version == weight_version)
        result = await session.execute(stmt)
        return list(result.scalars().all())


async def run(args) -> int:
    since = datetime.fromisoformat(args.since).replace(tzinfo=timezone.utc) if args.since else None
    rows = await fetch_rows(since, args.weight_version)
    if not rows:
        print(
            "metrics_engine: no rows in signal_outcomes matching the given filters. "
            "This is expected until the EA/bridge changes that populate it (step 1) "
            "have actually run and resolved at least a few setups.",
            file=sys.stderr,
        )
        return 1

    report = compute_report(rows)
    if args.regime_matrix:
        matrix = compute_regime_matrix(rows)
        if args.json:
            print(json.dumps(matrix, indent=2, default=str))
        else:
            print_regime_matrix(matrix)
        return 0
    if args.json:
        print(json.dumps(report, indent=2, default=str))
    else:
        print_report(report)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--since", help="ISO date/datetime — only rows received at/after this (e.g. 2026-08-01)")
    parser.add_argument("--weight-version", help="only rows tagged with this exact weight_version")
    parser.add_argument("--json", action="store_true", help="machine-readable output (for step 4's gating layer)")
    parser.add_argument("--regime-matrix", action="store_true", help="print the Symbol x Session x Volatility matrix instead of the two-track report")
    args = parser.parse_args()
    sys.exit(asyncio.run(run(args)))


if __name__ == "__main__":
    main()
