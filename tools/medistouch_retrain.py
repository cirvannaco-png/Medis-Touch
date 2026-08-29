#!/usr/bin/env python3
"""Offline check of the v2.10 diagnostic confidence model against real outcomes.

The EA logs two CSVs per symbol (see EA/includes/Core/SignalLogger.mqh):

    MedisTouch_Signals_<SYMBOL>.csv    one row per published setup
    MedisTouch_Outcomes_<SYMBOL>.csv   one row per resolved setup, joined by SignalID

Since v2.10 the outcome rows also carry the diagnostic columns: Confidence
(the live additive score), EnvExecConfidence (the candidate multiplicative
score), ContradictionPenalty, EnvScore, ExecScore, ConfidenceAtSignal,
ConfidenceDecayed and DecayBars.

This script answers one question and refuses to answer any other:

    on THIS account's resolved trades, does the multiplicative score rank
    outcomes better than the additive score the EA currently acts on?

It does not fit weights and it does not write anything back into the EA.
That is deliberate. The diagnostic columns exist to be measured first; a
score that has not beaten the live model out of sample has not earned the
right to size a position. If the comparison favours the additive score -- or
the sample is too small to tell -- the correct action is to keep collecting
data, not to promote the model.

Usage:
    python tools/medistouch_retrain.py MedisTouch_Outcomes_XAUUSD.csv
    python tools/medistouch_retrain.py outcomes.csv --min-sample 50

Standard library only, so it runs anywhere the EA's CSVs land.
"""

from __future__ import annotations

import argparse
import csv
import math
import sys
from dataclasses import dataclass
from typing import Optional

# Outcome labels the tracker writes that mean "this resolved as a win"/"a loss".
WIN_OUTCOMES = {"TP1", "TP2", "FINAL_TP", "TP", "WIN"}
LOSS_OUTCOMES = {"SL", "STOP", "LOSS"}


@dataclass
class Row:
    signal_id: str
    outcome: str
    win: bool
    realized_r: float
    additive: float          # Confidence -- what the EA acts on today
    multiplicative: float    # EnvExecConfidence -- the v2.10 candidate
    contradiction: float
    env: float
    execution: float
    conf_at_signal: float
    conf_decayed: float
    decay_bars: int


def _f(row, key, default=0.0):
    raw = (row.get(key) or "").strip()
    if not raw:
        return default
    try:
        return float(raw)
    except ValueError:
        return default


