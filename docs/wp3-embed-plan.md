# WP3 — `llm_embed()`: plan & embedding-context decision

**Author:** architect agent · **Date:** 2026-07-06 · **Status:** planning artifact for founder review.
**Scope:** ROADMAP §3/§5 Phase 1 / WP3 ("Embeddings"), the **final Phase-1 WP**. WP0/WP1/WP6a/WP2 merged to `main`. Branch `wp3-embed`.

This document contains three deliverables:

1. **The design decision** — the context strategy that reconciles per-call `pooling` with llama.cpp's create-time `pooling_type`, and the causal-vs-non-causal question, resolved together with a single recommendation.
2. **The WP3 implementation breakdown** — golden-first, ordered, mapped to `API-GRAMMAR.md` §3 and the WP3 acceptance criteria, each step independently verifiable.
3. **ADR (proposed) D-011** — written in `DECISIONS.md` format and marked `proposed`, ready to append, at the very end.

**I do not edit `DECISIONS.md` or any root planning doc, nor any `.R`/`.rs`/`.py` source** — the founder appends the accepted ADR and the coder writes the code from this plan. Nothing here changes the approved API surface: `llm_embed(m, x, pooling = c("mean", "last", "model"), normalize = TRUE)` (`API-GRAMMAR.md` §3) is **binding (D-003)**; this plan decides only the *implementation strategy* behind that fixed signature.

The precedent doc is `docs/wp1-plan.md` (referenced by D-005/D-006); this follows its structure.

---

## 0. What is fixed before we start (verified against the code)

| Fact | Source (verified) |
|---|---|
| `llm_embed(m, x, pooling = c("mean","last","model"), normalize = TRUE)` → base `matrix`, `length(x)` rows × `n_embd` cols, rownames = `names(x)` else `seq_along(x)` as chr; error class `rebirth_error_embed`. | `API-GRAMMAR.md` §3, `[approved]` binding |
| Generation context is **causal**, created in `engine.rs::load()` with `cparams.n_ctx = req.context_length` and **defaults otherwise** (i.e. `embeddings = false`, `pooling_type = UNSPECIFIED`, `attention_type = UNSPECIFIED`). | `engine.rs` L446–451 |
| `LoadedModel` wraps **one** `Context` (which owns `Arc<Model>`); the handle is `Arc`-shared and `unsafe impl Send + Sync` (asserted, not enforced — D-008 gate G2). | `engine.rs` L248–272, L157–158, L256–257 |
| The `#[repr(C)] llama_context_params` mirror already carries `pooling_type` (field 11, `c_int`), `attention_type` (field 12, `c_int`), and `embeddings` (`bool`, first bool after `abort_callback_data`) — **field-for-field against `llama.h` b9726 L336–395** (checked line by line for this WP). | `ffi.rs` L96–133 vs `include/llama.h` L336–395 |
| Enums: `llama_pooling_type` {UNSPECIFIED=-1, NONE=0, MEAN=1, CLS=2, LAST=3, RANK=4}; `llama_attention_type` {UNSPECIFIED=-1, CAUSAL=0, NON_CAUSAL=1}. | `include/llama.h` L171–184 |
| `llama_get_embeddings_ith(ctx, i)` returns per-token embeddings **only** when `pooling_type == NONE` or the model is generative — the tokens with `logits[i] != 0`, contiguously, in batch order; shape `[n_embd]`. `llama_get_embeddings_seq(ctx, seq)` returns the pooled vector (NULL for NONE; `float[n_cls_out]` for RANK). | `include/llama.h` L1011–1031 |
| In embeddings mode the **batch `logits[i]` flag selects which tokens' embeddings are output** (all tokens if the flag array is NULL, else the flagged ones). | `include/llama.h` L234–238 |
| The numpy oracle's post-final-norm hidden state is computed at `reference_forward.py:174` (`x = rmsnorm(x, output_norm)`) **immediately before** the LM-head matmul (`:175`). This tensor *is* what `llama_get_embeddings_ith` returns under NONE pooling ("result_norm"). | `reference_forward.py` L174–175 |
| Oversized single batch trips `GGML_ASSERT(n_tokens_all <= n_batch)` → process abort. Decode paths must respect `n_batch` (generate.rs chunks). | HANDOFF §7; `generate.rs` L553–568 |
| Synthetic model: causal `llama`, `n_embd = 32`, 2 layers, **`no_vocab`** (ids-only, no tokenizer). Golden input `INPUT_TOKENS = [1,7,13,22,5,31,44,2]`. | `synthetic_model.py` L32–49 |
| No new dependency permitted (R or Rust) — FORBIDDEN in WP3; D-006 minimal hand-written FFI stands. | ROADMAP §5 WP3; D-006 |

---

## 1. The decision — embedding-context strategy (the WP3 crux)

### 1.1 The tension, stated precisely

Embeddings require the context in **embeddings mode** (`embeddings = true`). Two context properties that shape the *compute graph* are fixed at **context creation** and cannot be changed per call:

- **`pooling_type`** — whether and how llama pools per-token hidden states into one sequence vector.
- **`attention_type`** (equivalently the causal flag) — whether attention is causal (decoder) or non-causal/bidirectional (encoder).

But `llm_embed`'s `pooling` is **per-call** (`"mean"`, `"last"`, `"model"` chosen at call time), and WP3's scope (ROADMAP §5 WP3) explicitly requires **"dedicated embedding GGUFs supported"** — i.e. BERT/RoBERTa-class encoders, which need **non-causal** attention. The generation context (`load()`) is causal and `embeddings = false`; reusing it as-is computes **wrong** vectors for an encoder and offers **no** per-call pooling control.

### 1.2 Recommendation (single path)

