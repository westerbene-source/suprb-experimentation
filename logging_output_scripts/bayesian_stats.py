"""
Statistical comparison utilities for the final SupRB thesis evaluation.

Primary basis: Cohen's d_z (paired effect size) for PRACTICAL significance.
Bayesian paired t-test is the primary SIGNIFICANCE test. A frequentist
paired t-test is included for completeness only, per the thesis
methodology -- it is not the basis for any conclusion on its own.

Pairing is done at the SEED level (up to 25 independent random_state
values per condition), not at the raw fold level (200 rows). The 25 seeds
are independent ShuffleSplit draws with no overlapping training data
between them, so they do NOT need the correlated-t-test correction that
comparisons over overlapping CV folds require -- use
bayesian_paired_ttest() (uncorrelated) for the seed-level comparisons this
module is built around.

bayesian_correlated_ttest() is included separately in case you decide you
actually want the raw fold-level (n<=200, overlapping-fold) comparison
instead -- do not mix the two pairing levels within one table, since they
answer different questions (seed-level: "does this generalize across
random data partitions"; fold-level: "is there a difference in this
specific set of folds").
"""
import os

import numpy as np
import pandas as pd
from scipy import stats as sps


def cohens_dz(diffs: np.ndarray) -> float:
    """Cohen's d_z for paired differences: mean(diff) / std(diff)."""
    diffs = np.asarray(diffs)
    return diffs.mean() / diffs.std(ddof=1)


def effect_size_label(dz: float) -> str:
    a = abs(dz)
    if a < 0.2:
        return "negligible"
    if a < 0.5:
        return "small"
    if a < 0.8:
        return "medium"
    return "large"


def frequentist_paired_ttest(a: np.ndarray, b: np.ndarray) -> float:
    """Two-sided p-value of a standard paired t-test. Reported for completeness only."""
    _, p = sps.ttest_rel(a, b)
    return p


def bayesian_paired_ttest(diffs: np.ndarray, rope: float = 0.0) -> dict:
    """
    Bayesian paired t-test for INDEPENDENT paired samples (no CV-fold
    correlation correction) -- use this for seed-level comparisons.
    rope: region of practical equivalence, +/- this value around zero.
    """
    diffs = np.asarray(diffs)
    n = len(diffs)
    mean = diffs.mean()
    std = diffs.std(ddof=1)
    scale = std / np.sqrt(n)
    posterior = sps.t(df=n - 1, loc=mean, scale=scale)
    return {
        "mean_diff": mean,
        "p_a_better": 1 - posterior.cdf(rope),
        "p_b_better": posterior.cdf(-rope),
        "p_rope": posterior.cdf(rope) - posterior.cdf(-rope),
    }


def bayesian_correlated_ttest(diffs: np.ndarray, n_train: int, n_test: int, rope: float = 0.0) -> dict:
    """
    Bayesian CORRELATED t-test (Benavoli et al. 2017 / Nadeau-Bengio
    correction) for comparisons over OVERLAPPING CV folds (e.g. raw
    fold-level rows from one ShuffleSplit scheme). rho = n_test / (n_train
    + n_test) is the standard correction for this train/test split ratio.
    Only use this if you deliberately switch to fold-level pairing.
    """
    diffs = np.asarray(diffs)
    n = len(diffs)
    mean = diffs.mean()
    var = diffs.var(ddof=1)
    rho = n_test / (n_train + n_test)
    scale = np.sqrt(var * (1 / n + rho / (1 - rho)))
    posterior = sps.t(df=n - 1, loc=mean, scale=scale)
    return {
        "mean_diff": mean,
        "p_a_better": 1 - posterior.cdf(rope),
        "p_b_better": posterior.cdf(-rope),
        "p_rope": posterior.cdf(rope) - posterior.cdf(-rope),
    }


def load_condition_seed_means(dataset: str, condition: str, subdir: str, metric_col: str) -> pd.Series:
    """
    Reads the per-dataset CSV exported by mlruns_to_csv, filters to one
    condition, and averages `metric_col` across the 8 folds within each
    seed (params.random_state). Returns a Series indexed by seed.
    """
    path = os.path.join("mlruns_csv", subdir, f"{dataset}_all.csv")
    df = pd.read_csv(path)
    if "params.random_state" not in df.columns:
        raise KeyError(
            f"'params.random_state' column missing from {path}. Make sure mlruns_to_csv's exported "
            f"columns include 'params.random_state' (needed for seed-level pairing)."
        )
    sub = df[df["tags.condition"] == condition]
    if sub.empty:
        available = sorted(df["tags.condition"].dropna().unique().tolist())
        raise ValueError(f"No rows for condition={condition!r} in {path}. Available: {available}")
    return sub.groupby("params.random_state")[metric_col].mean()


def compare_conditions(dataset: str, cond_a: str, cond_b: str, subdir: str, metric_col: str,
                        label_a: str, label_b: str, rope: float = 0.0) -> dict:
    seeds_a = load_condition_seed_means(dataset, cond_a, subdir, metric_col)
    seeds_b = load_condition_seed_means(dataset, cond_b, subdir, metric_col)
    common = seeds_a.index.intersection(seeds_b.index)

    n_a, n_b = len(seeds_a), len(seeds_b)
    if len(common) < n_a or len(common) < n_b:
        print(f"WARNING [{dataset}] {label_a} vs {label_b}: only {len(common)} seeds in common "
              f"(a has {n_a}, b has {n_b}) -- a seed likely failed/was killed on one side. "
              f"Check before trusting this row.")

    a = seeds_a.loc[common].values
    b = seeds_b.loc[common].values
    diffs = a - b

    dz = cohens_dz(diffs)
    bayes = bayesian_paired_ttest(diffs, rope=rope)
    p_freq = frequentist_paired_ttest(a, b)

    return {
        "dataset": dataset,
        "comparison": f"{label_a} vs {label_b}",
        "n_seeds": len(common),
        "cohens_dz": dz,
        "effect_size": effect_size_label(dz),
        "p_a_better_bayes": bayes["p_a_better"],
        "p_rope_bayes": bayes["p_rope"],
        "p_freq": p_freq,
    }


def generate_comparison_table(datasets: list, condition_pairs: list, subdir: str, metric_col: str,
                               out_path: str, rope: float = 0.0) -> pd.DataFrame:
    """
    condition_pairs: list of (cond_a, cond_b, label_a, label_b) tuples.
    Writes a LaTeX table to out_path and returns the underlying DataFrame.
    """
    rows = []
    for dataset in datasets:
        for cond_a, cond_b, label_a, label_b in condition_pairs:
            try:
                rows.append(compare_conditions(dataset, cond_a, cond_b, subdir, metric_col, label_a, label_b, rope))
            except (ValueError, KeyError) as e:
                print(f"SKIPPED [{dataset}] {label_a} vs {label_b}: {e}")

    result_df = pd.DataFrame(rows)

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    lines = [
        r"\begin{tabular}{llrrrrr}",
        r"\hline",
        r"Dataset & Comparison & $n$ & $d_z$ & Effect & $P(\text{a better})$ & $p$ (freq.) \\",
        r"\hline",
    ]
    for _, r in result_df.iterrows():
        lines.append(
            f"{r['dataset']} & {r['comparison']} & {r['n_seeds']} & {r['cohens_dz']:.3f} & "
            f"{r['effect_size']} & {r['p_a_better_bayes']:.3f} & {r['p_freq']:.4f} \\\\"
        )
    lines += [r"\hline", r"\end{tabular}"]
    with open(out_path, "w") as f:
        f.write("\n".join(lines))

    return result_df