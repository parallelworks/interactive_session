# fileserver — directory browser session (worked example, session)

The smallest possible session: **no custom server code at all**. The start script
just runs Python's stdlib `http.server`, which already does directory listing and
downloads. Shows that a `session_runner` service can be a stock binary/built-in.

> ⚠ Exposes the chosen directory **read-only** to anyone with the session URL.
> Point it at data you mean to share, not `$HOME` secrets.

## Files
| file | role |
|------|------|
| `controller-v3.sh` | verifies `python3` (nothing to install). |
| `start-template-v3.sh` | `python3 -m http.server "${service_port}" --bind 0.0.0.0 --directory "${fs_dir}"` + `cancel.sh` + `sleep inf`. |
| `build_yaml.py` → `fileserver.yaml` | base64-embeds the two scripts; wires `session_runner`. |

## Run
```bash
python3 build_yaml.py
pw workflows create fileserver --yaml fileserver.yaml --display-name "File Server"
pw workflows run fileserver -i '{"resource":"gcpsmall","scheduler":false,"fs":{"directory":"/home/alvaro/pw/jobs"}}' --name fs1 -o json
P=$(cat ~/pw/jobs/fileserver/<NNNNN>/SESSION_PORT); curl -s localhost:$P/   # directory listing
pw workflows runs cancel <slug>
```
Verified: the session served a live directory listing of the chosen path.
