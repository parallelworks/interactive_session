# Fractal demo — worked example

A complete, verified Activate workflow that progressively renders a Mandelbrot set
and serves a live progress page as a **tunnel session**. Built by following the
[activate-workflows skill](../../SKILL.md) end to end.

## Files
| file | role |
|------|------|
| `mandelbrot_server.py` | stdlib HTTP server; background row-by-row render; serves `/`, `/fractal.png`, `/status`, `/healthz`. Pure stdlib zlib PNG encoder → nothing to install. |
| `controller-v3.sh` | `session_runner` controller script — verifies `python3` (no installs). |
| `start-template-v3.sh` | `session_runner` start script — binds `${service_port}` on `0.0.0.0`, writes `cancel.sh`, `sleep inf`. |
| `build_yaml.py` | base64-embeds the three files into a self-contained workflow YAML. |
| `fractal_session.yaml` | the generated, deployable workflow (preprocessing → `session_runner/v1.4`). |

## Develop / test locally (Step 1)
```bash
python3 mandelbrot_server.py --port 8731 --width 240 --height 160 --max-iter 120 &
curl localhost:8731/status ; curl -s localhost:8731/fractal.png -o out.png
```

## Build + deploy + run (Steps 2–3)
```bash
python3 build_yaml.py                               # regenerate YAML after any edit
pw workflows run --dry-run -i '{"resource":"gcpsmall","scheduler":false}' ./fractal_session.yaml
pw workflows create fractal --yaml fractal_session.yaml --display-name "Fractal Demo"
# (use `pw workflows update fractal --yaml fractal_session.yaml` on later edits)
pw workflows run fractal \
  -i '{"resource":"gcpsmall","scheduler":false,"fractal":{"width":420,"height":280,"max_iter":180}}' \
  --name "fractal-e2e" -o json
```
Choose a resource whose login node is the host you can inspect (so the job dir and
process are local), or `pw ssh <resource>` to reach it. `"workspace"` also works but
runs on the separate workspace node.

## Verify (Steps 3–4)
```bash
pw workflows runs logs <slug> --job create_session   # expect "Session is ready"
pw sessions ls -o table | grep fractal                # running / tunnel
P=$(cat ~/pw/jobs/fractal/<NNNNN>/SESSION_PORT)
ps -x | grep mandelbrot_server                        # the live process
curl -s localhost:$P/status                           # progressive → {"done": true}
pw workflows runs cancel <slug>                        # stop service + session when done
```
