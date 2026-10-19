# CRAN request and submission procedure

Status: direct form submission authorized on 2026-10-19; **nothing sent or uploaded**.
The wrapper follow-up and its new non-shared-R check must finish before a final
candidate is described as verified. PR72's eleven successful checks are parent
evidence; no relm admission decision or Rust exception exists.

## Founder decision

Skip the preliminary email. Submit through the official form after the final
candidate passes its technical checks, disclose the Rust/Cargo requirement and
unmet age guidance, and address any requested changes. This is permission to
request consideration, not an exception granted by CRAN.

The founder also authorizes the agent to merge PR73 when **all twelve current
checks pass** and their required routes/results are verified. Any failed check
must be corrected first. No further merge confirmation is needed. This does not
authorize a separate GitHub release or omission of required checks.

## Actual package submission

1. Complete the current packaging matrix, including the non-shared-R installation,
   and merge the exact accepted head. Keep the tested dependency graph and report
   Cargo/rustc >= 1.85.0, CMake >= 3.28 and the unmet two-year Cargo-age guidance
   openly in the submission comments. Do not claim farm compatibility or approval.
2. Build one `relm_0.5.0.tar.gz` with current R release/patched, retain its SHA256
   and run `R CMD check --as-cran` on that same archive with current R-devel.
   Include example/vignette/manual results, exact licenses and explained notes.
3. Upload the same source archive to win-builder's R-devel form as a submission check.
   Results go to the maintainer address in DESCRIPTION. Record the input digest
   and returned logs; this checks portability but does not submit to CRAN.
4. Complete `cran-comments.md` for that exact archive and review all warnings or
   significant notes. `New submission` is expected for a new package; it does
   not grant an exception to other requirements.
5. Use the authorized official CRAN submission form, choose the source
   archive and provide the requested maintainer/details/comments. The maintainer
   must accept the confirmation email. Confirm access to the DESCRIPTION email
   before upload; no credentials or confirmation links belong in the repository.
6. Follow the CRAN response. If changes are requested, preserve the original
   result, fix the affected causes, check the revised archive and explain the
   corrections on resubmission. Do not send duplicate submissions while one is
   pending or publish a CRAN-accepted claim before acceptance.

GitHub merge, a GitHub/r-universe release, win-builder testing and CRAN admission
are distinct events. No Windows GPU hardware or VM is required for the CPU
submission path. WP16 API documentation and the project's 30-day green-CI window
before v1.0 remain separate obligations.

## Acceptance assessment

There is no defensible package-specific acceptance percentage in our evidence.
The cross-platform checks, offline sources, explicit limits and license inventory
support proceeding with preparation. Rust/Cargo age and actual farm tools are
material open questions; the new installation route also needs its own results.
Passing GitHub checks cannot settle CRAN's human review. If tool requirements are
accepted and final checks pass, proceeding to submission is reasonable, with
possible requests for changes. If the requirements are refused, an older verified
dependency graph or waiting are alternatives; neither is already approved or done.

## Official references (checked 2026-10-19)

- [CRAN Rust guidance](https://cran.r-project.org/web/packages/using_rust.html)
- [CRAN policies and submission rules](https://cran.r-project.org/web/packages/policies.html)
- [Submission checklist](https://cran.r-project.org/web/packages/submission_checklist.html)
- [Submission form](https://cran.r-project.org/submit.html)
- [win-builder instructions](https://win-builder.r-project.org/)
- [win-builder upload](https://win-builder.r-project.org/upload.aspx)
- [Rust 1.85 release date](https://blog.rust-lang.org/2025/02/20/Rust-1.85.0/)
