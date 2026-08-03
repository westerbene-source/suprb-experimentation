#!/usr/bin/env bash
###############################################################################
# start_study.sbatch
#
# This is the COORDINATOR job. It:
#   1. Starts one shared PostgreSQL instance in a stable shared directory
#   2. Creates the Optuna study (so workers can use load_if_exists=True)
#   3. Submits ALL workers as ONE combined allocation (see worker.sbatch) so
#      they are scheduled atomically and start at the same wall-clock time
#   4. Waits for the worker job to finish
#   5. Exports the study to a local SQLite file (for offline Optuna dashboard)
#   6. Shuts down PostgreSQL cleanly
#
# Usage:
#   sbatch slurm/start_study.sbatch --optimizer spea2 --dataset airfoil_self_noise --n-workers 25
#
# Or with defaults (see variables below):
#   sbatch slurm/start_study.sbatch
###############################################################################
#SBATCH --job-name=study_coordinator
#SBATCH --partition=cpu
#SBATCH --nodelist=oc-compute04
#SBATCH --cpus-per-task=4
#SBATCH --mem=8G
#SBATCH --time=100:00:00
#SBATCH --output=output/coordinator_%j.out
#SBATCH --error=output/coordinator_%j.err

# ---------------------------------------------------------------------------
# Parse arguments (override defaults via command line)
# ---------------------------------------------------------------------------
OPTIMIZER="spea2"
DATASET="airfoil_self_noise"
N_WORKERS=25          # how many parallel worker tasks to launch (all at once)
TIMEOUT_HOURS=24      # per-worker tuning budget passed to OptunaTuner's `timeout=` (hours)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --optimizer)  OPTIMIZER="$2";  shift 2 ;;
        --dataset)    DATASET="$2";    shift 2 ;;
        --n-workers)  N_WORKERS="$2";  shift 2 ;;
        --timeout)    TIMEOUT_HOURS="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

source /projects/shared/lib/slurm-utils.sh

PROJECT_DIR="/home/$USER/suprb-experimentation"
export PYTHONPATH="${PYTHONPATH}:${PROJECT_DIR}"

# Shared stable location for the PostgreSQL socket & data
# (NOT in $SCRATCH — that disappears when this job ends and workers are still running)
PG_BASE="${PROJECT_DIR}/.postgres_shared/${SLURM_JOB_ID}"
PG_DATA="${PG_BASE}/data"
PG_SOCKET_DIR="${PG_BASE}/socket"
READY_FLAG="${PG_BASE}/.pg_ready"

mkdir -p "$PG_DATA" "$PG_SOCKET_DIR"

# Export so worker.sbatch / worker_task.sh can pick these up
export PG_SOCKET_DIR
export STUDY_NAME="${OPTIMIZER}_tuning_${DATASET}_job${SLURM_JOB_ID}"

# Where the SQLite export ends up (stable dir, not $SCRATCH, so it survives
# and is easy to point optuna-dashboard at afterwards)
SQLITE_DIR="${PROJECT_DIR}/studies"
SQLITE_PATH="${SQLITE_DIR}/${STUDY_NAME}.db"
mkdir -p "$SQLITE_DIR"

# STORAGE_URL is used both for study creation below and for the SQLite
# export in cleanup(), so it needs to exist before cleanup() can ever fire.
STORAGE_URL="postgresql+psycopg2:///optuna_db?host=${PG_SOCKET_DIR}"

