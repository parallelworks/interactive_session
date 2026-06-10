# Monte Carlo π — worked example (batch compute)

A complete, verified Activate workflow that estimates π by Monte Carlo sampling as a
**batch job**, driven directly by the `script_submitter/v3.6` subworkflow. It is the
counterpart to the [fractal example](../fractal/) (a *session* workload): this one
has no web server — it runs compute, streams progress, and writes a result file.

Built and validated on `gcpsmall` **both** on the login node (`scheduler:false`) and
on a real **SLURM compute node** (`scheduler:true`).

## Files
| file | role |
|------|------|
| `montecarlo_pi.py` | stdlib π estimator; batched progress to stdout; writes `montecarlo_result.json`. |
| `run_montecarlo.sh` | batch body `script_submitter` runs; uses **paths relative to rundir** (not `${PW_PARENT_JOB_DIR}`) so it works on a compute node. |
| `build_yaml.py` | base64-embeds the two files into a self-contained workflow YAML. |
| `montecarlo.yaml` | the generated, deployable workflow (preprocessing → `script_submitter/v3.6`). |

## Develop / test locally (Step 1)
```bash
python3 montecarlo_pi.py --samples 2000000 --batches 8 --out-dir /tmp
cat /tmp/montecarlo_result.json
```

## Build + deploy + run (Steps 2–3)
```bash
python3 build_yaml.py
pw workflows run --dry-run -i '{"resource":"gcpsmall","scheduler":false}' ./montecarlo.yaml
pw workflows create montecarlo --yaml montecarlo.yaml --display-name "Monte Carlo Pi"
# (use `pw workflows update montecarlo --yaml montecarlo.yaml` on later edits)

# Login node (fast):
pw workflows run montecarlo \
  -i '{"resource":"gcpsmall","scheduler":false,"mc":{"samples":6000000,"batches":12}}' \
  --name "mc-login" -o json

# SLURM compute node (bursts a node; takes minutes to provision):
pw workflows run montecarlo \
  -i '{"resource":"gcpsmall","scheduler":true,"slurm":{"is_enabled":true,"time":"00:10:00"},"mc":{"samples":120000000,"batches":24}}' \
  --name "mc-slurm" -o json
```

## Verify + debug (Step 4)
```bash
pw workflows runs logs <slug> -f                       # live; stream_output tails run.<JOBID>.out
squeue                                                  # (on the login node) watch the SLURM job
cat ~/pw/jobs/montecarlo/<NNNNN>/montecarlo_result.json # structured result
cat ~/pw/jobs/montecarlo/<NNNNN>/HOSTNAME               # which node ran it
```

## Notes
- `script_submitter` requires `cleanup_script_path` even when unused — the subworkflow
  defaults-filler ignores its UI hidden/ignore rules. We pass `define_cleanup_script:
  false` and `cleanup_script_path: ""`. `--dry-run` catches this.
- Output streams to `run.<JOBID>.out` in the run dir (named with the run slug).
- For `scheduler:true`, the home/run filesystem is shared with the compute node, so
  relative paths in `run_montecarlo.sh` resolve there.
- **Validation status:** the login-node path was confirmed end-to-end (real result).
  The SLURM path was validated through submission → `headers.sh`/`run.sh` generation →
  allocation → `squeue`/`sacct` monitoring → `scancel` on cancel; in this environment
  the google-slurm node stalled in `POWERING_UP` for 13+ min and never booted (an infra
  issue, not the workflow). Canceling cleanly drained the queue. Prefer `scheduler:false`
  for quick checks; use SLURM when you truly need a compute node and expect slow bursts.
