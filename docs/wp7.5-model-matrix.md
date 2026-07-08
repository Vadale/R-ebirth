# WP7.5a — modern-model support matrix

**Scope:** ROADMAP §3 Phase 3 / WP7.5a, per **D-021**. This is the running record of
which modern instruct models load and work **as text** through `rebirth` at the pinned
engine (llama.cpp **b9726**, Metal on macOS arm64), with the per-model checks and where
each was run. It is a support-status doc, not a benchmark suite.

D-021 verified the target decoder architectures are **already present at b9726** (no
vendor bump needed to load them as text): `LLM_ARCH_GEMMA4/QWEN3/QWEN3MOE/QWEN35/QWEN35MOE`
in `llama-arch.h`, with graphs in `src/models/{gemma4,qwen3,qwen35}.cpp`. WP7.5a part-1
delivered the two software pieces those models need beyond loading:

- **Chat-template resolver** (`generate.rs`): when a model's embedded Jinja chat
  template is present but b9726's applier cannot detect it, fall back to the
  architecture's builtin template (`gemma`/`chatml`/`llama3`). This is what makes
  `chat = TRUE` work for Gemma 4 (see the E4B row).
- **`llm_trace` per-arch matcher extension** (`trace.rs`): explicit, source-derived
  component tables for `qwen3`/`qwen35`/`gemma4`, with `gemma4`'s same-named `attn_out`
  tensor rejected as a name collision (D-014/D-021).

WP7.5a part-2 delivered the third piece: a **runtime sentinel intervention probe**
(`probe.rs`, D-021 §1.3) that supersedes the D-016 hard arch allow-list
(`{llama,qwen2,gemma3}`). Before `llm_steer`/`llm_ablate` return a handle, the engine
decodes one sentinel token on a throwaway context and checks, at each requested layer,
that a sentinel ablation pins the residual (`l_out-<il>[k]`) and a sentinel control
vector shifts it by exactly ε — proving the mechanism (`build_cvec` + the native cvec
path) actually takes effect on *this* model. Pass → interventions enabled (any
standard-residual decoder, incl. gemma4/qwen3/qwen35); fail → `rebirth_error_intervention`
naming what did not respond, never a silent no-op. The verdict is cached per model, so
the ~two-token cost is paid once.

The R constant is retargeted to a **documentation-only "behaviorally validated" tier**
(`INTERVENTION_VALIDATED_ARCHS`, non-gating): architectures with a committed WP5
acceptance fixture beyond the probe — `llama` (the exact numerical oracle,
`synthetic_intervene.rs`) and `qwen2` (the `[MODEL]` valence + KL fixtures on
Qwen2.5-0.5B). `gemma3` dropped from the old list (it was only source-verified, never
behaviorally validated); it still works whenever the probe passes. `gemma4` is
probe-verified and additionally **behaviorally spot-check-confirmed** (valence + KL, see
the E4B intervention spot-check below), but stays out of the fixture-backed constant until
it has a committed fixture of its own.

## Where the checks ran

- **[SPIKE]** — run once by the founder on the Mac mini M4 (16 GB, Metal), the ground
  truth for the load / chat / RSS columns. Recorded live, not from a model card.