# ---------------------------------------------------------------------------
# Cleanup: export study to SQLite, THEN stop PostgreSQL. Runs on any exit
# path (normal completion, error, or SIGTERM), so we always try to save a
# usable snapshot of the study before the database goes away.
# ---------------------------------------------------------------------------
cleanup() {
    if [ -f "$READY_FLAG" ]; then
        echo "[$(date)] Coordinator cleanup: exporting study to SQLite (${SQLITE_PATH})..."
        nix develop ./slurm --no-pure-eval --command python - <<PYEOF
import optuna
try:
    optuna.copy_study(
        from_study_name="${STUDY_NAME}",
        from_storage="${STORAGE_URL}",
        to_storage="sqlite:///${SQLITE_PATH}",
    )
    print("Exported study to ${SQLITE_PATH}")
except Exception as e:
    print(f"SQLite export failed: {e}")
PYEOF
    fi

    echo "[$(date)] Coordinator cleanup: stopping PostgreSQL..."
    nix develop ./slurm --no-pure-eval --command \
        pg_ctl -D "$PG_DATA" stop -m fast 2>/dev/null || true
    rm -f "$READY_FLAG"
    echo "[$(date)] Coordinator done."
}
trap cleanup EXIT ERR SIGTERM

cd "${PROJECT_DIR}"

# ---------------------------------------------------------------------------
# 1. Build devenv once
# ---------------------------------------------------------------------------
echo "[$(date)] Building devenv environment..."
nix develop ./slurm --no-pure-eval --command python --version

# ---------------------------------------------------------------------------
# 2. Start shared PostgreSQL (TCP disabled, UNIX socket only)
# ---------------------------------------------------------------------------
echo "[$(date)] Initialising PostgreSQL in ${PG_DATA}..."
nix develop ./slurm --no-pure-eval --command \
    initdb -D "$PG_DATA" --no-locale --auth=trust

echo "[$(date)] Starting PostgreSQL server..."
nix develop ./slurm --no-pure-eval --command \
    pg_ctl -D "$PG_DATA" \
           -o "-k ${PG_SOCKET_DIR} -h '' -N 200" \
           -l "${PG_BASE}/postgres.log" \
           start

sleep 4

nix develop ./slurm --no-pure-eval --command \
    createdb -h "$PG_SOCKET_DIR" optuna_db

echo "[$(date)] PostgreSQL ready at socket ${PG_SOCKET_DIR}"
touch "$READY_FLAG"

# ---------------------------------------------------------------------------
# 3. Pre-create the Optuna study so workers never race on creation
# ---------------------------------------------------------------------------
nix develop ./slurm --no-pure-eval --command \
    python - <<PYEOF
import optuna
optuna.create_study(
    study_name="${STUDY_NAME}",
    storage="${STORAGE_URL}",
    load_if_exists=True,
)
print("Study '${STUDY_NAME}' created/confirmed in storage.")
PYEOF

# ---------------------------------------------------------------------------
# 4. Submit ALL workers as ONE combined allocation.
#
# Instead of an array (where each element competes for scheduling
# independently and trickles in one-by-one on a busy cluster), this is a
# single job requesting --ntasks=$N_WORKERS. Slurm can only start it once
# the FULL allocation is available, so every task begins at the same
# wall-clock moment once it does start — no uneven head start between
# workers, and no more early workers finishing (or timing out) while later
# ones haven't even begun.
# ---------------------------------------------------------------------------
echo "[$(date)] Submitting ${N_WORKERS} workers as one synchronized allocation..."

WORKER_JOB_ID=$(sbatch \
    --parsable \
    --ntasks="${N_WORKERS}" \
    --export=NONE,OPTIMIZER="${OPTIMIZER}",DATASET="${DATASET}",PG_SOCKET_DIR="${PG_SOCKET_DIR}",STUDY_NAME="${STUDY_NAME}",TIMEOUT_HOURS="${TIMEOUT_HOURS}" \
    slurm/worker.sbatch)

echo "[$(date)] Workers submitted as job ${WORKER_JOB_ID}"
echo "[$(date)] Waiting for all workers to finish (job ${WORKER_JOB_ID})..."

# Poll until the job is gone from the queue
while squeue -j "${WORKER_JOB_ID}" -h 2>/dev/null | grep -q .; do
    sleep 60
done

echo "[$(date)] All workers finished. Coordinator will now export + clean up."
# Trap handles SQLite export + PostgreSQL shutdown
