# F6c reusable graphics implementation and acceptance

Date: 2026-10-07. D-044 is approved. Local implementation and acceptance are
complete on `codex/f6c-graphics`; final PR checks and integration remain pending.
This report does not announce a release or start F6d/F6e.

## Behavior and scope

The [approved contract](f6c-graphics-contract.md) adds two constructors and three
S3 methods: `plot.llm`, `llm_compare` / `plot.relm_comparison`, and `llm_timeline`
/ `plot.relm_timeline`. All use base R, ordinary data frames and existing live
observations. There is no implicit inference, new dependency, native/vendor
change or modification of model weights.

The model map separates metadata and configured steering/ablation from measured
activity. It labels omitted blocks and unavailable observation sites; detailed
llama/qwen2 layouts do not imply architecture support elsewhere. In particular,
qwen2 post-projection `attn_out` capture remains unavailable.

Comparisons validate caller-recorded model/settings/prompt identity and every
prior generated token ID. The current sampled token may differ. Divergent input
prefixes retain observations but withhold differences; missing truncated top-k
values remain unknown. Records are not authenticated, and `llm_tokens()` does
not supply the generation template's exact prompt IDs. Neither a descriptive
activation difference nor a top-k table establishes answer quality or causality.

Timelines retain whole newest states and worker-applied coefficients/revisions.
An update after state N is marked at N+1 only if that state is visible. Restoring
a coefficient does not erase KV history. A sampled token is not necessarily
committed output. Results retain no native model owner.

The [materialization ledger](f6c-memory-contract.md) accounts for admitted R
tables, metadata and package-produced Arrow conversion workspace. It excludes
caller-owned inputs/old histories, garbage awaiting collection, graphics-device
storage, model memory and total RSS. Arbitrary hostile IPC metadata decoded by
nanoarrow is not a hard pre-parser allocation bound. Integrity records are not
cryptographic signatures.

## Managed spill correction

The first actual default-directory spill failed before its first state. The R
nonce lacked `trace-`, while the existing native lease admits only
`trace-*.arrow`; the live writer appends `-<state>.arrow` to that nonce. The narrow
R correction adds the required prefix before metadata accounting. It changes no
native writer, security rule, lifetime or budget. An ordinary regression checks
both managed and custom configurations; actual managed spilling subsequently
passed. Prior F6a spill acceptance used custom directories and is not relabelled
as coverage of this managed case.

## Verification and provenance

The independent hand-calculated reference was committed before implementation
in `e3e66b55f9b33c0ef167a348aaf5d0815a24e5b8`. The
[one integrated review](../tests/graphics/measurements/review-20261007/review.md)
found four issues: consumed-context boundary admission, ragged data-frame
validation, omitted-history marker placement and omitted-block labels. All were
corrected with regressions; targeted closure and a narrow managed-spill addendum
are retained. That addendum preceded actual runtime closure and is not rewritten
as execution evidence.

The [acceptance archive](../tests/graphics/measurements/acceptance-20261007/README.md)
retains stage status, logs, source/installation manifests, failed source,
numerical records, figures and safe RStudio receipts. Each stage's exact source
is in its manifest, including parent stages carried forward without rerunning
unchanged work. Runtime source stayed unchanged after the successful install;
later documentation and NEWS edits are not relabelled as installed execution.

