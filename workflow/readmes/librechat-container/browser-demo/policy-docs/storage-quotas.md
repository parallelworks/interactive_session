# Sample DSRC — Storage and Quotas

> Training sample — a simplified, fictional excerpt modeled on HPCMP DSRC policy. Illustrative only; not authoritative. Effective 2026-01-01. Document ID: STOR-2026.

## Home (`$HOME`)
Your `$HOME` is backed up and is intended for source code, scripts, and configuration files — not large datasets. Illustrative quota: 100 GB.

## Scratch (`$WORKDIR`)
`$WORKDIR` is large, high-speed temporary space for job file I/O. It is **not** backed up, and files not accessed for **30 days** are subject to automatic purge by the file-system scrubber. Do not use it for long-term storage.

## Archive (`$ARCHIVE_HOME`)
`$ARCHIVE_HOME` is long-term archival storage on the center's archive system. Move results here before the scratch purge, and retrieve them with the center's archive commands.

## Checking usage
Storage quotas are enforced per user. Check your current storage with your center's quota command; core-hour allocation usage is shown by `show_usage`.
