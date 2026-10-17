# WP13 Linux CUDA implementation and results

2026-10-17, D-050. Local implementation, native numerical/device checks, installed
research workflow and bounded performance work are complete. One integrated
parent review is complete; final ordinary CI/PR integration remain; this is not a new release or
Windows/CRAN acceptance. [Plan](wp13-linux-cuda-plan.md),
[installation](linux-cuda.md), [raw evidence](../tests/cuda/evidence/2026-10-17/).

## Implementation

The default-off CUDA feature now reaches the extendr crate and R configure/link
path. The unchanged CUDA directory from pinned llama.cpp b10828 is restored;
G4 and reverse-patch coherence passed. NCCL is disabled for this single-GPU scope.
CUDA static objects use PIC before entering R's shared library. Both library and
wrapper generator use the same release profile and Rust flags, avoiding a second
CUDA build. The toolkit's real runtime libraries are linked with an explicit
rpath; no stub driver or LD_LIBRARY_PATH is required at R runtime.

The projection bridge verifies registry, device index/member, GPU type and default
buffer identity. CUDA uses synchronous get/set copies into the already charged
host row and the existing scheduler producer barrier. Host/Metal access remains
separate. There is no new owner, allocation formula, public signature, numerical
bound, kernel patch, dependency or generic device-loss recovery promise.
The existing research example gains an explicit backend argument, defaultCPU.

## Source-bound correctness

| Gate | Actual result | Scope |
| --- | --- | --- |
| Toolkit/device | Real CUDA allocation/kernel/sync/read/free;32 exact values | RTX 2060 Mobile/sm75, driver 580.178.04/CUDA 13.3.1 |
| Frozen numerical/resource gates | 19 tests, 0 failures/ignored; max logit .002340 / embedding .001516 / activation .003838 / intervention .001927 | Original nonPIC test build; existing .01 bound and frozen references; tiny FlashAttention CPU fallback retained |
| Projection transfer | 256 actual same-input/readback coordinates, maximum error 0;12 CUDA0 proofs;2 budget refusals | MLP/attention,10 rows/site; synchronous staging, not shared-memory/no-copy |
| Zero/live and worker | 224 exact values;zero row/read/write/barrier work;8 cases / 2 refusals;worker 10 cases / 2 refusals | Existing owner/cancel/restore/poison guards;35 identity controls carried |
| Production R install | PIC DLL 8bf2d82f..., noTEXTREL, realrpath,250 bodies/formals,0 codetools diagnostics / fixture hooks,27 compiled fields | Release/spill+cuda/selftestOFF;12 boundary cases / 58 expectations / 1 explicit selftest skip |
| Fresh installed workflow | 1 Qwen load, 4 traces, 8 successful async/live generations, 6 derives; 25/25 offload | Actual CUDA model/KV/compute; CPU-mapped weights remain |
| Saved result inspection | 7,168 capture values, 1,792 direction values (max error 5.55e-17), 1,792 zero identity pairs, 1,792 comparison coordinates, 3 legible plots | Raw-only parent verification; no model replay or generalized quality claim |

The installed source copy has 1,087 files; no source tar was produced by this gate.
1,091 bound inputs, 29 installed files, 25 workflow files and 5 stage logs were independently
checked. Native archives are normally cleaned by R installation; their survival
is not claimed. The Linux Rust 1.99 compiled profile differs from historical Mac
layout values; the current 27-field profile controls R accounting.

The valid-model installed workflow had no new native/R warnings or errors and
no compiler warnings. It retains exactly the known Qwen token 128247 `</s>`
NORMAL-to-CONTROL warning and its possible stopping effect. Test-only negative
bad-GGUF fixtures intentionally emit native errors. Generated answers remain
fallible: the flask answer contained a misleading heat-transfer explanation.
Downstream changed-history comparisons do not prove the same-input projection
formula; the separate native transfer test does.

## Bounded performance

A single diagnostic pass preceded the frozen final protocol. The final experiment
used one new repair-cafe prompt, actual saved tokenization, context 512 / max 128,
temperature 0 / top_p .95 / seed 8002 / raw text/no custom stops, the same Qwen Q8_0 file
`ca59ca7f13d0e15a8cfa77bd17e65d24f6844b554a7b6c12e07a5f89ff76844e`, and the same
production DLL. Three configurations ran in fixed order: CPU, CUDA, CUDA with 1 ms live polling.
Each ran one warmup and three measured iterations of each operation. No fourth
configuration, retuning, discarded slow sample or benchmark replay occurred.

Actual totals including warmup:3 loads / 3 tokenizations / 3 derives / 12 traces / 48 generations,
1,536 saved live states. All outcomes succeeded. Text and non-timing stream data
matched within each backend across repetitions and sync/stream/live; CUDA candidate
outputs and saved states also matched the baseline exactly. This does not assert
CPU/CUDA numerical identity. All outputs remain available for inspection.

Median [minimum, maximum] of the three measured samples:

