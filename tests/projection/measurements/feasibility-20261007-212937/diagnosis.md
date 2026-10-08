# Initial private feasibility failure

Overall run FAILED. Format, clippy, no-spill compilation and five exact native
cases passed at the retained source; their positive counts and raw log hashes
were independently checked. The forward test failed before any comparisons,
because its actual backend receipt log was empty. No benchmark executed.

Source control flow explains the failure: forward_reference_backend installed
start_load_log before the process first acquired engine::Backend. That acquisition
runs LOG_FILTER.call_once and replaces the collector with quiet_log. The expected
compute-buffer log was therefore absent; it is not evidence of a CPU/GPU or
projection numerical failure. The benchmark already initializes the backend
before its own logger, but its nested Metal forward shares this same helper.

Correction: initialize available_backends before installing the private forward
logger. Preserve backend assertions, numerical inputs, counts and bounds. Only
the test helper changes. Resume failed/unexecuted exact tests6-9 and both unrun
benchmarks; do not repeat accepted tests1-5 or references. Original overall run
remains failed, and accepted partial evidence retains its source hash.
