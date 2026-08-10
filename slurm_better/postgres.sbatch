#!/usr/bin/env bash
# Submitted by coordinator.sh with --nodelist=<node> and
# --export=NONE,RUN_ID=...,STUDY_NAME=...,PG_BASE=... Not meant to be
# submitted directly. Stays alive until coordinator.sh touches STOP_FLAG,
# then exports the study to SQLite and shuts down.
#SBATCH --job-name=study_postgres
#SBATCH --partition=cpu
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --time=120:00:00
#SBATCH --output=output/postgres_%j.out
#SBATCH --error=output/postgres_%j.err

source /projects/shared/lib/slurm-utils.sh

PROJECT_DIR="/home/$USER/suprb-experimentation"
cd "${PROJECT_DIR}"

PG_DATA="${PG_BASE}/data"
PG_SOCKET_DIR="${PG_BASE}/socket"
READY_FLAG="${PG_BASE}/.pg_ready"
STOP_FLAG="${PG_BASE}/.pg_stop"
mkdir -p "$PG_DATA" "$PG_SOCKET_DIR"
rm -f "$STOP_FLAG"

SQLITE_DIR="${PROJECT_DIR}/studies"
SQLITE_PATH="${SQLITE_DIR}/${STUDY_NAME}.db"
mkdir -p "$SQLITE_DIR"

STORAGE_URL="postgresql+psycopg2:///optuna_db?host=${PG_SOCKET_DIR}"

cleanup() {
    if [ -f "$READY_FLAG" ]; then
        nix develop ./slurm --no-pure-eval --command python - <<PYEOF
import optuna
try:
    optuna.copy_study(from_study_name="${STUDY_NAME}", from_storage="${STORAGE_URL}", to_storage="sqlite:///${SQLITE_PATH}")
except Exception as e:
    print(f"SQLite export failed: {e}")
PYEOF
    fi
    nix develop ./slurm --no-pure-eval --command pg_ctl -D "$PG_DATA" stop -m fast 2>/dev/null || true
    rm -f "$READY_FLAG" "$STOP_FLAG"
}
trap cleanup EXIT ERR SIGTERM

nix develop ./slurm --no-pure-eval --command initdb -D "$PG_DATA" --no-locale --auth=trust
nix develop ./slurm --no-pure-eval --command \
    pg_ctl -D "$PG_DATA" -o "-k ${PG_SOCKET_DIR} -h '' -N 200" -l "${PG_BASE}/postgres.log" start
sleep 4
nix develop ./slurm --no-pure-eval --command createdb -h "$PG_SOCKET_DIR" optuna_db

nix develop ./slurm --no-pure-eval --command python - <<PYEOF
import optuna
optuna.create_study(study_name="${STUDY_NAME}", storage="${STORAGE_URL}", load_if_exists=True)
PYEOF

touch "$READY_FLAG"

while [ ! -f "$STOP_FLAG" ]; do
    sleep 30
done
# trap fires on exit -> export + shutdown
