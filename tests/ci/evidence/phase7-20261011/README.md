# Retained CI timing snapshot

These two unmodified GitHub job metadata receipts were copied from the completed
Phase6 final acceptance. Both bind `435b31a420bafbe205e847c1ef1cee197101ae34`.
No new job or model was executed to produce this inventory.

`job-durations.csv` records all nine jobs; `step-durations.csv` records all 184
steps with real start/end timestamps. Seconds are the UTC difference between
`completedAt` and `startedAt`. For example, macOS oldrel-1 ran from
16:41:03 to 17:06:52 UTC on 2026-10-08: 1,549 seconds, or 25.8167 minutes.
Parallel job times must not be summed as elapsed wall time. These are one-run
observations, not a cost estimate or measured improvement. Full raw test logs
remain in their original acceptance, not duplicated here.

The maintainer disposition is in `docs/phase7-maintenance.md` at repository root.
