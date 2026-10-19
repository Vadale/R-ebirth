# Windows preflight path assertion failure

Original77feb30/run39161069016/job117774307127 remains failed. The newly added
preflight compared `.libPaths()` (forward slashes) with `normalizePath()`'s
Windows default (backslashes). R's actual function body normalizes with `/`.
The correction uses that same representation and retains strict equality/order.
No Quarto rendering or relm engine build/model execution occurred in this job;
full package checking was skipped. The actual Rtools SDK/registry preflight
passed, with its four source hashes verified again against this candidate.

The focused local control rejects the original default-spelling assertion and
passes all three base cases with an explicitly simulated Windows default. Real
Windows acceptance and the rest of the Quarto preflight are still pending.
Original raw output, source and metadata remain unchanged. No package/runtime,
archive, dependency, numerical or vignette change accompanies this test fix.
