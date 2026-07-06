//! Text and token embeddings (WP3), pooled in Rust over per-token hidden states.
//!
//! The engine wrapper for `llm_embed()`. Per D-011 every embedding runs through a
//! dedicated, transient embeddings-mode context (`EmbeddingContext`, created once
//! per call and sized to the batch) whose `pooling_type = NONE` makes
//! `llama_get_embeddings_ith` yield each token's post-final-norm hidden state (the
//! exact `result_norm` tensor the numpy oracle computes). Every pooling mode is
//! then a pure Rust reduction over those rows, so the whole path is one uniform,
//! golden-testable computation. The crate stays R-free (ARCHITECTURE.md §2): plain
//! Rust types in and out, C-FFI `unsafe` minimal and individually SAFETY-commented
//! (D-009). There is no `n_batch` chunking here — the context is sized so each
//! sequence decodes in one pass, which is the only correct choice for a
//! non-causal encoder (D-011 §1.3).

use crate::engine::{EmbeddingContext, LoadedModel};
use crate::error::RebirthError;
use crate::ffi;
use crate::generate::Batch;

/// Per-call pooling choice (mirrors the R `pooling` arg; the boundary parses it).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Pooling {
    /// Average of the per-token rows.
    Mean,
    /// The final token's row.
    Last,
    /// The reduction named by the GGUF `<arch>.pooling_type` metadata.
    Model,
}

impl Pooling {
    /// Parse the R-facing pooling name (already lowercased by `match.arg` in R);
    /// `None` for anything but the three known modes.
    pub fn parse(s: &str) -> Option<Pooling> {
        match s {
            "mean" => Some(Pooling::Mean),
            "last" => Some(Pooling::Last),
            "model" => Some(Pooling::Model),
            _ => None,
        }
    }
}

/// A row-major embedding block: row `r` is `values[r*n_embd .. (r+1)*n_embd]`.
/// Values are f32 (the engine's native precision); the boundary upcasts to f64.
#[derive(Debug, Clone, PartialEq)]
pub struct Embeddings {
    pub values: Vec<f32>,
    pub n_rows: usize,
    pub n_embd: usize,
}

/// The concrete reduction over per-token rows. `Pooling::Model` collapses to one
/// of these (or errors); `Mean`/`Last` map directly. Kept internal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Reduction {
    Mean,
    Last,
    Cls,
}

// --- pure reductions (unit-tested without a model) --------------------------

/// Elementwise mean of `rows` (each `n_embd` long, `rows` non-empty). Accumulated
/// in f64 to match the numpy oracle's arithmetic and avoid drift over many rows,
/// then stored as f32 (`Embeddings::values` is f32, upcast at the boundary).
fn mean_reduce(rows: &[Vec<f32>], n_embd: usize) -> Vec<f32> {
    let mut acc = vec![0.0f64; n_embd];
    for row in rows {
        for (a, &v) in acc.iter_mut().zip(row.iter()) {
            *a += v as f64;
        }
    }
    let n = rows.len() as f64;
    acc.iter().map(|&a| (a / n) as f32).collect()
}

/// Reduce the per-token `rows` (non-empty) to one pooled vector.
fn reduce(rows: &[Vec<f32>], reduction: Reduction, n_embd: usize) -> Vec<f32> {
    match reduction {
        Reduction::Mean => mean_reduce(rows, n_embd),
        Reduction::Last => rows[rows.len() - 1].clone(),
        Reduction::Cls => rows[0].clone(),
    }
}

/// L2-normalize `v` in place: `v /= sqrt(Σ v²)`, computed in f64 for stability.
/// A zero vector is left unchanged (all zeros) — never producing `NaN` (D-011).
fn l2_normalize(v: &mut [f32]) {
    let norm = v
        .iter()
        .map(|&x| (x as f64) * (x as f64))
        .sum::<f64>()
        .sqrt();
    if norm > 0.0 {
        for x in v.iter_mut() {
            *x = (*x as f64 / norm) as f32;
        }
    }
}

