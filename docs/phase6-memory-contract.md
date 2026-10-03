# Phase 6 allocation contract

Frozen design, 2026-10-03, under D-041 and the approved limits in
`phase6-live-introspection-plan.md` §5. Implementation and resource acceptance
are pending. This is an allocation ledger, not a total process-RSS guarantee.

## State admission

Let `H` be hidden width, `L` selected blocks, `C` selected components,
`V = L*C`, `N = H*V`, `K = top`, and `B = 3*max_raw_token_piece_bytes`.
The vocabulary piece bound is cached at model loading using checked size queries,
without retaining all vocabulary strings or querying an active context.
Three times the raw length bounds UTF-8 replacement of invalid byte sequences.
For F6a, steering-entry count `S` is zero; F6b accounts for its approved audit.

For the supported R64 allocation profile, `g(x)` is the smallest pool in
`{0,8,16,32,48,64,128}` that holds `x`, otherwise `8*ceiling(x/8)`.
Define `r(x)=48+g(x)` and `ch(b)=r(b+1)`. The implementation checks a runtime
fingerprint of integer, double, pointer and string allocations before relying
on this profile; unsupported profiles fail admission.

`F` is measured from complete empty state prototypes containing actual model
path, named prompt and attributes, plus empty interning and configuration
skeletons. The larger materialized/spill prototype includes maximum-width
coordinate/path/spec fields. F6b adds its step/audit/reply skeletons. Shared
objects may be counted more than once deliberately.

```
G = 3*g(4*K) + 3*g(8*K) + K*ch(B) + 8*(K>0)
A = N>0 ? max(44*N, 4*g(4*N)+3*g(8*N))
            + ch(B) + sum(ch(component_utf8_bytes)) + 8 : 0
U = 2*g(4*S) + g(8*S) + 8*(S>0)
materialized_bytes = F + G + A + U
proxy_bytes        = F + G + U
```

The proxy must fit `min(relm.trace_budget,32 MiB)`. Memory delivery additionally
requires materialized state and native owned capture to fit their existing
32 MiB/materialization and 8 MiB/transport limits. Otherwise spill or refuse;
there is no truncation. A single activation vector remains at most 1 MiB f32.
R and Rust twin this calculation before submission, and delivery checks actual
`object.size(state)` against its admitted bound as an integrity assertion.
That assertion does not replace predictive admission.

## Transient allocations

The conservative live-owned envelope sums separately live allocation slots,
even where their maximum lifetimes need not overlap:

```
T = 2*R_mode + R_payload + R_assembly + FFI_native + Logits_native
    + Capture_writer_native + Fixed_native + WP10_peak + F6b_owned_reply
```

`R_mode` is the materialized or proxy bound. Two copies cover delivery and
assembly/attribute copies. The independent R interning payload is
`F+G+U`, plus, for memory delivery,
`4*g(4*N)+g(8*N)+3*g(4*V)+g(8*C)+g(8)+ch(B)+sum(ch(component_bytes))`.
Assembly adds `2*r(4*N)+2*r(8*N)` for expanded label indices/pointer columns.

Native conversion arrays contribute `24*N+12*V+44*K` on the memory path
(`N=V=0` for spilled conversion), plus explicit interning allocations.
Raw logits and unchanged sampler arrays contribute `20*vocabulary_size`.
Top-k rank/tuple/result capacities, decoded strings, and the temporary raw/display
piece buffers are separate. Native structure sizes, reserved capacities and
actual metadata string capacities are recorded as named compiled ledger fields;
no arbitrary fixed allowance stands in for them. R independently recomputes
its variable terms and checks the complete ledger sum using this compiled profile.

`WP10_peak` is the existing six-term `stream_transport_peak_bound()`:
68,558,976 bytes at its conservative limits. Counting only its three native
queue byte caps would omit decoder/output/R/CSV work. Ordinary async input,
normalization, template and token buffers retain their separately stated bounds;
a combined call estimate adds the inherited async envelope, explicitly allowing
overlap in the accounting. Model weights, KV/backend memory, allocator overhead,
thread stacks and caller-retained/copied objects remain outside this envelope.
The requested lazy output slice/matrix is reported separately from transport.

F6b additionally counts immutable f64 directions (`8*H*S`), original and
candidate dense f32 layer buffers (`8*H*D`), one scaled vector (`4*H`), command,
coefficient and audit arrays (`52*S`), and compiled direction descriptors.
The R direction copy and normalized reply/index work are separate; none is
needed for F6a's NULL-only replies.

## Arrow and files

The writer emits at most 4096 values per record and derives smaller fragment
sizes from the actual string and aligned buffer bounds. Let `a64(x)=64*ceil(x/64)`:

```
D(n,b,c) = 5*a64(4*n) + 2*a64(4*(n+1))
           + a64(n*b) + a64(n*c) + 7*a64(ceil(n/8))
```

Measure schema framing with actual maximum-width metadata and record framing
with the existing IPC encoder's fixed seven-field, sixteen-buffer shape.
Choose a target of at least 1 MiB, or enough for one bounded row and its framing;
then choose the largest fragment fitting both the target and 4096 rows using
the cached maximum token-label bound. Freeze that per-component row count for
the writer, even for shorter actual labels: adaptive row counts can increase
64-byte padding and invalidate a whole-file estimate.
Sum full fragments and tails **per selected vector**, including schema/end
framing, and multiply by maximum states. Reject estimates above 2 GiB before
submission; enforce actual remaining bytes during every write.

Account queue capacities, producer and writer rows, builder/encoding workspace
(four slots each reserving the full admitted frame minus record metadata) and
metadata workspace separately. A byte cap
and cancellation-aware condition variables bound producer waits. Finish/join
runs on the generation worker, never the R poll path. Ownership transfers when
the completed state is drained, so a retained proxy survives a later callback
cancellation; only verified undelivered files are removed.

Metadata binds coordinate space, prompt-token count, state/source IDs, and
record row/byte limits in addition to the existing nonce/model/spec. Before
R column conversion, the reader checks record lengths and reported buffer
sizes/capacities. This bounds conversion of streams written under the contract;
it does not claim a bound on arbitrary malicious IPC decoding or process RSS.

## Required implementation evidence

- R/native formula equality, checked arithmetic and exact-bound rejection.
- Actual small and large state sizes below the predictive bounds.
- Native allocated capacities and serialization below their advertised ledger.
- Long-piece strings and split/tail Arrow records; whole-call byte/file refusal.
- Cancellation/error/close while waiting for a state or writer; delivered-file
  survival and verified unpublished-file cleanup.
- Independent numerical/source-coordinate parity under memory and spill.

No measurement in the native feasibility benchmark substitutes for these gates.
