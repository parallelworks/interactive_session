# Fractal Demo

A tiny, self-contained example that renders a **Mandelbrot fractal** while a web
page shows the progress live.

```
  run.sh ──renders──▶ fractal.png + status.json ──serves──▶ live web page
```

A single script, `run.sh`, both computes the fractal and serves a page that
shows it filling in. It uses **only the Python standard library** — nothing to
download — so it works the same everywhere, even on a machine with no internet.

## Quick start

```bash
./install.sh                        # builds the Python environment under ~/pw/software
RESOLUTION=1000 PORT=8000 ./run.sh  # render a 1000x1000 fractal and serve it on port 8000
```

Open `http://localhost:8000/` and watch the fractal render. Press Ctrl+C to stop.

## The two scripts

| Script | What it does |
| --- | --- |
| `install.sh` | Builds a Python virtual environment at `~/pw/software/fractal-demo`. No packages to download. |
| `run.sh` | Renders the fractal and serves the live progress page. `RESOLUTION` sets the image size, `PORT` the page's port. |

## Controlling the run time

The resolution is set with the **`RESOLUTION`** environment variable, in pixels
(default 1000). Bigger images take longer — the work grows with the square of
the resolution:

```bash
RESOLUTION=500  ./run.sh   # quick
RESOLUTION=1500 ./run.sh   # longer (about 9x the work of 500)
```

### Advanced options (environment variables)

```bash
PORT=8090 ./run.sh                                   # serve the page on a different port
MAX_ITER=400 ./run.sh                                # more fractal detail per pixel
WORK_DIR=/scratch/$USER/fractal ./run.sh             # write output to shared scratch
PW_SOFTWARE=/shared/envs ./install.sh                # put the venv elsewhere
```

## How it works

- `run.sh` starts a small web server (Python's `http.server`) on `PORT`, serving
  the work folder, then computes the fractal one row at a time.
- As it goes it writes the partial image (`fractal.png`) and a small
  `status.json` into the work folder. The page polls `status.json` once a second,
  updates the progress bar, and reloads the image — so you see it render top to
  bottom.
- Files are written to a temporary name and then renamed, so the page never reads
  a half-written image.
- When the render finishes the server keeps running so the result stays viewable.
