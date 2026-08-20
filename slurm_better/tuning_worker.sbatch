#!/usr/bin/env bash
#SBATCH --job-name=suprb_tune
#SBATCH --partition=cpu
#SBATCH --cpus-per-task=2
#SBATCH --mem-per-cpu=2G
#SBATCH --time=26:00:00
#SBATCH --output=output/tune_%A_%a.out
#SBATCH --error=output/tune_%A_%a.err
set -e

unset SLURM_MEM_PER_NODE

source /projects/shared/lib/slurm-utils.sh

PROJECT_DIR="/home/$USER/suprb-experimentation"
cd "${PROJECT_DIR}"

trap 'save_results "$SCRATCH" ~"/results/tuning-${SLURM_ARRAY_JOB_ID}/task-${SLURM_ARRAY_TASK_ID}"' EXIT ERR SIGTERM

STORAGE_URL="postgresql://${PG_HOST}:${PG_PORT}/optuna_db"

# 1. Serialize devenv shell entry (fast — just cleanup + venv reconciliation)
flock /home/$USER/suprb-experimentation/.devenv.lock \
    nix develop ./slurm_better --no-pure-eval --command true

# Test DB connectivity
nix develop ./slurm_better --no-pure-eval --command python - <<PYEOF
import psycopg2, sys
try:
    psycopg2.connect(dbname="optuna_db", host="${PG_HOST}", port="${PG_PORT}").close()
except Exception as e:
    print(f"DB connection FAILED: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

TIMEOUT_SECONDS=$(nix develop ./slurm_better --no-pure-eval --command \
    python -c "print(int(float('${TIMEOUT_HOURS}') * 3600))")

nix develop ./slurm_better --no-pure-eval --command \
    env \
        PYTHONPATH="${PROJECT_DIR}:${PYTHONPATH}" \
        OPTUNA_STORAGE="${STORAGE_URL}" \
        OPTUNA_STUDY_NAME="${STUDY_NAME}" \
        WORKER_TIMEOUT="${TIMEOUT_SECONDS}" \
    python "${PROJECT_DIR}/runs/subsumption/tune_only.py" \
        -p "${DATASET}" \
        -j "${SLURM_ARRAY_JOB_ID}" \
        -o "${OPTIMIZER}" \
        --worker-id "${SLURM_ARRAY_TASK_ID}"
