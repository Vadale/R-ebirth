# F6c integrated review and targeted closure

Date: 2026-10-07. Reviewer: independent Codex review agent.
Branch: `codex/f6c-graphics`. Local base at both review stages:
`e3e66b55f9b33c0ef167a348aaf5d0815a24e5b8`.

## Scope and method

This is the one integrated independent review required by
`.claude/skills/new-wp/SKILL.md`, followed by targeted closure of its four
findings. D-044/API approval was already resolved and was not reopened.

The initial review covered the uncommitted R-only implementation in
`rebirth/R/graphics-helpers.R`, `graphics-compare.R`, `graphics-timeline.R` and
`graphics-plots.R`, the new `helper-graphics.R` and five `test-graphics-*.R`
files, the approved graphics contract, allocation ledger, API-GRAMMAR section
12 and hand-calculated `tests/graphics/reference/paired.csv`. The four product
source snapshots alongside this report preserve the initially reviewed source.

The reviewer checked correctness, API and plot semantics, full generated-prefix
alignment, worker-applied audit transitions, malformed-input classed failures,
Arrow conversion bounds and native-owner retention. Relevant existing live
state, spill integrity and context-exhaustion source was read to resolve specific
questions. The curated graph excludes R/docs and was not used as evidence for
these files. No source, fixture, native or golden file was changed by the reviewer.

The initial review used tiny model-free R diagnostic snippets with the existing
F6b namespace and sourced F6c overlay. It did not run models, builds, a broad
suite or previous F6a/F6b acceptance. The owner's passing source-suite receipt
was `/private/tmp/relm-f6c/source-attempt-4.log`; this was not installed-package
acceptance. Closure was limited to reading the four corrections, their targeted
regressions and the owner's new source-suite receipt. The reviewer did not
rerun tests at closure. This report is the reviewer's only repository write.

## Original review

**Verdict: request-changes.** Four concrete findings:

1. **[P2] Valid context-exhaustion states are rejected** —
   `rebirth/R/graphics-helpers.R:140` requires
   `context_length >= context_pos`. F6a emits the final sampled state before
   checking exhaustion, so `source_pos == context_length` and
   `context_pos == context_length + 1` are valid. Validate against the consumed
   `source_pos`; add a model-free boundary regression.
2. **[P2] Ragged frames bypass structural validation** —
   `rebirth/R/graphics-helpers.R:41–46` checks column types but not lengths.
   Diagnostic snippets produced raw `simpleError` for zero-length `elapsed`
   and two-element `token_id`; a steering frame declaring one row with two
   intervention IDs was accepted and returned a corrupt timeline. Check every
   column's length against the validated row count before scalar/vector
   operations, and reject with `relm_error_trace`.
3. **[P2] Truncation invents a later steering-change marker** —
   `rebirth/R/graphics-plots.R:172–173` treats the first retained positive
   revision as a new change. Reproduced: a change applied after state 1,
   followed by a two-state window through state 4, retains states 3–4 but draws
   its change at state 3 instead of state 2. Derive marker positions from
   `applied_after_state + 1`; omit markers outside the retained range while
   preserving their audit annotation.
4. **[P2] Leading and trailing omitted blocks are unlabelled** —
   `rebirth/R/graphics-plots.R:89–90` labels only gaps between selected layers.
   Selecting layers 5–6 of a 24-layer model shows no indication that 1–4 and
   7–24 were omitted, contrary to the approved map contract. Render both
   boundary gaps.

No native-owner retention issue was found in constructor results. Complete
generated-prefix alignment and missing top-k handling were implemented
correctly. The reported source-suite pass remained source-only evidence.
The most important fix was structural frame validation: malformed inputs
escaped classed failures and could produce an invalid result.

## Targeted closure

All four original findings are **closed for the source identified below**.
This is a targeted correction check, not another integrated review or a claim
that the remaining feature acceptance has completed.

| Finding | Verified correction | Targeted regression inspected |
| --- | --- | --- |
| 1 | Context admission uses the consumed `step$source_pos`, admitting a final sampled position one beyond the context and still rejecting an out-of-range consumed position. | `the last sampled state can exceed consumed context by one` in `test-graphics-compare.R` |
| 2 | `graphics_frame()` obtains a finite, whole, nonnegative row count with `.row_names_info()` and requires every column length to equal it before value operations. | `ragged step, logits and steering frames fail with classed conditions` in `test-graphics-compare.R` covers empty/long elapsed, long token IDs, short logits and ragged steering. |
| 3 | `graphics_change_states()` derives positions from `applied_after_state + 1` and retains only positions inside the visible state range; the plot uses these positions while preserving the last-change audit annotation. | `truncation preserves change timing without inventing a visible event` in `test-graphics-plots.R` checks no marker for the dropped state-2 change and a marker for a new state-5 change. |
| 4 | The map treats zero as the predecessor of its first selected layer and separately labels the omitted range after the last selected layer. | `a middle block selection labels both omitted boundary ranges` in `test-graphics-plots.R` captures actual graphics text calls for `1-4` and `7-24`. |

