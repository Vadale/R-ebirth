# AGENTS.md — Instructions for any coding agent

**Read `CLAUDE.md` in this directory first and treat it as binding.** It is the complete project guide (stack, rules, document map, agents, skills). This file exists so that non-Claude tools that look for `AGENTS.md` find the same rules.

Condensed hard rules (full versions in `CLAUDE.md`):

1. Everything you produce is in **English**; conversation with the founder is in Italian.
2. Your task = the current work package in `ROADMAP.md` §3. Use the prompt templates in `ROADMAP.md` §5.
3. Binding docs, in order: `SOLO-PHASE-PLAN.md` (decisions, §2 API grammar) → `ROADMAP.md` (execution) → `API-GRAMMAR.md` (approved signatures — export nothing that is not in it) → `DECISIONS.md` (settled; do not relitigate).
4. Base-R idiom: S3, plain `data.frame`/`matrix` returns, native `|>`, `llm_*` prefix, no tidyverse dependencies.
5. No new R or Rust dependencies without an approved `DECISIONS.md` entry.
6. Golden-first for numerics (`tests/llm-golden/`); tests pass locally before "done"; report failures honestly.
7. Errors reach R as classed conditions — a raw Rust panic in the console is a bug.
8. Small diffs, one concern per commit, English commit messages.
9. Primary target: macOS arm64, R 4.6.1, 16 GB — `llm_trace()` must respect capture filters and the disk-spill path. CI models are tiny; never require a large download in tests.
10. Honesty limits (`CLAUDE.md`): no "C-speed on all R code", no "bias fixed", no "impossible in Python", guardrail = mechanism not guarantee.
