# Phase 7: one supported research workflow

Date: 2026-10-11. Authorized by the founder's instruction to start Phase 7.
Base: merged F6e `7bc688a2bfaf570db7498424a19854202185144c`.
Scope decision: D-043. This is not the historical WP14 compiler programme.

## Definition of done (verbatim roadmap exit)

> runnable primary path; reviewed maintainability inventory and targeted
> changes; relevant regressions/compatibility checks passing; external workflow
> completed with honest assistance/failure records; supported capability matrix
> and remaining debt published. No specific percentage of code/test deletion is
> required and no maintenance-time reduction is claimed without measurement.

D-047 explicitly amends the quoted external-participant requirement: maintainer
functional acceptance now closes the phase, with independent user feedback
deferred until after publication. The historical wording above is retained.

## Closed implementation scope

1. One repository example and guide for load → observe → compare → intervene →
   evaluate → export, using existing public APIs and a cached pinned Qwen model.
   The example records real captures, settings, model identity, conditions,
   outputs and plots. It is a small exploratory usability exercise, not another
   efficacy experiment or a rerun of the consumed F6d/F6e holdouts.
2. Consolidate navigation and capability checks in the root/package README,
   installation guide and documentation index. Correct stale claims that live
   observation/steering are future work. Publish a compact capability matrix.
3. Record a maintenance disposition and measured coverage/cost inventory from
   retained final F6e CI receipts. Keep distinct platform, numerical, resource,
   ownership and lifecycle gates. Remove only demonstrated duplication; do not
   invent a speedup or start a CI framework or native refactor.
4. Execute the complete workflow as maintainer and prepare a short optional
   post-publication user-feedback procedure. D-047, approved after the initial
   plan, defers external participation and removes it as a phase-completion gate.
   Maintainer evidence will not be labelled external-user acceptance.

No public export, dependency, native runtime, vendor, artifact schema, numerical
bound, release or platform change is planned. Any newly discovered runtime defect
gets a separate concrete diagnosis before expanding this scope.

## Verification order and stop rule

- Validate example preflight/refusal behavior without loading a model.
- Run the new walkthrough once on the cached model in a separate process, with
  explicit installed-package provenance; inspect saved outputs and figures.
- Check changed links, package-facing instructions and capability statements.
- One integrated review of this coherent deliverable, followed only by affected
  correction checks. One final PR matrix; no manual replay of old acceptance.
- Under D-047, maintainer functional validation is the current gate. External
  usability feedback is deferred until after publication, not reported as passed.

The initial 40–80k-token estimate was a planning range, not measured consumption
or authorization to expand scope. Reassess before new work beyond these four
items. Keep long operations in the background and reuse the existing quiet
monitor only when an operation needs later completion handling.
