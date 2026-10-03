# Phase 6 implementation and validation

Status: in progress, 2026-10-03. F6a and F6b are authorized under D-041.
F6a is implemented and local acceptance passes; focused Linux sanitizer and
ordinary CI acceptance remain pending. F6b runtime is not implemented. The binding
contract is `phase6-live-introspection-plan.md`; F6b coefficient replies and
audit fields are finalized there before implementation. No new dependency,
vendor modification, model download or numerical tolerance is introduced.

## First owned-hook feasibility attempt

The initial native prototype installs a context-owned dispatcher, with a stable
address across worker transfer and destruction after its native context. Active
arming remains test-only pending feasibility and resource accounting. It copies
only the selected source row, retains ordinary chunked prefill, and distinguishes
raw MLP output from post-intervention residuals. It is not the async/R transport.

Evidence: `tests/live-state/measurements/feasibility-20261003-160105` contains
losslessly compressed logs, source snapshot, manifest and independent result
verification. Formatting and clippy passed. Four synthetic cases passed,
including independent NumPy source states, filtering, cleanup after observer
failure, worker transfer, context-full boundaries, last-row pruning and long
prefill across batch/microbatch boundaries. Eighteen distinct reference states
were used; repeating the long-prefill case with another batch size compared
3,840 activation values. Maximum activation difference was 0.0034464036 and
maximum logit difference 0.0041723264, under existing pinned numerical bounds.
One explicitly invoked cached-model benchmark is ignored by the synthetic run;
this is not a missing synthetic test or a new tolerance.

The attempt FAILED: both active performance gates failed in the unoptimized
Cargo test profile. Requested-CPU medians were 10.3847s callback-free,
10.4145s dormant and 19.7604s active, versus the unchanged 16.8571s active limit.
Requested-Metal medians were 10.6829s,10.7086s,20.2461s versus 17.3043s. All modes
generated the same128tokens within each run; dormant ratios were 1.00286 and
1.00241. These are debug measurements, not production performance acceptance.
The original receipts record requested backend names but lack actual offload
evidence; they do not independently establish Metal kernel execution.

About9.4s per128states was measured inside the top20-logit callback itself.
Source inspection found a full-vocabulary sort and two vocabulary-sized
temporary arrays on every state. The R package uses an optimized release build,
whereas this harness used default debug tests. A scoped correction preserves
the old full-softmax reduction order and ranking/tie semantics while selecting
only the requested entries. Literal old-algorithm parity controls and explicit
backend/offload/profile receipts precede one production-profile measurement.
The sampler and performance thresholds are unchanged. No debug failure is
relabelled as acceptance, and no retry-until-green policy is used.

The whole-source freeze check also failed: two unused F6b draft producer files
were relocated under `live-state/f6b/` while the attempt ran. Independent checks
confirmed that every other captured source hash, including all six native files
and every F6a reference dependency, remained unchanged. The moved files were
not F6a inputs. This permits the precise numerical/diagnostic conclusions above;
the original manifest failure remains recorded.

## Optimized CPU result and Metal preflight correction

Attempt `feasibility-20261003-162847` passed formatting, clippy, three top-k
parity controls and five focused synthetic cases. The unchanged independent
golden differences remain within their original bounds. Actual CPU load/backend
receipts and the release build profile were verified. Across the prescribed
128-token measurements, medians were1.356983666s callback-free,
1.35696725s dormant and1.418246417s active, against the unchanged active limit
3.315475499s. Both CPU performance gates pass. Profile and selection algorithm
changed together; these data do not isolate their respective speed effects.
This remains a native observer measurement, excluding the future R transport.

The attempt failed overall before any Metal timing: the new harness expected
a selected device name beginning with `Metal`; pinned b10828 actually uses
`MTL0`. The retained log reports the Apple M4,25/25 offloaded layers and a
300.25MiB MTL0 compute buffer. The correction is confined to the test module:
match an exact `MTL<digits>` device to its own finite positive compute buffer,
while retaining the full offloaded-layer check. A regression consumes the
actual retained log excerpt, reproduces the old rejection and rejects spoofed
names, wrong-device buffers, absent receipts and invalid buffer sizes.

