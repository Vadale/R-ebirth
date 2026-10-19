# WP16 — documentation and API compatibility

Authorized by the founder on 2026-10-19: complete documentation, agent examples
and API/version policy in one PR; merge only after every current check succeeds.
This does not authorize a new release or a replacement CRAN submission.

## Acceptance copied from the roadmap

**WP16 — Docs site + freeze:** full pkgdown from runnable examples;
**AI-readable docs bundle** (`llms.txt` + self-contained executable examples per
export — the "AI-native documentation" goal); semver policy; `llm_*` declared
stable. *Acceptance:* 30-day green CI window → **v1.0**.

The documentation/compatibility delivery and the elapsed 30-day release gate
are separate. A green implementation PR does not satisfy thirty days of history.
See [the policy](api-policy.md) for the exact compatibility and release gates.

## Delivery

- A source-derived inventory of every export and registered S3 method, with
  reference topics; a small checker refuses an unexplained surface change.
- Sixteen standalone examples, each containing its own setup and cleanup.
  Synthetic examples are labelled. Native examples require an explicit verified
  local model; the downloader requires separate explicit opt-in.
- Download-free CI executes synthetic examples and public argument refusals.
  Successful native examples are checked separately with new bounded prompts on
  the already cached model. No consumed efficacy task, native benchmark, golden
  regeneration or automatic large model download is involved.
- A complete pkgdown render reuses the package already installed by the ordinary
  R CI job. Documentation tooling stays outside relm Imports/Suggests. The site
  artifact contains the agent guide, reference text, raw scripts and llms.txt.
- Update current user entry points and submission status; preserve historical
  records, prior failures, the submitted source bytes and numerical limits.

## Verification boundary

Run source/signature/example coverage checks; execute the new examples; render
the full site; inspect generated links, reference coverage and representative
pages. Perform one integrated owner review. Then use the ordinary final CI
matrix once on the complete PR and inspect actual routes before merging.
No runtime/API/dependency/version/kernel or tolerance change is in this WP.

Local evidence retains original failures and actual outputs. Missing prerequisites
or unexecuted model paths are reported explicitly, not promoted to passed runs.
The submitted relm 0.5.0 archive remains the exact prior candidate while CRAN
responds; this repository documentation can advance independently.

See [the implementation report](wp16-implementation.md) for actual execution,
preserved failures and scope limits. GitHub Pages publication follows a successful
current-main R workflow; the existing twelve-check PR matrix remains required.
