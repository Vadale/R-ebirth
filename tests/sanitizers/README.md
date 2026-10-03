# Scoped native sanitizer acceptance (D-019)

## Graph storage sizing regression (D-039)

`python3 tests/sanitizers/graph_size.py --cc clang --evidence /new/output/path`
extracts the actual checkout's sizing, pointer helper and hash selector, with
the actual ggml type headers. It compiles no full engine and downloads no model.
An independent remainder-based alignment oracle and an exactly sized allocated
buffer verify 68 size/gradient combinations, every field offset/alignment and
endpoint writes. A negative invocation must reproduce the original null-plus-96
UBSan error, proving that the check is active. Missing/duplicate cases, diagnostics,
source drift and pre-existing evidence directories fail closed.

The ordinary Rust workflow runs this on Linux and the native arm64 Mac host;
the scoped nightly also runs it with pinned `clang-19`. Commands, current source
hashes, compiler identity, extracted code and result hashes are retained. This
does not certify arbitrary-size overflow handling or replace the selected
native sanitizer gate. Original proposal snapshots remain historical evidence.

## CPU callback signatures (D-040)

`python3 tests/sanitizers/cpu_callbacks.py --evidence /new/output/path` extracts
all seven actual-source adapters, verifies direct trait assignments and checks
forwarded pointers, counts, strides and writes against typed C++ stubs. Strict
compiler checks reject each original cast and accept the current assignments.
Uninstrumented negative controls must actually execute. The sanitized original
calls must fail with the expected function-type diagnostic when instrumentation
exists. macOS without that compiler hook records runtime coverage as unavailable,
never accepted; it can still exercise type and forwarding contracts.

The Linux nightly uses pinned `clang-19` / `clang++-19`, explicit
`llvm-symbolizer-19` and `--require-runtime`. Missing instrumentation or any
surviving original call fails before the expensive product build. No native
numerical kernel is replaced by this stub control; every product case in the
chosen selection below remains mandatory. Four source-mutation controls run with the existing
harness tests. Sources, commands, compiler/symbol receipts and failures are kept
under the nightly artifact's `cpu-callbacks` directory.

## Full native gate

`nightly-memory-safety.yaml` retains Valgrind and adds an independent Linux CPU
ASan/UBSan job. This harness is never imported by the package. Its controls and
selected tests are download-free (the committed synthetic GGUF only).