**Serve `llm_embed()` from a dedicated, transient embeddings-mode context created once per call, configured `embeddings = true`, `pooling_type = NONE`, `attention_type = UNSPECIFIED`, and do all pooling in Rust over the per-token post-final-norm hidden states from `llama_get_embeddings_ith`.**

Concretely:

- **One context per `llm_embed` call**, not per input string and not cached on the handle. `llm_embed` is already vectorized over the whole input `x`, so the whole batch shares one context; it is created at the start of the call and dropped at the end (RAII). No interior mutability is added to the `Arc`-shared handle (keeps D-008 G2 simple).
- **`pooling_type = NONE`** → `llama_get_embeddings_ith(ctx, i)` yields token `i`'s **post-final-norm** hidden state (the exact `result_norm` tensor the oracle computes at `reference_forward.py:174`). All three `pooling` modes then become one Rust reduction over these rows.
- **`attention_type = UNSPECIFIED` (leave it unset, do *not* force a value)** → llama auto-selects **causal** for generative models (Qwen, the synthetic) and **non-causal** for encoders (BERT), driven by the model's own `hparams.causal_attn`. This is the *only* setting that is correct for both families without a per-model branch. Forcing CAUSAL breaks encoders; forcing NON_CAUSAL corrupts decoder embeddings.
- **Size the context to the batch:** pre-tokenize all inputs, take the longest token length `L`, and create the context with `n_ctx = n_batch = n_ubatch = min(L, handle_context_length)`. Setting `n_batch = n_ubatch = n_ctx` guarantees **every sequence fits one `llama_decode`** — required for non-causal encoders (whose whole sequence must live in a single ubatch) and simultaneously the clean way to avoid the `GGML_ASSERT(n_tokens_all <= n_batch)` abort without per-chunk pooling bookkeeping. Sizing to the batch max (not blindly to a large default) respects the 16 GB rule: compute buffers scale with `n_ubatch`, so we allocate only what the batch needs and free it at call end.
- Any single input longer than `handle_context_length` → `rebirth_error_embed` (message states the two sizes), before allocation.

This makes **one uniform numeric path** for every pooling mode, exactly reproducible by the numpy oracle, and adds **exactly one** new FFI symbol (`llama_get_embeddings_ith`).

### 1.3 Why chunking is *not* used here (reconciling the HANDOFF note)

The HANDOFF's "accumulate across `n_batch` chunks (running sum for mean; keep the last token for last)" guidance is correct **only for causal models**, where a later chunk attends to earlier chunks through the KV cache. For a **non-causal** encoder, splitting a sequence across ubatches is numerically wrong (token *i* must attend to token *i+1*). Rather than branch pooling logic on causality, the recommendation sizes the embedding context so **each sequence is one batch** (`n_batch = n_ubatch = n_ctx ≥ L`). This is correct for both families and simpler. (Generation keeps its own chunking, unchanged — that path is always causal.)

### 1.4 Alternatives rejected

