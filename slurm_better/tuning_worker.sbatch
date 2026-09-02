#!/usr/bin/env bash
#SBATCH --job-name=suprb_tune
#SBATCH --partition=cpu
#SBATCH --cpus-per-task=2
#SBATCH --mem=1G
#SBATCH --time=26:00:00
#SBATCH --output=output/tune_%A_%a.out
#SBATCH --error=output/tune_%A_%a.err
set -e

unset SLURM_MEM_PER_NODE

source /projects/shared/lib/slurm-utils.sh

PROJECT_DIR="/home/$USER/suprb-experimentation"
cd "${PROJECT_DIR}"

if [ -n "$USER_SCRATCH" ]; then
    export XDG_RUNTIME_DIR="${USER_SCRATCH}/xdg_runtime_${SLURM_ARRAY_JOB_ID}_${SLURM_ARRAY_TASK_ID}"
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"
    echo "[$(date)] Overrode XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR}"
else
    echo "Warning: USER_SCRATCH not set, leaving XDG_RUNTIME_DIR as-is — midnight nix develop failures may recur" >&2
fi

trap 'rm -rf "$XDG_RUNTIME_DIR"; save_results "$SCRATCH" ~"/results/tuning-${SLURM_ARRAY_JOB_ID}/task-${SLURM_ARRAY_TASK_ID}"' EXIT SIGTERM

STORAGE_URL="postgresql://${PG_HOST}:${PG_PORT}/optuna_db"

sleep $(( SLURM_ARRAY_TASK_ID % 5 ))

exec 9>"${PROJECT_DIR}/.devenv.lock"
flock 9

nix develop ./slurm_better --no-pure-eval --command bash -c '
    flock -u 9
    exec env \
        PYTHONPATH="'"${PROJECT_DIR}"':${PYTHONPATH}" \
        OPTUNA_STORAGE="'"${STORAGE_URL}"'" \
        OPTUNA_STUDY_NAME="'"${STUDY_NAME}"'" \
        TIMEOUT_HOURS="'"${TIMEOUT_HOURS}"'" \
    python "'"${PROJECT_DIR}"'/runs/subsumption/tune_only.py" \
        -p "'"${DATASET}"'" \
        -j "'"${SLURM_ARRAY_JOB_ID}"'" \
        -o "'"${OPTIMIZER}"'" \
        --worker-id "'"${SLURM_ARRAY_TASK_ID}"'"
'