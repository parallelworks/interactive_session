# FEniCS Topology Optimization

An interactive session that runs SIMP (Solid Isotropic Material with Penalization) topology optimization using FEniCS and serves a real-time web dashboard showing the evolving density field and convergence history.

## Features

- Four pre-configured structural optimization problems (cantilever, MBB beam, bridge, half wheel)
- Parameterized mesh resolution, volume fraction, and penalization exponent
- Real-time browser dashboard with density field heatmap and convergence plots
- Automatic conda environment installation with FEniCS and dependencies
- SLURM and PBS scheduler support

## Use Cases

- Structural design exploration and education
- Topology optimization parameter studies
- Demonstrating finite element methods on HPC resources

## Configuration

### Load Type
Selects the structural optimization problem, which defines both the boundary conditions (supports) and applied loads:
- **Cantilever**: Left edge fixed, downward point load at the mid-right edge
- **MBB Beam**: Classic half-symmetry benchmark with roller support at bottom-right
- **Bridge**: Bottom corners pinned, uniform downward load along the top
- **Half Wheel**: Center bottom support, uniform downward load along the top

### Mesh Resolution
`Mesh Elements (X)` and `Mesh Elements (Y)` control the number of finite elements in the horizontal and vertical directions. Higher values produce finer detail but increase computation time. Typical values: 60x30 (fast) to 180x90 (detailed).

### Volume Fraction
Target ratio of material to void (0 to 1). A value of 0.5 means 50% of the domain will be filled with material. Lower values produce sparser, more organic structures.

### Penalization Exponent
Controls how aggressively intermediate densities are penalized toward 0 or 1. The standard value is 3.0. Values of 1.0 produce blurry results; values above 4.0 may cause convergence issues.

## Requirements

- Internet access on the controller node (for conda installation on first run)
- Sufficient disk space for Miniconda and the FEniCS conda environment (~3 GB)

## Getting Started

1. Select your compute resource and scheduler settings
2. Choose a load type and adjust mesh/optimization parameters as desired
3. Launch the session
4. The dashboard will open automatically, showing real-time optimization progress
5. The session runs until the optimization converges or reaches the maximum iterations
