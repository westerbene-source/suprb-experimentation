import json
import os
import sys

import mlflow
import numpy as np
import time

from logging_output_scripts import violin_and_swarm_plots
from logging_output_scripts import moo_plots
from logging_output_scripts.stat_analysis import calvo, ttest, cohens_pairwise_d
from logging_output_scripts.utils import filter_runs

saga_datasets = {
    "combined_cycle_power_plant": "Combined Cycle Power Plant",
    "airfoil_self_noise": "Airfoil Self-Noise",
    "concrete_strength": "Concrete Strength",
    # "energy_cool": "Energy Efficiency Cooling",
    "protein_structure": "Physiochemical Properties of Protein Tertiary Structure",
    "parkinson_total": "Parkinson's Telemonitoring"
}

datasets_no_pppts = {
    "combined_cycle_power_plant": "Combined Cycle Power Plant",
    "airfoil_self_noise": "Airfoil Self-Noise",
    "concrete_strength": "Concrete Strength",
    "parkinson_total": "Parkinson's Telemonitoring"
}


def mlruns_to_csv(datasets, subdir, normalize):
    all_runs_df = mlflow.search_runs(search_all_experiments=True)

    experiments = mlflow.search_experiments()

    experiment_names = {
       exp.experiment_id: exp.name
       for exp in experiments
    }

    all_runs_df["experiment_name"] = all_runs_df["experiment_id"].map(experiment_names)

    # Condition tags (written by annotate_conditions.py) and the seed key
    # (needed for seed-level pairing in the stats) get carried through into
    # the exported CSVs whenever they're present, without requiring them to
    # exist (so this still works for older, non-condition-tagged settings).
    extra_cols = [
        c for c in ["tags.condition", "tags.rd_method", "tags.pruning", "tags.adaptive", "params.random_state"]
        if c in all_runs_df.columns
    ]

    print("Dataset\t\t\tMin MSE\tMax MSE\tMin Complexity\tMax Complexity")
    for dataset in datasets:
        mse = "metrics.test_neg_mean_squared_error"
        complexity = "metrics.elitist_complexity"
        hypervolume = "metrics.hypervolume"
        sc_iters = "metrics.sc_iterations"
        spread = "metrics.spread"
        test_hypervolume = "metrics.test_hypervolume"
        df = all_runs_df[
            all_runs_df["experiment_name"].str.contains(
                f"p:{dataset}",
                case=False,
                na=False,
            )
            & (all_runs_df["tags.fold"] == "True")
        ]
        df = df[
            ["tags.mlflow.runName", "artifact_uri", mse, complexity, hypervolume, test_hypervolume, spread, sc_iters]
            + extra_cols
        ]
        print(f"{dataset}\t\t\t{np.min(df[mse]):.4f}\t{np.max(df[mse]):.4f}\t{np.min(df[complexity]):.4f}\t"
              f"{np.max(df[complexity]):.4f}")

        roots = all_runs_df[all_runs_df["tags.mlflow.runName"].str.contains(
            dataset, case=False, na=False) & (all_runs_df["tags.root"] == 'True')]
        roots = roots[["tags.mlflow.runName", "artifact_uri", "params.tuned_params"] + extra_cols]

        df[mse] *= -1
        if normalize:
            df[mse] = (df[mse] - np.min(df[mse])) / (np.max(df[mse]) - np.min(df[mse]))
            df[complexity] = (df[complexity] - np.min(df[complexity])) / (
                    np.max(df[complexity]) - np.min(df[complexity]))
        os.makedirs(f"mlruns_csv/{subdir}", exist_ok=True)
        df.to_csv(f"mlruns_csv/{subdir}/{dataset}_all.csv", index=False)
        roots.to_csv(f"mlruns_csv/{subdir}/{dataset}_roots.csv", index=False)


ga_baseline = {
    "Baseline c:ga32": "GA 32",
    "Baseline c:ga64": "GA 64",
}

ga_baseline_more_tuning = {
    "Baseline c:ga32": "GA 32",
    "Baseline c:ga64": "GA 64",
}

moo_baseline = {
    "Baseline nsga2": "NSGA-II",
    "Baseline nsga3": "U-NSGA-III",
    "Baseline spea2": "SPEA2",
}

spea2_only = {"Baseline spea2": "SPEA2"}

# --- Final evaluation: condition-tag-based comparisons (2 x 4 design) -----
# Keys must exactly match the tags.condition values written by
# annotate_conditions.py.
final_eval_es = {
    "es_nopruning_noadaptive": "ES Baseline",
    "es_pruning_noadaptive": "ES + Pruning",
    "es_nopruning_adaptive": "ES + Adaptive",
    "es_pruning_adaptive": "ES + Pruning + Adaptive",
}
final_eval_ns = {
    "ns_nopruning_noadaptive": "NS Baseline",
    "ns_pruning_noadaptive": "NS + Pruning",
    "ns_nopruning_adaptive": "NS + Adaptive",
    "ns_pruning_adaptive": "NS + Pruning + Adaptive",
}


def run_main():
    with open("logging_output_scripts/config.json", "r") as f:
        config = json.load(f)

    config["datasets"] = current_dataset

    config["output_directory"] = setting[0]
    if not os.path.isdir("diss-graphs/graphs"):
        os.mkdir("diss-graphs/graphs")

    if not os.path.isdir(config["output_directory"]):
        os.makedirs(config["output_directory"])

    config["normalize_datasets"] = setting[3]

    config["heuristics"] = setting[1]
    config["reference_heuristics"] = setting[5] if len(setting) > 5 else {}
    config["data_directory"] = setting[4]
    config["use_condition_tags"] = setting[6] if len(setting) > 6 else False

    with open("logging_output_scripts/config.json", "w") as f:
        json.dump(config, f)

    time.sleep(10)

    all_runs_df = mlflow.search_runs(search_all_experiments=True)
    filter_runs(all_runs_df)

    if len(config["heuristics"]) > 1:
        try:
            calvo(ylabel=setting[2])
        except Exception as e:
            # calvo() lives in stat_analysis.py, which may still filter by
            # runName substring and not understand condition-tag keys.
            print(f"WARNING: calvo() failed ({type(e).__name__}: {e}) -- continuing without it.")

    moo_plots.create_plots()


if __name__ == '__main__':
    final_eval_es_setting = [
        "diss-graphs/graphs/FINAL_EVAL_ES", final_eval_es, "Configuration", False,
        "mlruns_csv/FINAL_EVAL_ES", {}, True,
    ]
    final_eval_ns_setting = [
        "diss-graphs/graphs/FINAL_EVAL_NS", final_eval_ns, "Configuration", False,
        "mlruns_csv/FINAL_EVAL_NS", {}, True,
    ]

    current_dataset = saga_datasets

    for setting in [final_eval_es_setting, final_eval_ns_setting]:
        mlruns_to_csv(current_dataset, subdir=setting[4].split("/")[-1], normalize=True)
        run_main()
        print(f"\nFinished creating plots for {setting[4].split('/')[-1]}")