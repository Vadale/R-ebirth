# F6e review correction closure

**Passed: both P2 findings are closed.** This is the authorized same-reviewer correction closure of the single integrated review at `e2081b43ebc7108c7bdc7b96fc2203b679d222a7`, limited to those findings. It is not a second implementation review.

Inspected published HEAD: `1a9ec091f43c6d869f9184f95af2ce3a89bbb850`. No product or test files were modified, and no tests, builds, models, reference generators or remote jobs were executed. The new instrumented evidence directory was already present as untracked parent-owned evidence; a clean worktree is not claimed.

## Closed findings

1. **Zero projection plus live capture — closed.** `rebirth/src/rust/rebirth-llm/src/projection.rs:336` now returns before row access when the selected coefficient is zero and no private probe/audit requires observation. Classification, occurrence/ready bookkeeping and row-count validation precede the bypass. The shared dispatcher still proceeds to live capture. The focused test pins untouched NaN-pattern scratch storage, zero projection rows/read bytes/write bytes/barriers, exact capture/logit/token identity, private-audit reads, malformed capture refusal and graph-reuse rejection without delivery. The two-state native regression passed8 cases/2 refusals/224 identity values, locally and in the exact-head Linux evidence. This is identity evidence, not a new independent numerical oracle.

2. **Historical registry capacity growth — closed.** `rebirth/src/rust/rebirth-ffi/src/projection_transfer_boundary.rs:81` sizes the replacement to live weak entries plus the candidate. Existing admission/source/duplicate checks remain before allocation and final assignment; the prior old-capacity-plus-one ledger remains a conservative upper bound. The focused model-free source verifies64 sequential registration/releases at capacity2, eight simultaneous candidates up to nine entries, five atomic refusals preserving the old allocation and entries, and compaction back to2. Its recorded result is78 cases/5 refusals. Actual installed R evidence separately covers11 GC calls, four open candidates finalized by GC, three simultaneously derived owners,13 recorded profiles, compaction and survival of the original handle. These distinguish Rc controls from actual R finalization.

## Source and evidence binding

The two corrected runtime files match the local, fresh-installed and Linux source manifests exactly:

| Source | SHA-256 |
| --- | --- |
| `projection.rs` | `44b77be2e93e0770c3b51343bd9bb62c78b595fd29cf02e978a8fc9271e48be0` |
| `projection_transfer_boundary.rs` | `8acb17b70db5a60c232e01ae189dc565321b68b70a33c9b6d68d1d2dc61e64c1` |

The unchanged admission helper and shared capture dispatcher also match all three manifests. The registry regression matches all three. The current zero/live test hashes to `c73bdbc206d897c4d868b9e7eb8c3f748cf904012125655eea3f06769fba8fb2`. Inlining only its provenance helper reconstructs exactly `3b7e80cbaac257d132f2c901e3895b67a64c5ede18ece8cd951e671242982f55`, the source bound by the earlier local/installed evidence. Runtime, test assertions and unconditional execution are unchanged by that extraction. These are source-file hashes, not commit IDs.

- Local `review-fix-counter-20261008-150046`: owner receipt and native markers retain86 cases/7 refusals/224 identity values; the compiled profile remains pinned. No actual R GC is claimed by that local native receipt.
- Fresh installed `installed-review-resume-20261008-151830`: ten named cases,1,792 coordinate pairs and13 registry profiles. The parent independently verified bitwise RDS identity and actual profiles; this closure additionally read the frozen harness, checked receipt/source hashes and directly checked all1,792 unique finite CSV pairs for equality. Eleven GC calls and four GC-finalized open candidates are recorded. DLL binding remains `e3182fb2260256afb95d15a6c7019b6285a251ff6a045fe7150b07a872e9f07d`.
- Linux run `37784612697`, exact HEAD above: ASan/UBSan8 cases/2 refusals/224 identity values; separate Memcheck18 cases/4 refusals/227 values. This closure read the actual libtest captured markers and both finished Memcheck XML records (zero errors and zero suppressions), verified their archived hashes and the12-entry remote archive manifest. The archive manifest SHA-256 is `6433bf9dede74ba863e047d0641431918db4859b1a1f4b4333e1546eb3a609dd`; scope SHA-256 is `4fc29cbff9883bafa8be57004cd7048e199450c690cce0bd9358a6f84dbf2c5d`. The parent independently verified270 native objects, Rust production/arrow_array/std instrumentation, runtime fault controls and literal `%3A`/`%p` filename controls. This closure binds that receipt rather than claiming to rerun those audits.

Full inspected source/receipt hashes and precise read-only checks are recorded in `review-closure.json`.

## Retained limits

The Linux affected tests are default-feature CPU unit fixtures; the production integration binary was built but not executed in that affected run. Linux evidence does not execute the R/SEXP/FFI registry or GPU. The separately bound installed gate supplies actual R GC coverage. No additional platform, performance, RSS, independent-golden or efficacy acceptance follows.

The warning addendum is retained:17 ASan and10 Memcheck compiler diagnostics come from pinned external dependencies/standard library and match the parent run. There are zero own-package compiler warnings/errors; the whole build is not described as warning-free. The installed pinned-tokenizer warning remains explicit.

Both grouped cross-schedule accuracy outliers remain unaccepted (maximum0.0115248 exceeds the frozen downstream0.01 bound). No tolerance changes, retuning or reinterpretation of those results occurs here. All earlier acceptance/failure scopes remain intact.

The reviewer authored the independent projection references and efficacy verifier. This closure does not claim an independent authorship review of those artifacts; the parent separately validated actual outputs. The product corrections and focused controls inspected here were not authored by this reviewer.

No remaining correction is requested for either original P2 finding. This concludes their closure without opening another review loop.