Raw receipts, exact source snapshot and independent verification are under
`tests/live-state/measurements/feasibility-20261003-162847`. Runtime source is
byte-identical after the parser correction; CPU evidence retains its original
source label. Only the previously unexecuted Metal measurements were resumed; the original
CPU source label and failed overall result remain unchanged.

## Verified Metal feasibility and next implementation boundary

The scoped `metal-20261003-163736` attempt passed format/clippy, the retained-log
parser regression and the release Metal experiment. Independent verification
checked all twelve receipts (one warmup and three interleaved rounds in each
mode), source/model hashes, actual MTL0 Apple M4 selection, 25/25 offloaded layers
and the matching 300.25 MiB compute buffer. The source manifest is
`c30d3bc32a3d138e39c16a940d792306a9edc1a2a7d8cb5b25bd909edbfa0ec2`.
The callback-free, dormant and active medians are 1.192104958, 1.249553334 and
1.332110666 seconds for 128 tokens. The dormant ratio is 1.048190703, within the
unchanged 1.05 bound but with little headroom; the active limit is 3.068157437s.
Lossless evidence and source snapshots are retained under
`tests/live-state/measurements/metal-20261003-163736`.

Combined with the separately scoped CPU and independent synthetic results,
this passes the native hook feasibility gate. It does not measure R transport,
acknowledgement or spill, and does not complete F6a. The next implementation
freezes the full transient memory formula, then adds bounded state/acknowledgement,
R/FFI ownership and cancellation, and completed bounded Arrow streams. No further
unchanged feasibility rerun is needed.

## Independent dynamic-steering reference

New fixtures are separate from existing goldens and model files. F6a uses the
existing two-layer seeded synthetic model. F6b adds a tiny three-layer seeded
fixture under `tests/llm-golden/live-state/f6b`, generated without downloading a
model or adding dependencies. Steering an early supported block changes the
cached K/V of a later block, making a history-preserving incremental reference
distinguishable from incorrectly replaying the entire prefix with the newest
coefficient. The existing two-layer fixture alone cannot prove that boundary.
Python reproducibility and negative controls are reference checks, not F6b
native-runtime acceptance.

## F6a transport implementation in progress

The uncommitted native/R/FFI increment now introduces the one-state acknowledgement
boundary, live admission and coordinate checks, cancellation-aware spill, and
metadata-bound lazy reads. The R allocation profile and complete conservative
ledger are frozen in `phase6-memory-contract.md`; R independently checks native
preflight estimates before drawing an omitted seed. These changes are not yet
accepted: source syntax checks are preparation, not a built-package or model test.
New independent R tests cover admission, state/ack ordering, memory formulas,
Arrow boundaries and cached-Qwen integration. Existing references remain fixed.
The demo keeps at most 64 scores/positions rather than activation history.

## First full transport compilation attempt

`transport-20261003-173544` failed before runtime tests. Both formatting checks
passed; clippy rejected two large enum variants (`CaptureSink::Spill` and
`LiveTrace::Spilled`). The correction boxes those owned descriptors and retains
both the heap objects and owning pointers in the compiled allocation ledger.
No lint suppression, numerical change or test-bound relaxation is introduced.
The failed log, status, manifest and matching R/native/FFI sources are retained
under `tests/live-state/measurements/transport-20261003-173544`.

The single integrated review also identified a spill workspace underestimate:
a shorter actual token label can permit more rows per byte-bounded fragment than
the worst-label admission shape. The correction reserves the full admitted
fragment body workspace rather than one maximum-label packing. Its regression
covers a shorter-label fragment with more rows. The same review found that
adaptive fragment rows also invalidate whole-file byte admission through
64-byte buffer padding. The writer therefore uses the predeclared per-component
row count calculated with the cached maximum token length; an encoded
near-boundary regression must cover this second failure. This finding is distinct
from runtime acceptance; the original implementation was not accepted.