- **[MODEL]** — an automated `testthat` test that runs only when the corresponding
  `REBIRTH_TEST_MODEL_*` environment variable points at a local GGUF (founder's Mac);
  it **skips in CI/CRAN**, which download no models.
- **[CI]** — the unit tests that run per-commit with no model: the arch→builtin map, the
  per-arch trace matcher, and the `gemma4` `attn_out` collision rejection are all locked
  model-free in `cargo test` (`generate.rs`/`trace.rs` unit tests).

The license-clean CI/reproduction default stays **Qwen (Apache-2.0)**; Gemma models are
gated by the Gemma Terms of Use and are never fetched in CI (D-023).

## Support matrix

| Model | Env var | Arch | Layers × hidden | Params | Quant | Load | `chat=TRUE` | `llm_trace` residual | RSS | License |
|---|---|---|---|---|---|---|---|---|---|---|
| Gemma 4 E4B (`gemma4:e4b-it-qat`) | `REBIRTH_TEST_MODEL_GEMMA4` | `gemma4` | 42 × 2560 | 7.5B | Q4_0 | ✓ [SPIKE] | ✓ after Task 1 [SPIKE][MODEL] | ✓ (residual only) [MODEL] | ~4.8 GB [SPIKE] | Gemma Terms of Use — **gated** |
| Qwen 3.5 9B (text-only instruct GGUF) | `REBIRTH_TEST_MODEL_QWEN35` | `qwen35` | _TBD_ | ~9B | _TBD_ | _pending pin_ | _pending pin_ | _pending pin_ | _TBD_ | Apache-2.0 |
| Qwen 3 (mid-size, text-only) | `REBIRTH_TEST_MODEL_QWEN3` | `qwen3` | _TBD_ | _TBD_ | _TBD_ | _pending pin_ | _pending pin_ | _pending pin_ | _TBD_ | Apache-2.0 |
| Gemma 4 E2B (text-only) | `REBIRTH_TEST_MODEL_GEMMA4` | `gemma4` | 35 × _TBD_ | ~E2B | _TBD_ | _pending pin_ | _pending pin_ | _pending pin_ | _TBD_ | Gemma Terms of Use — **gated** |
| Gemma 3 4B (text-only, control) | — | `gemma3` | _TBD_ | 4B | _TBD_ | ✓ (WP4) | ✓ (embedded template detected) | ✓ (residual, mlp_out) | _TBD_ | Gemma Terms of Use — **gated** |

`llm_trace` component availability per arch (part-1, source-verified at b9726 —
`component_name()` in `trace.rs`):

| Arch | `residual` (`l_out`) | `mlp_out` (`ffn_out`) | `attn_out` (post-`Wo`) |
|---|---|---|---|
| `llama` | ✓ | ✓ | ✓ (only arch that names it) |
| `qwen2` | ✓ | ✓ | error (pre-`Wo` `kqv_out` only) |
| `gemma3` | ✓ | ✓ | error (pre-`Wo` `kqv_out` only) |
| `qwen3` | ✓ | ✓ | error (pre-`Wo` `kqv_out` only) |
| `qwen35` | ✓ | ✓ | error (pre-`Wo` only) |
| `gemma4` | ✓ | **error** (dense-only `ffn_out`; MoE layers differ) | **error** (name collision — a different quantity) |

## Gemma 4 E4B spike detail (2026-07-08)

- **Model blob:** `gemma4:e4b-it-qat` — the Ollama text blob at
  `~/.ollama/models/blobs/sha256-e8b6a059ba86947a44ace84d6e5679795bc41862c25c30513142588f0e9dba1d`
  (5.15 GB on disk).
  - **SHA256:** `e8b6a059ba86947a44ace84d6e5679795bc41862c25c30513142588f0e9dba1d`
    (the Ollama blob digest = the GGUF file's SHA256).
- **Loads clean as text** through today's `llm()`: arch `gemma4`, 42 layers × 2560
  hidden, 7.5B params, Q4_0, Metal, ~4.8 GB resident.
- **`chat = FALSE`** already worked pre-Task-1 ("The capital of France is" → "Paris").
- **`chat = TRUE`** used to fail with `llama_chat_apply_template failed (-1)`: Gemma 4's
  embedded Jinja template does not contain the `<start_of_turn>` literal that b9726's
  applier keys on (`llama-chat.cpp:155`), so detection returned `-1`. **Task 1 fixes it**
  by resolving `gemma4` → the builtin `"gemma"` template (`LLM_CHAT_TEMPLATE_GEMMA`,
  applied at `llama-chat.cpp:391-399`), which is byte-correct for the family. No vendor
  bump; the fix is in the R/Rust layer only.

## Gemma 4 E4B intervention spot-check (2026-07-08) [MODEL]

Run on the founder's Mac (Metal) against the E4B blob above, exercising the WP7.5a
part-2 sentinel probe and the steer/ablate mechanism end to end. All figures are from a
standalone `[MODEL]` script (public API only), not yet a committed fixture.

- **Probe passes.** Every requested layer's ablation-pin and steer-shift sentinel
  responds; `llm_steer`/`llm_ablate` derive handles (probe adds ~one throwaway decode,
  cached per model). Steering and ablation both visibly change generation.
- **Reversibility holds — on the deterministic forward pass.** The source's next-token
  distribution (`llm_logits`) is bit-identical after probed steer + ablate derivations,
  and order-independent (steer∘ablate = ablate∘steer). NB: gemma4 *greedy generation* on
  Metal is not bit-reproducible even with **no** derivation (a backend FP-reduction
  property — two back-to-back base generations diverge; `llm_logits` is stable), so
  reversibility is verified on the teacher-forced forward pass, matching the exact
  bit-for-bit Rust oracle on the synthetic model (`synthetic_intervene.rs`, CPU).
- **KL-ablation causal control** (5 factual prompts, layer 34, K = 24 neurons, mean KL
  vs base over the full-vocab softmax): targeted (top-|activation|) = **0.4127** vs a
  matched random set = **0.0006** → **671×**; base‖base floor = 0.0000. Targeted ablation
  is three orders of magnitude more disruptive than random — a genuine causal effect, not
  generic perturbation.
- **Valence steering** (10 committed neutral prompts, the committed 141-word lexicon, a
  gemma4-derived diff-in-means direction, `chat = FALSE`, `max_tokens = 48`,
  `temperature = 0`): clean `+coef > base > -coef` at layer 21 / coef ±14 →
  **+0.0280 / +0.0054 / −0.0029**, pos−neg = **+0.0309** (above the Qwen fixture's 0.03
  bar), also positive at layer 31 (both coefs). Gemma 4 needs a larger coefficient than
  Qwen (14 vs 10), consistent with its wider residual (2560 vs 896).

**Tier decision.** Both behavioral checks pass, so Gemma 4 interventions are
**probe-verified and behaviorally spot-check-confirmed**. Gemma 4 is deliberately **not**
added to `INTERVENTION_VALIDATED_ARCHS` (which stays `{llama, qwen2}`): that constant is
reserved for architectures with a *committed, reproducible* acceptance fixture (llama's
numerical oracle; qwen2's SHA256-pinned valence + KL fixtures), per the honest-by-
construction rule "claim only what a golden covers." A committed gemma4 fixture (a pinned
gemma4 direction artifact + calibrated thresholds, mirroring `test-llm-steer-valence.R`)
is **chartered as a WP7.5b/follow-up** and needs founder sign-off on committing a
Gemma-derived artifact under the Gemma Terms of Use.

## Notes on obtaining text-only GGUFs (D-021 / D-023)

- **A combined text+vision GGUF is refused by the loader.** Gemma-3/4 QAT checkpoints
  distributed as a single file with both the text decoder and the vision tower fail to
  load (`expected N, got M` — the loader's single call site passes the upstream default
  `partial = false`). Vision is a separate subsystem, deferred to v0.2.0 / Phase 11
  (D-023).
- **Use a text-only GGUF or the Ollama text blob.** The Gemma 4 E4B row above uses the
  Ollama `gemma4:e4b-it-qat` blob, which is a plain **text** GGUF and loads clean.
  Reveal a blob path with `ollama show <model> --modelfile`.
- **Ollama competes for the 16 GB.** Stop the Ollama server (or confirm `ollama ps` shows
  no resident model) before a rebirth model session so the two do not both hold the model
  in memory.

## Pending (to be filled when the models are pinned)

Pin text-only instruct GGUFs for Qwen 3.5 (up to ~9B), Qwen 3 (mid-size), and Gemma 4
E2B, record their SHA256 / quant / layers×hidden / RSS / tokens-s here, and run the
`[MODEL]` generation + per-arch `llm_trace` tests (`REBIRTH_TEST_MODEL_QWEN3`,
`REBIRTH_TEST_MODEL_QWEN35`, `REBIRTH_TEST_MODEL_GEMMA4`). The `qwen3`/`qwen35`/`gemma4`
trace matcher arms and the `gemma4` `attn_out` rejection are already covered model-free in
CI; the `[MODEL]` rows validate them end-to-end on real weights.
