# Helios

Submits a [Helios](https://www.create.hpc.mil/helios) rotary-wing CFD job on an HSP cluster. The workflow loads the CREATE environment, then runs `csi` against the case directory specified at launch.

## Inputs

| Input | Description |
|-------|-------------|
| Resource | Target compute cluster |
| Helios Case Directory | Path to the directory containing Helios input files |
| Number of Processors | Passed as `-p` to `csi` |
| Helios Version | Version string used to locate the binary under `${CREATE_HOME}/av/helios/` |
| Load CREATE Environment | Command to load the CREATE module (default: `module load create`) |