The closely related history-coordinate correction was also inspected:
`anyNA(current)` precedes scalar comparisons in the timeline validator, and
`corrupt missing history coordinates produce a classed failure` tests each step
column. No wider history or graphics review was performed at closure.

The owner-run `/private/tmp/relm-f6c/source-attempt-6.log` reports completion of
all five focused graphics source test files without failure. It retains the
warning that `testthat` was built under R 4.5.2. The owner reported that attempt
5 failed a raw PDF-text assertion because PDF kerning split the text; attempt 6
uses direct graphics text capture. That fixture correction verifies emitted
labels and does not establish visual legibility or clipping acceptance.

**Closure verdict: approve the four targeted corrections.** No original review
finding remains open at this source scope. Installed-package, cached-model,
visual and RStudio acceptance remain separate owner-run gates; neither the
initial source overlay nor this closure substitutes for them.

## Exact source scope

SHA-256 of the original product snapshots in this directory:

| Snapshot | SHA-256 |
| --- | --- |
| `graphics-helpers.R` | `6200ab2ec52253c57088102a5d7ed8cf59c46fd26421a04c5084821d6ec4d703` |
| `graphics-compare.R` | `7f38536772576e7cd8c78c78e5863c6aa44b7f86b4b2a577eb95551b75fe8faf` |
| `graphics-timeline.R` | `61997af497eb81e0ea31e1cc689b946a740b37b8db7d3aa18447f45f31069103` |
| `graphics-plots.R` | `618017c06d9d1c39b81a4ca23a886bee4bd50dda340f35f0ca7e7eb662b2c557` |

SHA-256 of product source, targeted regression files and receipt read at closure:

| File | SHA-256 |
| --- | --- |
| `rebirth/R/graphics-helpers.R` | `679b804cca76eeed386365401e79389e2a9bc50717e874508aa3fe7b4d7af8e8` |
| `rebirth/R/graphics-compare.R` (unchanged) | `7f38536772576e7cd8c78c78e5863c6aa44b7f86b4b2a577eb95551b75fe8faf` |
| `rebirth/R/graphics-timeline.R` | `c4a57ec358e3d12a274dad25eaaba167f74f7eca45cc56c68ec624438ee5f1cd` |
| `rebirth/R/graphics-plots.R` | `c2bfc41bc7c3e9e0e2f189b2aa69f7c46a54b4d7026c54a12e85e5c6c7c594cb` |
| `rebirth/tests/testthat/test-graphics-compare.R` | `1ae8d6a13121843bda5782b51971213a4cc19d26cacd33d155858543635e95e2` |
| `rebirth/tests/testthat/test-graphics-plots.R` | `391ff85ac1c6a747bd44dd00ce86283fa7363cec7abe75a12d0e33c83cdb0ee9` |
| `rebirth/tests/testthat/test-graphics-timeline.R` | `2c02c5e47ac7f9cee9e55e4e90c48d1f7d1d03f96bf76002f7e256cfa148f6e3` |
| `/private/tmp/relm-f6c/source-attempt-6.log` | `da69ce84676c7af08ebd299f795e1cf3eafd906e7dd81d477bd9908a981c3539` |

## Focused integration addendum: managed live-spill filename

Date: 2026-10-07. This addendum addresses one new material integration failure
reported after the four-finding closure. It is not a repeated broad review.
The four original findings remain closed at their stated source scope.

**New finding: managed live spill is rejected before the first state.** The
owner's attempt at `/private/tmp/relm-f6c/package-20261007-133713` passed its
installation and installed-tests stages but failed model composition. The
reviewer read its status, failure log, saved R source and `run-spill.rds` error.
The receipt contains `relm_error_trace`: "Could not create a new file in the
leased spill directory." Existing successful F6a spill evidence used
caller-managed directories, according to the owner; it did not cover this
managed route. This newly observed failure remains preserved.

The exact mismatch is source-confirmed:

