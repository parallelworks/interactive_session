#!/usr/bin/env python3
"""
SIMP Topology Optimization using FEniCS (legacy dolfin).

Solves: min_rho  c(u(rho))  s.t.  integral(rho) <= volfrac * |Omega|
where c is the compliance (strain energy) and u solves the linear
elasticity PDE with penalized stiffness E(rho) = E_min + rho^p * (E0 - E_min).

Density update uses the standard optimality criteria (OC) method.
"""

import argparse
import json
import os
import sys
import time

import numpy as np

import dolfin


def setup_problem(nelx, nely, load_type):
    """
    Create mesh, function spaces, boundary conditions, and load specification.

    Returns: mesh, V (displacement), D (density), bcs, load_info (dict)

    load_info has one of two forms:
      {"type": "point", "points": [(x, y, component, magnitude), ...]}
      {"type": "boundary", "subdomain": SubDomain, "traction": (tx, ty)}
    """
    mesh = dolfin.RectangleMesh(
        dolfin.Point(0, 0), dolfin.Point(nelx, nely), nelx, nely
    )

    V = dolfin.VectorFunctionSpace(mesh, "CG", 1)
    D = dolfin.FunctionSpace(mesh, "DG", 0)

    if load_type == "cantilever":
        # Left edge fixed, point load downward at mid-right
        def left_boundary(x, on_boundary):
            return on_boundary and dolfin.near(x[0], 0.0)

        bcs = [dolfin.DirichletBC(V, dolfin.Constant((0, 0)), left_boundary)]

        # PointSource: (x, y, component_index, magnitude)
        load_info = {
            "type": "point",
            "points": [(float(nelx), float(nely) / 2.0, 1, -1.0)],
        }

    elif load_type == "mbb_beam":
        # MBB beam: symmetry on left (ux=0), pin bottom-right (uy=0),
        # point load top-left downward
        def left_symmetry(x, on_boundary):
            return on_boundary and dolfin.near(x[0], 0.0)

        def bottom_right(x, on_boundary):
            return dolfin.near(x[0], nelx) and dolfin.near(x[1], 0.0)

        bc_left = dolfin.DirichletBC(V.sub(0), dolfin.Constant(0), left_symmetry)
        bc_br = dolfin.DirichletBC(
            V.sub(1), dolfin.Constant(0), bottom_right, method="pointwise"
        )
        bcs = [bc_left, bc_br]

        load_info = {
            "type": "point",
            "points": [(0.0, float(nely), 1, -1.0)],
        }

    elif load_type == "bridge":
        # Bottom corners pinned, distributed load on top
        def bottom_left(x, on_boundary):
            return dolfin.near(x[0], 0.0) and dolfin.near(x[1], 0.0)

        def bottom_right(x, on_boundary):
            return dolfin.near(x[0], nelx) and dolfin.near(x[1], 0.0)

        bc_bl = dolfin.DirichletBC(
            V, dolfin.Constant((0, 0)), bottom_left, method="pointwise"
        )
        bc_br = dolfin.DirichletBC(
            V, dolfin.Constant((0, 0)), bottom_right, method="pointwise"
        )
        bcs = [bc_bl, bc_br]

        class TopEdge(dolfin.SubDomain):
            def inside(self, x, on_boundary):
                return on_boundary and dolfin.near(x[1], nely)

        load_info = {
            "type": "boundary",
            "subdomain": TopEdge(),
            "traction": (0.0, -1.0),
        }

    elif load_type == "half_wheel":
        # Center bottom support, distributed load on top
        def center_bottom(x, on_boundary):
            return abs(x[0] - nelx / 2.0) < 1.5 and dolfin.near(x[1], 0.0)

        bcs = [
            dolfin.DirichletBC(
                V, dolfin.Constant((0, 0)), center_bottom, method="pointwise"
            )
        ]

        class TopEdge(dolfin.SubDomain):
            def inside(self, x, on_boundary):
                return on_boundary and dolfin.near(x[1], nely)

        load_info = {
            "type": "boundary",
            "subdomain": TopEdge(),
            "traction": (0.0, -1.0),
        }

    else:
        raise ValueError(f"Unknown load_type: {load_type}")

    return mesh, V, D, bcs, load_info


