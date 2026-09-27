"""
Produces the Cohen's d_z / Bayesian paired t-test / frequentist paired
t-test significance tables for the final evaluation.

Run this AFTER generate_final_eval_plots.py has produced the per-dataset
CSVs under mlruns_csv/FINAL_EVAL_ES and mlruns_csv/FINAL_EVAL_NS.

Decide the metric before running: hypervolume is recommended as the
primary comparison (captures front quality as a whole, which is what
pruning/adaptive control actually act on); test MSE is a reasonable
secondary/robustness check, but noisier since the reported solution is
stochastically SAMPLED from the Pareto front rather than a fixed point.
Run this script once per metric you want a table for.
"""
from bayesian_stats import generate_comparison_table

DATASETS = [
    "airfoil_self_noise",
    "concrete_strength",
    "combined_cycle_power_plant",
    "parkinson_total",
    "protein_structure",
]

# Pick ONE metric per run of this script.
METRIC = "metrics.hypervolume"                    # recommended primary
# METRIC = "metrics.test_neg_mean_squared_error"   # secondary/robustness check


def pairs_for(rd_method: str):
    """
    All 6 pairwise comparisons among the 4 conditions (baseline, pruning,
    adaptive, pruning+adaptive) -- i.e. every edge AND both diagonals of
    the 2x2 (pruning x adaptive) factorial square:

      - baseline -> pruning              (main effect of pruning alone)
      - baseline -> adaptive             (main effect of adaptive alone)
      - baseline -> pruning+adaptive     (combined effect vs. doing nothing)
      - pruning -> pruning+adaptive      (does adding adaptive help on top of pruning)
      - adaptive -> pruning+adaptive     (does adding pruning help on top of adaptive)
      - pruning -> adaptive              (which single intervention helps more)
    """
    base = f"{rd_method}_nopruning_noadaptive"
    pruning = f"{rd_method}_pruning_noadaptive"
    adaptive = f"{rd_method}_nopruning_adaptive"
    both = f"{rd_method}_pruning_adaptive"

    return [
        (base, pruning, "Baseline", "+ Pruning"),
        (base, adaptive, "Baseline", "+ Adaptive"),
        (base, both, "Baseline", "+ Pruning + Adaptive"),
        (pruning, both, "+ Pruning", "+ Pruning + Adaptive"),
        (adaptive, both, "+ Adaptive", "+ Pruning + Adaptive"),
        (pruning, adaptive, "+ Pruning", "+ Adaptive"),
    ]


if __name__ == "__main__":
    metric_tag = METRIC.split(".")[-1]
    for rd_method, subdir in [("es", "FINAL_EVAL_ES"), ("ns", "FINAL_EVAL_NS")]:
        df = generate_comparison_table(
            datasets=DATASETS,
            condition_pairs=pairs_for(rd_method),
            subdir=subdir,
            metric_col=METRIC,
            out_path=f"diss-graphs/graphs/FINAL_EVAL_{rd_method.upper()}/tables/significance_{metric_tag}.tex",
        )
        print(f"\n=== {rd_method.upper()} ({METRIC}) ===")
        print(df.to_string(index=False))