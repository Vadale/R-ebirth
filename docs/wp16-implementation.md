# WP16 documentation delivery and validation

The WP16 change supplies the public compatibility policy, a source-derived
inventory of sixteen exports and seventeen registered S3 methods, sixteen
standalone examples, and a complete pkgdown site with machine-readable text.
No package API, runtime, native source, dependency version or numerical bound
changes. The source submitted to CRAN remains unchanged and pending review.

## What was executed locally

The examples reused an existing production CPU installation on Linux/R 4.6.1.
Its public R bodies and formals matched the current thirty-three-entry surface.
The installed package reports 0.4.0 and its DLL SHA-256 is
`fd4be0fdc56d7885392332d6f8e7024152396923cb3be8a359fd69d0ded1894d`.
This is documentation workflow evidence with matching R entry points, not a new
0.5.0 native build or additional platform certification.

| Scope | Observed result |
| --- | --- |
| Five model-free examples | Formula marker/refusal, grouped probe, direction, aligned comparison and timeline passed |
| Eleven public usage checks | Classed refusals observed without loading a model |
| Ten native examples | All completed on cached Qwen2.5 0.5B Q8_0, CPU/context 512; no model download |
| Generation | One bounded synchronous answer with recorded seed 16101; no quality inference |
| Cancellation | Cooperative request accepted and `relm_error_cancelled` observed |
| Trace / embeddings | A 1-by-896 last-position trace matrix and a 2-by-896 embedding matrix |
| Recorded direction | Two new construction pairs/four captures, 896-coordinate direction and zero-coefficient application; reserved selection/evaluation prompts were not evaluated |
| Downloader | Pinned cache reuse with an unchanged file size/mtime and expected SHA-256, with proxies pointed at a closed loopback port |
| Synthetic arithmetic | Known unit direction and comparison differences matched the declared inputs |

The original one-pair application example failed the existing minimum-two-pairs
guard. Its failed run and the already successful ablation output were retained;
only the remaining examples ran after correcting the example to two pairs.
This added one failed load/two captures to the ten successful example loads.
No old benchmark, efficacy holdout or golden suite was manually replayed.
The cached model digest was
`ca59ca7f13d0e15a8cfa77bd17e65d24f6844b554a7b6c12e07a5f89ff76844e`.
Saved RDS outputs, seeds, conditions and shapes were inspected without inference.

## Site and review

The complete site renders the reference and six existing vignettes, plus six
guide/policy articles. It supplies `llms.txt`, `llms-full.txt`, `api-surface.csv`
and the sixteen raw scripts. Model opt-ins stay unset during rendering. Twelve
pkgdown diagnostics explicitly report false model-example conditions; they are
retained and are not model-execution passes or suppressed warnings.
The separate maintainer-tool installation also retained third-party compiler
warnings (including Sass and ragg); no warning-free toolchain claim is made.

Initial missing-Pandoc and child-library failures were retained and corrected by
selecting the installed renderer and passing the actual library paths to Quarto.
An initial filename-order assertion was corrected to compare sorted export names.
Source coverage, parsing, YAML and link checks passed. Local browser inspection
covered the homepage, agent guide and direction reference; it identified and
corrected generated article source links. One integrated owner review covered
the final documentation, examples, compatibility promises and publishing route.
There was no new independent-agent review or external-human usability study.
The final render contains 59 HTML pages; local targets and anchors are checked,
and the copied scripts must match the repository bytes exactly.
The R YAML parser reports coercion warnings on two existing bare-dot workflow
directory values; hosted workflow execution remains the authoritative check.
The first Pages URL is present only in the site staging metadata, so package
incoming checks do not receive a URL before the first deployment exists.

## CI, publication and release boundary

The existing full matrix remains required. Its Linux R-release leg reuses the
already installed package for the five model-free examples, eleven refusals and
complete render. It retains the generated site and execution scope as an artifact.
A separate publication job deploys only the artifact of a successful current-main
R workflow; it does not execute downloaded artifact code. PRs do not deploy.
Hosted current-package acceptance and deployed-site verification are pending at
the time this implementation report is committed; their receipts remain local.

The agent is authorized to merge this PR after **all** current checks pass.
The thirty-day green-CI window starts only after the accepted post-merge main
matrix, according to [the API/version policy](api-policy.md). Neither this
documentation delivery nor that future elapsed window automatically releases 1.0
or implies CRAN acceptance.
