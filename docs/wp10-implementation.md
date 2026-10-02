# WP10 — Token streaming implementation and evidence

Updated: 2026-10-02. **Local automated and actual foreground RStudio acceptance passed; final CI and integration pending.**
The founder approved D-038 after the concrete proposal. The
[contract](wp10-streaming-plan.md) and API-GRAMMAR section 10 bind this work.
Baseline: merged WP9 `b16e2c0`; branch `codex/token-streaming`. No new release.

Roadmap acceptance: **live token stream feeds a growing data.frame; live
token-statistics demo.**

## Scope

The existing native worker gains a bounded event queue; R consumes plain-data-
frame batches through `on_token` or writes them to a caller-owned binary file
connection. Token identities and stable text deltas are distinct. Final result,
names, seed and existing generation/schema rules remain unchanged. No new
dependency/export or vendor patch is authorized.

Three coordinated implementation areas cover stable decoder output, queue/FFI
ownership and R delivery. One integrated implementation review covered the
substantive diff. The accepted design review is not implementation acceptance.

## Review findings retained

The integrated implementation review identified a quadratic stop-prefix suffix
search on legal long near-matches. This was a source finding, not an executed
test failure. A bounded conservative stop holdback was substituted before
the first native build; the unchanged full decoder/stop check remains authority.

The first integrated clippy attempt failed compilation in the new vocabulary-only
test fixture: it used the pre-b10828 `use_mmap` field. The fixture now uses
`load_mode = LLAMA_LOAD_MODE_NONE`, matching the existing engine's pinned ABI.
No product loading mode or acceptance threshold changed. Original failed log:
`/private/tmp/relm-wp10/native-20261002-125206/clippy.log`.

Source-only R helper checks passed admission, connection identity, schema,
CSV quoting/Unicode/literal-NA and memory probes. At 64 rows the materialized
batch was 78,496 bytes against its 139,264-byte estimate; counted CSV copies
were 547,824 against 925,696 bytes. These checks do not validate native delivery.
An initial reader probe exposed base R's CRLF normalization inside quoted
fields. The serializer retains original bytes; document the reader limitation
and preserve the failed round-trip probe rather than changing output text.

The corrected native build passed formatting and clippy. Its library suite
passed 113 tests and failed the new context-exhaustion fixture: a requested
64-token window is padded to 256 by pinned llama.cpp (`llama-context.cpp`),
so the fixture reached its generation budget instead of the context boundary.
The fixture now reads `model.context_length()`, fills that actual window and
requires exactly one sampled token with `ContextFull`; the ordinary case still
requires the full token budget with `MaxTokens`. Product code and limits are
unchanged. The failed run is retained under
`tests/streaming/measurements/native-20261002-125502`. All eight stable-decoder
tests passed in that run; later integration/release/FFI stages did not execute.

The corrected native candidate passed on 2026-10-02: formatting, clippy,
142 engine test outcomes (114 library + 28 integration; one explicitly ignored
calibration), 24 optimized async outcomes and seven FFI tests. Optional real-model
test bodies remain environment-gated; these totals do not establish cached
Qwen/VLM acceptance. Separate installed-package streaming receipts below cover those
paths. Runtime input manifests match before/after the native run. Full
receipts: `tests/streaming/measurements/native-20261002-130325`.
The two preceding failed attempts remain preserved. Package pipeline PID41062 installed successfully into a fresh WP10 library and
regenerated native wrappers/manuals. The full R run reported two errors in new
streaming fixtures and 54 explicit skips. First, `rb+` was assumed to be writable
binary, but this R version reports text/read-only; the test now uses `r+b` and
closes its connection even on assertion failure. Second, the numeric `no_vocab`
synthetic GGUF was incorrectly used for public character generation. That exact
seeded sync/async/stream equality test now runs with cached Qwen (including
duplicate prompt names), while native raw-token synthetic parity remains passed.
All expectations and deadlines are retained; no product code changed. Failed logs
are preserved under `tests/streaming/measurements/package-20261002-131002`.

Only the two test files differ from the installed runtime's input manifest, as
recorded in `resume-provenance.json`. Detached resume PID47692 ran corrected
streaming tests plus all three required cached-model cases, followed by previously
unexecuted vignette/source/scoped-check stages. It reuses the verified fresh WP10
installation; no native rebuild or repeat of unrelated passing R tests.

