# Optional user feedback after publication

D-047 defers actual external participation until users have the product. Phase 7
uses maintainer functional acceptance; this document does not claim that an
external researcher has tested it or that onboarding is independently validated.
No outreach, release or account setup is performed by this procedure.

Give a volunteer the [installation guide](getting-started.md) and the
[research walkthrough](../examples/research-workflow/README.md). Ask them to:

1. Identify whether their installed build supports the walkthrough, and prepare
   its explicitly optional packages and pinned cached model.
2. Execute it in a new output directory. Record setup and execution time separately.
3. Find the original and projected answers for the evaluation prompt, inspect
   the comparison figure, and explain one observation and one limitation.
4. Reopen the saved CSV/RDS and figures without another model run.
5. Report confusing instructions, error messages and any developer assistance.

Use this small record; do not include private prompts, credentials or model files:

| Field | Observation |
|---|---|
| Date and voluntary participant identifier | |
| OS, R and installed relm build/source | |
| Prior R and relm experience | |
| Setup time / walkthrough time | |
| Steps completed or failed | |
| Exact error and log location, if appropriate to share | |
| Assistance required and by whom | |
| What the comparison shows / does not show | |
| Most confusing step | |
| Proposed improvement | |

A failure is useful feedback, not a reason to erase the record. Address concrete
problems in bounded follow-ups. Do not infer generalized ease of use, performance
or model quality from one participant or from successful maintainer execution.