def solve_elasticity(V, D, rho, bcs, load_info, penal, E0=1.0, E_min=1e-9, nu=0.3):
    """Solve linear elasticity with SIMP-penalized stiffness."""
    mesh = V.mesh()
    u = dolfin.TrialFunction(V)
    v = dolfin.TestFunction(V)

    E = E_min + rho ** penal * (E0 - E_min)
    lmbda = E * nu / ((1 + nu) * (1 - 2 * nu))
    mu = E / (2 * (1 + nu))

    def epsilon(u):
        return 0.5 * (dolfin.grad(u) + dolfin.grad(u).T)

    def sigma(u):
        return lmbda * dolfin.div(u) * dolfin.Identity(2) + 2 * mu * epsilon(u)

    a = dolfin.inner(sigma(u), epsilon(v)) * dolfin.dx

    if load_info["type"] == "boundary":
        boundaries = dolfin.MeshFunction(
            "size_t", mesh, mesh.topology().dim() - 1, 0
        )
        load_info["subdomain"].mark(boundaries, 1)
        ds = dolfin.Measure("ds", domain=mesh, subdomain_data=boundaries)
        traction = dolfin.Constant(load_info["traction"])
        L = dolfin.dot(traction, v) * ds(1)
        A, b = dolfin.assemble_system(a, L, bcs)
    else:
        # Point loads — assemble with zero RHS, then add PointSource
        L = dolfin.dot(dolfin.Constant((0.0, 0.0)), v) * dolfin.dx
        A, b = dolfin.assemble_system(a, L, bcs)
        for px, py, comp, mag in load_info["points"]:
            ps = dolfin.PointSource(V.sub(comp), dolfin.Point(px, py), mag)
            ps.apply(b)

    u_sol = dolfin.Function(V)
    dolfin.solve(A, u_sol.vector(), b)
    return u_sol


def compute_compliance(V, D, u_sol, rho, penal, E0=1.0, E_min=1e-9, nu=0.3):
    """Compute total compliance (strain energy)."""
    E = E_min + rho ** penal * (E0 - E_min)
    lmbda = E * nu / ((1 + nu) * (1 - 2 * nu))
    mu = E / (2 * (1 + nu))

    def epsilon(u):
        return 0.5 * (dolfin.grad(u) + dolfin.grad(u).T)

    def sigma(u):
        return lmbda * dolfin.div(u) * dolfin.Identity(2) + 2 * mu * epsilon(u)

    return dolfin.assemble(dolfin.inner(sigma(u_sol), epsilon(u_sol)) * dolfin.dx)


def compute_sensitivity(D, u_sol, rho, penal, E0=1.0, E_min=1e-9, nu=0.3):
    """Compute element-wise sensitivity dc/drho."""
    dE = penal * rho ** (penal - 1) * (E0 - E_min)
    lmbda_E = nu / ((1 + nu) * (1 - 2 * nu))
    mu_E = 1.0 / (2 * (1 + nu))

    def epsilon(u):
        return 0.5 * (dolfin.grad(u) + dolfin.grad(u).T)

    ce = dolfin.inner(
        lmbda_E * dolfin.div(u_sol) * dolfin.Identity(2)
        + 2 * mu_E * epsilon(u_sol),
        epsilon(u_sol),
    )

    return dolfin.project(-dE * ce, D)


def oc_update(D, rho, dc, volfrac, mesh):
    """Optimality criteria density update."""
    rho_arr = rho.vector().get_local()
    dc_arr = dc.vector().get_local()
    vol = np.array([cell.volume() for cell in dolfin.cells(mesh)])
    total_vol = vol.sum()

    # Ensure sensitivities are strictly negative (numerical safeguard)
    dc_arr = np.minimum(dc_arr, -1e-20)

    l1, l2 = 0.0, 1e9
    move = 0.2

    while (l2 - l1) / (l2 + l1 + 1e-30) > 1e-3:
        lmid = 0.5 * (l2 + l1)
        rho_new = np.maximum(
            0.001,
            np.maximum(
                rho_arr - move,
                np.minimum(
                    1.0,
                    np.minimum(
                        rho_arr + move,
                        rho_arr * np.sqrt(-dc_arr / lmid),
                    ),
                ),
            ),
        )
        if (rho_new * vol).sum() > volfrac * total_vol:
            l1 = lmid
        else:
            l2 = lmid

    rho_new_fn = dolfin.Function(D)
    rho_new_fn.vector().set_local(rho_new)
    return rho_new_fn


