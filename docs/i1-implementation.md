# I1 — External statistical assistant: implementation and evidence

Date: 2026-10-02. Local functional verification and independent review complete;
final CI and PR integration pending. Contract: [I1 plan](i1-assistant-plan.md),
under D-036. The access/graphics limitations below are not passed gates.

## Delivered integration

Installed Codex CLI 0.152.1 executes local Rscript 4.5.1 on macOS arm64 through
ordinary shell tools. The existing statistical skill supplies the workflow;
no MCP server, relm adapter, R/Rust dependency, global-library change or new public
function is required. The skill is a companion outside the relm package/release.

`integrations/assistant-tools.py` provides explicit-target installation, content
verification, a deterministic portable plugin ZIP and a runtime/package doctor.
It refuses existing destinations, altered copies, extra files and symlinks;
there is no silent overwrite, package install or background service. Eighteen
model-free boundary tests passed locally, including actual missing-R recovery.
The existing R artifact-runner checks passed. These checks join the ordinary R
CI matrix; subscription-backed client runs remain explicit local acceptance.

A new project copy was installed and verified; the actual client inventory
discovered it. The 39,909-byte archive contains root `plugin.json` and the nine
allowlisted skill files, SHA256
`9b3e1a365349dca46be719aa77274061cde56b94c430166f0987151c6442b83f`.
This verifies files and manual discovery, not native plugin installation or a
public marketplace listing. See [installation and use](../integrations/README.md).

## Retained startup failure and recovery

The first attempt inherited `gpt-6.1-sol`/xhigh from personal configuration. The
CLI's ChatGPT-authenticated backend rejected the model before statistical
execution. Its exact error is in `evidence/bootstrap-failure/` below; this is not
evidence of skill selection or an R computation failure.

The refreshed account catalog offered `gpt-5.6-sol`. The corrected evaluation
used that model with medium reasoning through per-invocation flags. Personal
settings, authentication, seven frozen prompts and sandbox policy were unchanged.
Other models were not benchmarked; the original identifier was not retested.

## Actual client observations

Evidence root: [`tests/assistant-integration/evidence`](../tests/assistant-integration/evidence/).
All seven sequential client processes finished without transport errors/timeouts
in 17 minutes 12 seconds. Exit zero alone is not acceptance. Each final answer,
executed script, statistical artifact and meaningful intermediate failure was
reviewed. The table reports final outcomes, without erasing earlier attempts.

| Fixed case | Invocation | Observed result | Wall time |
|---|---|---|---:|
| Independent groups | No language named | Selected the skill and R; mean difference, Welch CI, diagnostics and plot | 147 s |
| Repeated observations | No language named | Selected the skill and R; random intercept/slope model, person-level and AR(1) sensitivity, plots | 294 s |
| One observation per group | No language named | R descriptive difference only; population inference withheld | 101 s |
| Required package unavailable | Explicit R | Checked availability; no installation or substitute method; inference withheld | 95 s |
| Deliberately nonconvergent fit | Explicit R | One requested GLM fit; actual warning retained; nominal intervals labelled untrustworthy | 121 s |
| Explicit Python | Explicit other language | Used Python, without R or statistical-skill activation | 56 s |
| Explicit statistical skill | Guided invocation | R/Welch result and plot after documented graphics recovery | 219 s |

These are times from client launch to final response, including model reasoning,
tool execution and corrections, not pure R fit times or a general latency SLA.
Installation needs an existing assistant/login, Python, R and an explicit copy;
no new server, credentials or model download were needed. A first-install user
study and cold-machine setup duration have not been measured.

The simple and guided estimates are B minus A = **3.833333**, 95% Welch CI
**[2.304902, 5.361764]**, with 12 independent observations per group. Independent
arithmetic matches the estimates and bounds to 1e-12. The longitudinal fixture
has 60 people and 300 observations. The fitted difference in slopes is
**1.361073 points per visit**, 95% approximate mixed-model CI
**[1.108227, 1.613919]**; multiplying by four gives the visit-0-to-4 contrast.
The separate 60-person slope sensitivity agrees with independently calculated
Welch arithmetic, CI **[1.103438, 1.618708]**. This does not independently validate
nlme, its approximate degrees of freedom or all study assumptions. Answers
distinguish observational association from causation and avoid inventing a
practical-importance threshold.

All six final R scripts were inspected before fresh-process replay. Every
numerical, diagnostic and condition CSV compared equal byte for byte. The Python
result also reproduced. Replay intentionally excludes manifests/session paths
and graphics byte equality. Labelled final plots were visually inspected.
Receipts are in `replay/`, `native-client/simple-replay.json` and
`arithmetic-verification.json`; original generated sources remain unmodified.

## Retained failures and limits

- The longitudinal client corrected three intermediate errors: an unqualified
  `lme.formula` update, inherited plot aesthetics and an incorrectly namespaced
  `qqnorm`. Failed artifacts remain beside final `analysis-deliverables`.
- Two guided attempts reported runner completion without delivering the requested
  plot. Subsequent file checks caught this. X11/cairo warnings occurred in tool
  output outside `conditions.csv`; compact excerpts and full-stream hashes are
  preserved. Final `analysis-output-final` explicitly uses macOS Quartz. It is
  Mac execution evidence, not a portable plotting demonstration.
- The guided client created graphics probes and a temporary direct-source analysis
  under `/tmp`, despite the prompt requesting all artifacts in its workspace.
  This is an observed scope-instruction failure. No unrelated-user-file reads,
  package installs or data uploads were observed in the reviewed commands. The
  host sandbox remained active; the skill and trusted-code runner do not enforce
  filesystem confinement. Use host permissions for actual access control.
- The simple plot uses unseeded jitter. Its numerical results reproduce; point
  placement does not. Original code/output is preserved rather than silently
  replacing it with a corrected demonstration.
- Diagnostic labels and non-significant residual tests are not proof of model
  adequacy. Longitudinal confidence intervals are model-dependent and use
  approximate degrees of freedom; expert design/assumption review remains needed.
- The sample used one configured client/model, synthetic data and ambient skills.
  It establishes observed implicit selection in the two positive requests, not a
  universal activation probability, a clean-account comparison, all R methods,
  another client, or Windows support. Explicit invocation is reported separately.
- Harness prompts/logs were present in each workspace; the missing-package case
  read its own logs. Reviewer expectations were not sent to the client. Full raw
  events stay local because tool outputs contain third-party skill text and user
  context; committed receipts retain relevant commands, messages and hashes.
- Statistical computation is local, but hosted assistants can receive prompts,
  tool results and plots. This is not an offline or private-data guarantee.

One integrated independent source/event/artifact review found no blocking
implementation defect and confirmed the bounded statistical interpretation. It
did not rerun fits or certify every assumption. Its explicit limitations above
are carried into this report. Final CI and integration are the remaining I1
delivery steps; no further native build, model call, release, marketplace
submission or subsequent work package is part of this milestone.