| Gate | Actual result and scope |
| --- | --- |
| Fresh installed graphics tests | 24 cases, 110 expectations, no skips or test warnings; executable example also passed. Source-overlay runs are separate earlier evidence. |
| Affected spill correction | 3 installed cases, 14 expectations (including the new seven-expectation prefix regression). Other installed cases retain their earlier source scope. |
| Actual cached Qwen composition | Three runs, 24 states total: reference, additive intervention and managed spill. 896 coordinates; expected additive difference 0.05 within 1e-6, and in-memory/spilled values exactly equal. Paired-prefix, truncated-history and object/ledger/budget assertions passed. |
| Independent receipt verification | Recomputed all 896 coordinate deltas, additive expectation and exact spill equality; checked retained state IDs 3:8, exported CSV values and all RStudio restoration flags. |
| Visual/export inspection | Nine synthetic PDF/PNG pairs (normal, compact, monochrome), three actual-model views, foreground RStudio map/comparison/timeline and Console PDF/CSV export. Figures preserve their source tables. |
| Vignette | New synthetic graphics vignette executed through Quarto; the supplied-model example is deliberately not executed during rendering. |
| Final source build/scoped check | Zero errors, two warnings caused by intentionally omitted full rendered vignettes; no NOTE. Tests/native install were excluded from this scoped check because their focused acceptance is recorded separately. Full ordinary CI remains required. |

The installed F6c R package used an isolated library and the unchanged accepted
F6b DLL, SHA-256
`6edc6e6d512bb16e9d5ad8ed22093291e61a81bb89e5c2d07bee134db6ff04ac`.
Installation used `--no-configure --no-libs`; staged/final loading was checked.
There was no new native build or renewed native/sanitizer acceptance. The cached
Qwen2.5-0.5B Q8_0 GGUF SHA-256 is
`ca59ca7f13d0e15a8cfa77bd17e65d24f6844b554a7b6c12e07a5f89ff76844e`.
No model was downloaded. Existing F6a/F6b and other work-package evidence keeps
its original source, warning and hardware scope.

## Retained failures and limits

- Source-only fixture attempts retain missing-function red tests, named-type
  expectations, a nanoarrow schema-construction error and a raw PDF-text
  assertion invalidated by kerning. The last uses actual graphics text-call
  capture; separate rendered inspection establishes readability.
- `package-20261007-133713` failed on managed spill after the reference and
  intervention runs passed. Its initial collector did not save activation
  states, so the corrected composition required new paired runs. It remains a
  failed overall run.
- `package-resume-20261007-134046` passed the installation, affected tests and
  actual composition, then failed only the rendering harness: `$` did not find
  an inherited namespace function. The corrected harness explicitly binds
  installed functions. This failed overall run is not relabelled as passed.
- `docs-20261007-134232` passed rendering but Quarto hit the sandbox's `sysctl`
  restriction before document execution. The authorized local-runtime run
  rendered it successfully. Its source check initially reported an extra NOTE
  for generated assets left in the source tree. Moving those artifacts out and
  repeating only source build/check removed the NOTE.
- Local R is 4.5.1. External `testthat`/`nanoarrow` patch-version warnings and
  early roxygen namespace-link warnings are retained; the final installed-
  namespace documentation pass emitted none. This is not clean-CRAN acceptance.
- A very narrow RStudio pane clipped long titles/captions. Widening the pane and
  redrawing was inspected successfully. Use 10x7-inch exports, or the checked
  7x5 layout; arbitrary tiny devices are not claimed readable.

Foreground plotting took place after the founder's unlock reply. User globals,
values, RNG, library/search paths, environment, working directory and options
were checked restored; editor documents were untouched. The first restoration
check detected a Metal context environment setting and RStudio width setting;
their original values were restored and all eight final checks passed. Private
workspace/preflight backups remain local. The namespace stays loaded safely,
with model handles closed; namespace unloading is not claimed.

## Separate GitHub maintenance item

PR60's nine ordinary checks and both post-merge workflows passed. The independent
main [model-tolerance nightly 37610986083](https://github.com/Vadale/R-ebirth/actions/runs/37610986083)
failed because a lifecycle child calls `library(relm)` while that workflow only
loads source in its parent. The failed child lacked an installed package. Its
[log and diagnosis](../tests/graphics/measurements/main-nightly-37610986083/README.md)
are preserved. This milestone does not change or rerun that workflow, and does
not claim all GitHub workflows are green or a general GitHub outage.