- **A — Reuse the generation context via `llama_set_embeddings(ctx, true)` + read per-token `llama_get_embeddings_ith`.** For a generative model whose default pooling is NONE (Qwen, synthetic) this returns *identical numbers* to a dedicated NONE context, which is why it is tempting. Rejected because: (i) it gives **no per-call pooling** for any model whose default `pooling_type` is not NONE; (ii) it perturbs the **generation KV state** (embeddings decode shares the generation context's cache, forcing clears and interfering with an interleaved `llm_generate`); (iii) it has **no path to encoder GGUFs** — the generation context is `embeddings = false` and tuned for decoding — which fails the "dedicated embedding GGUFs supported" scope outright.
- **B — Two contexts: a NONE context for `mean`/`last` (Rust pooling) plus a model-pooling context using `llama_get_embeddings_seq` for `"model"`.** Rejected: doubles KV/compute buffers on the 16 GB machine, splits `"model"` onto a *second* numeric path that is harder to golden uniformly, and buys nothing — llama's MEAN/CLS/LAST pooling are exactly the simple reductions (average / first-token / last-token) we already compute in Rust over the per-token states, and RANK is not an embedding (it errors under either design). See §2.4 for the proof that Rust reduction reproduces llama's own pooling.
- **C — A per-handle cached embedding context, created lazily on first `llm_embed`.** Saves context allocation across repeated `llm_embed` calls, but forces **interior mutability** (`RefCell`/`OnceCell`) into the `Arc<Model>`-shared, `unsafe impl Send + Sync` handle — reopening the D-008 G2 thread-safety gate — for a cost that is negligible because a single `llm_embed` already batches the whole corpus through one context. Recorded as a **future optimization**, not WP3 scope (see §9 backlog note).
- **D — Force `attention_type = CAUSAL` (or NON_CAUSAL).** Rejected: CAUSAL breaks encoders; NON_CAUSAL corrupts decoder embeddings. UNSPECIFIED (model-driven) is the only correct default, and it is what upstream's own embedding path uses.

---

## 2. Pooling map — exactly how each mode reaches the engine

All modes share: create the NONE-pooling embedding context (§1.2), `clear_memory()`, decode the sequence's token ids as **one batch with every token flagged for output** (`logits[i] = 1` for all `i`), then read per-token rows `e_i = llama_get_embeddings_ith(ctx, i)` for `i ∈ [0, n_tokens)`. Each `e_i` is `n_embd` f32 (the post-final-norm hidden state at position `i`). Pooling is a pure Rust reduction over `{e_i}`:

| `pooling` | Engine call | Rust reduction | Notes |
|---|---|---|---|
| `"mean"` | per-token `llama_get_embeddings_ith` | elementwise **average** of all `n_tokens` rows | pooled over exactly the decoded tokens (`add_special = true`), no exclusion — matches llama.cpp MEAN |
| `"last"` | per-token `llama_get_embeddings_ith` | the **last** row (`e_{n-1}`) | one sequence at a time, no padding, so the last decoded token is the last real token — matches llama.cpp LAST |
| `"model"` | per-token `llama_get_embeddings_ith` | reduction named by the GGUF's own pooling (below) | model's `<arch>.pooling_type` metadata selects mean / first-token / last |

Then, if `normalize = TRUE`, **L2-normalize the pooled vector in Rust**: `norm = sqrt(Σ v²); if norm > 0 { v /= norm }` (a zero vector is returned unchanged — never `NaN`). Values are upcast **f32 → f64** at the boundary (the `matrix` is `double`, consistent with the trace schema's "f32 upcast to double").

### 2.4 `"model"` served precisely, and the two error paths

`"model"` uses the model's own pooling **when the GGUF defines one** (API-GRAMMAR §3). We read the model's intended pooling from GGUF metadata **`<general.architecture>.pooling_type`** (e.g. `bert.pooling_type`) via the **existing** `llama_model_meta_val_str` getter — the same key llama.cpp itself reads into `hparams.pooling_type` — parsed as an integer exactly like `engine.rs::quantization()` parses `general.file_type`. We then map it to a Rust reduction:

| metadata `<arch>.pooling_type` | Meaning | WP3 behavior |
|---|---|---|
| `1` (MEAN) | mean pooling | Rust **mean** reduction |
| `2` (CLS) | first-token pooling | Rust **first-token** (`e_0`) reduction |
| `3` (LAST) | last-token pooling | Rust **last** reduction |
| `0` (NONE) **or key absent** | no pooling defined (e.g. Qwen2.5 — a pure generative LM) | **`rebirth_error_embed`**: "this model defines no pooling; pass `pooling = \"mean\"` or `\"last\"`" — a clean classed condition, **never** a crash or a silent fallback |
| `4` (RANK) | reranker classification head | **`rebirth_error_embed`**: "this is a reranking model (RANK pooling), not an embedding model" — RANK is not an embedding (`llama_get_embeddings_seq` returns rank scores, not a vector); we do not attempt it |
| any other integer | unknown (future enum value) | **`rebirth_error_embed`** "unsupported model pooling type N" — the `vendor-bump` catch-all (see §9) |

**Why metadata-read + Rust reduction rather than `llama_get_embeddings_seq`:** llama's MEAN pooling is a plain average, CLS is "take token 0", LAST is "take the last token" — for embeddings llama does **not** run a trained CLS pooler/dense head (that head only exists for RANK/classification). So the Rust reduction over the per-token `result_norm` states is **bit-for-bit the same computation** llama would do internally, which keeps `"model"` on the *same* single golden-tested numeric path as `"mean"`/`"last"` and needs no second context and no extra FFI symbol. The only pooling type we cannot replicate (RANK) is not an embedding and is a clean error.

---

## 3. FFI additions (`rebirth-llm/src/ffi.rs`) + the `#[repr(C)]` offset checkpoint

### 3.1 New `extern "C"` symbols — exactly one

Add to the `extern "C"` block (a new `// --- embeddings ---` section):

```rust
/// Per-token embedding for output slot `i` (post-final-norm hidden state,
/// "result_norm") when the context was created with pooling_type = NONE.
/// Points at `n_embd` f32 owned by the context, valid until the next decode.
/// NULL for an invalid slot. (llama.h b9726 L1020-1025.)
pub fn llama_get_embeddings_ith(ctx: *mut llama_context, i: i32) -> *mut f32;
```

**Not added, deliberately** (keeps the D-006 minimal surface; note this in the code comment so a reviewer knows it is intentional):

- `llama_set_embeddings` — unneeded: we set `cparams.embeddings = true` at creation (the upstream embedding path does the same); no runtime toggle.
- `llama_get_embeddings_seq` / `llama_pooling_type` — unneeded: the chosen strategy pools in Rust and reads the model's pooling from metadata (`llama_model_meta_val_str`, already declared).

All other calls the embed path needs are **already declared**: `llama_context_default_params`, `llama_init_from_model`, `llama_free`, `llama_model_n_embd`, `llama_n_ctx`, `llama_decode`, `llama_batch_init`/`llama_batch_free`, `llama_get_memory`/`llama_memory_clear`, `llama_model_meta_val_str`, `llama_model_get_vocab`/`llama_vocab_type` (tokenizer presence), `llama_tokenize`.

### 3.2 The `#[repr(C)]` offset checkpoint (flag for the security-auditor — D-008)

WP3 is the first code that **writes** `pooling_type`, `attention_type`, and `embeddings` on the by-value `llama_context_params` struct. D-008 audited that struct field-for-field for the fields WP1 used (`n_ctx`); WP3 relies on these three additional fields sitting at the correct offsets. I re-verified them line-by-line against `include/llama.h` L336–395 for this WP (see §0 table). Because the struct is passed **by value** and obtained from `llama_context_default_params()`, a misaligned mirror would surface as **wrong default values**, not a link error — so the guard must be a value check, not just a compile check.

**Required executable guard** (a `#[cfg(test)]` in `ffi.rs` or `engine.rs`):

```rust
#[test]
fn context_params_embedding_fields_have_the_expected_abi() {
    // SAFETY: default params are a plain by-value C struct.
    let p = unsafe { ffi::llama_context_default_params() };
    // The three fields WP3 writes must read their documented b9726 defaults; a
    // reordered/misaligned #[repr(C)] mirror surfaces garbage here (D-008 guard).
    assert_eq!(p.pooling_type, -1, "LLAMA_POOLING_TYPE_UNSPECIFIED");
    assert_eq!(p.attention_type, -1, "LLAMA_ATTENTION_TYPE_UNSPECIFIED");
    assert!(!p.embeddings, "embeddings default is false");
}
```

This runs in `cargo test -p rebirth-llm` on every CI run and every `vendor-bump`, failing loudly if a future tag reorders the struct. **Security-auditor checkpoint at the WP3 boundary review:** confirm this test exists and passes, and that the mirror still matches `llama.h` at the vendored tag (it feeds directly into D-008's tracked concern that the by-value param structs match field-for-field).

---

## 4. Rust engine surface (`rebirth-llm`, R-free)

New module **`rebirth/src/rust/rebirth-llm/src/embed.rs`** (mirrors how `generate.rs` isolates the generation algorithm), wired via `mod embed;` and re-exports in `lib.rs`. Keeps all C-FFI `unsafe` minimal and individually SAFETY-commented (D-009). No R types anywhere in this crate.

### 4.1 Public types

```rust
/// Per-call pooling choice (mirrors the R `pooling` arg; the boundary parses it).
pub enum Pooling { Mean, Last, Model }
impl Pooling { pub fn parse(s: &str) -> Option<Pooling> { /* "mean"/"last"/"model" */ } }

/// Row-major embedding block: row r = values[r*n_embd .. (r+1)*n_embd].
pub struct Embeddings { pub values: Vec<f32>, pub n_rows: usize, pub n_embd: usize }
```

Internal `enum Reduction { Mean, Last, Cls }` is the resolved reduction (`"model"` collapses to one of these or errors).

### 4.2 Where the embedding context lives, and lifecycle

- **`engine.rs`** (it already owns all context creation) gains an `EmbeddingContext` RAII wrapper next to `Context`:

  ```rust
  pub(crate) struct EmbeddingContext {
      ptr: NonNull<ffi::llama_context>,
      _model: Arc<Model>,   // keeps the model alive for the context's life
      n_embd: usize,
  }
  impl Drop for EmbeddingContext { /* SAFETY: llama_free once, before the Arc<Model> */ }

  impl LoadedModel {
      /// Build a fresh embeddings-mode context sized to `n_ctx` tokens:
      /// embeddings=true, pooling_type=NONE(0), attention_type=UNSPECIFIED(-1),
      /// n_batch = n_ubatch = n_ctx (so any sequence <= n_ctx fits one decode).
      pub(crate) fn create_embedding_context(&self, n_ctx: u32)
          -> Result<EmbeddingContext, RebirthError> { /* llama_init_from_model */ }

      /// The model's own pooling from GGUF `<arch>.pooling_type`, or None if
      /// the key is absent (parsed like `quantization()` parses file_type).
      pub(crate) fn model_pooling_type_meta(&self) -> Option<i32> { /* meta_str + parse */ }
  }
  ```

  `create_embedding_context` has direct access to `self.ctx.model.ptr` and `self.ctx.model.clone()`, so **no new pointer accessor** is needed beyond the two `pub(crate)` methods above. It reads `n_embd` via the already-declared `llama_model_n_embd`.

- **`embed.rs`** holds the algorithm:

  ```rust
  impl EmbeddingContext {
      /// Decode `ids` as one all-tokens-flagged batch and return the per-token
      /// post-final-norm rows (n_tokens x n_embd), engine-native order.
      fn per_token(&self, ids: &[i32]) -> Result<Vec<Vec<f32>>, RebirthError>;
  }

  impl LoadedModel {
      /// Exact-value building block for the synthetic golden test: per-token
      /// embeddings for a raw id sequence (no tokenizer needed).
      pub fn token_embeddings(&self, ids: &[i32]) -> Result<Vec<Vec<f32>>, RebirthError>;

      /// Pooled + optionally L2-normalized embeddings for pre-tokenized inputs
      /// (used by the golden test; ids-only, no tokenizer required).
      pub fn embed_token_batch(&self, batches: &[&[i32]], pooling: Pooling, normalize: bool)
          -> Result<Embeddings, RebirthError>;

      /// The R-facing entry: tokenize each text (requires a tokenizer;
      /// add_special = true, parse_special = false) then embed. One context for
      /// the whole batch, sized to the longest input.
      pub fn embed_texts(&self, texts: &[&str], pooling: Pooling, normalize: bool)
          -> Result<Embeddings, RebirthError>;
  }
  ```

- **Batch reuse:** promote `generate.rs`'s already-SAFETY-reviewed `Batch` (and its `new`/`fill`) to `pub(crate)`. `EmbeddingContext::per_token` builds a `Batch`, fills it with `logits_last_only = false` (**all** tokens flagged for output), and calls `ffi::llama_decode(self.ptr.as_ptr(), …)` against the **embedding** context (its own SAFETY note). This avoids a second, near-identical batch path.

### 4.3 Control flow of `embed_texts` (the memory-conscious batch)

1. `require_tokenizer()?` (reuse generate.rs's check; a `no_vocab` model → `RebirthError::Tokenize`, mapped at the boundary — text embedding needs a tokenizer).
2. Resolve the reduction from `pooling` (§2.4): `Mean`/`Last` are direct; `Model` reads `model_pooling_type_meta()` and maps, erroring (`RebirthError::Embed`) on NONE/absent/RANK/unknown. Resolve **once**, before the loop.
3. Tokenize every input (`add_special = true, parse_special = false`), collecting id vectors; track `L = max len`. Any single input `> handle context_length` → `RebirthError::Embed` (states both sizes), before any allocation.
4. `let ctx = self.create_embedding_context(min(L, context_length))?;` — one context for the batch.
5. For each id vector: `ctx.per_token(ids)?` → reduce (`Reduction`) → optional `l2_normalize` → append `n_embd` f32 to `values`.
6. Return `Embeddings { values, n_rows = texts.len(), n_embd }`. `ctx` drops here (frees the KV/compute buffers).

`embed_token_batch` is the same minus tokenization (ids supplied) and minus the tokenizer requirement — the path the synthetic golden exercises.

### 4.4 New error variant

`error.rs`: add `Embed { reason: String }` to `RebirthError`, `class()` → `"rebirth_error_embed"`, and a `Display` following the §1.8 shape (*what happened → likely cause → what to try*), e.g. for the no-pooling case: "This model defines no pooling, so `pooling = \"model\"` is unavailable. Pass `pooling = \"mean\"` or `\"last\"`." Structured field: `reason`.

---

## 5. FFI boundary (`rebirth-ffi/src/lib.rs`)

One new internal `#[extendr]` entry (not exported; the R `llm_embed()` calls it):

```rust
// Embed a character vector. R has validated m/x/pooling/normalize; here we parse
// the pooling enum, run under with_model's catch_unwind, and return the flat
// row-major matrix values + dims. No 1-based<->0-based conversion is needed:
// llm_embed takes text, not token-id indices (the internal ids never surface to
// R), so the §4 index boundary is crossed nowhere here.
#[extendr]
fn rebirth_embed(ptr: Robj, texts: Vec<String>, pooling: &str, normalize: bool) -> Robj {
    with_model(&ptr, |model| {
        let pool = Pooling::parse(pooling).ok_or_else(|| RebirthError::Internal {
            context: format!("pooling '{pooling}' reached the boundary unresolved (R must match.arg)"),
        })?;
        let refs: Vec<&str> = texts.iter().map(String::as_str).collect();
        let emb = model.embed_texts(&refs, pool, normalize)?;
        Ok(List::from_pairs(vec![
            ("ok", Robj::from(true)),
            ("values", Robj::from(emb.values.iter().map(|&v| v as f64).collect::<Vec<f64>>())),
            ("n_embd", Robj::from(emb.n_embd as i32)),
            ("n_rows", Robj::from(emb.n_rows as i32)),
        ]).into())
    })
}
```

- Register `fn rebirth_embed;` in `extendr_module! { mod rebirth; … }`.
- `with_model` already provides `catch_unwind` + closed/foreign-pointer → `rebirth_error_closed` + panic → `rebirth_error_internal` (reuse it verbatim).
- Extend `error_fields()` with the `Embed { reason }` arm → `[("reason", reason)]`, so the R condition carries the structured `reason` field (§8, programmatic handling).
- Values are upcast to `f64` here (R doubles); the returned `values` is row-major (`n_rows × n_embd`), consumed by `matrix(..., byrow = TRUE)` in R.

---

## 6. R surface (`rebirth/R/embed.R`)

New file `embed.R`:

```r
#' Embed text with a model
#'
#' Encodes each string in `x` into a fixed-length numeric vector ... (returns a
#' base matrix, one row per input).
#' ...
#' @param m An `llm` handle from [llm()].
#' @param x A non-empty character vector to embed; `names(x)` become the row names.
#' @param pooling How to reduce per-token vectors to one per input: `"mean"`
#'   (average), `"last"` (final token), or `"model"` (the model's own pooling when
#'   the GGUF defines one; otherwise an error asking for `"mean"`/`"last"`).
#' @param normalize Single logical. `TRUE` (default) L2-normalizes each row so
#'   rows are unit vectors and dot products are cosine similarities.
#' @return A numeric `matrix`, `length(x)` rows by the model's embedding size
#'   (columns), with row names `names(x)` (or the input positions).
#' @seealso [llm()], [llm_tokens()], [llm_generate()]
#' @examplesIf nzchar(Sys.getenv("REBIRTH_TEST_MODEL_QWEN"))
#' m <- llm(Sys.getenv("REBIRTH_TEST_MODEL_QWEN"))
#' e <- llm_embed(m, c(a = "cats and dogs", b = "domestic pets"))
#' dim(e)
#' close(m)
#' @export
llm_embed <- function(m, x, pooling = c("mean", "last", "model"), normalize = TRUE) {
  if (!inherits(m, "llm")) abort_argument("m", "`m` must be an `llm` handle returned by llm().")
  ensure_open(m)
  pooling <- match.arg(pooling)
  if (!is.character(x) || length(x) == 0L || anyNA(x)) {
    abort_argument("x", "`x` must be a non-empty character vector without NA.")
  }
  if (!is.logical(normalize) || length(normalize) != 1L || is.na(normalize)) {
    abort_argument("normalize", "`normalize` must be a single logical value (TRUE or FALSE).")
  }
  payload <- rebirth_check(rebirth_embed(m$ptr, x, pooling, normalize))
  mat <- matrix(payload$values, nrow = payload$n_rows, ncol = payload$n_embd, byrow = TRUE)
  rownames(mat) <- if (!is.null(names(x))) names(x) else as.character(seq_along(x))
  mat
}
```

Notes and rules honored:

- **Validation in R, before the boundary** (§2 three-layer): bad `m`/`x`/`normalize` → `rebirth_error_argument` via `abort_argument()` (D-007), carrying the `argument` field. `pooling` uses `match.arg()` — the established idiom for closed enums in this package (`llm()` uses `match.arg(backend)`); a bad `pooling` is a programming error, not a user-data condition. Engine-side failures (no-pooling `"model"`, RANK, over-long input, tokenizer-less model) return through the boundary as `rebirth_error_embed`/`rebirth_error_tokenize`. This mirrors `generate.R` exactly (argument checks → `rebirth_error_argument`; engine → `rebirth_error_generation`).
- **Matrix shape/rownames per spec:** `byrow = TRUE` because `values` is row-major; rownames = `names(x)` when set else `seq_along(x)` as character. No column names required (spec is silent → leave `NULL`).
- **Roxygen "Missing link" rule (HANDOFF §7):** cross-reference **only existing topics** — `[llm()]`, `[llm_tokens()]`, `[llm_generate()]`. **Do not** reference `[llm_trace()]`/`[llm_probe()]` (not yet documented → "Missing link" WARNING → CI failure under `error-on = warning`).
- **Runnable example** is `@examplesIf nzchar(Sys.getenv("REBIRTH_TEST_MODEL_QWEN"))`: no in-repo model carries a tokenizer (the synthetic is `no_vocab`), so the R text path cannot execute in CI yet — same honest guard `llm()`/`llm_generate()` use. State this in the roxygen `@details`.

Exports / registration:

- Add `@export` (roxygen regenerates `NAMESPACE`).
- **Spec-first allow-list:** update `tests/testthat/test-package.R` expected set to `c("llm", "llm_tokens", "llm_generate", "llm_embed")`.
- `NEWS.md`: one bullet for `llm_embed()` (pooling modes, normalize, matrix return, golden-validated).

---

## 7. Golden-first test plan (Harness B extension)

### 7.1 Synthetic embeddings golden (the exact-value oracle) — `[SYNTHETIC]`, runs in CI

**Oracle extension** (via the **`golden-update` skill**, the only sanctioned way to touch goldens):

- Refactor `reference_forward.py` so the post-final-norm hidden state is a named intermediate: `hidden_states(weights, tokens)` returns `x` **after** `x = rmsnorm(x, output_norm)` (current L174); `forward()` becomes `hidden_states(...) @ output.T`. This is a pure extraction — the numpy ops and their order are unchanged, so **`logits.npy` must not drift** (the `--check` self-check enforces it: `python reference_forward.py --check`).
- Emit new goldens from `hidden_states(build_weights(), INPUT_TOKENS)` (shape `8 × 32`, float64):
  - `goldens/embeddings.npy` + `goldens/embeddings.csv` — the **per-token post-final-norm hidden states** (the tensor `llama_get_embeddings_ith` returns under NONE pooling). This is the precise match: engine `token_embeddings(INPUT_TOKENS)[i]` ≡ oracle `hidden_states[i]`.
  - Extend `metadata.json` with `mean_pool`, `last_pool`, `mean_pool_normalized`, `last_pool_normalized` (each a length-32 array) and `embeddings_sha256`. `*_normalized` = `v / np.linalg.norm(v)`.
- Add a same-machine determinism assertion for `hidden_states` to `--check` (two recomputations identical), matching the existing logits guard.

**Rust integration test** `rebirth/src/rust/rebirth-llm/tests/synthetic_embed.rs` (mirrors `synthetic_logits.rs`; **this is the de-risking STEP 1** of WP3 — it proves the minimal `no_vocab` model can produce embeddings before any R work):

1. Load the synthetic GGUF on `BackendKind::Cpu` (exact path identical across CI platforms).
2. `token_embeddings(&INPUT_TOKENS)` → `8 × 32`; assert **dimensions** = `8 × n_embd(32)`; assert each value within `ATOL` of `embeddings.csv` (F32-engine vs F64-oracle). Set `ATOL` from the observed gap with headroom, justified in a comment like `synthetic_logits.rs`'s (hidden states are pre-LM-head, so their F32/F64 gap is *smaller* than logits'; start from the logits test's `1e-2` and tighten to observed).
3. `embed_token_batch(&[&INPUT_TOKENS], Pooling::Mean, false)` row 0 ≈ `metadata.mean_pool`; `Pooling::Last` ≈ `last_pool`; the same two with `normalize = true` ≈ the `*_normalized` arrays. This pins **each pooling mode and the L2 path** against the independent oracle.

### 7.2 Semantic-similarity fixture — `[MODEL]`, gated on `REBIRTH_TEST_MODEL_QWEN` (skips in CI/CRAN)

- Commit a small fixture `tests/testthat/fixtures/embed-similarity.csv` (or an inline list in a helper) of **robustly separated** sentence groups — authored once, committed, **not cherry-picked**: the test asserts a *ranking property* that must hold, not a hand-tuned threshold. Because Qwen2.5-0.5B is a **generative** LM (usable but not a SOTA embedder), choose clearly-separated content, e.g. a "pets" pair {"The cat slept on the sofa.", "A dog napped on the couch."} vs an unrelated "physics" sentence {"Quarks are bound by the strong force."}.
- Test (`test-llm-embed-model.R`, `skip_if(!nzchar(Sys.getenv("REBIRTH_TEST_MODEL_QWEN")))`): `e <- llm_embed(m, sentences, pooling = "mean", normalize = TRUE)`; cosine similarity = the row dot products (rows are unit vectors). Assert **every within-group (related) pair ranks above every cross-group (unrelated) pair** (a strict, non-flaky ordering with margin), the WP3 acceptance property "related sentence pairs rank above unrelated ones".

### 7.3 Dimension check for both CI models — acceptance "dimensions match the model card"

- **Synthetic** (`[SYNTHETIC]`, always in CI): the ids path in §7.1 already asserts `ncol == 32`. Add an R check that would exercise text only if a tokenizer existed — since the synthetic is `no_vocab`, instead assert at the ids/engine level (already covered) and document why the R text dimension check for the synthetic is N/A.
- **Qwen2.5-0.5B-Instruct Q8_0** (`[MODEL]`, gated): `expect_equal(ncol(llm_embed(m, "hello")), m$hidden_size)` and `expect_equal(m$hidden_size, 896L)` (the model-card `n_embd`). Also assert `nrow == length(x)` and rownames behavior (named vs `seq_along`).

### 7.4 R argument + error tests (`[NOW]`, no model — run in CI)

Using a **stubbed/fixture `llm`** object (as `test-llm-print.R` does) or the synthetic handle where a boundary call is not reached: each bad `m`/`x`/`normalize` → its `rebirth_error_argument` (with `argument` field); a bad `pooling` → base `match.arg` error. These need no model because validation precedes the boundary.

---

## 8. Step-by-step implementation order (golden-first, each commit independently verifiable)

Guiding rule: goldens/tests first where practical; small commits; no export absent from `API-GRAMMAR.md`; a Rust panic reaching R is a bug.

**Step 0 — Golden extension (`golden-update` skill).** `[SYNTHETIC]`
Refactor `reference_forward.py` (`hidden_states`), emit `embeddings.npy`/`.csv` + `metadata.json` pooled arrays, add the determinism self-check.
- **Verify:** `python reference_forward.py --check` passes **and** reports `logits.npy` unchanged (no drift); `embeddings.sha256` recorded.

**Step 1 — FFI symbol + ABI guard.** `[NOW]`
Declare `llama_get_embeddings_ith`; add the `context_params_embedding_fields_have_the_expected_abi` test (§3.2); promote `Batch`/`new`/`fill` to `pub(crate)`.
- **Verify:** `cargo test -p rebirth-llm` (ABI test green); `cargo clippy … -D warnings`; `cargo fmt --all --check`.

**Step 2 — `rebirth-llm` engine surface.** `[NOW] structure / [SYNTHETIC] values`
`error.rs` `Embed` variant; `engine.rs` `EmbeddingContext` + `create_embedding_context` + `model_pooling_type_meta`; `embed.rs` with `Pooling`/`Embeddings`/`Reduction`, `per_token`, `token_embeddings`, `embed_token_batch`, `embed_texts`, `l2_normalize`; `lib.rs` re-exports.
- **Verify:** unit tests for `Pooling::parse`, the reduction functions, `l2_normalize` (incl. zero-vector → zeros), and `"model"` resolution mapping (NONE/absent/RANK → `Embed`). `cargo test -p rebirth-llm`.

**Step 3 — Synthetic embeddings golden test (de-risking).** `[SYNTHETIC]`
`tests/synthetic_embed.rs` per §7.1.
- **Verify:** `cargo test -p rebirth-llm` — per-token matrix, mean/last, and normalized variants all within tolerance of the oracle; **this is the proof the whole embedding path is numerically correct** before any R code.

**Step 4 — `rebirth-ffi` boundary.** `[NOW]`
`rebirth_embed` (§5); `error_fields` `Embed` arm; register in `extendr_module!`.
- **Verify:** `cargo build -p rebirth-ffi --lib`; `rextendr::document()` regenerates `extendr-wrappers.R`; `cargo clippy`/`fmt` green.

**Step 5 — R surface + export.** `[NOW] validation / [MODEL] values`
`R/embed.R` (§6); `@export`; update `test-package.R` allow-list; `NEWS.md` bullet; argument/error tests (§7.4).
- **Verify:** `devtools::document()`; `devtools::test("rebirth")` (argument tests green, `[MODEL]` skipped); the spec-first allow-list test passes with `llm_embed` added.

**Step 6 — `[MODEL]` fixtures + CI green.** `[MODEL]` local / `[NOW]` CI
Commit the similarity fixture and `test-llm-embed-model.R` (§7.2/§7.3), gated on `REBIRTH_TEST_MODEL_QWEN`.
- **Verify (CI):** `R CMD check` clean (error-on-warning); `cargo test` green cross-platform; `[MODEL]` tests skipped in CI.
- **Verify (local, founder hardware):** run with `REBIRTH_TEST_MODEL_QWEN` set → dimension check (`ncol == 896`), similarity ranking, rownames.

**Step 7 — Phase-1-close hygiene.** `[NOW]`
`simplifier` pass (mandatory at phase end / >~500 lines); `reviewer`; `security-auditor` at the FFI boundary (confirm §3.2 guard + the by-value struct still matches `llama.h`); `doc-writer` once acceptance passes.

**Blocked-now summary**

| WP3 acceptance criterion | Status | Where |
|---|---|---|
| Golden vs reference where the backend exposes one | **[SYNTHETIC]** (in CI) | Steps 0,3 |
| Dimensions match the model card for both CI models | **[SYNTHETIC]** synthetic in CI; **[MODEL]** Qwen local | Steps 3,6 |
| Semantic-similarity fixture: related > unrelated | **[MODEL]** (gated) | Step 6 |
| R CMD check clean; cargo test green | **[NOW]** | Steps 1–6 |

---

## 9. Scope discipline (backlog notes — NOT WP3 scope; for a future `DECISIONS.md` note)

Per planning rule 5, out-of-scope ideas go to a backlog note, not the WP list:

- **Per-handle cached embedding context** (alternative C) — a latency optimization for repeated `llm_embed` calls, deferred because it reopens D-008 G2 (interior mutability on the `Send + Sync` handle) for negligible gain given per-call batching.
- **Multi-sequence batching** (several inputs in one `llama_decode` via distinct `seq_id`s + `llama_get_embeddings_seq`) — a throughput optimization; WP3 processes inputs sequentially (API-GRAMMAR §1.5: "sequentially in Phases 0–4").
- **A pinned dedicated embedding GGUF** (BERT/nomic/bge-class) for **automated non-causal coverage.** WP3 *implements* the non-causal path (UNSPECIFIED attention) but no encoder model is pinned in `SOLO-PHASE-PLAN.md` §3, so its automated golden coverage waits on the founder pinning one (a gated `REBIRTH_TEST_MODEL_EMBED` test). This keeps the honesty limit: we design and unit-cover the encoder path, and we do **not** claim verified non-causal embeddings until a fixture exists. (Full ESM-2/DNABERT support is already deferred to the Phase-18 arch ADR, D-010.)

---

## 10. WP3 acceptance (verbatim, ROADMAP §5) — the definition of done

**ACCEPTANCE**
- Dimensions match the model card for both CI models.
- Semantic-similarity fixture: related sentence pairs rank above unrelated ones (fixed committed fixture, not cherry-picked).
- Golden vs reference where the backend exposes one.
- R CMD check clean; cargo test green.

**FORBIDDEN**
- Silent normalization changes; new dependencies.

(Honored: `normalize` is strictly validated and its L2 effect is explicit, Rust-side, and golden-pinned — no silent change; the only FFI addition is one already-vendored symbol and the only Rust/R additions use no new crates or packages.)

---

## 11. What the founder must decide, and the exact next action

**Founder decisions:**
1. **Accept / amend ADR D-011** (below) — the embedding-context strategy. WP3 implementation depends on it.
2. **(Optional, non-blocking) Pin a small embedding GGUF** for automated non-causal coverage (§9). WP3 ships without it; this only adds a gated `[MODEL]` encoder test later. Not required to start or finish WP3.

Everything else is settled: the signature (D-003), no-new-dependency (D-006), the unsafe partition (D-009), and the golden pipeline (WP6a) all stand unchanged. No prior ADR is contradicted; D-011 is additive.

**Exact next action:** founder reviews **D-011**; on acceptance I hand off to the `coder`, who starts at **Step 0** (golden extension via the `golden-update` skill) and proceeds through Step 3 (the synthetic embeddings golden — the numerical de-risking gate) before the boundary/R work. The `[MODEL]` acceptance (Step 6) runs on the founder's Mac with `REBIRTH_TEST_MODEL_QWEN` set; CI covers everything else.

---

## Deliverable 3 — ADR (proposed), ready to append to `DECISIONS.md`

```
## D-011 — WP3 embedding-context strategy
- **Date:** 2026-07-06 · **Status:** proposed
- **Decision:** serve `llm_embed()` from a **dedicated, transient embeddings-mode llama context created once per call** (not cached on the handle, not the generation context), configured `embeddings = true`, `pooling_type = NONE`, `attention_type = UNSPECIFIED` (llama auto-selects causal for generative models, non-causal for encoders), and sized to the batch's longest input (`n_ctx = n_batch = n_ubatch = min(longest input, handle context_length)`, so every sequence fits one `llama_decode` — required for non-causal encoders and avoiding the `GGML_ASSERT(n_tokens_all <= n_batch)` abort). **All pooling is done in Rust** over the per-token post-final-norm hidden states from `llama_get_embeddings_ith`: `"mean"` = average of the token rows, `"last"` = the final token row, `"model"` = the reduction named by the GGUF `<arch>.pooling_type` metadata (MEAN→average, CLS→first token, LAST→last token). `normalize = TRUE` = L2 per row, in Rust. `"model"` when the model defines no pooling (NONE / key absent, e.g. Qwen2.5) → `rebirth_error_embed` telling the user to pass `"mean"`/`"last"`; RANK (reranker) pooling → `rebirth_error_embed` (RANK is not an embedding); any unknown pooling enum → `rebirth_error_embed`. The only new FFI symbol is `llama_get_embeddings_ith`; the model's pooling is read via the existing `llama_model_meta_val_str`. Full analysis in `docs/wp3-embed-plan.md`.
- **Why:** the generation context (`engine.rs::load()`) is causal and created with `embeddings = false` and model-default (UNSPECIFIED) pooling, so it can neither serve the per-call `pooling` choice nor compute correct vectors for the dedicated encoder GGUFs WP3 must support (ROADMAP §5 WP3). A NONE-pooling context yields per-token `result_norm` states — the exact tensor the numpy oracle already computes (`reference_forward.py:174`, before the LM head) — so `mean`/`last`/`model` collapse to one Rust reduction that is exactly golden-testable against the synthetic model, and MEAN/CLS/LAST reductions are bit-identical to llama's own internal pooling (llama runs no trained pooler for embeddings), so nothing is lost by pooling in Rust. Leaving `attention_type` UNSPECIFIED is the only setting correct for both decoders (causal) and encoders (non-causal) without a per-model branch. A per-call transient context needs no interior mutability on the `Arc`-shared, `unsafe impl Send + Sync` handle (keeps D-008 gate G2 simple) and respects the 16 GB rule (compute buffers sized to the batch, freed at call end). This adds exactly one hand-written FFI symbol, honoring D-006's minimal surface, and writes only `pooling_type`/`attention_type`/`embeddings` on the by-value `llama_context_params`, whose offsets were re-verified against `llama.h` b9726 and are guarded by an executable default-value ABI test (D-008 checkpoint).
- **Alternatives rejected:** reuse the generation context via `llama_set_embeddings(ctx, true)` + per-token reads (works only for generative models whose default pooling is NONE; gives no per-call pooling otherwise, perturbs the generation KV state, and has no path to encoder GGUFs); two contexts — a NONE context for `mean`/`last` plus a model-pooling context using `llama_get_embeddings_seq` for `"model"` (doubles KV/compute buffers, splits `"model"` onto a second numeric path harder to golden, and buys nothing because MEAN/CLS/LAST are exact Rust reductions and RANK is an error either way); a per-handle cached embedding context (saves context allocation across calls but forces interior mutability into the `Send + Sync` handle — reopening D-008 G2 — for negligible gain, since `llm_embed` already batches the whole input through one context; recorded as a future optimization); forcing `attention_type = CAUSAL` (breaks encoders) or `NON_CAUSAL` (corrupts decoder embeddings).
```
