#!/bin/bash
# Monte Carlo pi — batch job body executed by script_submitter.
#
# script_submitter cd's into `rundir` before running this script, so we use paths
# RELATIVE to rundir. Do NOT rely on ${PW_PARENT_JOB_DIR} here: for scheduled
# (SLURM/PBS) jobs this runs on a *compute node* where that variable may not be
# exported — but the home/rundir filesystem is shared, so relative paths work.
set -o pipefail

echo "::notice::host=$(hostname) cpus=$(nproc) pwd=$(pwd) date=$(date)"

# Optional inputs written by the workflow's preprocessing job.
[ -f inputs.sh ] && source inputs.sh

python3 montecarlo/montecarlo_pi.py \
    --samples "${mc_samples:-12000000}" \
    --batches "${mc_batches:-24}" \
    --out-dir .

echo "::notice::result file (montecarlo_result.json):"
cat montecarlo_result.json
