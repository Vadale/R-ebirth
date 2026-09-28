# Validation status and remaining acceptance gates

Updated 2026-09-28 for merged Spark support and D2 batch operation; the historical
maintenance, S1 and D1 results below retain their original scope.
This ledger describes implemented checks and their limits; a workflow definition
alone is not evidence that its latest execution succeeded. Inspect the
[current runs](https://github.com/Vadale/R-ebirth/actions) before integration.

The b9726 → b10828 engine update and optional Spark checks are recorded in
[D-032 validation](spark-native-validation.md). Local native, package, numerical,
vision and Spark Metal acceptance passed. The reused extraction pilot improved
to 8/10 exact records, without a new quality acceptance. Spark PR #46 merged
at `2c827a7` after all nine PR checks and the dispatched Linux/Mac model, vision,
demo and Valgrind workflows passed. D2 has separate operational acceptance below.

## Implemented checks

| Obligation | Executable evidence | Where it runs / prerequisite |
|---|---|---|
| Public arguments, conditions, S3 contracts | `rebirth/tests/testthat/` | R-CMD-check on macOS/Linux, release and oldrel; model-free cases always run |
| No cross-session spill overwrite | `test-llm-trace-spill-session.R`; Rust `synthetic_spill` | R CI checks fresh-process names and RNG neutrality; Rust checks existing file and symlink preservation |
| Memory/disk slice agreement and corruption refusal | `test-llm-trace-spill.R` | R CI, synthetic fixture, no download |
| CPU operation independent of Metal | Rust `cpu_backend` | Executed in R-CMD-check on macOS/Linux, including Metal-enabled builds; no model download |
| Native correctness and static analysis | `cargo test`, `cargo clippy`, `cargo fmt --check` | Rust engine CI; FFI tests/clippy in R-CMD-check; no-spill engine configuration also tested |
| Honest Rust floor | `tests/toolchain/test-msrv.R`; full package build with Rust 1.85.0 | R-CMD-check; Linux oldrel overrides the stable toolchain with `RUSTUP_TOOLCHAIN` |
| Independent synthetic numerical oracle | `tests/llm-golden/synthetic/reference_forward.py --check` and Rust integration tests | Per-commit Rust/golden CI; committed model and unchanged goldens |
| Real-model activation semantics | `test-llm-trace-golden.R` vs HF fp32 reference | Model-tolerance nightly or local `RELM_TEST_MODEL_QWEN`; D-018 scale-robust criteria |
| Golden gate rejects layer/index mutations | Model-free mutation cases in `test-llm-trace-golden.R` | Per-commit R CI; shares the gate used by the real-model comparison |
| Vision text, embeddings, encoder reference | `test-llm-vision.R`; `tests/llm-golden/vision/` | Vision nightly downloads the pinned pair and builds an unpatched encoder on the same runner; some local pins are machine-specific |
| Demo repeatability and analysis | `tests/demos/demo-utils.R`, Demo B plot self-test; demo scripts | Model-free checks per commit; Demo A/B end-to-end nightlies use the small pinned model |
| Native memory safety | `tests/valgrind/` | Scheduled Linux Valgrind/leak job; synthetic model |
| Repeated model lifetime | `test-llm-model.R` | Local/model nightly with Qwen and `NOT_CRAN=true`; 30 load/unload cycles, not the planned 1,000 trace/generate workload |
| Vendor integrity | `verify_vendored_tree.sh` | Per-commit hashes and reverse-patch coherence |
| Rust supply chain | `cargo deny` and `cargo audit` | Deterministic licenses/bans/sources per commit; advisory-feed checks nightly |
| Package installation, help, examples, vignettes | `R CMD build`; `R CMD check --no-manual` | R-CMD-check with the declared Quarto vignette builder; local checks need Quarto CLI and R package |

The six scheduled workflows were re-enabled on 2026-09-27 after GitHub disabled
them for inactivity. Maintenance [PR #42](https://github.com/Vadale/R-ebirth/pull/42)
merged at `01c10e9` after all nine PR checks and six fresh nightly workflows
passed, including vision on macOS/Linux. The earlier vision installation failure
did not require weaker numerical thresholds. This records that integration's
evidence, not a claim that every later run is green.

## Local maintenance evidence

R 4.5.1 on macOS arm64, Rust 1.96.0, existing local Qwen2.5-0.5B and cached vision
assets. The complete source R suite passed **968 expectations, zero failures,
seven skips**, with `NOT_CRAN=true`. The skips are one opt-in network download
and six Gemma4/Qwen3/Qwen3.5 checks requiring additional models. No golden was
regenerated. Rust default tests passed 94 cases (one ignored), and no-spill tests
passed 79 (one ignored); formatting, Clippy, the synthetic oracle and vendor
integrity checks passed. The original public two-session spill reproduction also
passed with GPU access restricted. The rendered-vignette package check subsequently
completed with zero errors, warnings and notes, and the remote checks above
passed before maintenance integration. These results belong to PR #42; the D-028
documentation update does not constitute a new feature test run.

## Open work, not delivered guarantees

- **Unpatched text-logit comparator:** `tests/llm-golden/reference/` is a plan,
  separate from the implemented upstream vision comparison.
- **Large-trace memory acceptance:** a full 4B-model spill run on the 16 GB target
  remains a hardware acceptance. Small synthetic and 0.5B tests do not prove it.
- **Long-session stress:** the planned 1,000 trace/generate cycles are not a
  scheduled gate. Current repeated-load and Valgrind checks cover narrower paths.
- **ASan/UBSan:** rebuild and instrument the full vendored C++ path; not replaced
  by the existing Valgrind job. Restricting native self-tests to a non-default
  feature also remains tracked work.
- **Embedding and model breadth:** pin a small dedicated non-causal encoder and
  complete the pending modern-model matrix. Correct opt-in variables are
  `RELM_TEST_MODEL_*`, as used by the tests.
- **Spill lifecycle:** the existing seven-day managed-directory sweep is based on
  age, not proof that the owner process exited. Protecting long-lived sessions
  during that sweep remains separate lifecycle work; custom directories are not swept.
- **Vision debt:** the upstream failed-projector-construction leak remains
  documented in NEWS; stronger content provenance for the nightly reference is
  still pending.
- **Statistical probes:** Demo A is exploratory. Parameter/layer selection and
  its uncertainty need an explicit nested-CV or held-out evaluation contract
  before a confirmatory `llm_probe()` product is built.
- **Windows/CUDA:** deferred pending suitable hardware testing. WSL2 CUDA,
  native Rtools builds, and Windows distribution are not certified by current
  macOS/Linux checks. This maintenance package adds no Windows support claim.

For a new acceptance gate, record its command, fixture/model and checksum,
platform/backend, measured criterion, CI job or manual owner, and latest result.

## D-028 increment — reference evidence and remaining gates

The [near-term plan](structured-production-plan.md) defines scope and sequencing.
S0 specifies concrete commands, fixtures and promotion thresholds for constrained
output, extraction and batch artifacts. WP11a and WP12a own the later probe and
service contracts; I1 specifies its selected adapter checks. S0 has offline
reference-artifact checks; S1 now has local native/runtime evidence, detailed in
[S1 implementation](s1-implementation.md). D1 has a measured negative result; D2 has application/process acceptance evidence
in [the D2 report](d2-batch-operation.md). Later product gates remain unexecuted.

| WP | Planned gate | Required execution context | Status |
|---|---|---|---|
| S0 | Frozen codebook, labelled pilot, document-group split audit, batch artifact example, API/dependency proposals | `python3 tests/structured-output/verify.py --self-test` and `check_batch_contract.py` in the same directory; 32 cases / 7 sources / 5 groups | Offline checks passed; D-030 approved |
| S1 | Supported-schema validation, unsupported-constraint rejection, incomplete-output/resource cases, unchanged unconstrained goldens | Tiny model-free fixtures in CI plus explicit small-model latency/memory comparison | Accepted/merged PR #44: all nine PR checks and model run pass; Mac Metal 1.531× with no positive peak-RSS increase; Linux CPU/R 4.6.1 1.417× and +2.30 MiB |
| D1 | Field accuracy, evidence support, unsupported values, missingness, coverage and correction time against baselines | Frozen held-out public-document pilot; model/build/backend recorded | Evaluated, failed promotion: 0/10 joint matches, 1/4 known amounts, 6/8 unsupported fields in task-valid records; human correction time unmeasured |
| D2 | Clean setup/offline run, interruption/resume, no duplicate commits, stale-identity refusal, resource report | Fresh Mac session and declared Linux CPU environment | Implemented under approved D-031; 466 local process assertions pass; native Mac/Linux evidence tracked in the D2 report |
| WP11a/b | Selection-aware/grouped evaluation, fold-local preprocessing, independent statistical references and controls | Synthetic reference fixtures plus pinned anatomy-lab example | Not run |
| WP12a/b | Declared load limits, overload, worker exit/recovery, request isolation and 1,000-cycle memory stress | Chosen Mac/Linux CPU service recipe; supervisor/worker versions pinned | Not run |
| I1 | Actual adapter calls and reconstruction after a new R process; retrieval quality when applicable | One pinned upstream integration per WP | Not run |

S0 checks source/case/schema digests, exact Unicode spans, grouped partitions,
output-record constraints, and deliberate corruption/missing-prediction guards.
The fixture-only batch check passes identity and expected skip/retry assertions;
it performs no inference, atomic writes, locking or real interruption recovery.
Its frozen first-amount baseline gets 6/10 joint value/evidence matches and 2/4
known amounts on the held-out pilot; it emits 9/14 unsupported nonmissing fields.
Always-missing also gets 6/10 records but 0/4 known amounts, so cannot pass the
quality gate. These are simple-rule outcomes, not relm/model results. S0 required
only offline reference checks. S1 subsequently adds the approved Serde dependencies,
native generation constraints and regression tests, with unchanged existing
goldens. The complete local R suite passes 1,068 expectations, zero failures and
seven declared skips; Rust default/no-spill and FFI tests plus fmt/Clippy pass.
The rendered-vignette source build and R CMD check also pass with zero errors,
warnings and notes.
The [S1 report](s1-implementation.md) distinguishes measured runtime/schema
behavior from application correctness; its development output still fails task
consistency checks. The later [D1 report](d1-extraction-evaluation.md) records
a separate, frozen held-out evaluation: all four promotion checks fail. Its
10/10 schema-valid outputs contain only 2/10 task-valid and 0/10 fully grounded
records. The unconstrained comparator has 1/10 joint matches. All predictions,
failed records and proposed source-review corrections are preserved. Eight
evaluator regressions and the 150-prediction artifact rescore pass; model-free
checks enter the existing Rust/golden CI job. D1 usefulness and human usability
remain unestablished. D2 operational results are separate from extraction quality.
