#!/usr/bin/env bash
#SBATCH --job-name=study_postgres
#SBATCH --partition=cpu
#SBATCH --cpus-per-task=2
#SBATCH --mem=3G
#SBATCH --time=120:00:00
#SBATCH --output=output/postgres_%j.out
#SBATCH --error=output/postgres_%j.err

source /projects/shared/lib/slurm-utils.sh

PROJECT_DIR="/home/$USER/suprb-experimentation"
cd "${PROJECT_DIR}"

# Use $USER_SCRATCH (node-local, persists across your jobs, cleaned after 7 days)
# This avoids the midnight cleanup that affected $SCRATCH.
if [ -n "$USER_SCRATCH" ]; then
    # Include JOB_ID and RUN_ID to make the directory unique per run.
    PG_DATA="${USER_SCRATCH}/pg_data_${SLURM_JOB_ID}_${RUN_ID}"
    PG_SOCKET_DIR="${USER_SCRATCH}/socket_${SLURM_JOB_ID}_${RUN_ID}"
else
    # Fallback to /tmp if USER_SCRATCH isn't set (shouldn't happen on this cluster)
    echo "Warning: USER_SCRATCH not set, using /tmp" >&2
    PG_DATA="/tmp/$USER/pg_data_${SLURM_JOB_ID}_${RUN_ID}"
    PG_SOCKET_DIR="/tmp/$USER/socket_${SLURM_JOB_ID}_${RUN_ID}"
fi

READY_FLAG="${PG_BASE}/.pg_ready"
STOP_FLAG="${PG_BASE}/.pg_stop"

SQLITE_DIR="${PROJECT_DIR}/studies"
SQLITE_PATH="${SQLITE_DIR}/${STUDY_NAME}.db"

mkdir -p "$PG_DATA" "$PG_SOCKET_DIR" "$SQLITE_DIR"
rm -f "$STOP_FLAG" "$READY_FLAG"

STORAGE_URL="postgresql://localhost:${PG_PORT}/optuna_db"

# Cleanup: stop PostgreSQL and remove the data directories from USER_SCRATCH
cleanup() {
    echo "[$(date)] Cleanup: stopping PostgreSQL..."
    nix develop ./slurm_better --no-pure-eval --command pg_ctl -D "$PG_DATA" stop -m fast 2>/dev/null || true

    # Export the study to SQLite (on home, safe)
    if [ -f "$READY_FLAG" ]; then
        echo "[$(date)] Exporting study to SQLite..."
        nix develop ./slurm_better --no-pure-eval --command python -u - <<PYEOF 2>&1 | tee -a "${HOME}/export_${SLURM_JOB_ID}.log"
import optuna
try:
    optuna.copy_study(from_study_name="${STUDY_NAME}", from_storage="${STORAGE_URL}", to_storage="sqlite:///${SQLITE_PATH}")
    print("Study exported to ${SQLITE_PATH}")
except Exception as e:
    print(f"SQLite export failed: {e}")
PYEOF
    fi

    # Remove the local data directories to free up USER_SCRATCH space
    rm -rf "$PG_DATA" "$PG_SOCKET_DIR"
    rm -f "$READY_FLAG" "$STOP_FLAG"
}
trap cleanup EXIT ERR SIGTERM

# Init with --no-sync for speed
if [ ! -f "$PG_DATA/PG_VERSION" ]; then
    echo "[$(date)] Initialising PostgreSQL data directory..."
    nix develop ./slurm_better --no-pure-eval --command initdb -D "$PG_DATA" --no-locale --auth=trust --no-sync
fi

echo "[$(date)] Starting PostgreSQL on port ${PG_PORT}..."
nix develop ./slurm_better --no-pure-eval --command \
    pg_ctl -D "$PG_DATA" -o "-h localhost -p ${PG_PORT} -N 200 -c dynamic_shared_memory_type=sysv -c unix_socket_directories=${PG_SOCKET_DIR} -c fsync=off -c synchronous_commit=off -c full_page_writes=off -c checkpoint_timeout=15min -c max_wal_size=2GB -c shared_buffers=512MB" \
    -l "${PG_BASE}/postgres.log" start

echo "[$(date)] Waiting for PostgreSQL to accept connections on port ${PG_PORT}..."
until nix develop ./slurm_better --no-pure-eval --command pg_isready -h localhost -p "$PG_PORT"; do
    sleep 1
    echo "[$(date)] checking..."
done
echo "[$(date)] PostgreSQL is ready."

# Create database
echo "[$(date)] Creating database optuna_db..."
nix develop ./slurm_better --no-pure-eval --command createdb -h localhost -p "$PG_PORT" optuna_db

# Create Optuna study
echo "[$(date)] Creating Optuna study..."
nix develop ./slurm_better --no-pure-eval --command python -u - <<PYEOF 2>&1 | tee "${HOME}/create_study_${SLURM_JOB_ID}.log"
import optuna
study = optuna.create_study(study_name="${STUDY_NAME}", storage="${STORAGE_URL}", load_if_exists=True)
print(f"Study created/loaded: {study.study_name}")
PYEOF

if [ $? -ne 0 ]; then
    echo "[$(date)] ERROR: Study creation failed. Check ${HOME}/create_study_${SLURM_JOB_ID}.log" >&2
    exit 1
fi

echo "[$(date)] Touching ready flag..."
touch "$READY_FLAG"

# Heartbeat loop (keeps the job alive)
last_heartbeat=0
while [ ! -f "$STOP_FLAG" ]; do
    now=$(date +%s)
    if (( now - last_heartbeat >= 240 )); then
        nix develop ./slurm_better --no-pure-eval --command python - || echo "[$(date)] heartbeat query failed"
import psycopg2
conn = psycopg2.connect(dbname="optuna_db", host="localhost", port="${PG_PORT}")
conn.cursor().execute("SELECT 1;")
conn.close()
PYEOF
        last_heartbeat=$now
    fi
    sleep 10
done