The review also found that live metadata was counted in the native aggregate
input budget only at submission, after the omitted R seed draw. The complete
normalized aggregate and four descriptors are now checked before that draw;
the FFI checks borrowed strings before making owned copies. Three new R
regressions cover the public unchanged-RNG path and exact byte/descriptor limits.
The focused R set now has26cases, including seven cached-model cases. The added
close-inside-state case checks the outstanding-ack cancellation/cleanup path;
the plan clarifies the inherited WP10 error precedence, without changing it.
At that point these regressions had only been parsed. Their later built-package
execution is recorded below.

## Corrected transport run and test synchronization

`transport-20261003-175131` passed formatting and clippy. The no-spill build
compiled, with an unused binding warning retained. Native live tests completed
17 passes, one failure and one intentionally ignored cached-model benchmark.
All allocation/Arrow writer/ownership controls and the independent capture
comparisons passed at that recorded source. The run as a whole FAILED; ordinary
async and FFI execution had not started. Complete logs and57matching source/
receipt files are retained under the corresponding measurements directory.

The sole failing synthetic async test used a queue-wakeup notification as if it
identified publication of the next state. `drain_stream()` wakes the same
condition variable, and the previous outstanding state's loop can consume the
next test sender before acknowledgement; the test then checks a token prefix
prematurely. The correction uses a separate test-only job/state-correlated
publication notification emitted exactly once. Actual token/causal assertions,
production ordering, deadlines and limits remain unchanged. A deterministic
wake regression must validate this seam. Only that changed test boundary and
the previously unexecuted affected async/FFI stages are resumed; passing Arrow
and numerical gates retain their original source scope.

## Native transport recovery accepted

`transport-resume-20261003-180124` passed format/clippy, warning-free no-spill
compilation, four targeted live-order/publication/ack cases, and seven FFI tests.
The ordinary async stage reports21passing outcomes:20actual cases and one
explicit early return because the optional VLM/projector environment is unset.
This is not fresh VLM acceptance and does not repeat the accepted WP9 matrix.

Source manifest `05df6c9f584177040150cb4c118eee8c4eedc5b83e9637e9985aed9d473e2c3f`
was independently matched to all current input files. Only `async_job.rs`
differs from the immediately preceding failed source, through the test seam and
cfg-scoped no-spill borrow. The prior17passing allocation/Arrow/numerical gates
retain that original source and the failed overall result. Raw logs, manifest,
changed source and independent verification are retained under the recovery
measurements directory. The package/R/model stage is the next gate; native
recovery alone does not establish public F6a acceptance.

## Installed R acceptance and public latency

`package-20261003-180453` installed into a new F6-specific library and regenerated
the private wrappers and manuals. All26 R cases passed860 expectations, including
all seven actual cached-Qwen cases, without skips or test warnings. These cover
real-width memory/proxy bounds, all-layer spill equality, long templated prefill,
callback ordering/reentrancy, cancellation and close while awaiting state ack.
All653 source hashes matched manifest
`6f9940c2858c9d93f7cbfd9656ad80324ecf58e95300f1d4ddcf063d23b40a34`.
The scoped package check has zero errors and two warnings from deliberately
omitted rendered vignettes. Full CI/package vignettes remain required. The
external testthat R4.5.2-versus-runtime4.5.1 and duplicate `-lc++` warnings are
retained. Raw logs, R results, installed hashes and source snapshot are in the
matching measurements directory; no native/model matrix is repeated.

`public-latency-20261003-181308` then used that exact installed package. Each
backend has one warm-up plus three interleaved ordinary/live pairs, all128tokens
with identical seeded output within each pair. CPU medians were1.060s ordinary
and1.446s live, within2.870s; Metal-handle medians were1.629s and2.702s, within
3.7235s. Maximum delivered state size was44,392bytes against62,920admitted bytes;
the full live transient ledger was71,831,288bytes plus the independently charged
ordinary async bound. The callback includes `object.size` and scalar receipt
work (1–11ms total per128states), so it is not literally empty. These are bounded
engineering measurements, not a universal throughput promise. Package logging
suppresses engine INFO messages; this run verifies the selected handle/backend
and installed bytes, while actual device/offload receipts retain the earlier
native feasibility source. All-layer/spill throughput and contextual RSS are recorded separately below.

