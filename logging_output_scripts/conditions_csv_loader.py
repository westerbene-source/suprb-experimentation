"""
Reads the per-dataset CSVs exported by mlruns_to_csv() and filters them by
condition tag. This is a drop-in replacement for utils.get_csv_df /
utils.get_csv_root_df, used only when cfg["use_condition_tags"] is set --
it deliberately does not touch utils.py, since the tag-based scheme filters
on 'tags.condition' rather than a runName substring.

Requires that mlruns_to_csv() includes 'tags.condition' among the columns
it exports (see the updated generate_final_eval_plots.py).
"""
import os

import pandas as pd


def _load(path: str, condition: str) -> pd.DataFrame:
    if not os.path.exists(path):
        raise FileNotFoundError(f"{path} does not exist -- did you run mlruns_to_csv for this dataset/subdir yet?")
    df = pd.read_csv(path)
    if "tags.condition" not in df.columns:
        raise KeyError(
            f"'tags.condition' column missing from {path}. Make sure annotate_conditions.py ran "
            f"BEFORE mlruns_to_csv, and that mlruns_to_csv's exported columns include 'tags.condition'."
        )
    out = df[df["tags.condition"] == condition].reset_index(drop=True)
    if out.empty:
        available = sorted(df["tags.condition"].dropna().unique().tolist())
        raise ValueError(f"No rows with tags.condition == {condition!r} in {path}. Available: {available}")
    return out


def get_condition_df(problem: str, condition: str, subdir: str) -> pd.DataFrame:
    path = os.path.join("mlruns_csv", subdir, f"{problem}_all.csv")
    return _load(path, condition)


def get_condition_root_df(problem: str, condition: str, subdir: str) -> pd.DataFrame:
    path = os.path.join("mlruns_csv", subdir, f"{problem}_roots.csv")
    return _load(path, condition)