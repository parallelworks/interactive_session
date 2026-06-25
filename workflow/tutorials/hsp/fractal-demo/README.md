# Fractal Demo

A tiny, self-contained example that renders a **Mandelbrot fractal** while a web
page shows the progress live. 

The job writes its progress into a shared folder. The server reads that folder
and shows it on a web page, so you can watch the image fill in.

```
  run.sh  ──writes──▶   status.json    ◀──reads──   server.sh
                        fractal.png                (live web page)
```

It uses **only the Python standard library** — nothing to download — so it works
the same everywhere, even on a machine with no internet access.

## Quick start

```bash
./install.sh              # builds the Python environment under ~/pw/software
./server.sh               # start the progress page (http://localhost:8000/)
RESOLUTION=1000 ./run.sh  # in another terminal: render a 1000x1000 fractal
```

Open the URL that `server.sh` prints and watch the fractal render.

## The three scripts

| Script | What it does |
| --- | --- |
| `install.sh` | Builds a Python virtual environment at `~/pw/software/fractal-demo`. No packages to download. |
| `run.sh` | Computes the fractal and writes the image + progress. |
| `server.sh` | Serves a web page that shows the live progress. |

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
MAX_ITER=400 ./run.sh                                # more fractal detail per pixel
WORK_DIR=/scratch/$USER/fractal ./run.sh             # use shared scratch
PORT=8090 ./server.sh                                # serve on a different port
PW_SOFTWARE=/shared/envs ./install.sh                # put the venv elsewhere
```

> Set `WORK_DIR` to a folder both scripts can see (shared storage), so the job
> and the server read and write the same files.

## How it works

- The fractal is computed one row at a time. Every so often the job writes the
  partial image (`fractal.png`) and a small `status.json` into the work folder.
- The web page polls `status.json` once a second, updates the progress bar, and
  reloads the image — so you see it render top to bottom.
- Files are written to a temporary name and then renamed, so the page never
  reads a half-written image.
