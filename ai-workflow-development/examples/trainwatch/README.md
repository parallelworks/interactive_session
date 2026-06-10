# trainwatch — live training dashboard (worked example, session)

A session workload that simulates a training run and serves a **live dashboard**:
the page polls `/metrics` and draws a loss curve as inline SVG client-side. The
contrast to the fractal demo — that renders an image server-side; this streams a
numeric time series and charts it in the browser. Same `session_runner/v1.4` wiring.

## Files
| file | role |
|------|------|
| `trainwatch_server.py` | stdlib HTTP server; background "training" thread; `/`, `/metrics`, `/healthz`. |
| `controller-v3.sh`, `start-template-v3.sh` | the `session_runner` contract scripts. |
| `build_yaml.py` → `trainwatch.yaml` | base64-embeds the three files; wires `session_runner`. |

## Run
```bash
python3 build_yaml.py
pw workflows create trainwatch --yaml trainwatch.yaml --display-name "Train Watch"
pw workflows run trainwatch -i '{"resource":"gcpsmall","scheduler":false,"train":{"epochs":40,"period":0.4}}' --name tw1 -o json
pw workflows runs logs <slug> --job create_session   # "Session is ready"
P=$(cat ~/pw/jobs/trainwatch/<NNNNN>/SESSION_PORT); curl -s localhost:$P/metrics
pw workflows runs cancel <slug>                        # stop service + session
```
Verified: session registered as a tunnel; `/metrics` advanced live; loss curve renders.
