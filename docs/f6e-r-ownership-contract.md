# F6e R constructor ownership

This supplements the [compiled memory contract](f6e-memory-contract.md). The
helpers in `rebirth/R/projection-owners.R` are internal and **not publicly armed**.
Source-level tests do not establish installed/native constructor acceptance.

## Measured pointer correction

The first corrected native ledger pipeline completed six libtests and one
R-hosted fixture: 95 cases, 40 refusals and no model. Its collector then failed
because it treated a populated external pointer as an empty pointer. Preserve
that overall failed status. The subsequent collector-only recovery uses the
same raw outputs, with 28 new controls and no native rerun. The previously
unexecuted R recomputation then matched 156 terms in 12 cases, accepted all exact
budgets and rejected all budgets minus one.

On the measured R64 process an empty external pointer has object.size 64;
a populated LlmHandle pointer has 184, including its 120-byte tag. The tag has
a 56-byte character-vector owner and a 64-byte type-name character payload.
The actual R-hosted pointer-identity assertion proves the two type-name payloads
are shared. Therefore two empty pointer skeletons require an additional
`2 * 56 + 64 = 176` unique tag bytes. object.size on a list traverses repeated
tag occurrences and reports 432 for the two pointers, 304 for their two tags,
and 688 for all four references. These recursive measurements are not unique
heap sizes. The original assertion that object.size omits a populated pointer's
tag was false. The constructor deliberately measures **empty** pointer
skeletons; it does not subtract tag bytes from actual populated objects.

Receipts: `tests/projection/measurements/public-ledger-resume-20261008-010121`
and `tests/projection/measurements/ledger-tag-recovery-20261008`.

## Environment and finalizer storage

object.size of an environment measures only its 56-byte header on this R64 ABI.
Both source and candidate own two ordinary bindings, `ptr` and `closed`, with
empty parent and no attributes. The candidate uses `new.env(hash = FALSE)`.
The source can retain its actual existing hash table. A bounded R-hosted native
query must first read its capacity and ordinary binding names directly without
allocating `env.profile()`'s capacity-length count vector. It rejects additional,
active, attributed or differently parented state before value lookup. Official
binding access may rebox at most two immediate scalars (112 bytes, explicitly
charged in R query workspace); promises are inspected unforced and refused.
Pointer identity and plain closed-scalar checks then precede returned facts.
The metadata pass does not copy R's private binding layout or use CAR on an
unboxed binding cell. The targeted unarmed transfer run verifies these controls
in R, including compiled-scalar/un-hashed/29-slot hashed fixtures and refusal
without executing active bindings or promises.

For each state, the measured wrapper skeleton already includes its header and
pointer reference. Add:

| Owner | Charge |
|---|---|
| Source hash table, if present | `r(8 * actual_hash_slots)` |
| Two binding nodes | `2 * object.size(pairlist(NULL)) = 112` |
| Binding symbols, conservatively | `2 * object.size(as.name("ptr")) = 112` |
| Closed logical scalar | `object.size(FALSE) = 56` |
| R state finalizer weak reference | `r(4 * sizeof(SEXP)) = 80` |
| Native pointer finalizer weak reference | `r(4 * sizeof(SEXP)) = 80` |
| C finalizer function-pointer owner | `r(sizeof(R_CFinalizer_t)) = 56` |

Thus the extra is 496 bytes for an un-hashed state, or 776 for the existing
29-slot hashed state. The package's existing finalizer closure is shared; no
per-handle closure captures the source model or constructor frame. Both
finalizers remain idempotent through existing close/drop semantics.

