# WP-V3 day-1 spike — the T2 multimodal embedding mechanism (D-026.5, plan §3.5)

**Date:** 2026-07-14 · **Author:** coder agent · **Status:** decided (mechanism
implemented in this branch; the D-011 divergence needs the founder's ADR
addendum sign-off at the WP gate — draft text in the WP report).

The question fixed by `docs/phase11-vision-plan.md` §3.5: can the interleaved
image+text ingest run **inside the D-011 embeddings context**
(`embeddings = true`, `pooling_type = NONE`, pool in Rust over per-token rows),
honoring the encoder-side subtleties (qwen-vl M-RoPE positions on the embedding
decode), or is the fallback needed?

## Verdict

**Yes — the ingest runs inside the D-011 embeddings context**, with one
structural amendment to D-011's pooling scope: **pooling reduces over the
TEXT-position rows** (all of them, across every text chunk); image content
conditions those rows through attention. Image-position rows are **structurally
unreachable** through the upstream decode path at b9726, and every route to
them is closed by an existing binding rule (evidence below). This is also
upstream's own multimodal-embedding semantics at the pinned tag.

## Evidence (all line numbers at the vendored/pinned b9726)

1. **The upstream ingest flags at most one output row.**
   `mtmd_helper_eval_chunks` → `eval_chunk_single`: text-chunk batches set
   `logits[j] = false` for every token (mtmd-helper.cpp L364), flagging only
   the final token of the final chunk when `logits_last` (L369-370, L426).
   Image chunks (`mtmd_helper_decode_image_chunk`) hard-code
   `batch.logits[i] = false` in **every** position-setting path — normal
   (L167), M-RoPE 2-D (L185), M-RoPE 1-D (L202) — and the function has **no
   output-flag parameter at all**. In an `embeddings = true, pooling NONE`
   context, llama stores a per-token row **only for flagged tokens**
   (`llama_get_embeddings_ith` is NULL otherwise), so the unmodified helper can
   surface exactly one row.
2. **Every route to image-position rows is closed.**
   (a) Patching the helper to flag image tokens = a vendored-tree change —
   forbidden without founder approval (D-015 discipline, WP constraints).
   (b) Building the image `llama_batch` ourselves with flags on = duplicating
   `decode_embd_batch::set_position_mrope_2d` (mtmd-helper.cpp L173-188) — the
   hand-rolled M-RoPE reimplementation D-026.5 explicitly bans (fails-silent).
   (c) In-graph pooling (`pooling_type = MEAN` on the context +
   `llama_get_embeddings_seq`) pools per **ubatch**; a multimodal prompt is
   inherently multi-decode (text/image chunks), so the "pooled" value would
   cover only the final segment. (d) A single mixed batch is impossible:
   `llama_batch` carries `token` XOR `embd` input, and no public API exposes
   the token-embedding lookup needed to convert text to `embd` input.
   (e) The final-norm graph tensor gathers **only flagged rows**
   (`inp_out_ids` before `result_norm`), so a WP4-style eval-callback tap
   cannot observe post-norm rows for unflagged positions either; the last
   block's `l_out` is pre-norm — pooling it would silently diverge from the
   text path's post-final-norm rows (D-011's `result_norm` contract).
3. **Upstream's own multimodal embeddings are text-scoped.** The b9726 server
   accepts media on `/embeddings` (`tokenize_input_prompts(vocab, mctx, …)`,
   server-context.cpp L4987) and flags **text** tokens for embedding output
   (`common_batch_add(…, slot.need_embd())`, L3160-3165 — "embedding requires
   all tokens in the batch to be output"), while its image chunks go through
   `mtmd_helper_decode_image_chunk` (L623) whose flags are false;
   `send_embedding` (L1995-2035) reads only flagged rows. So at the pinned tag
   the reference implementation, too, produces multimodal embeddings from text
   positions conditioned on images — our mechanism matches it and is strictly
   more inclusive for `mean` (all text chunks' rows, not only the final
   segment's).
4. **`x = ""` (image-only input) still has text rows.** `mtmd_tokenize` wraps
   every image in the projector's delimiter text tokens — for qwen2vl
   `<|vision_start|>` … `<|vision_end|>` (mtmd.cpp L457-459), for the gemma
   family `<start_of_image>`/`<end_of_image>` — so an input with empty text
   still pools over real, image-conditioned rows (the closing delimiter
   attends causally to the whole image). If a future projector had no
   delimiters and no text rows existed, the engine raises a classed
   `relm_error_embed` (never a silent zero vector).
5. **M-RoPE fidelity without reimplementation.** The per-chunk loop mirrors
   `mtmd_helper_eval_chunks`' own sequencing (mtmd-helper.cpp L410-434):
   image/audio chunks are delegated **unchanged** to
   `mtmd_helper_eval_chunk_single` (upstream owns the M-RoPE 2-D positions and
   the gemma3 non-causal toggle); text chunks are decoded by our existing
   flag-all `Batch` at the helper-accounted positions — upstream's own text
   loop uses plain 1-D `pos = n_past++` even for M-RoPE models (L361; llama
   expands text positions internally), and `n_past` advances by
   `mtmd_input_chunk_get_n_pos` exactly as the helper does (L331, L378).
   Nothing image-side is hand-rolled.
6. **Working probe on the pinned 2B VLM** (Qwen2-VL-2B-Instruct Q4_K_M +
   mmproj-f16, the WP-V2 dev artifacts): the env-gated integration test
   `rebirth-llm/tests/vlm_embed.rs` runs the mechanism end-to-end inside the
   D-011 context on CPU and asserts: `llama_decode` accepts the helper's embd
   batches in an embeddings-mode context; one row per text token, every value
   finite; row width = `n_embd`; bit-identical across two runs; and the pooled
   vector moves when the image is present vs text alone (the image genuinely
   conditions the rows). Results in the WP report.

## What was rejected

- **Last-token-only multimodal pooling** (helper unchanged,
  `logits_last = true`): simplest, but it silently narrows the pooling surface
  (the default `pooling = "mean"` would have to error on images) — rejected in
  favor of the text-scoped mechanism that keeps `mean`/`last` both meaningful.
- **The plan's §3.5 fallback** (generation-style context + pool last-layer
  hidden states over text+image positions): unreachable for the same flagging
  reasons (evidence 2e) — the fallback as written assumed per-position access
  that does not exist zero-patch at b9726.
- **Pooling `mtmd_batch_get_output_embd` encoder outputs into the mix**: those
  are the projector's *input* embeddings, not decoder hidden states — mixing
  spaces would be unprincipled and diverge from D-011's `result_norm` contract.

## Consequence for the contract (needs the founder's sign-off)

The plan fixed the contract as "a pooled vector per (text, image) input" and
anticipated an ADR addendum if the mechanism diverged from D-011. It diverges
in exactly one clause: **with images present, pooling reduces over the text
positions** (image content enters through attention) instead of "all
positions". Text-only inputs are byte-identical to D-011 (all positions ARE
text positions). The proposed D-026/D-011 addendum text is in the WP report
for the founder to accept or amend at the gate.
