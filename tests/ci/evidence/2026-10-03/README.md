# Local CI refinement receipts — 2026-10-03

These are local test-runner/routing validation receipts, not fresh model or
numerical acceptance. See `docs/ci-efficiency-implementation.md` for complete
scope. `verify-local.R` preserves the actual task-local script/library paths;
it is an execution receipt, not a portable CI entrypoint. The installed native
library predates this test/workflow-only change. The compressed log retains
all explicit model skips and the testthat patch-version warning.

The source manifest pins the reviewed workflow/routing/test inputs. The
relocated test expressions were compared to main daee903, independently of
models. Python routing tests (15) and workflow parsing/guards were additionally
verified by the delegated implementer; those are reported checks, without a
fabricated raw process log here. Their committed runner executes in ordinary CI.
