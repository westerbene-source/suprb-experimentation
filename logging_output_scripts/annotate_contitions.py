#!/usr/bin/env python3
"""
Classifies every fold-run's experimental condition (rule-discovery method,
pruning on/off, adaptive control on/off) from its logged params.json
artifact, and writes the result back as MLflow tags:

    tags.rd_method   -> "es" | "ns"
    tags.pruning     -> "on" | "off"
    tags.adaptive    -> "on" | "off"
    tags.condition   -> "<rd_method>_<pruning|nopruning>_<adaptive|noadaptive>"

Run this ONCE against the merged mlruns store, after merge_mlruns.py and
before mlruns_to_csv / the plotting pipeline. Always run with dry_run=True
first and eyeball the printed condition counts before writing anything.

Classification basis (confirmed from actual params.json files):
  - rule_discovery starts with "NoveltySearch(" -> ns, else -> es
  - rule_discovery__subsumption is None/"None"  -> pruning off
                                 otherwise       -> pruning on   (this is a
    100% new contribution -- it never existed before pruning was added, so
    "None" reliably means "no pruning")
  - early_stopping_patience == -1 AND
    extra_rules_patience   == -1                -> adaptive off
    (either != -1)                               -> adaptive on
    (-1 is SupRB's disabled-feature sentinel, confirmed from your own
    params.json examples)

Usage:
    python annotate_conditions.py --tracking-uri file:///path/to/merged/mlruns --dry-run
    python annotate_conditions.py --tracking-uri file:///path/to/merged/mlruns
"""
import argparse
import json
import os
from collections import Counter, defaultdict

from mlflow.tracking import MlflowClient


def classify_condition(params: dict) -> dict:
    rd_raw = params.get("rule_discovery") or ""
    rd_class = rd_raw.split("(")[0].strip()
    rd_method = "ns" if rd_class == "NoveltySearch" else "es"

    pruning_on = params.get("rule_discovery__subsumption") not in (None, "None")

    adaptive_on = (
        params.get("early_stopping_patience", -1) != -1
        or params.get("extra_rules_patience", -1) != -1
    )

    return {
        "rd_method": rd_method,
        "pruning": "on" if pruning_on else "off",
        "adaptive": "on" if adaptive_on else "off",
        "condition": f"{rd_method}_{'pruning' if pruning_on else 'nopruning'}_"
                     f"{'adaptive' if adaptive_on else 'noadaptive'}",
    }


def _params_path_for_run(run) -> str:
    artifact_dir = run.info.artifact_uri.replace("file://", "")
    return os.path.join(artifact_dir, "params.json")


def annotate_all_runs(tracking_uri: str, dry_run: bool = True) -> None:
    client = MlflowClient(tracking_uri=tracking_uri)
    runs = client.search_runs(search_all_experiments=True, max_results=50000)
    print(f"Found {len(runs)} total runs in store.")

    condition_counts = Counter()
    missing_by_fold_tag = defaultdict(int)
    tagged = 0

    for run in runs:
        params_path = _params_path_for_run(run)
        if not os.path.exists(params_path):
            missing_by_fold_tag[run.data.tags.get("fold", "<no fold tag>")] += 1
            continue

        with open(params_path) as f:
            params = json.load(f)

        tags = classify_condition(params)
        condition_counts[tags["condition"]] += 1

        if not dry_run:
            for k, v in tags.items():
                client.set_tag(run.info.run_id, k, v)
            tagged += 1

    print("\n=== Condition counts (runs WITH a params.json) ===")
    for cond, count in sorted(condition_counts.items()):
        print(f"  {cond:30s} {count}")
    if len(condition_counts) != 8:
        print(f"\n  ^^ WARNING: expected exactly 8 distinct conditions, found {len(condition_counts)}. "
              f"Check the list above before trusting the tagging.")

    print("\n=== Runs with NO params.json, broken down by tags.fold ===")
    for fold_tag, count in missing_by_fold_tag.items():
        print(f"  fold={fold_tag!r:20s} {count}")
    print("  (Expected: this should be mostly/only root/tuning-summary runs, i.e. fold='True' "
        "missing here would mean an actual fold run is missing its params.json -- investigate that.)")

    if dry_run:
        print("\nDRY RUN -- no tags were written. Re-run with --no-dry-run once the counts above look right.")
    else:
        print(f"\nWrote condition tags to {tagged} runs.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--tracking-uri", required=True, help="e.g. file:///home/wolfbene/final-eval/mlruns")
    parser.add_argument("--dry-run", dest="dry_run", action="store_true", default=True)
    parser.add_argument("--no-dry-run", dest="dry_run", action="store_false")
    args = parser.parse_args()

    annotate_all_runs(args.tracking_uri, dry_run=args.dry_run)