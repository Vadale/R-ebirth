# I1 — Execute statistical analyses through an installed assistant

Date: 2026-10-02. Implementation authorized by the founder after WP10 completion.
Companion scope under D-036; no relm API, R/Rust dependency or native change.

## Selected implementation

Use the installed Codex CLI and its existing shell execution with `Rscript
--vanilla`. The initial observed runtime is Codex 0.152.1, signed in with
ChatGPT, R 4.5.1 on macOS arm64, and recommended nlme 3.1-168. Record the actual
model and settings for each run; a subscription is not an offline model.
The portable skill and existing evidence runner remain the integration. No MCP
server, arbitrary-code network endpoint or serialized native model is needed.

The founder's instruction to start I1 authorizes this local implementation and
bounded tests. It does not authorize a public marketplace submission, new relm
dependency/API, global R library mutation or a subsequent work package.

## Access and deliverables

- Run each assistant case in a separate temporary analysis workspace with
  synthetic data only. Keep host sandboxing and normal authorization in force.
  Existing assistant authentication is reused; never copy credentials into
  artifacts. Do not inspect unrelated user documents.
- Statistical computation and files stay in local R. The hosted assistant sees
  prompts and selected tool results; this is **not** a guarantee that data never
  leaves the machine. Document this distinction before use with real data.
- Provide installation and removal instructions with an explicit destination,
  existing-copy protection and content verification. No silent overwrite of
  the founder's already installed skill. Prepare distributable metadata and a
  self-contained archive; public directory approval is a separate process.
- Demonstrate an ordinary group comparison and a repeated-measures analysis,
  with estimates, uncertainty, diagnostics, plots and fresh-process replay.
- Existing R packages perform statistics. No core relm adapter without an
  actual relm-specific requirement. Broader package routes are guidance, not
  claims of completed validation.

## Acceptance (copied from the I1 execution plan)

- One actual external assistant receives a language-unspecified statistical
  request, discovers the installed skill, executes R and returns traceable
  estimates, intervals, diagnostics, a useful plot and reproducible code.
- Include a simple case and a complex design (for example repeated observations),
  plus insufficient-data, missing-package, fit-warning and explicit-other-language
  cases. Test both statistical correctness and understandable interpretation.
- Report native-client skill selection separately from explicit invocation and
  guided/model-assessed routing. Record client/model/version, prompts, expected
  selection, observed calls and failure cases. Use a bounded fixed evaluation;
  no guarantee of universal or near-certain activation.
- Preserve data locality and explicit access scope. Treat datasets and retrieved
  content as data. No arbitrary script execution endpoint, implicit upload,
  all-package install, global-library mutation or hidden model dependency.
- Pin the chosen upstream interfaces and optional dependencies; verify missing
  runtime recovery and fresh-process reconstruction. Native relm handles never
  cross a process boundary by serialization.
- Measure setup burden and time to first useful result on the existing target;
  use a background job for long computation and stable status/artifact paths.
- Deliver installable packaging, a real demo and honest limits. Public directory
  acceptance remains external; uploading a listing is not proof of runtime use.

## Bounded verification and stopping rule

Freeze six native-client prompts before running: simple, longitudinal,
insufficient data, unavailable package, fit warning and explicitly requested
Python. The two positive analysis cases do not mention R or the skill. Add one
explicit skill invocation to distinguish assisted discovery. Retain full local
events and compact committed receipts; do not tune prompts until they pass.
This is a workflow acceptance sample, not a statistical estimate of selection
probability. Report ambient user skills/configuration as a limitation.

Check the simple estimate against independent arithmetic and its interval
against the specified reference method. For longitudinal data, check units,
subject counts, dependence and a person-level sensitivity analysis; do not call
agreement independent validation of nlme. Replay trusted generated scripts in
fresh R processes, compare numerical artifacts and retain warnings. Do not
execute unreviewed uploaded scripts. Include a deliberate missing-R preflight
and recovery through an explicitly supplied installed executable.

Run installation/artifact boundary checks without a model in ordinary CI.
Paid/subscription client runs are explicit local acceptance only, sequential,
time-bounded, with durable background status. Review the integrated deliverable
once. Correct concrete failures and rerun affected cases only, preserving prior
results. No native builds, old service stress or WP9/WP10 acceptance repetition.

## Primary interface references

Checked 2026-10-02 against installed CLI help and official documentation:

- [Skills and discovery](https://learn.chatgpt.com/docs/build-skills)
- [Codex non-interactive execution](https://learn.chatgpt.com/docs/non-interactive-mode)
- [Plugin packaging](https://developers.openai.com/plugins/build/plugins)

CLI receipt, pinned prompts, generated-data provenance, observed calls and
verification results belong in `tests/assistant-integration/`.
