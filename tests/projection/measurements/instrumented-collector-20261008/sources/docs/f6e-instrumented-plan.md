# F6e targeted native memory acceptance

Status: prepared source only, 2026-10-08. No command below has been executed by
this document's author. Parent owns execution and independent collection.

This closes the affected native instrumentation requirement in
[f6e-projection-contract.md §6](f6e-projection-contract.md). The accepted normal
production activation scope is manifest
`18ebedbbf3469f2ae7358e8044836f51e866372c3af2e84fc9107070aa0ab31e`.
The installed public budget error class is being corrected separately; this plan
does not claim that installed gate passed. Any subsequent native source change
requires an explicit new freeze before these commands, without silently editing
an accepted source receipt.

## 1 Exact new instrumented scope

Use only these existing, unchanged, unconditional tests. Their ordinary execution
was accepted already; the new claim is execution of these paths with memory
instrumentation on Linux CPU. Do not rerun the old full40/live15/steering10 suites,
private projection1–9, constructor49, references, CPU/Metal timings, grouped-prompt
diagnostics, or ordinary Valgrind intervention matrix.

| Cargo target | Exact test ID | Cases | Refusals | Values | Reported loads / constructors |
|---|---|---:|---:|---:|---:|
| `projection_production` | `default_constructor_routes_and_owned_lifecycle` | 13 | 9 | 288 | 1 / 2 |
| `rebirth_llm` (`--lib`) | `async_job::tests::projection_static_live_restore_cancel_and_poison` | 10 | 2 | 3 | 1 / 1 |

Each mode therefore requires two exact libtest successes, 23 cases, 11 refusals
and 291 values. The 288 values are lifecycle/logit equalities, and the three are
post-edit zero coordinates; neither is a new independent numerical oracle. The
reported model/constructor counts come from the test marker, not an independent
engine-call profiler. Each mode uses the committed, no-vocabulary, CPU tiny model
`tests/llm-golden/live-state/f6b/synthetic-llama-3l.gguf`, SHA256
`e255ed5db07f318cbc3bd1d4d5a5a261bdef0867b3bbd1e26228f015b872bd05`.
Its unchanged requests use H32/D3/Q48, context128, n_batch4, GPU layers0, raw
`[1,7,13]` logits and `[1,7]` generation. There is no download or text-tokenizer
claim.

The integration test links the actual production library without `cfg(test)` or
`projection-private`; the worker test uses the production async path with existing
numeric-input/publication/fault seams under `cfg(test)`. It exercises additive
live changes while static projection remains owned, post-edit observation,
cancellation, original-adapter restoration, failure-before-token publication,
poisoned handle destruction and untouched parent survival. The integration test
covers the bounded constructor, plan inheritance, shared lifetime, failed startup
ownership, and projected image/trace/embed/direct-residual-derive refusals.

## 2 Driver and proof obligations

New `tests/projection/instrumented.py` imports the existing
`tests/sanitizers/run.py` without replacing its globals or editing that harness.
It reuses `Run.command`, mixed runtime/fault probes, the complete native-object
auditor and its patched `build_cvec` disassembly proof, Cargo event/archive
parsers, libtest event validation and the conservative source skip guard. The
latter is a formatting guard, not a Rust control-flow proof. The new driver owns
only the two-test allowlist, exact positive marker collection, source freeze,
default-feature binding, projection-specific object checks and scoped Memcheck
mode. These are harness additions, not runtime additions or new dependencies.

`instrumented-scope.json` freezes the actual llm Rust/native/build sources,
reused sanitizer/probe code, workspace manifests/lock/config, engine tree and tiny
fixture. It includes explicit accepted-production source hashes. Source hashes
are checked before compilation and after all tests; the scope manifest itself
must also remain unchanged. Local uncommitted source can be tested honestly:
record both HEAD and the actual bytes rather than treating HEAD as the source.
The checked-out freeze must match; refusal on drift is not authorization to
regenerate the freeze automatically. Workflow changes are deliberately not in
this immutable native freeze and must be retained with the workflow/run receipt.

Both modes use fresh nonexistent target and evidence directories, no compiler
cache, no incremental compilation, no retries, and `SOURCE_DATE_EPOCH=1700000000`.
Cargo JSON must declare exactly the two executable targets and one production
rlib, each with the exact features `default,spill`; private/CUDA/no-spill builds
cannot qualify. The integration test creates this rlib in the same build; an
additional production-library build is unnecessary. Artifacts outside that
fresh target, duplicate binaries, missing production rlib or wrong features fail.
Each actual binary must contain the classifier, row accessor and consumer symbols.

