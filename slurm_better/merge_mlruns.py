#!/usr/bin/env python3
"""
Merge per-worker mlflow local file stores into one shared store.

Each eval worker writes to its own local scratch mlruns/ (to avoid NFS lock
contention). This script reads each worker's store via the mlflow client API
and re-creates every run in the destination store, since run/experiment IDs
and artifact_location paths are local to each store and can't be merged by
copying files directly.

Usage:
    python merge_mlruns.py --dest file:///home/user/suprb-experimentation/mlruns \
        --sources /home/user/mlruns-eval-8564/task-0/mlruns \
                  /home/user/mlruns-eval-8564/task-1/mlruns \
                  ...
"""

import argparse
import shutil
import tempfile
from pathlib import Path

import mlflow
from mlflow.entities import Metric, Param, RunTag
from mlflow.tracking import MlflowClient


def merge_experiment(src_client: MlflowClient, dst_client: MlflowClient, src_exp, dest_exp_id: str):
    runs = src_client.search_runs(
        experiment_ids=[src_exp.experiment_id],
        max_results=50000,
    )
    print(f"  {len(runs)} runs found in source experiment '{src_exp.name}' ({src_exp.experiment_id})")

    for run in runs:
        info, data = run.info, run.data

        new_run = dst_client.create_run(
            experiment_id=dest_exp_id,
            start_time=info.start_time,
            tags={k: v for k, v in data.tags.items() if not k.startswith("mlflow.")},
        )
        new_run_id = new_run.info.run_id

        # Params
        params = [Param(k, v) for k, v in data.params.items()]

        # Metrics: fetch full history (not just the latest value)
        metrics = []
        for key in data.metrics:
            for m in src_client.get_metric_history(info.run_id, key):
                metrics.append(Metric(m.key, m.value, m.timestamp, m.step))

        # Tags, keep run_name if present
        tags = [RunTag(k, v) for k, v in data.tags.items() if not k.startswith("mlflow.")]

        # log_batch has a size limit; chunk if needed
        def chunks(lst, n):
            for i in range(0, len(lst), n):
                yield lst[i : i + n]

        for m_chunk in chunks(metrics, 900) if metrics else [[]]:
            dst_client.log_batch(new_run_id, metrics=m_chunk, params=[], tags=[])
        if params:
            dst_client.log_batch(new_run_id, metrics=[], params=params, tags=[])
        if tags:
            dst_client.log_batch(new_run_id, metrics=[], params=[], tags=tags)

        # Artifacts
        with tempfile.TemporaryDirectory() as tmp:
            local_path = src_client.download_artifacts(info.run_id, "", tmp)
            if any(Path(local_path).iterdir()):
                dst_client.log_artifacts(new_run_id, local_path)

        dst_client.set_terminated(new_run_id, status=info.status, end_time=info.end_time)

    print(f"  merged {len(runs)} runs -> {dest_exp_id}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dest", required=True, help="Destination tracking URI, e.g. file:///path/to/mlruns")
    parser.add_argument("--sources", nargs="+", required=True, help="One or more source mlruns directories")
    parser.add_argument("--delete-sources", action="store_true", help="Remove source dirs after a successful merge")
    args = parser.parse_args()

    dst_client = MlflowClient(tracking_uri=args.dest)

    for src_dir in args.sources:
        src_path = Path(src_dir)
        if not src_path.is_dir():
            print(f"skip: {src_dir} does not exist")
            continue

        src_uri = f"file://{src_path.resolve()}"
        src_client = MlflowClient(tracking_uri=src_uri)

        print(f"Merging {src_uri} -> {args.dest}")
        for exp in src_client.search_experiments():
            if exp.name == "Default":
                continue

            dest_exp = dst_client.get_experiment_by_name(exp.name)
            if dest_exp is None:
                dest_exp_id = dst_client.create_experiment(exp.name)
            else:
                dest_exp_id = dest_exp.experiment_id

            merge_experiment(src_client, dst_client, exp, dest_exp_id)

        if args.delete_sources:
            shutil.rmtree(src_path)
            print(f"  removed {src_path}")

    print("Merge complete.")


if __name__ == "__main__":
    main()