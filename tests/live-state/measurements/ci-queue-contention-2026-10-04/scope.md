# Nonblocking stream-drain fixture recovery

The remote no-spill failure occurred at source3635292, with8of9 PR checks
passing. The queue observer runs under the predicate mutex; its channel signal
does not promise that the following nonblocking drain can acquire that mutex.
The affected test now honors contention under the original2second watchdog,
shared by acquisition and producer completion. A held-lock negative path
exercises contention deterministically. Original cancel/discard/full-row/full-byte
cases and assertions remain. No production behavior, numerical bound or deadline
was weakened. The exact failed log, job/attempt/PR snapshot and original source
are preserved here.

The first local verification passed format/default clippy and stopped before
tests on the additional no-spill clippy gate: a pre-existing single-variant
match in the historical-KV fixture. Feature-specific destructuring preserves
the same rows binding and all numerical assertions, without suppression.
The full failed local attempt is retained in local-attempt-1. Corrected targeted
verification in local-corrected passed format/clippy (default and no-spill) and
both tests in default-debug, no-spill-debug and default-release: six outcomes,
zero warnings/failures/ignored tests. Independent verification checked actual
test names/counts, log hashes and both current/snapshotted source hashes. No
failed attempt is relabelled as passed. Final PR-head CI remains required.