def run_optimization(nelx, nely, volfrac, penal, num_iterations, load_type, results_dir):
    """Main SIMP optimization loop."""
    os.makedirs(results_dir, exist_ok=True)

    status = {
        "state": "initializing",
        "iteration": 0,
        "total_iterations": num_iterations,
    }
    with open(os.path.join(results_dir, "status.json"), "w") as f:
        json.dump(status, f)

    mesh, V, D, bcs, load_info = setup_problem(nelx, nely, load_type)
    rho = dolfin.interpolate(dolfin.Constant(volfrac), D)

    convergence_file = os.path.join(results_dir, "convergence.csv")
    with open(convergence_file, "w") as f:
        f.write("iteration,compliance,volume_fraction,change\n")

    for iteration in range(1, num_iterations + 1):
        t0 = time.time()

        u_sol = solve_elasticity(V, D, rho, bcs, load_info, penal)
        compliance = compute_compliance(V, D, u_sol, rho, penal)
        dc = compute_sensitivity(D, u_sol, rho, penal)
        rho_new = oc_update(D, rho, dc, volfrac, mesh)

        change = np.max(np.abs(rho_new.vector().get_local() - rho.vector().get_local()))
        rho = rho_new

        vol = np.array([cell.volume() for cell in dolfin.cells(mesh)])
        current_vf = (rho.vector().get_local() * vol).sum() / vol.sum()
        elapsed = time.time() - t0

        print(
            f"Iter {iteration:4d}: compliance = {compliance:.4f}, "
            f"vol = {current_vf:.4f}, change = {change:.6f}, time = {elapsed:.2f}s"
        )
        sys.stdout.flush()

        # Save density array
        np.save(
            os.path.join(results_dir, f"density_{iteration:04d}.npy"),
            rho.vector().get_local(),
        )

        # Save mesh info on first iteration (for dashboard)
        if iteration == 1:
            cell_midpoints = np.array(
                [cell.midpoint().array()[:2] for cell in dolfin.cells(mesh)]
            )
            np.save(os.path.join(results_dir, "cell_midpoints.npy"), cell_midpoints)
            domain_info = {
                "nelx": nelx,
                "nely": nely,
                "num_cells": mesh.num_cells(),
            }
            with open(os.path.join(results_dir, "domain_info.json"), "w") as f:
                json.dump(domain_info, f)

        # Append convergence data
        with open(convergence_file, "a") as f:
            f.write(f"{iteration},{compliance:.6f},{current_vf:.6f},{change:.8f}\n")

        # Update status
        state = "complete" if (iteration == num_iterations or change < 1e-4) else "running"
        status = {
            "state": state,
            "iteration": iteration,
            "total_iterations": num_iterations,
            "compliance": float(compliance),
            "volume_fraction": float(current_vf),
            "change": float(change),
        }
        with open(os.path.join(results_dir, "status.json"), "w") as f:
            json.dump(status, f)

        if change < 1e-4 and iteration > 10:
            print(f"Converged at iteration {iteration} (change = {change:.8f})")
            break

    print("Optimization complete")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="SIMP Topology Optimization with FEniCS")
    parser.add_argument("--nelx", type=int, default=120)
    parser.add_argument("--nely", type=int, default=60)
    parser.add_argument("--volfrac", type=float, default=0.5)
    parser.add_argument("--penal", type=float, default=3.0)
    parser.add_argument("--num-iterations", type=int, default=100)
    parser.add_argument(
        "--load-type",
        type=str,
        default="cantilever",
        choices=["cantilever", "mbb_beam", "bridge", "half_wheel"],
    )
    parser.add_argument("--results-dir", type=str, required=True)

    args = parser.parse_args()
    run_optimization(
        nelx=args.nelx,
        nely=args.nely,
        volfrac=args.volfrac,
        penal=args.penal,
        num_iterations=args.num_iterations,
        load_type=args.load_type,
        results_dir=args.results_dir,
    )
