#!/usr/bin/env bash
# Run inside zellij on oc-head:
#   zellij
#   bash slurm_better/coordinator.sh --optimizer spea2 --dataset airfoil_self_noise --n-workers 25
set -e

OPTIMIZER="spea2"
DATASET="airfoil_self_noise"
N_WORKERS=25
TUNING_TIMEOUT_HOURS=24
NODE="oc-compute04"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --optimizer)      OPTIMIZER="$2";          shift 2 ;;
        --dataset)        DATASET="$2";             shift 2 ;;
        --n-workers)      N_WORKERS="$2";            shift 2 ;;
        --tuning-timeout) TUNING_TIMEOUT_HOURS="$2"; shift 2 ;;
        --node)           NODE="$2";                 shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

source /projects/shared/lib/slurm-utils.sh

PROJECT_DIR="/home/$USER/suprb-experimentation"
cd "${PROJECT_DIR}"

echo "[$(date)] Warming Nix cache..."
nix develop ./slurm_better --no-pure-eval --command true

RUN_ID="${OPTIMIZER}_${DATASET}"
STUDY_NAME="${OPTIMIZER}_tuning_${DATASET}_${RUN_ID}"

PG_BASE="${PROJECT_DIR}/.postgres_shared/${RUN_ID}"
PG_SOCKET_DIR="${PG_BASE}/socket"
READY_FLAG="${PG_BASE}/.pg_ready"
STOP_FLAG="${PG_BASE}/.pg_stop"
mkdir -p "$PG_SOCKET_DIR"

# Submit the DB job and wait for it to actually be ready BEFORE submitting
# any worker. This is the whole point: workers only ever enter the queue
# once they can use their allocation immediately, so none of them burn
# scheduled time sitting idle inside a job waiting on the DB.
echo "[$(date)] Run ${RUN_ID}: submitting PostgreSQL job on ${NODE}..."
PG_JOB_ID=$(sbatch --parsable --nodelist="${NODE}" \
    --export=NONE,RUN_ID="${RUN_ID}",STUDY_NAME="${STUDY_NAME}",PG_BASE="${PG_BASE}" \
    slurm_better/postgres.sbatch)
echo "[$(date)] Postgres job ${PG_JOB_ID} submitted, waiting for it to become ready..."

until [ -f "$READY_FLAG" ]; do
    if ! squeue -j "${PG_JOB_ID}" -h 2>/dev/null | grep -q .; then
        echo "[$(date)] ERROR: postgres job ${PG_JOB_ID} ended before becoming ready. Check output/postgres_${PG_JOB_ID}.err" >&2
        exit 1
    fi
    sleep 10
done
echo "[$(date)] PostgreSQL ready."

echo "[$(date)] Submitting ${N_WORKERS} tuning workers on ${NODE}..."
TUNE_JOB_IDS=()
for i in $(seq 0 $((N_WORKERS - 1))); do
    JOB_ID=$(sbatch --parsable --nodelist="${NODE}" \
        --export=NONE,OPTIMIZER="${OPTIMIZER}",DATASET="${DATASET}",PG_SOCKET_DIR="${PG_SOCKET_DIR}",STUDY_NAME="${STUDY_NAME}",TIMEOUT_HOURS="${TUNING_TIMEOUT_HOURS}",WORKER_ID="${i}" \
        slurm_better/tuning_worker.sbatch)
    TUNE_JOB_IDS+=("$JOB_ID")
done
echo "[$(date)] Tuning jobs: ${TUNE_JOB_IDS[*]}"

while squeue -j "$(IFS=,; echo "${TUNE_JOB_IDS[*]}")" -h 2>/dev/null | grep -q .; do
    sleep 60
done
echo "[$(date)] Tuning stage finished."

echo "[$(date)] Submitting ${N_WORKERS} evaluation workers on ${NODE}..."
EVAL_JOB_IDS=()
for i in $(seq 0 $((N_WORKERS - 1))); do
    JOB_ID=$(sbatch --parsable --nodelist="${NODE}" \
        --export=NONE,OPTIMIZER="${OPTIMIZER}",DATASET="${DATASET}",PG_SOCKET_DIR="${PG_SOCKET_DIR}",STUDY_NAME="${STUDY_NAME}",WORKER_ID="${i}" \
        slurm_better/eval_worker.sbatch)
    EVAL_JOB_IDS+=("$JOB_ID")
done
echo "[$(date)] Evaluation jobs: ${EVAL_JOB_IDS[*]}"

while squeue -j "$(IFS=,; echo "${EVAL_JOB_IDS[*]}")" -h 2>/dev/null | grep -q .; do
    sleep 60
done
echo "[$(date)] Evaluation stage finished."

echo "[$(date)] Signalling postgres job to export + shut down..."
touch "$STOP_FLAG"

while squeue -j "${PG_JOB_ID}" -h 2>/dev/null | grep -q .; do
    sleep 15
done
echo "[$(date)] Run ${RUN_ID} complete. Study exported to studies/${STUDY_NAME}.db"