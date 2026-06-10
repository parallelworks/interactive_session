# KasmVNC Container Desktop

A browser-based remote desktop powered by a KasmVNC container (Docker or Singularity). The container runs the VNC server and serves the web interface, while a terminal (**xterm**) runs **directly on the host compute node** — giving you full access to the cluster environment from inside the desktop.

---

## How It Works

```
Your Browser
    │  HTTPS / WebSocket
    ▼
KasmVNC Container  ←──────────────────────────────────────────────┐
│  • Xvnc display server   (e.g. :01)                             │
│  • nginx reverse proxy                                           │
│  • KasmVNC web client (HTML5)                                    │
└──────────────────────────────────────────────────────────────────┘
                              ▲  X11 display protocol
                              │  (via .Xauthority)
                         HOST NODE
                         • xterm terminal  ←── runs here, not in the container
                         • startup command ←── also runs here
                         • cluster modules, filesystems, GPUs
```

**The container is purely the display layer.** It provides the X server, VNC server, and browser interface. The `xterm` terminal window you see on the desktop — and any application you launch from it — runs **natively on the compute node**, with the container's X display as the rendering target.

This means:
- ✅ Full access to host modules (`module load ...`), MPI, CUDA, cluster filesystems
- ✅ No need to install your software inside the container
- ✅ Applications behave exactly as they would in an SSH session
- ✅ If you close the xterm window, it automatically reopens
- ⚠️ GUI apps launched from xterm use the container's X server — they appear in your browser desktop but run entirely on the host

---

## Features

- **Multiple OS Options**: Rocky Linux 8/9 or Ubuntu 22.04 (container OS only — host OS is unaffected)
- **Container Runtime**: Supports both Docker and Singularity
- **Software or GPU Rendering**: CPU (llvmpipe) by default, or hardware-accelerated OpenGL via VirtualGL on an NVIDIA GPU — auto-detected, with software fallback
- **Startup Application**: Automatically launch any host command when the session starts
- **Flexible Storage**: Auto-mount common directories plus custom paths
- **Scheduler Support**: Works with both SLURM and PBS job schedulers
- **Auto-reconnect xterm**: The xterm session restarts automatically if closed

---

## Use Cases

- Running GUI applications installed on the cluster (MATLAB, VMD, ParaView, FSL, etc.)
- Scientific visualization using host GPU and libraries
- Interactive development with full access to the cluster environment
- Running graphical tools that require a display but are already installed on the host

---

## Configuration

### Container Runtime
Choose **Docker** or **Singularity** depending on what is available on your cluster. Docker is the default; Singularity requires no root privileges and is preferred on clusters without a Docker daemon.

### Operating System
Selects the KasmVNC container image (Rocky Linux 8, Rocky Linux 9, or Ubuntu 22.04). This controls the look-and-feel of the desktop window manager only — it does **not** affect the host OS or the tools available in the xterm terminal.

### Rendering
Choose **Software (CPU)** for llvmpipe rendering, which runs on any node, or **Hardware (GPU)** for VirtualGL/EGL-accelerated OpenGL on an NVIDIA GPU (Singularity runtime). Hardware mode auto-detects the GPU at session start and falls back to software rendering if none is available. Defaults to software.

### Startup Application
Specify a command to run automatically when the session starts (e.g., `firefox`, `matlab`, `paraview`). This command runs **on the host compute node** using the container's X display.  Leave blank to start with just the xterm terminal.

### Additional Mount Paths
Common cluster directories (`/p/home`, `/p/work`, `/scratch`, etc.) are automatically mounted into the container if they exist. Specify extra paths (one per line) for additional data access inside the container itself. Each listed path is mounted if it exists on the host; if it does not, a warning is logged and the path is skipped.

### Compute Resources
Configure CPU, memory, and walltime. With Singularity, NVIDIA GPUs are auto-detected and enabled (`--nv`) when present; request GPU hardware through your scheduler directives (e.g. `#SBATCH --gres=gpu:1` for SLURM or `#PBS -l ngpus=1` for PBS).

---

## Requirements

- **Docker**: Docker daemon must be running and accessible (with or without `sudo`) on the target compute node.
- **Singularity**: `singularity` or `apptainer` must be available (via `module load singularity` or in `$PATH`).

---

## Getting Started

1. Select your cluster resource and configure scheduler settings (partition, CPUs, memory, walltime)
2. Choose your container runtime (Docker is the default; choose Singularity if Docker is unavailable)
3. Optionally set a startup application or additional mount paths
4. Launch the session
5. Click the link to open the browser-based desktop
6. Use the **xterm terminal** on the desktop to access your cluster environment — it is running directly on the compute node

The session runs until cancelled or the walltime expires.
