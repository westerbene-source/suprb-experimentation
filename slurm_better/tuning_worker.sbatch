#!/usr/bin/env bash
# Submitted individually by coordinator.sh, once per worker, only after the
# DB is confirmed ready. OPTIMIZER/DATASET/PG_SOCKET_DIR/STUDY_NAME/
# TIMEOUT_HOURS/WORKER_ID passed via --export. Not meant to be submitted
# directly.
#SBATCH --job-name=suprb_tune
#SBATCH --partition=cpu
#SBATCH --cpus-per-task=2
#SBATCH --mem-per-cpu=2G
#SBATCH --time=26:00:00
#SBATCH --output=output/tune_%j.out
#SBATCH --error=output/tune_%j.err
set -e

source /projects/shared/lib/slurm-utils.sh

PROJECT_DIR="/home/$USER/suprb-experimentation"
export PYTHONPATH="${PYTHONPATH}:${PROJECT_DIR}"
cd "${PROJECT_DIR}"

trap 'save_results "$SCRATCH" ~"/results/tuning-${SLURM_JOB_ID}/task-${WORKER_ID}"' EXIT ERR SIGTERM

STORAGE_URL="postgresql+psycopg2:///optuna_db?host=${PG_SOCKET_DIR}"

nix develop ./slurm_better --no-pure-eval --command python - <<PYEOF
import psycopg2, sys
try:
    psycopg2.connect(dbname="optuna_db", host="${PG_SOCKET_DIR}").close()
except Exception as e:
    print(f"DB connection FAILED: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

TIMEOUT_SECONDS=$(python3 -c "print(int(float('${TIMEOUT_HOURS}') * 3600))")

nix develop ./slurm_better --no-pure-eval --command \
    env \
        PYTHONPATH="${PROJECT_DIR}:${PYTHONPATH}" \
        OPTUNA_STORAGE="${STORAGE_URL}" \
        OPTUNA_STUDY_NAME="${STUDY_NAME}" \
        WORKER_TIMEOUT="${TIMEOUT_SECONDS}" \
    python "${PROJECT_DIR}/runs/subsumption/tune_only.py" \
        -p "${DATASET}" \
        -j "${SLURM_JOB_ID}" \
        -o "${OPTIMIZER}" \
        --worker-id "${WORKER_ID}"