- `rebirth/src/rust/rebirth-llm/native/spill_lease.cpp:153` admits only a
  path-safe leaf starting with `trace-` and ending with `.arrow`, subject to
  the existing lease identity and exclusive-open checks.
- `rebirth/src/rust/rebirth-llm/src/live_spill.rs:152–155` appends
  `-<state_id>.arrow` to `request.trace_id`; it does not add `trace-` itself.
- The failed attempt's `live_prepare()` supplied the path-safe nonce without
  that prefix, so its managed filename could not pass lease admission.

**Correction inspected:** `rebirth/R/live-state.R:305` now constructs
`paste0("trace-", gsub(".", "-", next_trace_id(), fixed = TRUE))`. The
original nonce and native per-state suffix remain intact, preserving uniqueness
and the metadata/file identity relationship. The extra ASCII prefix is accepted
by the existing native nonce validator. Caller-managed filenames also acquire
the prefix, which is compatible with their existing exclusive-create path.
The three relevant native source files have no working-tree diff; no lease
admission, suffix, native writer or native allocation formula was changed.

The ledger and suffix compatibility were checked in source:

- Prefixing occurs before UTF-8 normalization, `async_validate_inputs()`,
  `live_fixed_bytes()` and native preflight. Those paths therefore measure the
  prefixed metadata rather than an obsolete shorter string.
- Native request storage counts the actual `trace_id` capacity. The native
  path/report reserve includes its actual length, separator, maximum four-digit
  state suffix and `.arrow`; the Arrow schema estimate builds the maximum
  suffixed nonce from the same request.
- The existing R fixed-object prototype additionally prepends `trace-` when
  constructing its maximum path. With the correction this prototype is six
  bytes longer than the real path, which is conservative; it does not omit the
  new prefix or require weakening a bound. Its trace-ID prototype uses the
  actual prefixed ID plus `-1024`.

The new `live spill preparation supplies the managed lease filename prefix`
regression in `rebirth/tests/testthat/test-graphics-spill.R` was inspected only.
It captures the actual `live_prepare()` configuration for default and custom
directory selection, checks the expected filename prefix/suffix, a populated
fixed-byte estimate and distinct per-call IDs. It mocks the managed directory
provider and stops before native preflight, so it does not exercise an actual
lease or prove successful spilling. No tests, builds or model runs were executed
by this reviewer for the addendum; reading the saved RDS was diagnostic receipt
inspection only.

**Addendum verdict: the narrow source correction is supported; runtime closure
is pending the owner's actual managed-spill composition test.** Do not label
the managed-spill failure fully fixed based on this review or the mocked
regression. The status receipt records reuse of the accepted F6b DLL with SHA-256
`6edc6e6d512bb16e9d5ad8ed22093291e61a81bb89e5c2d07bee134db6ff04ac`;
this addendum makes no renewed native-acceptance claim.

The local base remains `e3e66b55f9b33c0ef167a348aaf5d0815a24e5b8`.
Exact addendum source and failure-receipt SHA-256 values:

| File | SHA-256 |
| --- | --- |
| Corrected `rebirth/R/live-state.R` | `de134b7a008f104bc22d68051407b565604c4a32e7559ff4c96efe897d356e64` |
| `rebirth/tests/testthat/test-graphics-spill.R` | `abd3e2850695b8a2fd81061a0d2f52bfb5dd69efa710a6dfdbcb71a3b6db7b18` |
| Unchanged `rebirth/src/rust/rebirth-llm/native/spill_lease.cpp` | `fc95db27e3069e5c7f28386bb05ee945c56e1ab48bcb192c4a6c280bb476285e` |
| Unchanged `rebirth/src/rust/rebirth-llm/src/live_spill.rs` | `6bbcc41f79a5ad947068c342a0be0a1a93d489042e7f7ff6ec661945f8b7cc0b` |
| Unchanged `rebirth/src/rust/rebirth-llm/src/live_state.rs` | `07ecab01a3fbeefb77498ae55aecb370c6d6d463eb2a0a08ed870a58c09a9126` |
| Failed attempt `r-install-source/R/live-state.R` | `bb067ec41fa883fe313faa35d88d948aa8211f709a8a453c26d375df17a271a1` |
| Failed attempt `model-composition.log` | `f8c0eb7fd58061a4e550eb93e374b1412ea1cd28dcb066b6301395b332322c1b` |
| Failed attempt `run-spill.rds` | `b47ef01ef053374fb8284f6b517876550efba3299755fc5325fdcc2ac26bd284` |

The final three paths are relative to
`/private/tmp/relm-f6c/package-20261007-133713`.
