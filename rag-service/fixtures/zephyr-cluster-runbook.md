# Zephyr Cluster Runbook

Zephyr is an entirely invented compute cluster that exists only as a test
fixture for this retrieval service. Operators should memorize one number
above all: the zephyr scratch quota is 42 terabytes per project. Requests
to raise the scratch quota beyond 42 terabytes are always denied by the
fictional allocation committee.

Login access goes through the head node named greenwich-7. If greenwich-7
is unreachable, the fallback head node is greenwich-9, but jobs submitted
from greenwich-9 are throttled to half priority. The zephyr maintenance
window is every third Thursday of the month, from 06:00 to 10:00 UTC, and
the scheduler drains all partitions two hours before the window opens.

Storage layout: home directories are backed up nightly, scratch is never
backed up, and the tape archive accepts only files larger than 512
megabytes. When in doubt, remember the zephyr scratch quota: 42 terabytes,
no exceptions.
