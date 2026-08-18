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

# Use $SCRATCH (node-local SSD) for PostgreSQL data and socket
# $SCRATCH is automatically set by Slurm and is cleaned up after the job.
# Fallback to /tmp if not set (should not happen in a job).
if [ -n "$SCRATCH" ]; then
    PG_DATA="${SCRATCH}/pg_data"
    PG_SOCKET_DIR="${SCRATCH}/socket"
else
    echo "Warning: SCRATCH not set, using /tmp" >&2
    PG_DATA="/tmp/$USER/pg_data_${SLURM_JOB_ID}"
    PG_SOCKET_DIR="/tmp/$USER/socket_${SLURM_JOB_ID}"
fi

# The flag directory (PG_BASE) is on shared storage, passed from coordinator.
READY_FLAG="${PG_BASE}/.pg_ready"
STOP_FLAG="${PG_BASE}/.pg_stop"

# Where to export the SQLite study at the end (on shared storage)
SQLITE_DIR="${PROJECT_DIR}/studies"
SQLITE_PATH="${SQLITE_DIR}/${STUDY_NAME}.db"

mkdir -p "$PG_DATA" "$PG_SOCKET_DIR" "$SQLITE_DIR"
rm -f "$STOP_FLAG" "$READY_FLAG"

# Connection string for Optuna – TCP/IP with port
STORAGE_URL="postgresql://localhost:${PG_PORT}/optuna_db"

cleanup() {
    if [ -f "$READY_FLAG" ]; then
        echo "[$(date)] Exporting study to SQLite..."
        nix develop ./slurm_better --no-pure-eval --command python - <<PYEOF
import optuna
try:
    optuna.copy_study(from_study_name="${STUDY_NAME}", from_storage="${STORAGE_URL}", to_storage="sqlite:///${SQLITE_PATH}")
    print("Study exported to ${SQLITE_PATH}")
except Exception as e:
    print(f"SQLite export failed: {e}")
PYEOF
    fi
    nix develop ./slurm_better --no-pure-eval --command pg_ctl -D "$PG_DATA" stop -m fast 2>/dev/null || true
    rm -f "$READY_FLAG" "$STOP_FLAG"
}
trap cleanup EXIT ERR SIGTERM

# Initialize DB if it doesn't exist (with --no-sync for speed)
if [ ! -f "$PG_DATA/PG_VERSION" ]; then
    echo "[$(date)] Initialising PostgreSQL data directory..."
    nix develop ./slurm_better --no-pure-eval --command initdb -D "$PG_DATA" --no-locale --auth=trust --no-sync
fi

# Start PostgreSQL with performance settings:
#   - listen on localhost:port
#   - socket dir in scratch
#   - disable fsync, full-page-writes, sync commit
#   - increase shared_buffers to 512MB (we have 3GB allocated)
#   - reduce checkpoint frequency
echo "[$(date)] Starting PostgreSQL on port ${PG_PORT}..."
nix develop ./slurm_better --no-pure-eval --command \
    pg_ctl -D "$PG_DATA" -o "-h localhost -p ${PG_PORT} -N 200 -c dynamic_shared_memory_type=sysv -c unix_socket_directories=${PG_SOCKET_DIR} -c fsync=off -c synchronous_commit=off -c full_page_writes=off -c checkpoint_timeout=15min -c max_wal_size=2GB -c shared_buffers=512MB" \
    -l "${PG_BASE}/postgres.log" start

echo "Waiting for PostgreSQL to accept connections on port ${PG_PORT}..."
until nix develop ./slurm_better --no-pure-eval --command pg_isready -h localhost -p "$PG_PORT"; do
    sleep 1
    echo "[$(date)] checking for connection on port $PG_PORT"
done

# Create database and Optuna study
nix develop ./slurm_better --no-pure-eval --command createdb -h localhost -p "$PG_PORT" optuna_db 2>/dev/null || true
nix develop ./slurm_better --no-pure-eval --command python - <<PYEOF
import optuna
optuna.create_study(study_name="${STUDY_NAME}", storage="${STORAGE_URL}", load_if_exists=True)
PYEOF

# Signal coordinator that we are ready
echo "[$(date)] touching ready flag"
touch "$READY_FLAG"

# Heartbeat every 4 minutes to keep the job alive (optional, but good)
last_heartbeat=0
while [ ! -f "$STOP_FLAG" ]; do
    now=$(date +%s)
    if (( now - last_heartbeat >= 240 )); then
        nix develop ./slurm_better --no-pure-eval --command python - <<PYEOF 2>/dev/null || echo "[$(date)] heartbeat query failed"
import psycopg2
conn = psycopg2.connect(dbname="optuna_db", host="localhost", port="${PG_PORT}")
conn.cursor().execute("SELECT 1;")
conn.close()
PYEOF
        last_heartbeat=$now
    fi
    sleep 10
done