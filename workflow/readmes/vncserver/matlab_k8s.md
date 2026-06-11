## MATLAB Interactive Session
This workflow launches MATLAB in a remote desktop [interactive session](../../../README.md) accessible via a web browser on a **Compute Cluster** (SLURM or PBS).

It utilizes either TurboVNC, TigerVNC or KasmVNC, depending on which is installed on the target resource.

### Requirements
- MATLAB must be installed on the target resource.
- **Users must have access to a valid MATLAB license.**
- Users must provide a command to load and start MATLAB (e.g., `matlab -desktop`).
