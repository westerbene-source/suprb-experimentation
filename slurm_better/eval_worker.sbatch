#!/usr/bin/env bash
#SBATCH --job-name=suprb_eval
#SBATCH --partition=cpu
#SBATCH --cpus-per-task=2
#SBATCH --mem-per-cpu=4G
#SBATCH --time=01:00:00
#SBATCH --output=output/eval_%j.out
#SBATCH --error=output/eval_%j.err
set -e

source /projects/shared/lib/slurm-utils.sh

PROJECT_DIR="/home/$USER/suprb-experimentation"
export PYTHONPATH="${PYTHONPATH}:${PROJECT_DIR}"
cd "${PROJECT_DIR}"

trap 'save_results "$SCRATCH" ~"/results/eval-${SLURM_JOB_ID}/task-${WORKER_ID}"' EXIT ERR SIGTERM

STORAGE_URL="postgresql://${PG_HOST}:${PG_PORT}/optuna_db"

nix develop ./slurm_better --no-pure-eval --command python - <<PYEOF
import psycopg2, sys
try:
    psycopg2.connect(dbname="optuna_db", host="${PG_HOST}", port="${PG_PORT}").close()
except Exception as e:
    print(f"DB connection FAILED: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

nix develop ./slurm_better --no-pure-eval --command \
    env \
        PYTHONPATH="${PROJECT_DIR}:${PYTHONPATH}" \
        OPTUNA_STORAGE="${STORAGE_URL}" \
        OPTUNA_STUDY_NAME="${STUDY_NAME}" \
    python "${PROJECT_DIR}/runs/subsumption/evaluate_only.py" \
        -p "${DATASET}" \
        -j "${SLURM_JOB_ID}" \
        -o "${OPTIMIZER}" \
        --worker-id "${WORKER_ID}"