### ASan/UBSan

Use the existing pinned Linux route: Ubuntu24.04, Rust
`nightly-2025-02-01` + rust-src, target `x86_64-unknown-linux-gnu`, LLVM/Clang19.1.1,
Ubuntu packages `1:19.1.1-1ubuntu1~24.04.2`. Rust/std use ASan with
`-Zexternal-clangrt`; C/C++ use ASan+UBSan with no recovery. Leak detection remains
on. Exact flags, compilers, runtime archives and commands are retained. Existing
safe mixed-language controls, Rust/C/C++ out-of-bounds failures, C++ signed
overflow, and refusal of the identical uninstrumented binary must pass for this
new build. They validate current instrumentation, not old product acceptance.

Both CMake compilation databases and every native object undergo the existing
flag/symbol audit. Additionally, the single actual `native/projection.cpp` object
must have ASan and UBSan references, and disassembly of
`relm_projection_classify`, `relm_projection_row`, and
`relm_projection_consumer` must contain both sanitizer families. Its object and
disassembly hashes are retained. Every Cargo-declared production rebirth_llm,
Arrow-array and rebuilt-std archive is bound to actual ASan compile commands and
ASan references. Each executed binary must define the established ASan/UBSan
runtime symbols. A failed compile/symbol check is an actionable diagnostic, never
permission to remove the check or infer instrumentation from flags alone.

### Targeted Valgrind

A separate, uninstrumented build of the same two tests covers Memcheck ownership,
invalid access, and definite/indirect leaks through constructor/drop/worker paths.
It does not repeat the old four-binary Valgrind matrix. It uses the same pinned
Rust only to obtain exact libtest JSON, ordinary Rust code generation (no
`-Zbuild-std`, no ASan), Clang19 and debug information. Engine CMake cache must
prove native/AVX/AVX2/AVX512/CUDA/Metal are OFF. Actual Valgrind/package versions
are recorded; no unsupported version is silently substituted after failure.

The gate preserves existing Memcheck semantics: `--error-exitcode=1`, full leak
check, errors for definite/indirect leaks, origin tracking, and the existing
unchanged suppression file. No suppression may be applied. The small separate
`instrumented_memcheck_probe.c` is never linked into relm: safe execution must
pass; heap use-after-free and a definite leak must exit1 with their actual XML
error kinds. Each product process requires protocol4/`memcheck`, the exact binary
path, RUNNING then FINISHED, zero errors/error-count pairs and zero suppression
pairs. XML provides the actual-wrapper proof instead of fragile text matching of
"ERROR SUMMARY". ASan/UBSan-linked binaries are explicitly rejected in this mode.
Possible/reachable allocations retain the established non-gating semantics.

Neither Linux mode provides R/SEXP marshalling, R-header accessor, GPU/Metal,
ThreadSanitizer, universal Rust UB, new numerical tolerance, throughput, or RSS
acceptance. Existing installed R/FFI and Metal evidence retain their own scopes.

## 3 Exact owner execution commands

Run these once in the background after the owner has reviewed the final native
source freeze. Toolchain installation is the existing workflow setup, not a model
download. Working directory is the repository root. The new driver requires its
evidence directory NOT to exist; place the outer console log beside it.

```sh
python3 tests/projection/instrumented_controls.py
python3 -u tests/projection/instrumented.py --mode sanitizers \
  --source-manifest tests/projection/instrumented-scope.json \
  --evidence "$RUNNER_TEMP/relm-f6e-asan-evidence" \
  --target "$RUNNER_TEMP/relm-f6e-asan-target"
python3 -u tests/projection/instrumented.py --mode valgrind \
  --source-manifest tests/projection/instrumented-scope.json \
  --evidence "$RUNNER_TEMP/relm-f6e-valgrind-evidence" \
  --target "$RUNNER_TEMP/relm-f6e-valgrind-target"
```

The commands execute exact binaries directly, not broad `cargo test` filtering.
Sanitizer build (cwd `rebirth/src/rust`):

```sh
cargo test --locked -p rebirth-llm --target x86_64-unknown-linux-gnu \
  --no-run --lib --test projection_production --message-format=json -vv -Zbuild-std
```