/// Map a GGUF `<arch>.pooling_type` value to a reduction, or an `Embed` error for
/// the pooling types that are not embeddings (or an absent key). Pure (no model)
/// so the mapping is unit-tested directly (§2.4 / D-011).
fn reduction_for_model_pooling(meta: Option<i32>) -> Result<Reduction, RebirthError> {
    match meta {
        Some(1) => Ok(Reduction::Mean), // MEAN
        Some(2) => Ok(Reduction::Cls),  // CLS (first token)
        Some(3) => Ok(Reduction::Last), // LAST
        // NONE (0) or absent: a pure generative LM (e.g. Qwen2.5) defines no
        // pooling, so `pooling = "model"` has nothing to resolve to.
        Some(0) | None => Err(RebirthError::Embed {
            reason: "This model defines no pooling, so pooling = \"model\" is unavailable. \
                     Re-run llm_embed() with pooling = \"mean\" or pooling = \"last\"."
                .to_string(),
        }),
        Some(4) => Err(RebirthError::Embed {
            reason: "This is a reranking model (RANK pooling); it produces relevance \
                     scores, not embedding vectors. Use a dedicated embedding model, \
                     or pooling = \"mean\"/\"last\" on a generative model."
                .to_string(),
        }),
        Some(other) => Err(RebirthError::Embed {
            reason: format!(
                "This model requests pooling type {other}, which rebirth does not \
                 support for embeddings (only mean, first-token, and last-token pooling \
                 are supported). Re-run llm_embed() with pooling = \"mean\" or \"last\"."
            ),
        }),
    }
}

// --- the embedding context's decode + read path ----------------------------

impl EmbeddingContext {
    /// Clear the KV cache so the next sequence starts from position 0. Sequences
    /// in one `llm_embed` call share this context, so it must be cleared between
    /// them (a harmless no-op on the first, freshly created context).
    fn clear_memory(&self) {
        // SAFETY: `self.ptr` is a live context; `llama_get_memory` returns its
        // (non-owning) memory handle, cleared in place.
        unsafe {
            let mem = ffi::llama_get_memory(self.ptr.as_ptr());
            if !mem.is_null() {
                ffi::llama_memory_clear(mem, true);
            }
        }
    }

    /// Decode `ids` as one all-tokens-flagged batch and return the per-token
    /// post-final-norm rows (`n_tokens` x `n_embd`, engine-native order).
    fn per_token(&self, ids: &[i32]) -> Result<Vec<Vec<f32>>, RebirthError> {
        if ids.is_empty() {
            return Err(RebirthError::Embed {
                reason: "Cannot embed an empty input: it has no tokens to encode. \
                         Remove empty strings from the input, or provide some text."
                    .to_string(),
            });
        }
        self.clear_memory();

        let mut batch = Batch::new(ids.len() as i32)?;
        // `logits_last_only = false`: flag every token so `llama_get_embeddings_ith`
        // returns a row for each position (§2 / D-011).
        batch.fill(ids, 0, false);
        // SAFETY: `self.ptr` is a live embedding context; `batch.raw` is a
        // fully-populated batch whose arrays outlive the call (owned by `batch`,
        // dropped after it). `llama_decode` reads the batch by value; `ptr::read`
        // bitwise-copies it without giving up ownership of the backing arrays.
        let status = unsafe { ffi::llama_decode(self.ptr.as_ptr(), std::ptr::read(&batch.raw)) };
        if status != 0 {
            return Err(RebirthError::Embed {
                reason: format!(
                    "The engine failed to compute embeddings (llama_decode returned {status}). \
                     This usually means the input did not fit the context window; try a shorter \
                     input, or reload the model with a larger context_length."
                ),
            });
        }

        let mut rows = Vec::with_capacity(ids.len());
        for i in 0..ids.len() {
            rows.push(self.embeddings_ith(i as i32)?);
        }
        Ok(rows)
    }

    /// Copy the `n_embd` post-final-norm row the engine stored for output slot `ith`.
    fn embeddings_ith(&self, ith: i32) -> Result<Vec<f32>, RebirthError> {
        // SAFETY: `self.ptr` is a live context; `llama_get_embeddings_ith` returns
        // a pointer to `n_embd` f32 owned by the context (valid until the next
        // decode). NULL means the slot produced no embedding — an inconsistency,
        // since we flagged every token for output.
        let ptr = unsafe { ffi::llama_get_embeddings_ith(self.ptr.as_ptr(), ith) };
        if ptr.is_null() {
            return Err(RebirthError::Embed {
                reason: format!(
                    "The engine returned no embedding for token slot {ith}. \
                     This is an internal inconsistency; please report it."
                ),
            });
        }
        // SAFETY: `ptr` points at `n_embd` valid f32 (the row width).
        let row = unsafe { std::slice::from_raw_parts(ptr, self.n_embd) };
        Ok(row.to_vec())
    }
}

