"""
Reads the per-dataset CSVs exported by mlruns_to_csv() and filters them by
condition tag. This is a drop-in replacement for utils.get_csv_df /
utils.get_csv_root_df, used only when cfg["use_condition_tags"] is set --
it deliberately does not touch utils.py, since the tag-based scheme filters
on 'tags.condition' rather than a runName substring.

Requires that mlruns_to_csv() includes 'tags.condition' among the columns
it exports (see generate_final_eval_plots.py).
"""
import os

import pandas as pd

# (dataset, condition) cells that are KNOWINGLY absent from the data, e.g. a
# run that was never executed. For exactly these cells the loader returns an
# empty DataFrame plus a loud warning instead of raising, so the rest of the
# pipeline still runs. Any cell NOT listed here still raises, so typos or
# genuinely lost data are never silently swallowed.
#
# ES run12 (sub001 on combined_cycle_power_plant) was never run. The condition
# name below is an assumption (sub001 = pruning without adaptive) -- confirm it
# against the annotate_conditions.py dry-run counts and fix it if needed.
KNOWN_MISSING = {
    ("combined_cycle_power_plant", "es_pruning_noadaptive"),
}


def _load(path: str, problem: str, condition: str) -> pd.DataFrame:
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
        if (problem, condition) in KNOWN_MISSING:
            print(f"WARNING: no data for condition={condition!r} on {problem!r} -- listed in KNOWN_MISSING, "
                  f"continuing without it.")
            return df.iloc[0:0].copy()
        available = sorted(df["tags.condition"].dropna().unique().tolist())
        raise ValueError(f"No rows with tags.condition == {condition!r} in {path}. Available: {available}")
    return out


def get_condition_df(problem: str, condition: str, subdir: str) -> pd.DataFrame:
    path = os.path.join("mlruns_csv", subdir, f"{problem}_all.csv")
    return _load(path, problem, condition)


def get_condition_root_df(problem: str, condition: str, subdir: str) -> pd.DataFrame:
    path = os.path.join("mlruns_csv", subdir, f"{problem}_roots.csv")
    return _load(path, problem, condition)