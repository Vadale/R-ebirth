# Phase 7 maintenance and CI inventory

Date: 2026-10-11. Baseline is integrated F6e `7bc688a` (accepted tree at
`435b31a`). This is a bounded disposition of the supported workflow, not a claim
that every unused function or all possible duplication has been discovered.
No native runtime, dependency, public API or numerical criterion changes.

## Concrete simplifications and retained surfaces

| Surface | Observation and disposition | Compatibility and evidence |
| --- | --- | --- |
| Onboarding | The package README still called live observations future work; separate introductions lacked a complete research/export path. Correct the claim and route both READMEs and the documentation index to one runnable guide. | Existing quickstarts and specialist guides remain. The new example uses existing public APIs. |
| Setup and result objects | Define model/dependency/output checks and the bounded workflow in one repository script. Save existing compare/timeline/direction objects plus CSV and text; no parallel object hierarchy. | `source()` performs no inference. Existing outputs refuse overwrite. Seven model-free preflight refusals guard this boundary. |
| R helpers | Phase 6 already consolidated eight shared test helpers in `helper-projection.R`. Keep production validators with distinct schema, lifetime and boundary responsibilities. | No demonstrated equivalence justifies deleting those checks; no speculative helper framework. |
| Native internals | Projection/live observation, resource accounting and owned-handle paths have separate contracts and source-bound evidence. Retain them. | Phase 7 does not reopen numerical or ownership implementation. Historical failed executions stay failed. |
| Generated files | Keep `rebirth/R/extendr-wrappers.R`, `NAMESPACE` and `man/` as generated/bound package surfaces, with their sources and existing checks. | Do not hand-delete or regenerate accepted output for navigation changes. No generator invocation in this phase. |
| Optional dependencies | Publish a single support matrix for core, async/live, probes, topics, documents and application examples. | `methods`/`nanoarrow` remain core; later/promises, glmnet, uwot/dbscan and separate application pins keep their existing roles. No new dependency. |
| Applications and companion tooling | Retain topics, batch/service, vision and I1; link them after the primary path. | No generalized serving/compiler framework, new satellite, or application rewrite. |
| Frozen evidence | Keep references, protocols, failures and source identities separate from current instructions. | No consumed efficacy replay or regeneration of numerical references. Current integration status is additive to historical reports. |

No proven unused product path was removed. The concrete reduction is in competing
entry points and duplicated workflow setup, not a claimed percentage of code or
maintenance-time savings. Generated files and evidence are intentionally retained.

## Measured final CI cost

Use the retained successful [R run 37810685919](https://github.com/Vadale/R-ebirth/actions/runs/37810685919)
and [Rust/integrity run 37810685971](https://github.com/Vadale/R-ebirth/actions/runs/37810685971),
accepted head `435b31a420bafbe205e847c1ef1cee197101ae34`.
[Raw job metadata and duration CSVs](../tests/ci/evidence/phase7-20261011/)
are copied from the existing final receipts, not new executions. Duration is
`completedAt - startedAt`; step rows use the same calculation. Jobs overlap:
adding job minutes does not give elapsed time or billed cost. One run is not a
performance distribution or evidence of a speedup; cache/runner conditions vary.

| Required job | Minutes | Distinct responsibility |
| --- | ---: | --- |
| Linux R oldrel-1 / Rust 1.85 | 14.70 | Older R compatibility and Rust floor, R/native boundary, package and applications |
| macOS R oldrel-1 | 25.82 | Older R on primary OS, native/Metal lifecycle and package/application behavior |
| macOS R release | 23.93 | Current R on primary OS, package and application behavior |
| Linux R release | 15.55 | Current R/Linux C API, package and applications |
| Golden self-check | 0.67 | Independent reference producer, frozen artifact structure and approved comparison |
| Rust fmt/clippy/test | 4.42 | Engine tests, release async path and feature/build variants |
| Supply chain | 0.22 | License, source and dependency constraints |
| Vendor integrity | 0.15 | Pinned source tree and patch coherence |
| macOS x86_64 link | 1.85 | Architecture/linking compatibility, not another numerical test |

The largest timed steps were R package checks (337–735 s) and application service
acceptance (265–370 s); dependency preparation also varies. Shared test names
across R/OS combinations are not proof of redundant coverage: Phase 6 exposed
real R API and floating-point portability differences. Removing those jobs would
lose a distinct gate. No extra platform job or native build is added here.

Existing fail-closed documentation routing already avoids six heavy jobs for
allowed external Markdown-only changes. Package, example, test, decision and
workflow changes still select the full matrix. This phase adds only the small
model-free walkthrough preflight to the existing four R jobs. The actual Qwen
walkthrough is a recorded maintainer acceptance, not a download/inference step
on every PR. Separate manual/nightly memory instrumentation retains its own
purpose; its unchanged accepted scopes are not manually replayed for Phase 7.

## Remaining debt and stop rule

- External-user usability feedback is deferred under D-047. Agent execution
  cannot establish how a first-time researcher understands the guide.
- Binary availability can lag source, and development builds share a version
  string. Capability checks improve diagnosis; they do not authenticate a build.
- Historical reports are extensive. The new index separates current instructions
  from evidence; wholesale deletion would lose provenance.
- Mac package/service steps dominate the observed matrix. A future optimization
  needs an isolated cost/coverage case; this sample does not justify weakening
  platform, resource or lifecycle acceptance.
- Model/site limits, truncated efficacy, known tokenizer behavior and
  cross-schedule numerical limits remain in the [support matrix](supported-workflow.md).

Close this bounded phase after maintainer execution, one integrated review and
required final CI. Do not start a native refactor, another efficacy experiment,
release or Phase 8 as an automatic consequence of this inventory.
