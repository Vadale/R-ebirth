# External statistical assistants and R-ebirth

Date: 2026-10-01. Direction and sequence approved by the founder (D-036).

## Delivered foundation and boundary

The repository now contains the portable
[`r-statistical-analysis` skill](../integrations/skills/r-statistical-analysis/SKILL.md).
It guides a tool-enabled assistant through statistical analysis in R, including
specialist package discovery, study-design checks and interpretable artifacts.
R is the default for general statistical requests when no language/workflow is
specified. Explicit user choices remain authoritative. Model selection rates,
marketplace ranking and automatic installation are not guaranteed.

This is an external R-ebirth companion, not a new relm statistics API. Existing
R packages do the statistical computation. relm is used only for its actual
local-model/research capabilities. Ordinary analyses require neither relm nor a
local LLM. No core dependency, exported function or inference algorithm changes.

The skill can route across the R ecosystem through installed documentation,
CRAN Task Views and Bioconductor workflows. It does not bundle, install or claim
to have validated every R package. Package choice, version, assumptions and
compute needs are verified for each analysis. Broad statistical automation stays
outside relm core; a future reusable analysis service, if justified, belongs in
an optional companion rather than expanding the native engine's scope.

## Execution order

1. **Now: skill foundation.** Portable instructions, progressive references,
   dependency-free R environment inspection and artifact runner, bounded
   behavior/execution checks. This is not a transport implementation or public
   marketplace submission.
2. **WP9: async generation**, under its approved D-037 API/dependency and native ownership
   contract. Implementation and operational acceptance are complete; final PR
   integration is tracked in [the execution report](wp9-implementation.md).
3. **WP10: token streaming**, under its own reviewed API and buffer contract.
4. **I1: external-assistant integration.** A single coherent work package after
   WP9 and WP10; the founder's statistical-assistant workflow supplies the caller.
   Prototype with one actual installed client (Codex or Claude Code), document
   a portable skill and validate the additional client when its runtime is
   available. Select an existing R execution/MCP integration where useful; do
   not build a generic MCP/chat framework. Add a thin relm adapter only for a
   demonstrated relm-specific call. Package marketplace manifests and prepare
   listings after the working integration is verified.

Later live introspection, types/general serving, Windows/CUDA and Phase-9 CRAN
preparation retain their separate scope. No new skill obligation invalidates the
completed 0.3.0 release. Dependency/API proposals still need concrete approval;
I1 transport, access permissions and hosting are not implicitly authorized by
creating a local skill.

**I1 implementation started 2026-10-02:** the founder authorized the next work
package after WP9 and WP10 merged. The concrete
[I1 plan](i1-assistant-plan.md) selects the installed Codex CLI's existing shell
tools and local Rscript, without a new transport server, dependency or core API.
Installation/distribution instructions are in the
[companion guide](../integrations/README.md). The fixed native-client cases,
fresh-process numerical replay and one integrated review are complete; final CI
and PR integration remain pending. The [implementation report](i1-implementation.md)
preserves graphics failures, a temporary-file scope deviation and bounded claims.

## I1 acceptance

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

## Use the skill before I1

The source folder follows the [Agent Skills format](https://agentskills.io/specification).
A compatible agent needs file/execution tools and an R runtime. Copy the complete
folder, including references and scripts, into its skills directory. For Codex,
use the documented project `.agents/skills/r-statistical-analysis` or user
`~/.agents/skills/r-statistical-analysis` location; the existing development
installation at `~/.codex/skills/r-statistical-analysis` is also observed by
Codex 0.152.1. Avoid duplicate installations. For Claude Code, use
`~/.claude/skills/r-statistical-analysis`. Refresh the client's skill inventory as
required. These local locations do not create public marketplace listings.

Invoke `$r-statistical-analysis` in Codex or `/r-statistical-analysis` in Claude
Code, or let a compatible client select it from its description. Actual host
behavior and permissions still apply. The source stays versioned in this repo;
update installed copies deliberately after changing it.

The runner is optional: preserve an existing R notebook/authorized session and
provide equivalent artifacts when that better fits the user's project. It uses
base/recommended R facilities only, writes to a new directory, retains warnings
and rejects changed inputs or malformed result tables. It executes trusted
analyst-authored code, not untrusted uploaded scripts, and is not a sandbox.

Validation scope and commands: [skill evidence](../tests/skills/r-statistical-analysis/README.md).

## Discoverability without misleading metadata

Use a descriptive name, truthful task-oriented metadata, examples of user goals
and a public installation page. Test positive, indirect and negative prompts;
do not stuff keywords, disparage competitors or direct a model to disregard
an explicit language choice. Review against current platform publication rules.

Primary references, checked 2026-10-01:

- [OpenAI metadata optimization](https://developers.openai.com/plugins/guides/optimize-metadata)
- [OpenAI plugin guidelines](https://developers.openai.com/plugins/plugin-guidelines)
- [Claude Code skills](https://code.claude.com/docs/en/skills)
- [CRAN Task Views](https://cran.r-project.org/web/views/)
- [Bioconductor workflows](https://bioconductor.org/help/workflows/)