| Operation | CPU wall seconds | CUDA wall seconds | CPU decode tokens/s | CUDA decode tokens/s |
| --- | --- | --- | --- | --- |
| Plain synchronous |2.427[2.405,2.447]|.504[.504,.505]|not instrumented|not instrumented|
| Plain token stream |2.499[2.495,2.512]|.514[.513,.514]|61.07[60.97,61.58]|261.18[261.18,261.36]|
| Filtered trace |.600[.591,.611]|.123[.101,.126]|not applicable|not applicable|
| Static projected stream |2.655[2.596,2.756]|.563[.563,.564]|56.95[54.91,58.36]|256.35[256.29,256.45]|
| Live stream |3.537[3.494,3.600]|1.118[1.109,1.158]|40.69[39.88,41.40]|118.10[112.98,118.13]|

Ordinary stream native first-token median was .3657 s CPU / .01682 s CUDA; the first R
delivery was .404 s / .052 s. These times include queue/prompt processing/sampling,
not pure prefill kernel time. Decode rate uses `(tokens-1)/(last-first native
elapsed)`. Sync calls have no invented event-based rate. Fresh-process load was
.286 s CPU / .479 s CUDA, not cold filesystem-cache loading; constructors .078 s / .080 s.

Global GPU memory baseline 1,502 MiB reached 1,507 MiB CPU / 2,798 MiB CUDA; process sampled RSS
peaks were1,271,132 / 1,108,904 KiB. CUDA temperature 36–45°C and SM clock 300–1,980 MHz varied.
The candidate reached 2,802 MiB and 42–47°C. These are coarse 200 ms GPU / 100 ms process
samples on an active desktop; short peaks, exclusive GPU allocation and causal
clock attribution are not established.

**Candidate rejected:**1 ms live timer median wall 1.141 s versus 1.118 s (+2.06%),
process CPU 1.237 s versus 1.093 s (+13.17%), decode 115.30 versus 118.10 tokens/s. It
failed the predeclared at least 5% wall improvement criterion. Production remains 5 ms;
there is no new R scheduler change or corresponding rebuild. Projection uses
changed histories, and live includes R conversion/callback acknowledgement; these
are application costs, not isolated kernel/operator microbenchmarks. Fixed order,
one prompt/small model and three samples do not prove universal or maximum speed.

### Instrumentation limitation and separate placement receipts

The final benchmark omitted backend initialization before installing the test
logger. The product's existing `Once` quiet logger then replaced it, leaving all
three original native logs empty. Timing/RDS/token/telemetry results were retained
and verified, but those executions cannot be described as fully logged or warning-
free. The original scripts/logs remain unchanged and the defect is documented.

Exactly two separate load-only checks initialized the logger correctly and used
the identical DLL/model/context/default GPU settings: CPU 0/25 offload with CPU model/
KV/compute and CUDA 25/25 with CUDA model 500.84 MiB / KV 6 MiB / compute 298.50 MiB, plus CPU_Mapped
137.94 MiB. Each retained the known tokenizer warning, no new native errors, and
closed its owner. They performed **zero generation, trace, derive or tokenization**.
They corroborate placement for the configuration; they do not recover the missing
benchmark logs. The earlier installed workflow and diagnostic profile had valid
native logs throughout. Timing acceptance retains this limitation explicitly.

## Preserved failures and resolutions

- Initial native placement fixture expected positive `gpu_layers`; actual metadata
  correctly retains the -1 all-layers sentinel. Only the assertion was corrected.
- A new test-only FFI declaration/range-pattern lint and a private fixture missing
  the existing native permit failed. Corrected fixture scope/permit; runtime guard
  and bounds stayed unchanged, only affected/unrun gates executed.
- First R install lacked six already-locked FFI crates in its offline cache.
  Fetching those exact versions added no dependency or version change.
- Wrapper linking after 22m24s native compilation failed SIGBUS. Core evidence and
  a separate 64 MiB EDQUOT control identified tmpfs user quota. The completed 2.52 GB
  debug cache moved byte-for-byte to disk with its old path preserved by symlink.
- The resumed wrapper passed, then R linking exposed missing CUDA PIC. Explicit
  CMake PIC required one affected recompile; final production shared link passed.
- Initial cross-filesystem hardlink preparation refused EXDEV; ordinary verified
  copies completed before native/model work. Raw-only inspector mistakes are
  preserved with corrections and did not cause inference replays.

Original failed statuses are never relabelled. Evidence manifests retain exact
source scopes; native nonPIC test evidence is not labelled execution of the PIC
DLL. Compiled artifacts/core journals remain local with hashes. There is no old
CPU/Metal/efficacy replay, frozen-golden regeneration or tolerance relaxation.

## Remaining boundaries

CUDA acceptance is this single Linux/sm75 host and the recorded dense-model
routes, not Windows, multiple GPUs, vision, universal architecture support or driver
fault recovery. Earlier cross-schedule numerical outliers, precision-policy
limits, consumed efficacy holdouts and model-quality caveats remain unchanged.
The integrated parent implementation review is complete (no independent-review
claim). Final nine ordinary CI jobs and PR integration are the remaining
publication gates. Ordinary CI has no CUDA device; localactual
hardware evidence supplies that separate obligation. Phase 9/CRAN is next only
after this phase closes; no release/tag is created here.