## Scoped Linux coverage and interactive gate

The sanitizer harness now has an explicit manual `live-only` selection:15 new
cases (four async acknowledgement/ownership, five capture/numerical/allocation,
six spill lifecycle/boundary). It omits the previously accepted15 product cases
and old Valgrind job. Default/scheduled execution includes all30 cases. Existing
compiler/runtime pins, mixed-language negative controls, object/flag audits,
exact per-test JSON results and raw hashes remain mandatory. Module-aware source
guards and captured golden stdout are checked by26 short Python controls.
A tiny local libtest executable independently verified the captured-stdout JSON
format; it is not Linux sanitizer acceptance. Remote execution is pending.

The actual foreground RStudio gate passed in a fresh R4.5.1 session using the
exact F6 library:6.911s of generation,97ms submission,196ms first state,
118states and117delivered tokens, with119event-loop heartbeats. A separately
submitted `1 + 1` returned2 below the R elapsed-clock resolution while the native
worker was active and117states had arrived. Cancellation at state118 reports
118sampled tokens and publishes neither token118 nor another state. The rolling
score retains64values; it is a neuron measurement, not a calibrated detector.

Initial UI navigation could not select a second RStudio process and timed out;
no test was falsely recorded. The founder then explicitly authorized closing
redundant sessions. Original globals/RNG were backed up and independently checked;
the duplicate empty session and old window were closed. The fresh test session
was restored after acceptance and the original user globals/RNG reloaded there.
Only that session remains open; editor documents were untouched. User workspace
backups are kept locally and excluded from repository evidence. Exact test and
restoration receipts are in `measurements/rstudio-20261003`.

The separate resource harness's first attempt rejected `attn_out` on Qwen2
before generation, an expected model-capability restriction mistakenly requested
by that harness. Its failure remains in`public-resource-20261003-184016`.
The targeted correction measures all-layer **residual** capture in memory and
spill with the same16tokens, deliberate20ms callback delay, warm-up/three paired
rounds and original bounds. No product code or limit changed; independent
three-component synthetic semantics retain their earlier accepted source.

## All-layer resource measurement

The corrected `public-resource-20261003-184903` passes on the same installed
package: one warm-up plus three interleaved memory/spill pairs,16tokens each,
all24Qwen residual layers and top20. A deliberately slow20ms state callback
exercises acknowledgement backpressure. Seeded output is identical within every
pair. Median elapsed was0.609s memory and0.631s spill, including0.331/0.330s of
callback work; these are contextual throughput reports, with no new ceiling.

Maximum delivered memory state868,680bytes is below970,040admitted; spill proxy
11,304bytes is below23,472admitted. Each16state spill call writes13,344,896bytes
against145,121,408admitted. All64actual Arrow files have retained size/digest
receipts in the scratch run; metrics, raw logs and manifests are losslessly
retained in the repository. Source hashes remain unchanged. Native framing,
fixed fragment rows, full writer workspace and capacity checks retain their
separately executed synthetic evidence.

The requested100ms RSS sampler captured51samples, peaking at1,319,760KiB for the
whole process, including model, R runtime/allocator, startup and shutdown. This
is context only, neither an incremental live-allocation estimate nor a promise
that total-process RSS equals the ledger. Raw sampling times are retained.

## Remaining gates

- Actual focused Linux sanitizer execution for the15 new live cases, preserving
  instrumentation/negative controls and independently verifying raw receipts.
- F6b coefficient changes, revision/source audit, zero removal, history and
  original-adapter restoration on all exit paths, with native reference checks.
- Final relevant CI and integration. Prior WP9/WP10/I1/maintenance acceptance
  is retained with its original source scope, not repeatedly executed here.

## Current-stable compiler compatibility

Initial PR59 head6bb861e failed ordinary Rust run37139324339 in Linux clippy:
remote stable Rust1.99 deprecates `AtomicU64::fetch_update`, while local1.96
accepted it. Four other Rust checks passed; the failing job did not reach its
product tests. Both complete available log forms are retained. This is a
compiler compatibility failure, not evidence of lost state or a numerical error.

