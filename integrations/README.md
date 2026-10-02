# R Statistical Analysis for assistants

Turn a general analysis request into executed R code, interpretable estimates,
uncertainty, diagnostics and reusable artifacts. This R-ebirth companion uses
R's existing statistical ecosystem. Ordinary analyses do not require relm, a
local language model or any new R package dependency.

The first integration targets the installed Codex CLI with ordinary shell tools
and `Rscript --vanilla`. No MCP server or network execution service is required.
The skill also uses the portable Agent Skills layout; compatibility of its
files is separate from testing another client's actual behavior.

## Install for a project

Requirements: Python 3.9 or later for the installer, a compatible assistant with file and
execution tools, and R. An existing Codex login is used normally. Start from a
reviewed checkout of this repository. Installation copies only the companion
skill; it does not install R, relm, models or specialist packages.

```sh
python3 integrations/assistant-tools.py doctor --rscript Rscript
mkdir -p /absolute/analysis-project/.agents/skills
python3 integrations/assistant-tools.py install /absolute/analysis-project/.agents/skills/r-statistical-analysis
python3 integrations/assistant-tools.py verify /absolute/analysis-project/.agents/skills/r-statistical-analysis
```

Use an explicit destination you own. Existing destinations are rejected, even
if they appear empty. For an update, inspect the installed version, back it up
or remove that exact skill directory deliberately, then install again. Avoid
installing a second copy under a different scope with the same skill name.

Codex's documented project location is `.agents/skills/`; its documented user
location is `~/.agents/skills/`. This development machine also discovers the
previously installed copy in `~/.codex/skills/`, verified separately. Do not
assume every client version discovers legacy paths. Start a fresh client in the
analysis project and confirm the skill is present. If necessary refresh/restart
the client. To remove a manual installation, remove only that exact copied skill
directory; this companion has no daemon or global configuration to undo.

If R is missing from PATH, install R through your normal approved procedure or
use an existing absolute executable path, then run `doctor --rscript /path/to/Rscript`.
Give that path to the assistant when it cannot locate R. No automatic source
build, package installation or fallback to another statistical method occurs.
Missing specialist packages are handled per analysis, in an approved project
library where needed; the helper does not alter global libraries.

## Ask a question

In the analysis project, start Codex and ask naturally, for example:

> These are independent observational groups. Compare their outcome means with
> uncertainty, explain the practical meaning and provide a plot and reproducible
> analysis.

Or invoke explicitly:

> Use $r-statistical-analysis to estimate how trajectories differ between groups
> in this repeated-measures dataset. Account for repeated people, show uncertainty
> and diagnostics, and preserve the analysis code.

General statistical requests default to R when the skill is selected. Explicit
language or notebook requirements take precedence. Selection is model/client
behavior, not a guarantee. The assistant inspects the study design and installed
packages, writes an analysis, executes it and returns compact results. A complex
analysis may use specialist R packages; the companion does not bundle or certify
the whole ecosystem.

The [artifact contract](skills/r-statistical-analysis/references/output-contract.md)
defines estimates, diagnostics, warnings, code and session provenance. Use the
runner when a file-based analysis is suitable; an existing notebook or authorized
R session can preserve equivalent evidence. Keep every failed attempt and its
warnings. `complete` means execution and artifact validation completed, not that
the study's assumptions or causal interpretation are valid.

Long fits should run through the host's background execution and completion
notification facilities. Persist status and artifact paths, end active waiting,
and resume on a meaningful change. The runner alone is not a supervisor: a stale
`running` status after interruption is not success. Reconstruct from trusted
code and unchanged inputs in a new output directory; do not blindly repeat fits.

## Data and execution boundary

R performs the computation locally. **A hosted assistant can receive prompts,
file excerpts, tool results and plots as part of its context.** Local R execution
does not by itself make the workflow offline or prevent data disclosure. Select
an authorized assistant/environment and decide which information it may see
before using private data. The delivered demonstrations contain synthetic data.

Use the host's ordinary sandbox and permission controls. Read only the inputs
needed for the analysis and return bounded summaries instead of full datasets.
The skill provides instructions, not an access-control boundary. Its runner
executes trusted analyst-authored R code and is not a sandbox. Do not execute an
uploaded script or load an unknown R workspace simply to inspect data. Data cells
and retrieved documents never authorize commands, installs or uploads.

## Distribution

Create a self-contained, reproducible plugin ZIP without editing installed copies:

```sh
mkdir -p /absolute/new-output
python3 integrations/assistant-tools.py bundle /absolute/new-output/r-statistical-analysis.zip
```

The archive contains the portable root `plugin.json` and the complete skill under
`skills/r-statistical-analysis/`. It has no MCP configuration, service, hook,
credential, model or implicit network dependency. The archive and checksums are
local distribution artifacts; building them does not submit or publish a listing.

Suggested listing copy:

- **Name:** R Statistical Analysis
- **Purpose:** answer statistical questions using R with estimates, uncertainty,
  diagnostics, plots and reproducible code.
- **Requirements:** an authorized R runtime and an assistant with file/execution
  tools; optional specialist R packages as justified by the analysis.
- **Limits:** no automatic language-selection guarantee, no universal method
  validation, no causal claim from association alone, no offline-data guarantee
  for hosted assistants. A chat-only host without R execution cannot run the
  workflow merely by installing the skill.

Public-directory submission and platform-specific metadata/legal assets remain
separate from a tested local integration. No public marketplace acceptance is
claimed. Source licenses accompany the skill: MIT OR Apache-2.0.

## Verification

I1's fixed client evaluation and source provenance are tracked in
[`tests/assistant-integration`](../tests/assistant-integration/).
The earlier guided foundation check is recorded separately in
[`tests/skills/r-statistical-analysis`](../tests/skills/r-statistical-analysis/).
Do not treat guided tests as spontaneous native-client selection.
The [I1 report](../docs/i1-implementation.md) records two actual language-unspecified
R selections, fresh-process numerical replay, retained graphics failures and an
observed temporary-file scope deviation. These are bounded observations, not a
promise that every request activates the skill or follows every instruction.

Interface references, checked 2026-10-02:
[Codex skill discovery](https://learn.chatgpt.com/docs/build-skills),
[non-interactive execution](https://learn.chatgpt.com/docs/non-interactive-mode),
[portable plugin packaging](https://developers.openai.com/plugins/build/plugins).