def load(path):
    """Read an outcomes CSV, keeping only rows that actually resolved.

    Unresolved / still-tracking rows carry no verdict, so including them
    would let the model score itself against outcomes nobody knows yet.
    """
    rows = []
    with open(path, newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames is None:
            return rows
        fields = set(reader.fieldnames)
        missing = {"EnvExecConfidence"} - fields
        if not ({"Confidence", "ConfidenceAtSignal"} & fields):
            missing.add("Confidence")
        if missing:
            raise SystemExit(
                "%s: missing v2.10 diagnostic column(s): %s.\n"
                "This file predates v2.10 -- collect fresh logs before comparing models."
                % (path, ", ".join(sorted(missing)))
            )
        for raw in reader:
            outcome = (raw.get("Outcome") or "").strip().upper()
            if outcome not in WIN_OUTCOMES and outcome not in LOSS_OUTCOMES:
                continue  # unresolved, expired, or a label this script does not judge
            additive = _f(raw, "Confidence", _f(raw, "ConfidenceAtSignal"))
            rows.append(
                Row(
                    signal_id=(raw.get("SignalID") or "").strip(),
                    outcome=outcome,
                    win=outcome in WIN_OUTCOMES,
                    realized_r=_f(raw, "RealizedR"),
                    additive=additive,
                    multiplicative=_f(raw, "EnvExecConfidence"),
                    contradiction=_f(raw, "ContradictionPenalty"),
                    env=_f(raw, "EnvScore"),
                    execution=_f(raw, "ExecScore"),
                    conf_at_signal=_f(raw, "ConfidenceAtSignal", additive),
                    conf_decayed=_f(raw, "ConfidenceDecayed", additive),
                    decay_bars=int(_f(raw, "DecayBars")),
                )
            )
    return rows


def auc(scores, wins):
    """Probability a random win outranks a random loss (ties count as half).

    AUC, not accuracy: a confidence score's job is to RANK setups, and
    accuracy would depend on whatever execution threshold happens to be
    configured. Returns None when one class is absent -- nothing to rank.
    """
    pos = [s for s, w in zip(scores, wins) if w]
    neg = [s for s, w in zip(scores, wins) if not w]
    if not pos or not neg:
        return None
    better = 0.0
    for p in pos:
        for n in neg:
            if p > n:
                better += 1.0
            elif p == n:
                better += 0.5
    return better / (len(pos) * len(neg))


def correlation(xs, ys):
    n = len(xs)
    if n < 3:
        return None
    mx, my = sum(xs) / n, sum(ys) / n
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    sxx = sum((x - mx) ** 2 for x in xs)
    syy = sum((y - my) ** 2 for y in ys)
    if sxx <= 0 or syy <= 0:
        return None
    return sxy / math.sqrt(sxx * syy)


def fmt(value):
    return "n/a" if value is None else "%.3f" % value


def report(rows, min_sample):
    total = len(rows)
    wins = [r.win for r in rows]
    win_count = sum(1 for w in wins if w)
    print("Resolved setups: %d  (wins %d, losses %d)" % (total, win_count, total - win_count))

    if total < min_sample:
        print(
            "\nSAMPLE TOO SMALL (<%d). No conclusion. Keep the v2.10 diagnostics\n"
            "logging and re-run later -- promoting a model on a handful of trades\n"
            "is how you overfit an account to noise." % min_sample
        )
        return 0

    a_auc = auc([r.additive for r in rows], wins)
    m_auc = auc([r.multiplicative for r in rows], wins)
    d_auc = auc([r.conf_decayed for r in rows], wins)

    print("\nRanking quality (AUC; 0.5 = coin flip, higher is better):")
    print("  additive Confidence      %s   <- what the EA acts on today" % fmt(a_auc))
    print("  multiplicative EnvExec   %s   <- v2.10 candidate" % fmt(m_auc))
    print("  decayed Confidence       %s   <- staleness-adjusted" % fmt(d_auc))

    r_vals = [r.realized_r for r in rows]
    print("\nComponent correlation with realized R:")
    print("  ContradictionPenalty  %s  (expect NEGATIVE if real)" % fmt(correlation([r.contradiction for r in rows], r_vals)))
    print("  EnvScore              %s  (expect positive if real)" % fmt(correlation([r.env for r in rows], r_vals)))
    print("  ExecScore             %s  (expect positive if real)" % fmt(correlation([r.execution for r in rows], r_vals)))
    print("  DecayBars             %s  (expect NEGATIVE if staleness hurts)" % fmt(correlation([float(r.decay_bars) for r in rows], r_vals)))

    print("\nVerdict:")
    if a_auc is None or m_auc is None:
        print("  Only one outcome class present -- nothing to rank. No conclusion.")
        return 0
    margin = m_auc - a_auc
    if margin > 0.02:
        print(
            "  The multiplicative score ranks better by %.3f AUC on this sample.\n"
            "  That is a reason to test it on a HELD-OUT period, not to switch yet.\n"
            "  Split the logs by date and confirm the edge survives out of sample." % margin
        )
    elif margin < -0.02:
        print(
            "  The additive score still ranks better (by %.3f AUC).\n"
            "  Keep v2.10 diagnostic-only. Do not promote the multiplicative model." % -margin
        )
    else:
        print(
            "  No meaningful difference between the two scores on this sample.\n"
            "  Keep v2.10 diagnostic-only and keep collecting."
        )
    print(
        "\nNothing was changed. This script never edits the EA: promoting the model\n"
        "means deliberately editing Analysis/Scoring.mqh, reviewed as a change in\n"
        "trading behaviour."
    )
    return 0


def main(argv):
    parser = argparse.ArgumentParser(
        description="Compare the v2.10 diagnostic confidence model against the live additive score."
    )
    parser.add_argument("csv", help="MedisTouch_Outcomes_<SYMBOL>.csv written by the EA")
    parser.add_argument(
        "--min-sample",
        type=int,
        default=30,
        help="resolved setups required before any verdict is printed (default 30)",
    )
    args = parser.parse_args(argv)

    rows = load(args.csv)
    if not rows:
        print("%s: no resolved setups found -- nothing to evaluate." % args.csv)
        return 0
    return report(rows, args.min_sample)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
