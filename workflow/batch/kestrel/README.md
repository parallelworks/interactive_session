# Kestrel

Submits a [Kestrel](https://www.create.hpc.mil/kestrel) fixed-wing CFD job on an HSP cluster. The workflow loads the CREATE environment, then runs Kestrel against the XML input file specified at launch.

## Inputs

| Input | Description |
|-------|-------------|
| Resource | Target compute cluster |
| Run Directory | Working directory for the job |
| Path to Kestrel XML File | Full path to the Kestrel XML case file |
| Number of Processors | Passed to the Kestrel executable |
| Kestrel Version | Version string used to locate the binary under `${CREATE_HOME}` |
| Load CREATE Environment | Command to load the CREATE module (default: `module load create`) |
