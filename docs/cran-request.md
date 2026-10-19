# CRAN request and submission procedure

Status: preparation authorized on 2026-10-19; **nothing sent or uploaded**.
The wrapper follow-up and its new non-shared-R check must finish before a final
candidate is described as verified. PR72's eleven successful checks are parent
evidence; no relm admission decision or Rust exception exists.

## Preliminary compiler inquiry — draft for maintainer approval

To: CRAN-submissions@R-project.org

Subject: Compiler requirements for a first submission of relm

Dear CRAN maintainers,

I am preparing the first submission of relm, an R package for local language-model
inference, activation capture and controlled interventions. It is currently
distributed through r-universe.

The package requires Cargo and rustc >= 1.85.0 and CMake >= 3.28. Its locked
Arrow 59 dependencies use Rust 2024 edition. We have verified a complete source
installation with Cargo/rustc 1.85.0, as well as Windows, Linux and macOS checks.
Rust sources and license notices are bundled; installation is offline, uses two
build jobs and does not install tools or download models. CUDA is optional and
disabled for ordinary CRAN builds.

I understand that your Rust guidance asks for testing with Cargo at least two
years old. Version 1.85.0 was released on 20 February 2025 and does not yet meet
that age. Before submitting, could you advise whether these tool requirements
are supportable on the check farm and acceptable for consideration, or whether
we should first target an older Rust dependency graph?

Repository: https://github.com/Vadale/R-ebirth
Package: https://vadale.r-universe.dev/relm

Thank you,
Alessandro Vadala

This is a requirements inquiry, not a package submission or a request to bypass
checks. Do not attach a binary or send the package by email. Update its evidence
wording if the final candidate or requirements change before the founder sends it.

## Actual package submission

1. Close or obtain an explicit disposition of the compiler requirements. Complete
   the current packaging matrix, including the non-shared-R installation.
2. Build one `relm_0.5.0.tar.gz` with current R release/patched, retain its SHA256
   and run `R CMD check --as-cran` on that same archive with current R-devel.
   Include example/vignette/manual results, exact licenses and explained notes.
3. With approval, upload the same source archive to win-builder's R-devel form.
   Results go to the maintainer address in DESCRIPTION. Record the input digest
   and returned logs; this checks portability but does not submit to CRAN.
4. Complete `cran-comments.md` for that exact archive and review all warnings or
   significant notes. `New submission` is expected for a new package; it does
   not grant an exception to other requirements.
5. With approval, use the official CRAN submission form, choose the source
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
