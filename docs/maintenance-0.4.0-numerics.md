# Numerical debt investigation for 0.4.0

Status: the CPU long-prefix oracle comparison now declares its precision
contract. The focused Mac correction passed; final Linux CI is pending. Default
inference precision, comparison bounds and frozen reference bytes are unchanged.

## Retained Linux failure

Candidate `27ea3c5`, GitHub run 38155585020, reproduces the Phase 7 failure on
an AMD EPYC 9V74. The engine result is 170 passed, 2 failed and 5 ignored;
release-profile and no-spill stages did not run. The same two tests stop at
public position 512, layer 2, residual neuron 13: native -0.02155396342277527,
reference -0.010776706505566835, absolute error 0.010777256917208433 > 0.01.

The new retained first-prefix diagnostic collected seven runs without changing
the operator or its bounds. The default 512-token decode, its exact replay and
four 128-token calls have identical final logits. Disabling observation produces
the same logits; zero projection agrees exactly with the ordinary context.
All 1,280 comparisons of the projection applied to its actual input rows have
zero error, and every expected site/position has one write witness.

At the failing coordinate the three residual addends have signed errors
-0.0019116699695587158, -0.00237216055393219 and -0.006493426393717527.
The native F32 addition is bitwise correct. Those input errors accumulate into
the failed residual comparison. Across all retained rows, the maximum absolute
activation error is 0.014189586043357849. Token-at-a-time execution lowers that
maximum to 0.0051439255475997925 but does not prove batching invariance.

These results exclude a missing site write or an observation-induced change in
the tested runs. They do not identify a kernel defect, establish harmlessness,
or justify changing an acceptance tolerance.

## Controlled precision contrast

The independent producer uses F64 attention and cached K/V. The native default
uses F16 K/V and automatic fused attention. The pinned graph source also casts
F32 K/V to F16 when taking its fused-attention branch. These are concrete
precision differences that must be isolated before attributing the discrepancy.

One new ignored test rebuilds only its idle test context under three explicit
configurations: F16 cache with fused attention disabled, F32 cache with it
disabled, and F32 cache with automatic selection. It preserves model weights,
projection plan, prefix, batch sizes, frozen reference and comparison bounds.
Its helper is compiled only under `cfg(test)`; production policy is unchanged.
The seven earlier runs are not repeated.

The same three configurations were executed once on Mac and once on Linux.
Actual context logs confirm the K/V types and attention settings:

| Configuration | Mac maximum activation error | Linux maximum activation error |
| --- | ---: | ---: |
| F16 cache, fused attention disabled | 0.003360047936439514 | 0.00323273241519928 |
| F32 cache, fused attention disabled | 0.000001225154846906662 | 0.00000116066075861454 |
| F32 cache, fused attention automatic | 0.002391672693192959 | 0.014189586043357849 |

Linux run38156888528 used an Intel Xeon6973P-C; the first-prefix experiment used
an AMD EPYC9V74. The Linux automatic-attention result reproduces the earlier
maximum error despite the requested F32 cache. In the pinned graph, automatic
fused attention casts F32 K/V to F16. Disabling it while retaining F16 cache
reduces the error; using F32 cache with it disabled reduces the error further.
All768 same-input projection comparisons per machine are exact. Independent
inspection also checked all4,224 Linux retained reference coordinates and signed
errors against the frozen CSVs.

This controlled contrast localizes the observed discrepancy to the attention
precision/execution choice, rather than a missing projection write or residual
addition. It does not prove a particular fused kernel defect or make the default
path agree with a higher-precision mathematical oracle.

## Corrected comparison contract

For the CPU `long_prefill` case only, the independent whole-forward comparison
now explicitly uses F32 K/V with fused attention disabled, approximating the
oracle's F64 attention without an intermediate F16 cache or fused conversion.
The original0.01 absolute bound and2e-6 same-input bound are unchanged. Other
cases and the Metal path retain their existing configurations. The context
helper is test-only; production defaults, outputs, memory and performance policy
are unchanged.

Before changing that test context, each affected test executes a separate
default-precision514-token guard: all66 retained rows are finite, every one of
1,028 site/position writes occurs exactly once, and384 projection coordinates
match their actual input-row equation. The existing default original/zero
comparisons remain bitwise exact across six output-policy cases and576 values.
These default-context checks make no whole-forward F64 accuracy claim.

The two focused Mac tests passed15 cases/34,748 oracle comparisons and3 cases/
10,042 comparisons. Their additional default-context guards each passed384
coordinates with zero scaled error. Format/clippy passed without compiler
warnings. Final cross-platform execution remains pending. Original failing CI
jobs remain failed; a correction pass does not relabel their results.

The earlier F6e cross-schedule0.0115248 outliers remain outside their0.01
acceptance scope. The new precision-aligned result neither retroactively accepts
those default-precision runs nor proves batching invariance or model quality.

Raw failures, observations and source hashes are retained under
`tests/maintenance/0.4.0/ci-27ea3c5`, `precision`, `ci-c6b831e` and `precision-fix`.
Both temporary diagnostic invocations have been removed from CI. Reporting uses
retained observations; no diagnostic or consumed evaluation is replayed.