These structures follow the official [R Internals manual](https://cran.r-project.org/doc/manuals/r-release/R-ints.html)
and the actual installed-version sources:
[memory.c, R 4.5.1](https://svn.r-project.org/R/tags/R-4-5-1/src/main/memory.c)
(`NewWeakRef`, `MakeCFinalizer`, `R_RegisterFinalizerEx`) and
[envir.c, R 4.5.1](https://svn.r-project.org/R/tags/R-4-5-1/src/main/envir.c)
(`R_NewHashTable`). The local R64 allocation fingerprint is required; native
function-pointer size comes from the installed R headers. The accessor's actual
264-byte C/Rust query workspace fits the compiled1464-byte response workspace;
this was verified in `unarmed-transfer-resume-20261008-015335`, separately from
the earlier profile receipt. All42 installed-header hashes were bound.

## Constructor binding and residual working arrays

`projection_owner_scan` walks one existing record at a time. It rejects hidden
attributes, nonfinite/out-of-f32 scaling, invalid layers/components, non-unit
projection vectors, duplicate sites and site 33. Its site cache contains two
fixed 32-element integer arrays. Existing projection vectors are counted once;
candidate entries share those immutable vectors and records. The existing
combined formula separately allows two new H-double owners. Entry skeletons,
real metadata, source/candidate wrapper names and two intervention reference
lists are measured. There is no second complete list merely for admission.

`projection_flatten` allocates exactly five arrays from admitted counts:
integer steer layers, double scaled steer vectors, integer ablation layers,
integer ablation neurons and double ablation values. Scalar filling preserves
record order without repeatedly growing arrays or allocating an H-sized scaled
temporary. Their exact R pool sizes are checked against actual materialized
arrays. Existing residual entry vectors and these five independent arrays are
charged separately. Borrowing a new projection direction does not eliminate the
native Arc charge.

`projection_new_llm` uses the same measured candidate shape: one independent
un-hashed state, one N+1 intervention reference list, shared metadata, and the
existing package finalizer. A private `projection` attribute records
`max_bytes` and `existing_direction_estimate` for subsequent additive/ablation
inheritance, whose public signatures have no budget argument. Its exact scalar
record is validated and measured; it does not authenticate native state. A
construction error closes the newly returned pointer through the existing
idempotent close path. Private-feature native transfer now passes its separate
tiny-model constructor gate; public application remains unavailable.

The measured transport and inventory-result records are also charged. These are
bounds for the specified owned materialization and explicit native workspaces,
not an exact RSS measure of R's evaluator, allocator, global intern pools or
garbage awaiting collection. The base model/KV cache and independently requested
live capture retain their separate contracts.

## Remaining admission gate

The internal binding inventories named fixed workflow objects as well as the
existing owners. `projection_binding_workspace` measures a14-field independent
term twin,15-field input matching record, five-field preparation envelope,
handle-only native result, two shallow model measurement skeletons and one
temporary projection entry skeleton. Model measurement skeletons have no
metadata or H-wide payload; those are already charged by the actual owner and
direction/adapter terms. Recursive `object.size` deliberately counts repeated
fixed references conservatively. The outer named prototype list is included,
so measuring the workspace itself has a bound. These are explicit objects,
not an unexplained fixed allowance or an RSS claim.

`projection_prepare` binds current profile/state facts to the actual source and
entry inventory, adds this workspace to `r_projection_fixed_bytes`, checks the
native preflight against the R twin, and only then allows five residual-array
allocations. The native constructor rechecks source identity and dynamic
registry capacity at transfer. An inherited residual edit uses the handle's
recorded budget; a new projection uses the explicitly supplied budget. A failed
R result assembly closes the delivered native handle through the existing
idempotent close path. The internal bridge is feature-gated and no public
function calls it until the actual combined acceptance passes.

The R inventory is now bound to actual native state facts and compiled query
frame on two closed-empty-pointer fixtures (992/1272 extra state bytes), with
candidate query/close/source-state checks. This is not loaded-model acceptance.
Before production wiring, recheck native source dimensions, plan/baseline
capacities and all required residual capability proofs without an uncharged
probe. Reserve the registry using its actual capacity, and return only the new
handle. Native source validation is not authentication of discarded ablation
input values. A missing cached capability must fail before allocation until an
explicitly charged probe path is provided. Test the combined exact budget and
budget-minus-one at that concrete constructor, including failure cleanup.
Only then enable the approved public operator and run affected installed,
resource/lifecycle, evaluation, rendering and instrumented acceptance.
