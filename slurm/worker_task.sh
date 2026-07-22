#!/usr/bin/env bash
###############################################################################
# worker_task.sh
#
# Body of a single worker task. Launched by the srun step in worker.sbatch —
# one copy per task, all starting at the same wall-clock time as part of one
# combined allocation. Do NOT submit this file directly with sbatch; it
# relies on env vars exported by the coordinator (OPTIMIZER, DATASET,
# PG_SOCKET_DIR, STUDY_NAME, TIMEOUT_HOURS) and on the Slurm-provided
# SLURM_PROCID / SLURM_JOB_ID variables set by srun.
###############################################################################
set -e

WORKER_ID="${SLURM_PROCID}"
PROJECT_DIR="/home/$USER/suprb-experimentation"
EXPERIMENT="runs/subsumption/subsumable_db.py"

source /projects/shared/lib/slurm-utils.sh

trap '
    echo "[$(date)] Worker ${WORKER_ID} trap: saving results..."
    save_results "$SCRATCH" ~"/results/sweep-${SLURM_JOB_ID}/task-${WORKER_ID}"
' EXIT ERR SIGTERM

cd "${PROJECT_DIR}"

# Small jitter (a few seconds) only to avoid every task hitting the shared
# Postgres socket in the exact same instant. This is NOT a start-time
# stagger — all tasks are already running at this point.
sleep $(( WORKER_ID % 5 ))

echo "[$(date)] Worker ${WORKER_ID}: checking devenv..."
nix develop ./slurm --no-pure-eval --command python --version

# ---------------------------------------------------------------------------
# Verify the PostgreSQL socket is reachable before starting expensive work
# ---------------------------------------------------------------------------
STORAGE_URL="postgresql+psycopg2:///optuna_db?host=${PG_SOCKET_DIR}"

echo "[$(date)] Worker ${WORKER_ID}: verifying DB connection..."
nix develop ./slurm --no-pure-eval --command python - <<PYEOF
import psycopg2, sys
try:
    conn = psycopg2.connect(dbname="optuna_db", host="${PG_SOCKET_DIR}")
    conn.close()
    print("DB connection OK")
except Exception as e:
    print(f"DB connection FAILED: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

# ---------------------------------------------------------------------------
# Run the experiment — one trial-contributing worker
# ---------------------------------------------------------------------------
echo "[$(date)] Worker ${WORKER_ID}: starting experiment (optimizer=${OPTIMIZER}, dataset=${DATASET})"

TIMEOUT_SECONDS=$(python3 -c "print(int(float('${TIMEOUT_HOURS}') * 3600))")

nix develop ./slurm --no-pure-eval --command \
    env \
        PYTHONPATH="${PROJECT_DIR}:${PYTHONPATH}" \
        OPTUNA_STORAGE="${STORAGE_URL}" \
        OPTUNA_STUDY_NAME="${STUDY_NAME}" \
        WORKER_TIMEOUT="${TIMEOUT_SECONDS}" \
    python "${PROJECT_DIR}/${EXPERIMENT}" \
        -p "${DATASET}" \
        -j "${SLURM_JOB_ID}" \
        -o "${OPTIMIZER}" \
        --worker-id "${WORKER_ID}"

echo "[$(date)] Worker ${WORKER_ID}: finished."
