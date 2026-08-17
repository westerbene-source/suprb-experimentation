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

PG_DATA="${PG_BASE}/data"
PG_SOCKET_DIR="${PG_BASE}/socket"       # keep for potential local connections, but not used
READY_FLAG="${PG_BASE}/.pg_ready"
STOP_FLAG="${PG_BASE}/.pg_stop"

# Clear stale state flags before starting
rm -f "$STOP_FLAG" "$READY_FLAG"
mkdir -p "$PG_DATA" "$PG_SOCKET_DIR"

# Connection string for Optuna – now using TCP/IP with port
STORAGE_URL="postgresql+psycopg2://localhost:${PG_PORT}/optuna_db"

# Cleanup on exit
cleanup() {
    if [ -f "$READY_FLAG" ]; then
        rm -f "${SQLITE_PATH}"
        nix develop ./slurm_better --no-pure-eval --command python - <<PYEOF
import optuna
try:
    optuna.copy_study(from_study_name="${STUDY_NAME}", from_storage="${STORAGE_URL}", to_storage="sqlite:///${SQLITE_PATH}")
except Exception as e:
    print(f"SQLite export failed: {e}")
PYEOF
    fi
    nix develop ./slurm_better --no-pure-eval --command pg_ctl -D "$PG_DATA" stop -m fast 2>/dev/null || true
    rm -f "$READY_FLAG" "$STOP_FLAG"
}
trap cleanup EXIT ERR SIGTERM

# Initialize DB if it doesn't exist
if [ ! -f "$PG_DATA/PG_VERSION" ]; then
    nix develop ./slurm_better --no-pure-eval --command initdb -D "$PG_DATA" --no-locale --auth=trust
fi

# Start PostgreSQL listening on localhost:${PG_PORT} (no socket directory specified)
nix develop ./slurm_better --no-pure-eval --command \
    pg_ctl -D "$PG_DATA" -o "-h localhost -p ${PG_PORT} -N 200 -c dynamic_shared_memory_type=sysv" \
    -l "${PG_BASE}/postgres.log" start

echo "Waiting for PostgreSQL to accept connections on port ${PG_PORT}..."
until nix develop ./slurm_better --no-pure-eval --command pg_isready -h localhost -p "$PG_PORT"; do
    sleep 1
    echo "[$(date)] checking for connection on port $PG_PORT"
done

# Create DB if it doesn't exist
nix develop ./slurm_better --no-pure-eval --command createdb -h localhost -p "$PG_PORT" optuna_db 2>/dev/null || true

# Initialize Optuna Study Schema
nix develop ./slurm_better --no-pure-eval --command python - <<PYEOF
import optuna
optuna.create_study(study_name="${STUDY_NAME}", storage="${STORAGE_URL}", load_if_exists=True)
PYEOF

# Signal to coordinator that workers can now connect
touch "$READY_FLAG"

# Heartbeat every 4 minutes
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