/// Decode each id sequence through `ctx`, reduce it, optionally L2-normalize, and
/// pack the rows into one row-major `Embeddings` block.
fn pool_batch<'a>(
    ctx: &EmbeddingContext,
    sequences: impl Iterator<Item = &'a [i32]>,
    n_rows: usize,
    reduction: Reduction,
    normalize: bool,
) -> Result<Embeddings, RebirthError> {
    let n_embd = ctx.n_embd;
    let mut values = Vec::with_capacity(n_rows * n_embd);
    for ids in sequences {
        let rows = ctx.per_token(ids)?;
        let mut pooled = reduce(&rows, reduction, n_embd);
        if normalize {
            l2_normalize(&mut pooled);
        }
        values.extend_from_slice(&pooled);
    }
    Ok(Embeddings {
        values,
        n_rows,
        n_embd,
    })
}

// --- the model-facing entry points ------------------------------------------

impl LoadedModel {
    /// Resolve the per-call `pooling` to a concrete reduction, once, before the
    /// per-input loop. `"model"` reads the GGUF `<arch>.pooling_type` metadata and
    /// maps it (erroring on NONE/absent, RANK, and unknown values).
    fn resolve_reduction(&self, pooling: Pooling) -> Result<Reduction, RebirthError> {
        match pooling {
            Pooling::Mean => Ok(Reduction::Mean),
            Pooling::Last => Ok(Reduction::Last),
            Pooling::Model => reduction_for_model_pooling(self.model_pooling_type_meta()),
        }
    }

    /// The context size for a batch whose longest input is `longest` tokens: the
    /// input length (at least 1) capped at the handle's context window. Sizing to
    /// the batch keeps the compute buffers small (the 16 GB rule, D-011).
    fn embedding_n_ctx(&self, longest: usize) -> u32 {
        (longest.max(1) as u32).min(self.context_length())
    }

    /// `RebirthError::Embed` if `len` tokens do not fit the context window, naming
    /// both sizes (checked before any allocation).
    fn check_embed_fits(&self, len: usize) -> Result<(), RebirthError> {
        let ctx = self.context_length();
        if len as u64 > ctx as u64 {
            return Err(RebirthError::Embed {
                reason: format!(
                    "An input is {len} tokens long, but this model's context window is {ctx} \
                     tokens. Shorten the input, or reload the model with a larger context_length."
                ),
            });
        }
        Ok(())
    }

    /// Exact-value building block for the synthetic golden test: the per-token
    /// post-final-norm embeddings for a raw id sequence (no tokenizer needed).
    pub fn token_embeddings(&self, ids: &[i32]) -> Result<Vec<Vec<f32>>, RebirthError> {
        self.validate_ids(ids)?;
        self.check_embed_fits(ids.len())?;
        let ctx = self.create_embedding_context(self.embedding_n_ctx(ids.len()))?;
        ctx.per_token(ids)
    }

    /// Pooled + optionally L2-normalized embeddings for pre-tokenized inputs
    /// (ids-only, no tokenizer required) — the path the golden test exercises.
    pub fn embed_token_batch(
        &self,
        batches: &[&[i32]],
        pooling: Pooling,
        normalize: bool,
    ) -> Result<Embeddings, RebirthError> {
        let reduction = self.resolve_reduction(pooling)?;
        let mut longest = 0usize;
        for ids in batches {
            self.validate_ids(ids)?;
            self.check_embed_fits(ids.len())?;
            longest = longest.max(ids.len());
        }
        let ctx = self.create_embedding_context(self.embedding_n_ctx(longest))?;
        pool_batch(
            &ctx,
            batches.iter().copied(),
            batches.len(),
            reduction,
            normalize,
        )
    }

