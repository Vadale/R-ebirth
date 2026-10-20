# Nightly installed-library correction

The scheduled model-tolerance job must install its selftest-enabled candidate
before testing. `pkgload::load_all()` makes the package available in the parent
session, but does not provide an installation for the fresh `Rscript` processes
used by the lifecycle tests.

## Observed failure

[Run 39232701351, job 117994244451](https://github.com/Vadale/R-ebirth/actions/runs/39232701351/job/117994244451)
failed at `library(relm)` in lifecycle children: no installed package was found.
The parent had used `load_all()` followed by `test_dir()`. The production
installation for the later S1 comparison was never reached.

The complete original log is retained locally, SHA-256
`8b24af12bee884b561fe05b9d2695a5aa20d62b037f5f3a0da145b1948c55941`.
The console reports ten detailed failures and truncates twelve others. This
diagnosis establishes the visible preparation failure; it does not establish
that every other failure has the same cause. Earlier failed run conclusions
are not evidence of an identical diagnosis.

## Correction and protection mapping

| Existing protection | Corrected execution |
| --- | --- |
| Selftest-enabled lifecycle fixtures | Ordinary `R CMD INSTALL` with `RELM_ENABLE_SELFTESTS=1`, in a new job-specific library |
| Fresh-child package loading | A fresh `Rscript` verifies the exact installed package, DLL location, version and three lifecycle fixture registrations before downloading the model |
| Full checkout test selection and private namespace access | The same unfiltered `test_dir()` uses `package="relm", load_package="installed"`; children inherit the candidate library through their existing helper |
| Test failures and errors fail the job | Full results are saved first, then any failed expectation, error, missing result or incomplete count fails the job |
| HF activation comparison must execute | The existing single-result and positive-expectation gate remains; a skipped result also explicitly fails |
| Numerical and lifecycle contracts | No test bodies, thresholds, deadlines, reference artifacts or model pins change |
| Production S1 and D2 acceptance | Their separate production installation and subsequent commands are unchanged; the selftest library is not used for these comparisons |

Installation logs, suite output, full testthat RDS/CSV results, session metadata
and child failure files are uploaded even when the job fails. Retaining results
does not turn a failed suite into a success.

## Focused verification and limits

A pure-R package control, with no relm native code or model, reproduces the old
parent-only path: two child-loading expectations fail and one parent namespace
expectation passes. Installing that same package in a library whose path contains
spaces makes all three expectations pass through the installed `test_dir()`
route. The successful control retains one warning because its child marker had
no final newline; this is not reported as warning-free execution.

The actual workflow's result-gate expressions accept one valid control and
reject eight negative controls: failure, error, skip, zero passed expectations,
missing golden, empty results, duplicate golden and an unknown count. These
controls are not executions of the HF model comparison.

The five shell blocks and three extracted R blocks parse. The model download,
schedule, native context-boundary command and production S1/D2 tail are byte
identical to the parent. An initial local syntax collector mistakenly treated
the unchanged D2 R block as shell; the collector was corrected without changing
that workflow block. A raw-result inspection initially omitted loading the
testthat namespace; it was corrected by reading the saved RDS again, with no
test replay.

The existing lifecycle tests remain the regression protection. Current ordinary
CI and the corrected scheduled nightly must provide their own results. Local
controls do not certify a new relm DLL, model numerics, S1/D2 results, or a green
thirty-day release window. The submitted CRAN archive is unchanged.
