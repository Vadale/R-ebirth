# Simplifier compendium

Current maintenance reference, 2026-10-11 (D048). The founder requested readable,
maintainable code before Windows/CUDA. The role is defined in
[the simplifier instructions](simplifier-instructions.md); verification follows
[D029](development-workflow.md). This document supersedes the July punchlist as
a work queue, while historical audit/evidence files remain unchanged.

## What good code means here

A reader should be able to find the public operation, its argument checks, its
resource owner and its failure path without following incidental wrappers.
R validates public shapes and raises classed conditions; the FFI handles indices,
R ownership and panic containment; the engine owns native resources. These
boundaries each carry a contract and are not candidates for arbitrary collapse.

Use one helper for a genuinely shared invariant, with the public caller retained
in errors. Keep distinct contracts separate: seed validation, nonnegative counts
and byte budgets are not interchangeable. Prefer short, named steps and direct
control flow. Move test machinery out of production files; do not move modules
merely to meet a line-count target. Numerical reduction order, materialized-byte
charges, cancellation, unforced R values and ownership guards take precedence
over cosmetic brevity.

## Changes in this maintenance candidate

| Concrete problem | Change | Verification |
| --- | --- | --- |
| Eight public functions repeated the same handle checks | One internal `validate_llm()` preserving call and evaluation order | Class/message/call, lazy arguments and native-close synchronization regressions |
| Thrown and async conditions duplicated construction | One `relm_condition()` used by both paths | Exact hierarchy, field order, parent and call regressions |
| Trace cardinality alone admitted a duplicate cell replacing a missing cell | Reject duplicate `(prompt_id, token_pos, neuron)` coordinates after cardinality validation | Memory and spill reader regressions; valid slices unchanged |
| Old R state inspection used a non-API frame accessor | Public frame lookup after existing active-binding/provenance checks | 24 fresh C controls including unforced promises and GC; public compiled symbol; installed R integration passes |
| Native fixture entry points shipped in the default DLL | Explicit non-default `selftest` feature; test modules separated from production boundary files | Default registrations omit all 12; explicit test build retains them; 443 installed R cases yield 6,704 passing expectations and 67 scoped skips |
| Stale instructions demanded full suites after each edit | D029 focused checks, explicit ownership and stop condition | One coherent maintenance/release milestone |

The first R cleanup removes seven copies of handle validation and one condition
constructor: production code changes by +47/-54 lines before generated wrappers.
Three native R-hosted fixture modules move 500 lines out of production
boundary files, without changing their assertions. Neither number is a speed or
memory-safety claim. The historical July audit's claim that cardinality catches
all trace duplication was too broad; the new coordinate regression closes that
specific gap without rewriting the old report.

## Reconciliation of the July punchlist

| July item | Current source disposition |
| --- | --- |
| 1. Context initialization/RAII | Already implemented: `engine.rs` has an owned context guard between initialization and final owner construction. Retain it. |
| 2. Trace payload interning | Already implemented: `trace_payload()` uses token/component index maps. No replacement or speculative rebenchmark. |
| 3. Whole-output stop checks | Retained deliberate behavior: stop timing includes provisional UTF-8 replacement, and async output snapshots are bounded before publication. A rolling-tail rewrite needs a measured bottleneck and an equivalent text contract; it is not a demonstrated correctness defect. |
| 4. Repeated position resolution | Already implemented: the planned trace path resolves each prompt once, sharing positions between estimation and capture. The independent in-memory entry has its own single resolution. |
| 5. Metadata clamping at the FFI | Already replaced with checked conversion/rejection in `rebirth_intervene()`. |
| 6. Default selftest exports | Addressed by this candidate's explicit build feature and registration checks. |
| 7. R trace file responsibilities | Already separated into trace, spill, storage and related helpers. |
| 8. Repeated summary scans | Grouped summary already implemented; no new performance claim. |
| 9. Sampling allocation reuse | An optimization proposal, not an established defect. Retain deterministic sampling/reduction order until a profile justifies additional buffer state. |
| 10. Generation result literals | Completion branches now also distinguish bounded structured and streamed output. Keep explicit stop contracts; a configurable finish helper would obscure different ownership/publication paths. |
| 11. Prompt-piece ownership | Borrowed batches feed `run_capture`; row strings are intentionally owned by retained capture rows. Do not remove copies whose lifetime contract requires ownership. |
| 12. Low-level Rust exports | Linkage/system probes remain used by native integration tooling; the crate is private and `publish = false`. The current release-sensitive surface is R registration, reduced separately. |
| 13. Generic count validation | Ordinary counts already use `is_count()`. Seed has intentional distinct bounds and semantics. |
| 14. Byte formatting twins | Existing R and Rust sentinel tests pin matching units, boundaries and rounding. |

## Actual unresolved work

The Phase 7 `long_prefill` investigation isolated an attention precision-policy
mismatch with the independent oracle. Its comparison now explicitly declares
F32 cache/unfused attention, with separate default-context operator/write/zero
identity guards. Focused local checks pass; final CI remains pending. Earlier
cross-schedule limits are still separate, unaccepted observations. See
[the retained diagnosis and comparison scopes](maintenance-0.4.0-numerics.md).
No frozen reference, tolerance, production precision or consumed evaluation was
changed to produce a passing result.

One integrated review is complete; its workflow flag and release-link findings
were corrected and closed separately. [Local evidence](../tests/maintenance/0.4.0/local/owner.json)
preserves the initial sandbox-access failures and the exact 61-case resumption,
with no rebuild or repetition of passing cases. Local installed libraries retain
0.3.0 metadata and do not constitute final 0.4.0 release acceptance.

Final CI, release checks, publication and distribution
verification are pending. Windows/CUDA, CRAN submission and independent external-user feedback
remain subsequent scopes. Model quality and supported-site limitations are not
silently converted into maintenance success claims.
