# pipeline — multi-job DAG (worked example)

A 3-stage data pipeline on one resource — **generate → analyze → report** — that
shows the orchestration primitives: a job graph wired with `needs`, data passed
between jobs via `$OUTPUTS` / `${{ needs.<job>.outputs.<KEY> }}`, and a conditional
step driven by an upstream output. Pure batch; **no subworkflow** — plain
orchestration is a first-class use (subworkflows are for job submission / sessions).

## Files
| file | role |
|------|------|
| `gen.py` | stage 1 — write `data.csv`; prints row count for `$OUTPUTS`. |
| `analyze.py` | stage 2 — least-squares fit → `stats.json`; prints `slope=`/`mean_y=`/`good_fit=` for `$OUTPUTS`. |
| `build_yaml.py` | base64-embeds the code and emits the 3-job DAG. |
| `pipeline.yaml` | generated, deployable workflow. |

## How the data flows
- `generate` captures `n_rows=$(python3 gen.py ...)` then `echo "n_rows=${rows}" | tee -a $OUTPUTS`.
- `analyze` pipes its KEY=VALUE stdout straight in: `python3 analyze.py | tee -a $OUTPUTS`.
- `report` `needs: [generate, analyze]` and reads `${{ needs.analyze.outputs.slope }}` etc.,
  with `if: ${{ needs.analyze.outputs.good_fit == 'true' }}` selecting a step.
- All jobs `cd ${PW_PARENT_JOB_DIR}` — the shared run dir — so files persist across jobs.

## Run
```bash
python3 build_yaml.py
pw workflows create pipeline --yaml pipeline.yaml --display-name "Data Pipeline (DAG)"
pw workflows run pipeline -i '{"resource":"gcpsmall","data":{"rows":1500,"noise":2.5}}' --name p1 -o json
cat ~/pw/jobs/pipeline/<NNNNN>/report.md
```
Verified: `report.md` rendered the cross-job outputs (rows=1500, slope≈3.0) and the
"good fit" conditional step fired.
