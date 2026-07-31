# Sample DSRC — Data Handling (CUI)

> Training sample — a simplified, fictional excerpt modeled on HPCMP DSRC policy. Illustrative only; not authoritative. Effective 2026-01-01. Document ID: DATA-2026.

## Handling CUI
Center systems are authorized for Controlled Unclassified Information (CUI). Mark and handle CUI in accordance with DoDI 5200.48. Only mission-related data may be stored on the system.

## Where CUI may be stored
Keep CUI on the system's authorized file systems — your `$HOME`, `$WORKDIR`, and `$ARCHIVE_HOME`. Do not copy CUI to unauthorized or personal systems, personal cloud accounts, or removable media. Move data only through approved, authenticated tools — the center's Kerberized transfer tools or the Parallel Works CLI (`pw buckets cp`), which transfers through a single authenticated endpoint inside the authorized boundary.

## Prompts and model data
Text sent to an on-system LLM — prompts, attached files, and retrieved context — carries the classification of its content. Do not send CUI to a model or service that is not authorized for it.

## Long-term storage
`$WORKDIR` is temporary and subject to purge (see the storage policy). Move results you need to keep to `$ARCHIVE_HOME` for long-term retention.
