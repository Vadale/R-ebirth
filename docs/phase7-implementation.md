# Phase 7 consolidation and maintainer acceptance

Date: 2026-10-11. Base is merged F6e `7bc688a2bfaf570db7498424a19854202185144c`.
This is a documentation/example increment under D-043 and D-047, with no relm
API, native runtime, dependency, numerical threshold or vendor changes.

## Delivered path

Both READMEs and the documentation index now lead to the same
[research walkthrough](../examples/research-workflow/README.md). The installation
guide checks actual development capabilities, avoiding reliance on a reused
version string. The [support matrix](supported-workflow.md) separates static
projection, additive live updates, model sites, optional tools and interpretation
limits. The [maintenance inventory](phase7-maintenance.md) records concrete
consolidation and measured existing CI cost without claiming a speedup.

The repository script defines functions without inference on `source()`. It
refuses absent/wrong models, incompatible installed capabilities, unavailable
async dependencies and existing output paths before creating results. It uses
one cached original model, one derived handle at a time, two actual construction
pairs, fixed conditions, bounded generations and existing result classes.
Outputs include all texts, first-state observations, timelines, directions,
CSV/RDS, provenance and three graphics. No package export or framework is added.

## Actual maintainer verification

[Retained receipts and outputs](../tests/research-workflow/evidence/2026-10-11/)
bind source SHA256 `829c7f5d4880449c83075937199360e1782c7a9c130d791e35744d98e1cef0f4`.
One isolated R 4.5.1 execution took 8.492 seconds including startup and model
checksum. It loaded cached Qwen2.5-0.5B Q8_0 once on requested CPU, made four
ordinary trace calls and eight successful async generation calls (32-token cap).
Six derived handles were closed sequentially, then the original was closed.
Constructor probes are separate from the eight ordinary generation calls.

The existing installed Phase6 R-state build was used, with DLL SHA256
`452eb8eb3b4e5257dffa772c26732dd8352c9db9bb0a6dea6a3637c7a66866f8`.
This is **not a fresh installation**, a clean-machine test or an assertion that
its R source is byte-identical to the final Phase6 tree. No package was installed
or native code rebuilt. Source/package compatibility remains covered by the
required final matrix. Native device logging was not instrumented in this
walkthrough: requested CPU and handle metadata are not fresh offload proof.

Saved-data inspection, with no model/RNG/plot replay, verified:

- Four captures, 7,168 values; two 896-coordinate directions independently
  recomputed from paired means (maximum differences `4.17e-17` and `8.33e-17`).
- All eight CSV texts/counts agree with their saved R objects. Original and zero
  projection match exactly for both text and sampled IDs on both prompts.
- Two comparisons, 1,792 coordinates: reference/intervention columns match the
  actual saved first states; every difference equals intervention minus reference.
- All exported-file hashes match. All three PNGs were visually inspected:
  titles, axes, site labels and caveats are readable and unclipped.

The practice outputs had 22 sampled states each. All four evaluation outputs
reached 32 states and show unfinished continuations. The result demonstrates
execution/export, **not efficacy or complete-answer brevity**. Sampling counts
are not silently treated as committed token counts. No warning/error was printed
in this R execution; the previously diagnosed pinned-model tokenizer behavior
and its stopping caveat remain applicable. This log is not an independent native
warning audit.

Changed documentation links were checked (114 local targets resolved). The R
workflow parsed with one new guarded step and the same four-job matrix; the
local YAML parser emitted two coercion warnings for existing `working-directory: .`
scalars. Those unchanged entries are not part of this edit.

Seven model-free preflight refusal cases passed before execution, preserving an
existing sentinel and creating no result directory; six prompt IDs/texts and
split roles were checked. The same small regression is now part of the existing
R jobs, with no new CI job or model download. It does not pretend to cover every
possible runtime failure. No old phase acceptance or consumed efficacy study
was manually rerun.

## Closure status

Maintainer functional acceptance is passed. Under the founder-approved D-047,
independent external-user feedback is deferred until after publication; the
[feedback procedure](phase7-user-feedback.md) is ready and no external study is
claimed. One integrated independent review found one P2 onboarding issue: the guide
used `~/models` after recommending a downloader with a different cache location.
The guide now carries the returned `model_path` into the call; the same reviewer
closed that finding by inspecting only the affected lines. Original review and
closure are retained with the evidence. The executed script/output bytes did
not change and no inference was replayed. The final PR matrix is pending;
Phase 7 is not yet declared integrated.


## First PR64 CI: inherited long-prefill numerical failure

The first candidate `7501d6c` failed the Rust engine job in run `38148048115`:
170 tests passed, two failed and four explicit diagnostic/feasibility tests were
ignored. All four R jobs and the other four Rust/integrity jobs passed (8/9);
the matrix as a whole remains failed. Both failures reach the same frozen `long_prefill` activation at source
position 512, layer 2, residual neuron 13: native `-0.02155396342277527` versus
reference `-0.010776706505566835`, absolute error `0.010777256917208433` above the
unchanged `0.01` bound. This is an internal activation, not the previously
recorded final-logit cross-schedule outliers. Its cause is unresolved. The
Phase7 candidate did not change the native runtime, this test or the references.

[Original failure, job metadata and automatic short-policy diagnostic](../tests/research-workflow/evidence/ci-7501d6c/)
are retained. The two short pruning-case receipts passed their independent
comparisons before the long case failed. The automatic short-policy diagnostic
cannot explain the missing long-prompt activation data. Release/no-spill stages
were skipped after failure and are not accepted executions in this run.

The affected test now emits the long case's already-computed logits, audit rows
and row witnesses before scalar checks can abort. Removing those output blocks
reconstructs the previous test byte-for-byte: no new inference, assertion,
schedule, reference or tolerance change. On failure, CI retains CPU information
and actual CMake caches. It no longer reruns the unrelated short-policy model
diagnostic automatically after any engine-test failure. This is a bounded data
retention change, **not a numerical fix or completed acceptance**. New retained
observations must establish the cause before a correction can be claimed.

The diagnostic-only source passes local format and clippy with warnings denied;
no local native test, model or reference producer was executed for this change.
