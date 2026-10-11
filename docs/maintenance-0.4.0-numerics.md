# Numerical debt investigation for 0.4.0

Status: diagnosis in progress. The existing bounds and frozen reference bytes
are unchanged; none of the following observations is a new accuracy acceptance.

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

The first Mac CPU execution passed all three diagnostic paths. Maximum retained
activation errors are respectively 0.003360047936439514,
0.000001225154846906662 and0.002391672693192959; actual context logs record cache
types and attention requests. This supports a precision contribution on that
machine, not a diagnosis of the Linux failure. The corresponding Linux execution
is pending. No production correction or revised acceptance is claimed yet.

Raw failures, observations and source hashes are retained under
`tests/maintenance/0.4.0/ci-27ea3c5` and `tests/maintenance/0.4.0/precision`.
The temporary CI invocation will be removed once its result is retained.
