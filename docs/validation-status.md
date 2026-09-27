# Validation status and remaining acceptance gates

Updated 2026-09-27 for the maintenance baseline after relm 0.2.0.
This ledger describes implemented checks and their limits; a workflow definition
alone is not evidence that its latest execution succeeded. Inspect the
[current runs](https://github.com/Vadale/R-ebirth/actions) before integration.

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
them for inactivity. The last pre-maintenance vision failure was macOS package
installation (`knitr` archive extraction), before numerical validation. Re-run
the workflow to distinguish a transient repository/cache issue from a code defect;
do not weaken golden thresholds to repair an installation failure.

## Local maintenance evidence

R 4.5.1 on macOS arm64, Rust 1.96.0, existing local Qwen2.5-0.5B and cached vision
assets. The complete source R suite passed **968 expectations, zero failures,
seven skips**, with `NOT_CRAN=true`. The skips are one opt-in network download
and six Gemma4/Qwen3/Qwen3.5 checks requiring additional models. No golden was
regenerated. Rust default tests passed 94 cases (one ignored), and no-spill tests
passed 79 (one ignored); formatting, Clippy, the synthetic oracle and vendor
integrity checks passed. The original public two-session spill reproduction also
passed with GPU access restricted. The rendered-vignette package check and fresh
remote CI must complete before integration; these R counts do not replace them.

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
