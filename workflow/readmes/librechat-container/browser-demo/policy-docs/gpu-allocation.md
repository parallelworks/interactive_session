# Sample DSRC — Allocations and Job Limits

> Training sample — a simplified, fictional excerpt modeled on HPCMP DSRC policy. Illustrative only; not authoritative. Effective 2026-01-01. Document ID: ALLOC-2026.

## Allocations
Compute time is charged in core-hours against your subproject, granted through your Service/Agency Allocation Authority (S/AAA). Check your remaining balance with `show_usage`. Jobs are rejected once a subproject's allocation is exhausted.

## Concurrent GPU limit
A single user may run on at most **8 GPUs at one time**, summed across all running jobs. Jobs that would exceed this stay queued until GPUs free up. This limit is per user, not per subproject.

## Queues and walltime
- `debug` — short interactive tests, maximum 1 hour.
- `standard` — default priority, maximum 168 hours (7 days).
- `high` — approved time-critical work only; request through the HPC Help Desk.

## Requesting an exception
To exceed the concurrent-GPU limit for a deadline, submit a request through pIE at least 3 business days in advance. Increases are temporary and expire automatically.