The narrow correction uses a checked `compare_exchange_weak` loop with the same
relaxed ordering and exhausted `u64::MAX` rejection. It supports the older pinned
sanitizer compiler without suppressing warnings or adopting the newer renamed
method. Sequence/exhaustion and contended uniqueness have dedicated regressions,
followed by the two affected acknowledgement cases. All four passed in
`atomic-compatibility-20261003-191220`, alongside format, clippy and no-spill
compilation, without warnings. Every source hash matched the frozen manifest.
The Linux sanitizer run at6bb861e also failed before any product execution,
as detailed below. Its preparatory receipts retain that original source. Final ordinary
checks must validate the corrected allocation helper at the final head. R/FFI,
capture, allocation formulas, numerical operations and acceptance bounds are
unchanged; accepted model/resource/RStudio receipts retain their original bytes.

## Live-only sanitizer library artifact correction

Sanitizer37139351757 at6bb861e completed its instrumented Cargo build and wrote
269 native-object audit records, then failed the Rust archive audit before any
of the15 selected product tests. The new unit-test-only selection emits a
libtest executable; unlike a build with integration targets, it does not also
produce the production `rebirth_llm` rlib expected by the existing audit. Actual
Cargo JSON and rustc arguments establish this artifact mismatch. The run is
FAILED with zero completed product tests, not accepted native memory evidence.

The scoped harness now explicitly builds the production library in the same
instrumented target after the live-only test build. This reuses native objects
and dependencies, adds no unrelated product test, and retains the three-archive
ASan audit. A successful non-test Cargo library artifact must identify one rlib,
whose bytes must match the unique archive inspected by llvm-nm. Missing,
duplicate, malformed, spoofed and libtest-only receipts fail closed. Full
selection keeps its existing build shape; compiler pins, flags, controls,
15 live test IDs and bounds are unchanged.

All26 targeted Python harness cases pass, including four new regressions, and
the actual retained failing Cargo output is correctly identified as libtest
rather than a production archive. The four unchanged callback-harness controls
retain their earlier execution. One corrected remote run is necessary because
the original hosted target is gone; no test has been silently rerun until green.
All709 downloaded files are inventoried; raw text receipts are losslessly
committed, while probe binaries remain locally retained with size/digest records.

## Cargo dependency variants in the scoped sanitizer build

Run37140337349 atd99679c passed the production-library binding and its ASan
archive inspection, then failed because the shared target contained two
`arrow_array` archives. The original uniqueness-by-glob assumption did not
account for Cargo's separate libtest and production-library dependency variants.
Both successful Cargo transcripts declare their respective Arrow archive, and
each `rebirth_llm` compiler command references the corresponding dependency.
The run still completed zero product tests; all714 artifacts and2333 source
hashes are retained/verified with that exact source. Ordinary Rust37140294367
passed all five jobs, independently of this sanitizer failure.

The correction selects **every** required non-test archive declared by the actual
successful Cargo stages. It rejects missing, malformed or duplicate artifacts
within a stage, validates the declared paths inside the instrumented target,
and audits each distinct archive with the existing compile-flag and ASan-symbol
checks. Identical paths shared across stages are recorded once with both stage
identities. It does not pick the first filesystem match or drop a dependency.
The live-only transcript has four archives across the same three audited crates;
the previously accepted full transcript has three. Per-archive receipts now name
the symbol-output file and contributing Cargo stages.

Thirty targeted Python controls pass. Complete actual stdout from the accepted
full run37117122286 and failed live run37140337349 validates both build shapes;
the earlier missing-library run37139351757 remains rejected. Exact selected
Cargo lines are committed as provenance-bound regression fixtures. This replay
also caught the standard library's actual `kind=["rlib"]` before dispatch; the
initial mock-only prototype used `lib` and was corrected. These are parser/audit
controls, not native product execution. No runtime, flags, numerical bounds,
selected product test IDs or dependencies changed. Corrected remote acceptance
is still required; the existing R candidate continues without duplication.