The toolchain is Rust `nightly-2025-02-01` (LLVM 19) plus Ubuntu 24.04's pinned
`clang-19`, `llvm-19` and `libclang-rt-19-dev`, version
`1:19.1.1-1ubuntu1~24.04.2`. A missing package/version is a failure, not a silent
upgrade. Preflight checks the actual compilers before the expensive engine build.
Rust's `-Zexternal-clangrt` selects Clang's runtime for all three languages;
`-Zbuild-std` instruments the standard library as well as Rust dependencies.
The link explicitly includes `libstdc++`: rustc uses `-nodefaultlibs`, which
otherwise prevents clang++ from supplying the C++ ABI used by runtime type checks.
An explicit target leaves host build scripts/procedural macros uninstrumented,
as recommended by the [Rust sanitizer documentation](https://doc.rust-lang.org/unstable-book/compiler-flags/sanitizer.html#working-with-other-languages).
C/C++ uses `-fsanitize=address,undefined` and `-fno-sanitize-recover=all`;
Rust uses ASan. The [Clang ASan](https://clang.llvm.org/docs/AddressSanitizer.html)
and [UBSan](https://clang.llvm.org/docs/UndefinedBehaviorSanitizer.html) documents
describe their separate scopes.

Before compiling the engine, a small mixed Rust/C/C++ binary must execute a safe
case, then fail with the expected diagnostic for Rust, C and C++ out-of-bounds
loads and C++ signed overflow. These expected failures have separate log files;
a generic crash/timeout is not a successful control. The identical uninstrumented
safe probe must be rejected by the runtime-symbol check. No probe enters the
vendored tree or package build.

`RELM_NATIVE_SANITIZERS=address,undefined` is the opt-in for both native CMake
builds. Unset, it changes no ordinary build flags. The workflow uses a fresh target
under `RUNNER_TEMP`, no cache actions, disabled compiler caches and incremental
compilation, with a baseline CPU engine. The relocated archives remain inside
that target, outside normal package/release paths. There are no suppressions or
automatic retries. Leak detection stays enabled.

After compilation the harness checks both compilation databases and every
resulting C/C++ object for ASan references, verifies UBSan references, and retains
`build_cvec` disassembly containing both sanitizer calls. Cargo's verbose log must
show ASan commands for the engine wrapper, Arrow and rebuilt Rust std; their
compiled archives must also contain ASan references. Cargo's verbose build-script
lines are retained as text beside its JSON stream; only compiler-artifact events
count, and the parser requires one successful build-finished event and every
selected binary without duplicates. Every real
test binary must define the ASan and UBSan runtime symbols; runtime archive hashes
and `ldd` output record static-runtime/dynamic-system-library linkage. Compiler
commands, source/fixture hashes and binary hashes are preserved with the results.

The default `full` allowlist in `run.py` executes 30 exact tests. The original
15 cover intervention/reversibility,
trace, spill/readback and spill-path preservation, generation/sampling, embedding,
async native handoff, cancellation/recovery/destruction and stream backpressure
ownership. The additional 15 F6a cases cover:

- Four async cases: state/token order and correlated acknowledgements,
  cancellation/discard while awaiting acknowledgement, publication versus wait
  notifications, and synthetic generation through memory and spill transport.
- Five capture cases: context reuse and worker transfer, observer failure cleanup,
  capture filters and context exhaustion, independent prefix activation/logit
  goldens including long prefill, and tiny/wide allocation bounds.
- Six spill cases: completed versus delivered ownership, writer failure and
  cancellation cleanup, IPC padding and cumulative file bounds, shorter-label
  workspace bounds, long-label single rows, and full-queue cancellation wakeup.

Each invocation must yield exactly one named libtest start and success,
zero failures and zero ignored tests. Empty/wrong filters fail. Existing numerical
forward-pass markers must also appear. The live prefix golden uses libtest
`--show-output`: its marker must occur in the named successful test event's
`stdout` field. No arbitrary non-JSON output is discarded or accepted. Other
cases retain `--nocapture` and their existing marker checks.
All selected functions are unconditional;
a conservative source guard rejects explicit early returns, environment model
gates and skip macros. Unit sources resolve by module (`async_job`,
`live_capture`, `live_spill`); the guard stops at the selected function's
same-indent closing brace, before subsequent helpers. This formatting guard is
not a general Rust parser or control-flow verifier. The actual
assertions in these tests remain the execution proof. Vision/model-gated tests are
excluded explicitly, including from successful coverage claims.
The spill feature remains enabled by the crate's default features. No
`--no-default-features` override or feature-gated allocation test is selected.

Run the fast adversarial harness checks without building the engine:

```sh
python3 -m unittest discover -s tests/sanitizers -p 'test_*.py' -v
```

On the pinned Linux host, run the full gate from any directory (the target path
must not already exist):

```sh
python3 tests/sanitizers/run.py --evidence "$RUNNER_TEMP/sanitizer-evidence" \
  --target "$RUNNER_TEMP/relm-sanitizer-target"
```

For the scoped F6a.2 acceptance, manually dispatch the workflow with
`sanitizer_selection: live-only`, or on the pinned Linux host use:

```sh
python3 tests/sanitizers/run.py --selection live-only \
  --evidence "$RUNNER_TEMP/live-sanitizer-evidence" \
  --target "$RUNNER_TEMP/relm-live-sanitizer-target"
```

This selects exactly the 15 new live cases in the `rebirth_llm` unit binary;
none of the original 15 product cases executes, and no old integration test
binary is requested. The workflow also skips the unchanged Valgrind job. All
Python controls, graph-sizing and callback controls, mixed-language fault probes,
fresh instrumented compilation, object audits and binary/runtime checks remain
mandatory. A scheduled run, omitted CLI selection or default manual dispatch
uses `full`; the optional existing `sanitizers_only` input still skips Valgrind
without narrowing the sanitizer allowlist.

Test output filenames percent-encode Rust module separators and other reserved
characters. Test IDs and exact libtest filters are unchanged; each executed-test
receipt includes its output filenames and digests, source module/digest and
selection. `provenance.json` also records the selection and complete exact test
allowlist; `SUCCESS.txt` names the selection and count. This avoids GitHub artifact
filename rejection without changing execution or acceptance criteria.

The workflow retains logs and partial receipts even on failure. `SUCCESS.txt`
exists only after every required test passes. A source edit or workflow file is
not a successful Linux acceptance run. The new F6a.2 selection has only
model-free Python harness control coverage at preparation time; its instrumented
Linux execution is still pending. Historical acceptance of the original 15
cases does not establish acceptance for these new paths. Scheduled runs still
execute both jobs.

Coverage is the native CPU paths actually exercised. This is neither a
ThreadSanitizer result nor Metal/CUDA, vision, R/SEXP marshalling, or universal
Rust UB coverage. It does not execute R callbacks/close semantics or F6b dynamic
coefficient updates. The ordinary native and R boundary checks remain separate.
