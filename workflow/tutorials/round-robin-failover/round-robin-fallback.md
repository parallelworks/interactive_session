# GPU Availability Probe with Round-Robin Fallback

## Overview

This workflow accepts a user-defined list of compute resources and attempts to verify GPU availability on each one by running `nvidia-smi` over SSH.

## How It Works

On each attempt (first try + retries), the target resource is selected using:

```
target = workers[ attempt_index % N ]
```

where `N` is the number of workers in the list. This means:

- Attempts cycle through the list in order.
- If a resource fails (nvidia-smi error, SSH timeout, etc.) the next attempt automatically moves to the next resource in the list.
- Once the end of the list is reached, it wraps back to the first resource.
- The step succeeds as soon as any resource responds with a working GPU.
- If `max-retries` is exhausted without a successful `nvidia-smi`, the workflow fails.

## Example

With 3 workers and `max-retries: 4` (= 5 total attempts):

| Attempt | Resource |
|---------|----------|
| 0 (first try) | workers[0] |
| 1 (retry 1) | workers[1] |
| 2 (retry 2) | workers[2] |
| 3 (retry 3) | workers[0] — wraps around |
| 4 (retry 4) | workers[1] |

## Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `max_retries` | number | 10 | Total number of retry attempts across all workers. |
| `workers` | list | — | One or more compute resources to probe. |

## Result

A `Check Exit Code` step always runs after the probe (regardless of success or failure) and emits a platform annotation:

- `::notice::` — GPU found and accessible on at least one resource.
- `::error::` — `nvidia-smi` failed on all resources after all retries.
