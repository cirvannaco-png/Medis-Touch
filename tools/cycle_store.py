"""
tools/cycle_store.py — saves a metrics_engine.py report as a tagged
cycle file that gating.py can later load. This is the seam between
"dummy data now" and "real data later": every file in the history
directory carries a `source` ("live" or "synthetic") and gating.py
refuses to mix them (see gating.py:_validate_cycles).

Not a database — plain JSON files in a directory, matching this repo's
existing bias toward file-based tooling for solo-dev-run-manually
scripts (tools/medistogit_retrain.py reads CSVs; this writes them).
Step 6 (scheduler) is what eventually moves this into Postgres for a
proper audit trail across cycles — this is the minimum that lets steps
3-4 be exercised today.

USAGE
    # after running metrics_engine.py --json > /tmp/report.json
    python tools/cycle_store.py --report /tmp/report.json \\
        --source live --history metrics_history/
"""
from __future__ import annotations

import argparse
import json
import os
from datetime import datetime, timezone


def save_cycle(report: dict, source: str, history_dir: str) -> str:
    if source not in ("live", "synthetic"):
        raise ValueError(f"source must be 'live' or 'synthetic', got {source!r}")

    os.makedirs(history_dir, exist_ok=True)
    generated_at = report.get("generated_at") or datetime.now(timezone.utc).isoformat()
    stamped = dict(report)
    stamped["source"] = source
    stamped["cycle_id"] = f"{source}_{generated_at.replace(':', '').replace('+', '_')}"

    fname = f"{stamped['cycle_id']}.json"
    path = os.path.join(history_dir, fname)
    with open(path, "w") as fh:
        json.dump(stamped, fh, indent=2, default=str)
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--report", required=True, help="path to a metrics_engine.py --json output file")
    parser.add_argument("--source", required=True, choices=["live", "synthetic"])
    parser.add_argument("--history", required=True, help="directory to write the tagged cycle file into")
    args = parser.parse_args()

    with open(args.report) as fh:
        report = json.load(fh)
    path = save_cycle(report, args.source, args.history)
    print(f"Saved: {path}")


if __name__ == "__main__":
    main()
