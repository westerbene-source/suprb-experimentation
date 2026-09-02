#!/usr/bin/env bash
set -e

PROJECT_DIR="/home/$USER/suprb-experimentation"

OPTIMIZER="spea2"
DATASET="parkinson_total"
STUDY_NAME="spea2_tuning_parkinson_total_spea2_parkinson_total"
STUDY_DB="${PROJECT_DIR}/studies/${STUDY_NAME}.db"

sbatch --nodelist=oc-compute04 \
    --array=0-2 \
    --export=ALL,OPTIMIZER="${OPTIMIZER}",DATASET="${DATASET}",STUDY_NAME="${STUDY_NAME}",OPTUNA_STORAGE="sqlite:///${STUDY_DB}" \
    slurm_better/eval_worker.sbatch