The resumed run executed all three required cached-model cases successfully
(seeded Qwen sync/async/stream equality; ordinary/structured/callback/CSV parity;
over-batch VLM prefill parity), with no skips. The run itself **failed** because
file admission accepted `/dev/null`: R's `file_test("-f")` returns true for that
device. Its raw receipt and source-scoped model carry-forward are retained under
`tests/streaming/measurements/package-resume-20261002-131640`.

A small internal FFI metadata query now checks the OS regular-file type, returning
false for missing paths, directories and devices; invalid arguments remain
classed errors. It neither opens nor writes the caller's connection. R uses this
query in the existing read-only admission checks. Regression tests cover normal
files, invalid inputs, directories, devices and symlinks. No dependency or public
export is added. Only this admission path, its FFI registration and regression
changed; generation/decoder/queue/CSV serialization are byte-identical to the
successful model-case source. Targeted FFI/install/boundary verification and
previously unexecuted package stages ran separately (PID48001), without
repeating real-model generation or the unchanged engine suite.

The file-admission correction passed FFI clippy/tests, package reinstall and
all controlled streaming boundary cases (329 passing expectations; three explicit
cached-model skips with separate passed receipts). One test-construction warning
came from R buffering a symlink to a device; `raw = TRUE` now requests unbuffered
construction explicitly, and the helper-only gate requires zero test warnings.
The pipeline subsequently failed **before launching Quarto** because the harness
PATH pointed to a removed temporary tool directory. The existing RStudio-bundled
Quarto 1.7.32 is now selected. The resumed documentation-only pipeline PID60538
ran the adjusted helpers, vignette, archive build and scoped check. No runtime
or model suite is repeated. Original receipts remain at
`tests/streaming/measurements/file-admission-20261002-132232`.

The final documentation pipeline passed: 94 helper expectations with no test
warnings, streaming vignette rendered with Quarto 1.7.32, source archive built,
and scoped `R CMD check` completed with **zero errors and two warnings** solely
for intentionally unbuilt full-package vignette outputs. Examples, dependency
checks, registered native calls and documentation consistency passed. This is
not a zero-warning full package check; final CI must build all vignettes. The
installed testthat built-under-R-4.5.2 warning on local R 4.5.1 remains recorded.
Receipts: `tests/streaming/measurements/package-docs-20261002-133118`.

The first actual foreground RStudio attempt streamed 2,048 tokens over 17.692 s,
first batch at 147 ms, with 293 heartbeats. It **failed the acceptance gate**:
the independent console probe arrived after completion (`native_running=false`).
No responsiveness claim is made from it. Original state was restored and the
failed receipt retained under `rstudio-late-probe-2026-10-02`. Only that interactive
measurement was repeated with eight prompts to allow adequate operator time;
the five-second/500-ms/heartbeat thresholds are unchanged.

The repeated foreground measurement **passed** on the same final installed
runtime: 4,096 streamed tokens, eight completed prompts, first batch at 101 ms,
2 ms submission, 34.788 s generation and 578 event-loop heartbeats. A separately
submitted `1 + 1` returned 2 while the native worker was active and 1,903 tokens
had already been delivered; elapsed time was below R's clock resolution and the
500-ms bound. An independent check confirmed sequential event IDs, monotonic
elapsed times, exact final-text reconstruction and the 128-token demo window.
Globals, RNG, library and search paths were restored; the namespace/DLL remains
loaded for safe finalizers. Editor documents were untouched. Receipts, scripts,
raw events, result and final runtime hashes are in
`tests/streaming/measurements/rstudio-2026-10-02`.

## Verification ledger

| Gate | Current result |
|---|---|
| Stable text versus pinned decoder | Passed all eight decoder tests, including actual pinned decoder/UTF8/cleanup/stops and 8 MiB near-match regression. |
| Bounded queue, cancellation, ownership and terminal delivery | Native debug/release and installed R delivery gates passed. |
| R callback/file/encoding boundaries and materialized memory | Passed after OS regular-file correction; adjusted helpers have zero test warnings. |
| Native goldens / FFI / package checks | Available native suite, seven FFI tests and scoped package checks passed; two omitted-vignette warnings retained. Full CI remains pending. |
| Cached Qwen and VLM streaming paths | All three actual cached-model cases passed at the recorded parent source; file admission correction has separate passed boundary checks. |
| Actual foreground RStudio streaming demo | Passed with the measured results above; first late-probe failure retained. |
| Final nine PR checks / integration | No WP10 PR yet. |

Long jobs use detached execution with durable status in `/private/tmp/relm-wp10`
and sparse monitoring in the same chat. Failed attempts must remain in the
ledger; a successful process exit alone does not establish an unexecuted gate.
