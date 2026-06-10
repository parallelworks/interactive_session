# sweep — fan-out / fan-in parameter study (worked example)

`prepare → {w1, w2, w3 in parallel} → aggregate`. Three worker jobs each
grid-search the minimum of Himmelblau's function over a different x-band, writing
`part_<id>.json`; an aggregator merges them and reports the global minimum. The
canonical HPC fan-out/fan-in shape expressed purely with the job graph.

## The pattern
- Workers `w1/w2/w3` each `needs: [prepare]` but **not each other** → the DAG runs
  them **concurrently** (verified: all three logged the same finish second).
- `aggregate` `needs: [w1, w2, w3]` → it joins (waits for all) before merging.
- Workers share `${PW_PARENT_JOB_DIR}` and write distinct `part_<id>.json` files.
- The repetitive worker jobs are generated in `build_yaml.py` (don't hand-copy jobs).

## Files
| file | role |
|------|------|
| `minimize.py` | one worker: grid-search a band → `part_<id>.json`. |
| `aggregate.py` | merge `part_*.json` → `sweep_result.json` + ranking. |
| `build_yaml.py` | base64-embeds the code; generates prepare + 3 workers + aggregate. |
| `sweep.yaml` | generated, deployable workflow. |

## Run
```bash
python3 build_yaml.py
pw workflows create sweep --yaml sweep.yaml --display-name "Parameter Sweep"
pw workflows run sweep -i '{"resource":"gcpsmall","sweep":{"steps":200}}' --name s1 -o json
cat ~/pw/jobs/sweep/<NNNNN>/sweep_result.json
```
Verified: `global_min≈0.002` and the three workers ran in parallel.