    /// The R-facing entry: tokenize each text (`add_special = true`,
    /// `parse_special = false`; requires a tokenizer) then pool + normalize. One
    /// context serves the whole batch, sized to the longest input (D-011).
    pub fn embed_texts(
        &self,
        texts: &[&str],
        pooling: Pooling,
        normalize: bool,
    ) -> Result<Embeddings, RebirthError> {
        self.require_tokenizer()?;
        let reduction = self.resolve_reduction(pooling)?;

        let mut id_vecs: Vec<Vec<i32>> = Vec::with_capacity(texts.len());
        let mut longest = 0usize;
        for &text in texts {
            let ids = self.tokenize(text, true, false)?;
            self.check_embed_fits(ids.len())?;
            longest = longest.max(ids.len());
            id_vecs.push(ids);
        }

        let ctx = self.create_embedding_context(self.embedding_n_ctx(longest))?;
        pool_batch(
            &ctx,
            id_vecs.iter().map(Vec::as_slice),
            texts.len(),
            reduction,
            normalize,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pooling_parses_the_three_modes_and_rejects_others() {
        assert_eq!(Pooling::parse("mean"), Some(Pooling::Mean));
        assert_eq!(Pooling::parse("last"), Some(Pooling::Last));
        assert_eq!(Pooling::parse("model"), Some(Pooling::Model));
        assert_eq!(Pooling::parse("cls"), None);
        assert_eq!(Pooling::parse(""), None);
        // Case-sensitive: R lowercases via match.arg before the boundary.
        assert_eq!(Pooling::parse("Mean"), None);
    }

    #[test]
    fn mean_reduce_averages_each_column() {
        let rows = vec![vec![0.0f32, 2.0, 4.0], vec![2.0, 4.0, 8.0]];
        assert_eq!(mean_reduce(&rows, 3), vec![1.0, 3.0, 6.0]);
    }

    #[test]
    fn reduce_picks_the_right_row_per_mode() {
        let rows = vec![vec![1.0f32, 1.0], vec![2.0, 2.0], vec![3.0, 3.0]];
        assert_eq!(reduce(&rows, Reduction::Cls, 2), vec![1.0, 1.0]);
        assert_eq!(reduce(&rows, Reduction::Last, 2), vec![3.0, 3.0]);
        assert_eq!(reduce(&rows, Reduction::Mean, 2), vec![2.0, 2.0]);
    }

    #[test]
    fn l2_normalize_makes_a_unit_vector() {
        let mut v = vec![3.0f32, 4.0];
        l2_normalize(&mut v);
        assert!((v[0] - 0.6).abs() < 1e-6, "{v:?}");
        assert!((v[1] - 0.8).abs() < 1e-6, "{v:?}");
        let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt();
        assert!((norm - 1.0).abs() < 1e-6, "unit norm, got {norm}");
    }

    #[test]
    fn l2_normalize_leaves_a_zero_vector_as_zeros_not_nan() {
        let mut v = vec![0.0f32; 4];
        l2_normalize(&mut v);
        assert!(v.iter().all(|&x| x == 0.0), "zero vector stays zero: {v:?}");
        assert!(v.iter().all(|x| !x.is_nan()), "never NaN: {v:?}");
    }

    #[test]
    fn model_pooling_maps_mean_cls_last_and_errors_on_none_rank_unknown() {
        assert_eq!(reduction_for_model_pooling(Some(1)), Ok(Reduction::Mean));
        assert_eq!(reduction_for_model_pooling(Some(2)), Ok(Reduction::Cls));
        assert_eq!(reduction_for_model_pooling(Some(3)), Ok(Reduction::Last));
        // NONE and an absent key both mean "no pooling defined".
        for none in [None, Some(0)] {
            assert!(
                matches!(
                    reduction_for_model_pooling(none),
                    Err(RebirthError::Embed { .. })
                ),
                "expected Embed error for {none:?}"
            );
        }
        // RANK (reranker) is not an embedding; an unknown enum is the vendor-bump
        // catch-all — both are clean Embed errors, never a crash.
        assert!(matches!(
            reduction_for_model_pooling(Some(4)),
            Err(RebirthError::Embed { .. })
        ));
        assert!(matches!(
            reduction_for_model_pooling(Some(99)),
            Err(RebirthError::Embed { .. })
        ));
    }
}
