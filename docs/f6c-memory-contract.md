# F6c materialization accounting

D-044 implementation ledger, 2026-10-07. This bounds live package-owned working
objects, not input objects already owned by the caller, unreachable garbage
waiting for R GC, device buffers, model memory, or total RSS. It does not bound
cumulative allocations over a generation.

Let F = 32768 bytes for fixed small lists, frame headers, validation scalars and
function temporaries. M is the measured size of admitted metadata: context,
step/logit/steering frames, prompt and identity scalars. These objects have
strict base types, bounded field counts and string lengths before their copies
or vectorized validation. Metadata copy/validation reserve is 8M.

For comparison N is the selected captured width before subsetting neurons;
K is the sum of the two top-logit row counts (at most 256). Reserve 2048 bytes
per N and K. This covers simultaneously selected neuron/value/source vectors,
seen/order/match/logical index vectors, two input slices, the six-column result,
joined logit data, frame assembly and copy-on-modify. It deliberately exceeds
the independent prototypes of those simultaneous allocations, rather than
calling only the final result size a peak bound.

For a spilled input with B admitted Arrow buffer capacity and Q batch rows,
reserve A = 4(B + 256Q + F). This covers two overlapping batch buffers, decoded
numeric/string columns and conversion/copy work. Byte and capacity checks occur
before as.data.frame conversion. The larger of the two inputs' A is sufficient
because the readers execute sequentially and retain only selected output arrays.
No unfiltered trace-to-matrix operation occurs. Reject unsupported nested schemas
before recursive conversion; preserve existing nonce/schema/source checks.

Comparison admission: F + 8M + 2048(N + K) + A <= max_bytes.
Timeline admission: F + 8M + 2048H <= max_bytes, where H is the retained number
of expanded audit rows, at least one per state. Remove oldest complete states
until this and max_states hold; reject if a single new state cannot fit. This
includes the new history, selection indexes, old/new row binding and replacement
attributes; caller-retained old histories remain outside the new working set.

Use scalar or bounded walks while validating/filtering caller-owned large
inputs, so an unselected input's length cannot trigger an uncharged full-length
logical vector. Never size a budget by serializing a native handle or environment.
All estimates use doubles and refuse non-finite or nonintegral arithmetic.
Assertions measure materialized stage objects and complete results against the
admitted ledger; independent allocation prototypes and boundary tests check the
formula on supported 64-bit R. A newly encountered allocation shape must extend
the ledger and receive a targeted check before acceptance; no silent multiplier
change to make a failed case green.
