#!/usr/bin/env bash
###############################################################################
# worker.sbatch
#
# ONE combined allocation holding ALL worker tasks for this study. Submitted
# by the coordinator with --ntasks=<n-workers>, so Slurm treats it as a
# single scheduling decision: the job only starts once the *entire*
# allocation (all ntasks x cpus-per-task x mem-per-cpu) is free, and once it
# starts, every task begins in the same instant via the single srun step
# below.
#
# This replaces the old --array=0-N approach, where each array element was
# scheduled independently and — on a busy cluster — trickled in one at a
# time, giving early workers a large, unfair head start over later ones
# (and sometimes leaving later ones with no time budget left at all).
#
# NOT submitted directly. The coordinator (start_study.sbatch) submits this
# with --ntasks=$N_WORKERS and --export=... set at submission time.
#
# Environment variables expected from coordinator (--export):
#   OPTIMIZER        e.g. "nsga2"
#   DATASET          e.g. "airfoil_self_noise"
#   PG_SOCKET_DIR    path to the shared PostgreSQL UNIX socket directory
#   STUDY_NAME       the Optuna study name to attach to
#   TIMEOUT_HOURS    per-worker time budget (hours, float ok)
###############################################################################
#SBATCH --job-name=suprb_workers
#SBATCH --partition=cpu
#SBATCH --nodelist=oc-compute04
#SBATCH --ntasks=25            # overridden by coordinator's --ntasks=$N_WORKERS
#SBATCH --cpus-per-task=2
#SBATCH --mem-per-cpu=4G       # 2 cpus x 4G = 8G/task, same per-worker budget as before
#SBATCH --time=30:00:00       # 24h tuning + margin for the post-tuning evaluation/logging phase
#SBATCH --output=output/workers_%j.out
#SBATCH --error=output/workers_%j.err
# NOTE: --ntasks and --export are set by the coordinator at submission time.

source /projects/shared/lib/slurm-utils.sh

PROJECT_DIR="/home/$USER/suprb-experimentation"
export PYTHONPATH="${PYTHONPATH}:${PROJECT_DIR}"

cd "${PROJECT_DIR}"

echo "[$(date)] Job ${SLURM_JOB_ID}: launching ${SLURM_NTASKS} workers as one synchronized step..."
unset SLURM_MEM_PER_NODE SLURM_MEM_PER_GPU

# A single srun step launches SLURM_NTASKS copies of worker_task.sh at once.
srun --ntasks="${SLURM_NTASKS}" --cpus-per-task=2 \
    --output="${PROJECT_DIR}/output/worker_%j_%t.out" \
    --error="${PROJECT_DIR}/output/worker_%j_%t.err" \
    bash "${PROJECT_DIR}/slurm/worker_task.sh"

echo "[$(date)] Job ${SLURM_JOB_ID}: all workers finished."