Memcheck build is the same without `-Zbuild-std`, in its own fresh target and
without sanitizer environment. Direct libtest arguments are exactly
`--exact <ID> --test-threads=1 --format=json -Zunstable-options --show-output`.
The driver wraps only the latter product executions under Valgrind, not Cargo or
build scripts. Controls must finish with
`F6E_PROJECTION_INSTRUMENTED_CONTROLS {"status":"passed","executed_tests":40}`.
Those 40 model-free controls are written but not executed by this author.

## 4 Exact workflow delta for parent (not applied here)

Edit only the existing `.github/workflows/nightly-memory-safety.yaml`:

1. Add `projection-only` to the manual `sanitizer_selection` options and update
   its description. Preserve the scheduled `full` default and old selections.
2. Add `inputs.sanitizer_selection != 'projection-only'` to the existing
   `valgrind-intervention` manual guard. Thus old intervention tests do not run
   on this request.
3. For `asan-ubsan-native`, keep checkout and pinned toolchain/install unchanged.
   When selection is projection-only, prepare an existing parent evidence-root
   directory plus new nonexistent `projection-asan`/`projection-valgrind`
   subdirectories and separate fresh targets. Other selections keep current paths.
4. Guard existing broad harness controls, graph-size regression and CPU-callback
   regression steps with `SANITIZER_SELECTION != 'projection-only'`; their
   accepted unrelated source tests carry forward. For projection-only run
   `instrumented_controls.py`, then the new driver sanitizer command above.
   The required runtime/object audits still run inside that driver.
5. In that same manually selected job, install Valgrind and invoke only the new
   driver's Valgrind mode. Use existing90-minute limit initially; any timeout is
   retained as failed/incomplete, without automatic retry. A separate parallel
   job is unnecessary for this bounded selection.
6. Keep `if: always()` artifact upload, include the parent evidence-root, outer
   console/control/toolchain-install logs, both mode subdirectories and the
   exact workflow/source-scope files. Default/full/live/steering execution remains
   the existing `tests/sanitizers/run.py` command and is not launched here.

No workflow or existing sanitizer harness was changed by this task. The parent
must bind the actual workflow diff and exact checkout to the run before dispatch.
A single manual projection-only run requests both memory modes; do not silently
fallback to full if that selection is missing.

## 5 Receipts, counts and failure handling

The only accepted product stdout marker is one
`F6E_PROJECTION_PRODUCTION_TEST` inside the named libtest success's captured stdout.
Its exact fields are `test,status,expected_cases,executed_cases,
expected_rejections,rejected_cases,expected_values,compared_values,model_loads,
constructor_calls,library_cfg_test,private_feature`. Types and all values must
match the table in §1; booleans cannot stand in for integers. Duplicate keys,
nonfinite constants, extra fields, missing/duplicate markers, wrong test IDs,
ignored/zero/failed runs and sanitizer findings anywhere fail closed. Other
captured diagnostics remain in raw output; they are not promoted into proof.

Each mode writes `executed-tests.json` only after each exact positive result,
then `projection-summary.json` and `F6E_PROJECTION_INSTRUMENTED` with:

```json
{"status":"passed","mode":"sanitizers or valgrind","selection":"projection-only",
 "executed_tests":2,"executed_cases":23,"rejected_cases":11,"compared_values":291,
 "reported_model_loads":2,"reported_constructor_calls":3,
 "default_features":["default","spill"],"source_manifest_sha256":"<sha256>"}
```

These are two separate instrumented repetitions, not 46 distinct feature cases
or doubled independent accuracy. Preserve command exits, Cargo JSON/verbose logs,
compile databases, binary/rlib/object/disassembly/runtime identities, raw stdout
and stderr, Memcheck XML, source manifest and before/after byte verification.
`artifact-sha256.json` covers files existing before SUCCESS is written, including
nested compiled controls; externally streamed console logs may continue changing
and must be hashed by the owner after process termination. Hashes alone do not
prove an uploaded binary exists: retain the selected binaries/archives or their
owner-managed immutable archive when independently verifying object binding.

A failed run retains `FAILURE.txt` and partial receipts; never overwrite/relabel
it. On a collector-only error recover retained raw data without model reruns.
On a concrete runtime or instrumentation failure diagnose the affected scope
before a targeted correction. No relaxed tolerance, suppression, feature switch,
no-op receipt, skip, lucky retry or broader unchanged suite is authorized here.

Remaining unrun: all40 new collector controls, both fresh Linux builds, actual
runtime controls, two named tests per mode, instrumentation/Valgrind receipts,
workflow dispatch and independent owner verification. This document is a concrete
execution plan, not instrumented acceptance.
