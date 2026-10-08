//! Tokenization, teacher-forced logits, and token-level generation.
//!
//! The engine wrapper for WP2. Everything here operates on plain Rust types
//! (token-id slices, strings, `Vec<f32>` logits) so the crate stays R-free
//! (ARCHITECTURE.md §2). The determinism contract (§7) is honored by drawing
//! every sampled token on the CPU from the returned logits with a dedicated
//! seeded RNG (`SplitMix64` below) — the GPU backend never selects a token, so
//! backend non-determinism cannot enter the output.

use std::cmp::Ordering;
use std::collections::BinaryHeap;
use std::os::raw::c_char;

use crate::engine::LoadedModel;
use crate::error::RebirthError;
use crate::ffi;
use crate::schema::CompiledSchema;
use crate::structured::{
    Constraint, Grammar, STRUCTURED_MAX_OUTPUT_BYTES, STRUCTURED_MAX_PROMPTS,
    STRUCTURED_MAX_PROMPT_BYTES, STRUCTURED_MAX_TOTAL_OUTPUT_BYTES,
    STRUCTURED_MAX_TOTAL_PROMPT_BYTES,
};

/// Teacher-forced logits for a token sequence: the next-token distribution at
/// every position. Row-major, `seq_len` rows of `n_vocab` each.
#[derive(Debug, Clone, PartialEq)]
pub struct Logits {
    /// `seq_len * n_vocab` values, position-major (row `p` starts at `p*n_vocab`).
    pub values: Vec<f32>,
    pub seq_len: usize,
    pub n_vocab: usize,
}

impl Logits {
    /// The logit row for position `pos` (0-based).
    pub fn row(&self, pos: usize) -> &[f32] {
        &self.values[pos * self.n_vocab..(pos + 1) * self.n_vocab]
    }
}

/// One entry of a next-token distribution's top-k (`llm_logits`): a token, its
/// logit, and its probability. `prob` is the softmax over the FULL vocabulary —
/// the token's true next-token probability, not a renormalized top-k share — so
/// the returned probabilities sum to at most 1.
#[derive(Debug, Clone, PartialEq)]
pub struct TokenLogit {
    /// Engine-native (0-based) vocabulary id; the FFI shifts it to the 1-based R API.
    pub token_id: i32,
    /// The token's decoded display piece.
    pub token: String,
    /// The raw logit, in the engine's native f32.
    pub logit: f32,
    /// Softmax probability over the full vocabulary, in `(0, 1]`.
    pub prob: f64,
}

/// A tokenized string: the engine-native (0-based) token ids and, aligned, the
/// display piece of each token. The FFI boundary is where 0-based becomes the
/// 1-based R API (ARCHITECTURE.md §4); this crate stays engine-native.
#[derive(Debug, Clone, PartialEq)]
pub struct Encoding {
    pub ids: Vec<i32>,
    pub pieces: Vec<String>,
}

// --- a batch that frees itself -------------------------------------------

/// RAII wrapper over `llama_batch`: `llama_batch_init` allocates the arrays,
/// `Drop` calls `llama_batch_free`. All member arrays are engine-owned and sized
/// to `n_tokens`; we only ever write the documented fields. `pub(crate)` so the
/// embedding path (`embed.rs`) reuses this already-SAFETY-reviewed batch fill
/// instead of duplicating a near-identical one.
pub(crate) struct Batch {
    pub(crate) raw: ffi::llama_batch,
    capacity: i32,
}

impl Batch {
    pub(crate) fn new(n_tokens: i32) -> Result<Self, RebirthError> {
        crate::domain::assert_current();
        // SAFETY: allocates a batch holding `n_tokens` tokens (embd = 0 -> token
        // array), one sequence id per token (n_seq_max = 1). Freed in Drop.
        let raw = unsafe { ffi::llama_batch_init(n_tokens, 0, 1) };
        if raw.token.is_null() {
            return Err(RebirthError::Generation {
                reason: "batch_alloc".to_string(),
            });
        }
        Ok(Batch {
            raw,
            capacity: n_tokens,
        })
    }

    /// Fill the batch with `tokens` at positions `start_pos..`, sequence 0.
    /// `logits_last_only` decides whether only the final token requests logits
    /// (generation) or every token does (teacher-forced scoring, and the
    /// embedding path, which flags every token for per-token output).
    pub(crate) fn fill(&mut self, tokens: &[i32], start_pos: i32, logits_last_only: bool) {
        crate::domain::assert_current();
        debug_assert!(tokens.len() as i32 <= self.capacity);
        let n = tokens.len();
        self.raw.n_tokens = n as i32;
        for (i, &tok) in tokens.iter().enumerate() {
            // SAFETY: `i < n <= capacity`; every array below was allocated with
            // `capacity` slots by `llama_batch_init`. `seq_id[i]` points at an
            // array of `n_seq_max = 1` element.
            unsafe {
                *self.raw.token.add(i) = tok;
                *self.raw.pos.add(i) = start_pos + i as i32;
                *self.raw.n_seq_id.add(i) = 1;
                *(*self.raw.seq_id.add(i)).add(0) = 0;
                let want = if logits_last_only {
                    (i == n - 1) as i8
                } else {
                    1
                };
                *self.raw.logits.add(i) = want;
            }
        }
    }
}

impl Drop for Batch {
    fn drop(&mut self) {
        crate::domain::assert_current();
        // SAFETY: `raw` came from `llama_batch_init` and is freed exactly once
        // (this owner drops once). `ptr::read` bitwise-copies the by-value batch
        // the C function consumes; the copy is not used afterwards.
        unsafe { ffi::llama_batch_free(std::ptr::read(&self.raw)) };
    }
}

// --- tokenization ---------------------------------------------------------

/// Two-pass FFI buffer sizing, shared by `tokenize` / `decode_tokens` /
/// `token_piece`. Those engine calls share one convention: given a buffer of
/// `cap` elements they either write `n >= 0` elements and return `n`, or return
/// a negative value whose magnitude is the exact capacity they need. `fill(ptr,
/// cap)` runs the call against a freshly allocated buffer of `cap` elements; on a
/// negative return the buffer is grown to the requested size and the call is
/// retried. Returns the buffer truncated to the elements actually written. The
/// unsafe FFI call lives inside each caller's `fill` closure, with its own SAFETY
/// note; this helper owns only the (safe) sizing loop.
fn sized_buffer<T: Clone + Default>(
    initial_cap: usize,
    mut fill: impl FnMut(*mut T, i32) -> i32,
) -> Vec<T> {
    let mut cap = initial_cap;
    loop {
        let mut buf = vec![T::default(); cap];
        let n = fill(buf.as_mut_ptr(), cap as i32);
        if n < 0 {
            cap = (-n) as usize;
            continue;
        }
        buf.truncate(n as usize);
        return buf;
    }
}

/// Exact size before materializing lossy UTF-8, including replacement bytes.
fn lossy_utf8_len(mut bytes: &[u8]) -> usize {
    let mut size = 0;
    while let Err(error) = std::str::from_utf8(bytes) {
        size += error.valid_up_to() + 3;
        bytes = match error.error_len() {
            Some(invalid) => &bytes[error.valid_up_to() + invalid..],
            None => return size,
        };
    }
    size + bytes.len()
}

/// Allocate exactly the validated UTF-8 size instead of allowing String's
/// geometric growth to hide retained capacity beyond the output estimator.
fn lossy_utf8_exact(mut bytes: &[u8]) -> String {
    let mut output = String::with_capacity(lossy_utf8_len(bytes));
    loop {
        match std::str::from_utf8(bytes) {
            Ok(valid) => {
                output.push_str(valid);
                return output;
            }
            Err(error) => {
                output.push_str(std::str::from_utf8(&bytes[..error.valid_up_to()]).unwrap());
                output.push('\u{fffd}');
                match error.error_len() {
                    Some(invalid) => bytes = &bytes[error.valid_up_to() + invalid..],
                    None => return output,
                }
            }
        }
    }
}

fn bounded_output_buffer(
    initial: usize,
    limit: usize,
    mut fill: impl FnMut(*mut u8, i32) -> i32,
) -> Result<Vec<u8>, RebirthError> {
    let mut capacity = initial.min(limit);
    loop {
        let mut bytes = vec![0; capacity];
        let written = fill(bytes.as_mut_ptr(), capacity as i32);
        if written >= 0 {
            if written as usize > capacity {
                return Err(RebirthError::Internal {
                    context: "invalid detokenizer size".into(),
                });
            }
            bytes.truncate(written as usize);
            let size = lossy_utf8_len(&bytes);
            if size > limit {
                return Err(crate::async_job::output_budget_error(size));
            }
            return Ok(bytes);
        }
        let needed = written
            .checked_neg()
            .ok_or_else(|| RebirthError::Internal {
                context: "invalid detokenizer size".into(),
            })? as usize;
        if needed > limit {
            return Err(crate::async_job::output_budget_error(needed));
        }
        if needed <= capacity {
            return Err(RebirthError::Internal {
                context: "non-increasing detokenizer size".into(),
            });
        }
        capacity = needed;
    }
}

impl LoadedModel {
    /// `Ok(())` if the model carries a tokenizer, else `RebirthError::Tokenize`.
    /// The text-facing entry points (encode / decode / templated generation /
    /// text embedding) all require one; the numeric synthetic model has a
    /// vocabulary but no tokenizer.
    pub(crate) fn require_tokenizer(&self) -> Result<(), RebirthError> {
        if self.has_tokenizer() {
            Ok(())
        } else {
            Err(RebirthError::Tokenize {
                reason: "the model carries no tokenizer (no_vocab)".to_string(),
            })
        }
    }

    /// Tokenize `text` into engine-native (0-based) ids plus their display
    /// pieces. `add_special` adds the model's BOS/EOS if it is configured to;
    /// `parse_special` treats special-token markup in `text` as tokens.
    pub fn encode(
        &self,
        text: &str,
        add_special: bool,
        parse_special: bool,
    ) -> Result<Encoding, RebirthError> {
        let _native = crate::domain::NativeGuard::try_acquire("encode")?;
        self.require_tokenizer()?;
        let ids = self.tokenize(text, add_special, parse_special)?;
        let pieces = ids
            .iter()
            .map(|&id| self.token_piece(id))
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Encoding { ids, pieces })
    }

    /// Detokenize engine-native (0-based) ids back into a single string. The
    /// engine reassembles multi-byte UTF-8 that spans token boundaries, so this
    /// is the correct inverse of [`encode`](Self::encode) (concatenating piece
    /// strings is not). `remove_special`/`unparse_special` are passed through.
    pub fn decode_tokens(
        &self,
        ids: &[i32],
        remove_special: bool,
        unparse_special: bool,
    ) -> Result<String, RebirthError> {
        let _native = crate::domain::NativeGuard::try_acquire("decode_tokens")?;
        self.require_tokenizer()?;
        self.validate_ids(ids)?;
        if ids.is_empty() {
            return Ok(String::new());
        }
        let vocab = self.vocab_ptr();
        // First guess ~8 bytes/token; sized_buffer grows on the engine's request.
        let fill = |ptr: *mut u8, cap| {
            // SAFETY: `vocab` is live; `ids` is a valid slice; `ptr` names `cap`
            // bytes (allocated by sized_buffer). The engine writes at most `cap`
            // bytes (no NUL).
            unsafe {
                ffi::llama_detokenize(
                    vocab,
                    ids.as_ptr(),
                    ids.len() as i32,
                    ptr.cast::<c_char>(),
                    cap,
                    remove_special,
                    unparse_special,
                )
            }
        };
        if let Some(limit) = crate::async_job::output_remaining() {
            let buf = bounded_output_buffer(ids.len() * 8 + 16, limit, fill)?;
            Ok(lossy_utf8_exact(&buf))
        } else {
            let buf = sized_buffer::<u8>(ids.len() * 8 + 16, fill);
            // Preserve the synchronous materialization path unchanged.
            Ok(String::from_utf8_lossy(&buf).into_owned())
        }
    }

    /// Reject ids outside `[0, n_vocab)` before they reach the engine (a bad id
    /// could otherwise trip an assert). Engine-native (0-based) ids.
    pub(crate) fn validate_ids(&self, ids: &[i32]) -> Result<(), RebirthError> {
        let n_vocab = self.n_vocab();
        for &id in ids {
            if id < 0 || id >= n_vocab {
                return Err(RebirthError::Tokenize {
                    reason: format!("token id {id} is outside the vocabulary [0, {n_vocab})"),
                });
            }
        }
        Ok(())
    }

    pub(crate) fn tokenize(
        &self,
        text: &str,
        add_special: bool,
        parse_special: bool,
    ) -> Result<Vec<i32>, RebirthError> {
        crate::async_job::checkpoint()?;
        if crate::async_job::output_remaining().is_some()
            && text.len() > crate::async_job::ASYNC_MAX_ARGUMENT_BYTES
        {
            return Err(RebirthError::Argument {
                argument: "prompt".into(),
                reason: "async templated prompt exceeds 16 MiB".into(),
            });
        }
        let vocab = self.vocab_ptr();
        let bytes = text.as_bytes();
        // Generous first guess; +8 covers any added special tokens on an empty or
        // tiny input. sized_buffer grows to the exact count if the engine asks.
        let fill = |ptr, cap| {
            // SAFETY: `vocab` is live; `bytes` outlives the call; `ptr` names
            // `cap` i32 (allocated by sized_buffer). Passing an explicit length
            // (not NUL-terminated) handles interior NUL bytes in `text`.
            unsafe {
                ffi::llama_tokenize(
                    vocab,
                    bytes.as_ptr().cast::<c_char>(),
                    bytes.len() as i32,
                    ptr,
                    cap,
                    add_special,
                    parse_special,
                )
            }
        };
        let tokens = if crate::async_job::output_remaining().is_some() {
            // A native sizing response must never allocate an over-context
            // token vector merely to discover overflow afterwards.
            let mut capacity = (bytes.len() + 8).min(self.context_length() as usize);
            loop {
                let mut tokens = vec![0i32; capacity];
                let written = fill(tokens.as_mut_ptr(), capacity as i32);
                if written >= 0 {
                    if written as usize > capacity {
                        return Err(RebirthError::Internal {
                            context: "invalid tokenizer size".into(),
                        });
                    }
                    tokens.truncate(written as usize);
                    break tokens;
                }
                let needed = written
                    .checked_neg()
                    .ok_or_else(|| RebirthError::Internal {
                        context: "invalid tokenizer size".into(),
                    })? as usize;
                self.check_fits(needed)?;
                if needed <= capacity {
                    return Err(RebirthError::Internal {
                        context: "non-increasing tokenizer size".into(),
                    });
                }
                capacity = needed;
            }
        } else {
            sized_buffer::<i32>(bytes.len() + 8, fill)
        };
        Ok(tokens)
    }

    /// Live transport uses an exact-capacity UTF-8 allocation so the cached
    /// vocabulary display-byte bound also bounds owned string storage.
    pub(crate) fn live_token_piece(&self, id: i32) -> Result<String, RebirthError> {
        let vocab = self.vocab_ptr();
        // SAFETY: live vocabulary, valid sampled/source id, sizing-only call.
        let needed =
            unsafe { ffi::llama_token_to_piece(vocab, id, std::ptr::null_mut(), 0, 0, true) }
                .checked_abs()
                .ok_or_else(|| RebirthError::Internal {
                    context: "live token size overflow".into(),
                })?;
        let mut bytes = vec![0_u8; needed as usize];
        // SAFETY: the exact sized buffer and vocabulary live throughout this call.
        let actual = unsafe {
            ffi::llama_token_to_piece(vocab, id, bytes.as_mut_ptr().cast(), needed, 0, true)
        };
        if actual != needed {
            return Err(RebirthError::Internal {
                context: "live token piece sizing changed".into(),
            });
        }
        let piece = lossy_utf8_exact(&bytes);
        if piece.capacity() as u64 > self.max_token_piece_bytes() {
            return Err(RebirthError::Internal {
                context: "live token allocation exceeded cached bound".into(),
            });
        }
        Ok(piece)
    }

    /// The display piece for a single engine-native id. Lossy: a single token
    /// may be a partial UTF-8 byte sequence; round-trip correctness comes from
    /// [`decode_tokens`](Self::decode_tokens) on the whole id vector, not from
    /// concatenating pieces.
    pub(crate) fn token_piece(&self, id: i32) -> Result<String, RebirthError> {
        let vocab = self.vocab_ptr();
        let buf = sized_buffer::<u8>(32, |ptr, cap| {
            // SAFETY: `vocab` is live; `ptr` names `cap` bytes (allocated by
            // sized_buffer). `lstrip = 0`, `special = true` so control tokens
            // render as their text.
            unsafe { ffi::llama_token_to_piece(vocab, id, ptr.cast::<c_char>(), cap, 0, true) }
        });
        Ok(String::from_utf8_lossy(&buf).into_owned())
    }
}

// --- forward pass ---------------------------------------------------------

impl LoadedModel {
    /// Clear the KV cache so the next forward pass starts from position 0.
    /// `pub(crate)` so the multimodal ingest (vision.rs) starts its pass from a
    /// clean cache exactly like the text paths here.
    pub(crate) fn clear_memory(&self) {
        // SAFETY: `ctx_ptr` is a live context; `llama_get_memory` returns its
        // (non-owning) memory handle, cleared in place.
        unsafe {
            let mem = ffi::llama_get_memory(self.ctx_ptr());
            if !mem.is_null() {
                ffi::llama_memory_clear(mem, true);
            }
        }
    }

    /// `n_vocab` as a positive `usize`, or a generation error when the model has
    /// an empty vocabulary (nothing could be scored or sampled). `pub(crate)` for
    /// the multimodal path (vision.rs), which shares the sampler loop.
    pub(crate) fn n_vocab_checked(&self) -> Result<usize, RebirthError> {
        match self.n_vocab() as usize {
            0 => Err(RebirthError::Generation {
                reason: "model has empty vocabulary".to_string(),
            }),
            n => Ok(n),
        }
    }

    /// Guard: reject a token sequence that cannot fit the context window.
    /// `pub(crate)` so the trace path (`trace.rs`) shares this exact check instead
    /// of reimplementing the same `ContextOverflow` computation.
    pub(crate) fn check_fits(&self, n_tokens: usize) -> Result<(), RebirthError> {
        let ctx = self.context_length();
        if n_tokens as u64 > ctx as u64 {
            return Err(RebirthError::ContextOverflow {
                prompt_tokens: n_tokens as u32,
                context_length: ctx,
                overflow: n_tokens as u32 - ctx,
            });
        }
        Ok(())
    }

    /// Submit ONE batch of `tokens` at `start_pos`, requesting logits per
    /// `logits_last_only`. Rejects an over-`n_batch` batch with a classed error
    /// BEFORE it reaches `llama_decode`, where more than `n_batch` tokens trips
    /// `GGML_ASSERT(n_tokens_all <= n_batch)` -> `ggml_abort` (a `SIGABRT`
    /// `catch_unwind` cannot intercept — it would kill the R session). Multi-token
    /// sequence ingest routes through [`decode_chunked`](Self::decode_chunked),
    /// which keeps every submit within the bound; the direct callers here pass a
    /// single continuation token. This guard is the last-line defense that makes
    /// the abort unrepresentable even for a future direct caller (audit P-1).
    fn decode(
        &self,
        tokens: &[i32],
        start_pos: i32,
        logits_last_only: bool,
    ) -> Result<(), RebirthError> {
        if tokens.is_empty() {
            return Err(RebirthError::Generation {
                reason: "empty_batch".to_string(),
            });
        }
        let n_batch = (self.n_batch() as usize).max(1);
        if tokens.len() > n_batch {
            return Err(RebirthError::Generation {
                reason: format!(
                    "decode batch of {} tokens exceeds n_batch {n_batch} (must be chunked)",
                    tokens.len()
                ),
            });
        }
        let mut batch = Batch::new(tokens.len() as i32)?;
        batch.fill(tokens, start_pos, logits_last_only);
        // SAFETY: `ctx_ptr` is live; `batch.raw` is a fully-populated batch whose
        // arrays outlive the call (dropped after it). `llama_decode` reads the
        // batch by value; we keep ownership of the backing arrays in `batch`.
        #[cfg(test)]
        self.projection()
            .begin(start_pos, tokens.len(), logits_last_only)?;
        self.live_capture().begin_decode(start_pos, tokens, self)?;
        #[cfg(test)]
        let projection_clock = std::time::Instant::now();
        let status = unsafe { ffi::llama_decode(self.ctx_ptr(), std::ptr::read(&batch.raw)) };
        #[cfg(test)]
        self.projection().time_decode(
            start_pos == 0 || tokens.len() > 1,
            projection_clock.elapsed().as_secs_f64(),
        );
        #[cfg(test)]
        if let Err(error) = self.projection().end() {
            // Reuse the worker's existing unusable-context ownership flag.
            self.steering_restore_failed.set(true);
            return Err(error);
        }
        self.live_capture().end_decode()?;
        if status != 0 {
            return Err(RebirthError::Generation {
                reason: format!("llama_decode returned {status}"),
            });
        }
        Ok(())
    }

    /// Decode `tokens` in `n_batch`-sized chunks, invoking `on_chunk(chunk_start,
    /// chunk_len)` right after each chunk's own [`decode`](Self::decode) — before
    /// the next chunk overwrites the engine's per-token logit buffer
    /// (`llama_get_logits_ith` addresses only the most recent decode, so an
    /// all-positions harvest MUST copy each chunk's rows out inside `on_chunk`).
    /// Positions are global: chunk `k` decodes at its offset in `tokens`, and the
    /// KV cache accumulates across chunks, so the harvested rows equal a single
    /// oversized decode's — callers clear the cache first when they need a fresh
    /// pass.
    ///
    /// This is the single chunked-ingest CHOKEPOINT (audit P-1): every multi-token
    /// forward pass over a caller-supplied sequence routes through here —
    /// generation's prompt ingest (via [`prompt_last_logits`](Self::prompt_last_logits))
    /// and the teacher-forced [`logits_for_tokens`](Self::logits_for_tokens) — so no
    /// ingest path can hand `llama_decode` more than `n_batch` tokens and the
    /// process-killing `GGML_ASSERT(n_tokens_all <= n_batch)` abort is
    /// unrepresentable (generation's single-token continuation decodes directly,
    /// trivially within the bound, which [`decode`](Self::decode) also guards). An
    /// empty `tokens` is rejected (matching [`decode`](Self::decode)) rather than
    /// silently harvesting nothing.
    fn decode_chunked(
        &self,
        tokens: &[i32],
        logits_last_only: bool,
        mut on_chunk: impl FnMut(usize, usize) -> Result<(), RebirthError>,
    ) -> Result<(), RebirthError> {
        if tokens.is_empty() {
            return Err(RebirthError::Generation {
                reason: "empty_batch".to_string(),
            });
        }
        let n_batch = (self.n_batch() as usize).max(1);
        let mut start = 0usize;
        while start < tokens.len() {
            crate::async_job::checkpoint()?;
            let end = (start + n_batch).min(tokens.len());
            self.decode(&tokens[start..end], start as i32, logits_last_only)?;
            #[cfg(test)]
            crate::async_job::test_checkpoint(crate::async_job::TestStage::PrefillChunk);
            crate::async_job::checkpoint()?;
            on_chunk(start, end - start)?;
            start = end;
        }
        Ok(())
    }

    #[cfg(test)]
    pub(crate) fn decode_projection_tokens(
        &self,
        tokens: &[i32],
        start: i32,
        last: bool,
    ) -> Result<(), RebirthError> {
        let _native = crate::NativeGuard::try_acquire("private projection decode")?;
        self.decode(tokens, start, last)
    }

    /// Copy the logit row the engine stored for output slot `ith`. A negative
    /// index reads in reverse (`-1` = the last output row, llama.h L1025) — the
    /// multimodal ingest uses that to fetch the whole-prompt distribution after
    /// `mtmd_helper_eval_chunks(logits_last = true)`; hence `pub(crate)`.
    pub(crate) fn logits_ith(&self, ith: i32, n_vocab: usize) -> Result<Vec<f32>, RebirthError> {
        // SAFETY: `ctx_ptr` is live; `llama_get_logits_ith` returns a pointer to
        // `n_vocab` f32 owned by the context (valid until the next decode). Null
        // means the slot did not request logits — an internal inconsistency.
        let ptr = unsafe { ffi::llama_get_logits_ith(self.ctx_ptr(), ith) };
        if ptr.is_null() {
            return Err(RebirthError::Generation {
                reason: format!("no logits at output slot {ith}"),
            });
        }
        // SAFETY: `ptr` points at `n_vocab` valid f32 (row length = vocab size).
        let row = unsafe { std::slice::from_raw_parts(ptr, n_vocab) };
        Ok(row.to_vec())
    }

    /// Clear the KV cache, decode `tokens` into it through the `n_batch`-chunking
    /// chokepoint (only each chunk's final token requests logits), and return the
    /// last position's logit row (`n_vocab` values) — the next-token distribution
    /// after the whole prompt.
    ///
    /// A causal context caps a `llama_decode` batch at `n_batch = min(n_ctx,
    /// requested)`, which can sit well below `n_ctx` (llama's default request is
    /// 2048), so a prompt longer than one batch MUST be split, which
    /// [`decode_chunked`](Self::decode_chunked) does. The KV cache accumulates
    /// across chunks, so the final row equals a single-batch decode's. Shared by
    /// [`generate`](Self::generate) (whose first sampling step reads this row) and
    /// [`next_token_logits`](Self::next_token_logits) (for which the row is the
    /// answer); the caller has already run [`check_fits`](Self::check_fits).
    ///
    /// Public so the `no_vocab` synthetic regression test can drive the chunked
    /// decode from a raw token-id vector — the text-level `next_token_logits`
    /// needs a tokenizer the synthetic fixture lacks, so it cannot reach this path.
    pub fn prompt_last_logits(
        &self,
        tokens: &[i32],
        n_vocab: usize,
    ) -> Result<Vec<f32>, RebirthError> {
        let _native = crate::domain::NativeGuard::try_acquire("prompt_last_logits")?;
        self.clear_memory();
        let total = tokens.len();
        let mut last: Vec<f32> = Vec::new();
        self.decode_chunked(tokens, true, |start, len| {
            // Only the FINAL chunk's last token carries the whole-prompt
            // distribution; it sits at chunk-local batch index len-1 (the sole slot
            // each chunk flags with logits_last_only). Read just that chunk, as the
            // pre-chunking code read only the last slot after its loop.
            if start + len == total {
                last = self.logits_ith((len - 1) as i32, n_vocab)?;
            }
            Ok(())
        })?;
        Ok(last)
    }

    /// Teacher-forced logits at every position of `tokens` (no sampling). This is
    /// the exact-value oracle path: the numpy reference computes the same rows.
    ///
    /// Routes through the [`decode_chunked`](Self::decode_chunked) chokepoint so a
    /// sequence longer than one decode batch (but within `context_length`) is
    /// split rather than aborting the process on
    /// `GGML_ASSERT(n_tokens_all <= n_batch)`. Every chunk flags all its tokens for
    /// logits and its rows are copied out before the next chunk's decode overwrites
    /// the engine buffer (`llama_get_logits_ith` addresses only the most recent
    /// decode); the KV cache accumulates across chunks, so a position attends to
    /// the whole prefix exactly as a single oversized decode would.
    pub fn logits_for_tokens(&self, tokens: &[i32]) -> Result<Logits, RebirthError> {
        let _native = crate::domain::NativeGuard::try_acquire("logits_for_tokens")?;
        self.check_fits(tokens.len())?;
        let n_vocab = self.n_vocab_checked()?;
        self.clear_memory();

        let mut values = Vec::with_capacity(tokens.len() * n_vocab);
        self.decode_chunked(tokens, false, |_start, len| {
            // Chunk-local batch index i is global position start+i; appending each
            // chunk's rows in index order rebuilds the position-major matrix.
            for i in 0..len {
                values.extend_from_slice(&self.logits_ith(i as i32, n_vocab)?);
            }
            Ok(())
        })?;
        Ok(Logits {
            values,
            seq_len: tokens.len(),
            n_vocab,
        })
    }

    /// The `top` most likely next tokens after `prompt` (`llm_logits`).
    ///
    /// The prompt is tokenized as a raw completion — the model's own special
    /// tokens added, special markup not parsed, exactly like `chat = FALSE`
    /// generation — then ingested through the same `n_batch`-chunked, last-only
    /// forward pass generation uses
    /// ([`prompt_last_logits`](Self::prompt_last_logits)), and the final position's
    /// next-token distribution is reduced to its top-`top` by [`top_k_logits`].
    /// Running on the handle's own generation context means an intervened handle's
    /// distribution reflects its interventions exactly as generation does; the
    /// chunking means a prompt longer than one decode batch (but within
    /// `context_length`) is split rather than aborting the engine. Requires a
    /// tokenizer (a `no_vocab` model raises [`RebirthError::Tokenize`]); an empty
    /// token sequence raises [`RebirthError::Generation`]; a prompt beyond
    /// `context_length` raises [`RebirthError::ContextOverflow`].
    pub fn next_token_logits(
        &self,
        prompt: &str,
        top: usize,
    ) -> Result<Vec<TokenLogit>, RebirthError> {
        let _native = crate::domain::NativeGuard::try_acquire("next_token_logits")?;
        self.require_tokenizer()?;
        let ids = self.tokenize(prompt, true, false)?;
        if ids.is_empty() {
            return Err(RebirthError::Generation {
                reason: "empty_prompt".to_string(),
            });
        }
        self.check_fits(ids.len())?;
        let n_vocab = self.n_vocab_checked()?;
        let last = self.prompt_last_logits(&ids, n_vocab)?;
        top_k_logits(&last, top)
            .into_iter()
            .map(|(id, logit, prob)| {
                Ok(TokenLogit {
                    token_id: id as i32,
                    token: self.token_piece(id as i32)?,
                    logit,
                    prob,
                })
            })
            .collect()
    }
}

// --- generation -----------------------------------------------------------

/// A deterministic SplitMix64 PRNG. Sampling draws all of its randomness here,
/// so a generation's output depends only on `(seed, params, logits)` and never
/// on backend RNG state: same seed + params ⇒ identical tokens across runs and
/// sessions (the determinism contract, ARCHITECTURE.md §7). SplitMix64 is the
/// reference seeding generator for the xoshiro family — good statistical quality
/// for a self-contained integer generator that needs no dependency.
struct SplitMix64 {
    state: u64,
}

impl SplitMix64 {
    fn new(seed: u64) -> Self {
        SplitMix64 { state: seed }
    }

    fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// A uniform double in `[0, 1)` with 53 bits of entropy.
    fn next_f64(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 * (1.0 / (1u64 << 53) as f64)
    }
}

/// Why [`LoadedModel::generate`] stopped producing tokens.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StopReason {
    /// Reached `max_tokens`.
    MaxTokens,
    /// The model emitted an end-of-generation token (EOS/EOT/…).
    EndOfGeneration,
    /// One of the `stop` strings appeared in the decoded output.
    StopString,
    /// The context window filled up before `max_tokens` was reached.
    ContextFull,
}

impl StopReason {
    /// The R-facing tag for this stop reason (a `finish_reason`-style label).
    pub fn as_str(&self) -> &'static str {
        match self {
            StopReason::MaxTokens => "length",
            StopReason::EndOfGeneration => "stop",
            StopReason::StopString => "stop_string",
            StopReason::ContextFull => "context_full",
        }
    }
}

/// Sampling and length controls for [`LoadedModel::generate`]. The R layer
/// composes these from the `llm_generate()` arguments; the engine only reads
/// them.
#[derive(Debug, Clone)]
pub struct GenerateParams {
    /// Maximum number of tokens to produce.
    pub max_tokens: usize,
    /// Softmax temperature. `<= 0` selects greedy decoding (argmax) — the exact,
    /// reproducible path the goldens pin.
    pub temperature: f32,
    /// Nucleus (top-p) cutoff in `(0, 1]`; ignored when greedy.
    pub top_p: f32,
    /// Seed for the CPU sampler. The caller records the drawn seed so a sampled
    /// run is reproducible.
    pub seed: u64,
    /// Stop strings: generation ends as soon as one appears in the output, which
    /// is truncated just before it.
    pub stop: Vec<String>,
}

/// The result of a generation run. Token ids are engine-native (0-based); the
/// FFI boundary shifts them to the 1-based R API.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Generation {
    /// The generated token ids (engine-native, 0-based), prompt excluded.
    pub tokens: Vec<i32>,
    /// The decoded continuation text (prompt excluded), truncated at a stop
    /// string when one fired.
    pub text: String,
    /// Why generation stopped.
    pub stop_reason: StopReason,
    /// The seed actually used (echoes `params.seed`; the R layer surfaces it so a
    /// sampled run can be replayed).
    pub seed: u64,
}

/// Index of the (first) maximum in `row`. Ties resolve to the lowest index, so
/// greedy decoding matches `numpy.argmax` on the oracle exactly.
fn argmax(row: &[f32]) -> usize {
    let mut best = 0usize;
    for (i, &v) in row.iter().enumerate() {
        if v > row[best] {
            best = i;
        }
    }
    best
}

/// Draw one token id from `logits` under temperature + nucleus (top-p) sampling,
/// using `rng` for the single uniform it needs. The computation is fully
/// deterministic given `rng`'s state: a stable sort (value desc, then index) and
/// a fixed reduction order make the result reproducible on a given platform.
fn sample(logits: &[f32], temperature: f32, top_p: f32, rng: &mut SplitMix64) -> usize {
    let n = logits.len();
    // Descending by logit; ties broken by ascending index for a total, stable
    // order (f32::total_cmp handles any -0.0/NaN without a panic).
    let mut order: Vec<usize> = (0..n).collect();
    order.sort_unstable_by(|&a, &b| logits[b].total_cmp(&logits[a]).then(a.cmp(&b)));

    // Softmax with temperature, in descending order, max-shifted for stability.
    let inv_t = 1.0 / (temperature.max(1e-6) as f64);
    let max = logits[order[0]] as f64;
    let mut probs: Vec<f64> = order
        .iter()
        .map(|&i| ((logits[i] as f64 - max) * inv_t).exp())
        .collect();
    let total: f64 = probs.iter().sum();
    for p in probs.iter_mut() {
        *p /= total;
    }

    // Nucleus: the shortest high-probability prefix whose mass reaches top_p.
    let p_cut = (top_p as f64).clamp(f64::MIN_POSITIVE, 1.0);
    let mut cum = 0.0;
    let mut keep = n;
    for (k, &p) in probs.iter().enumerate() {
        cum += p;
        if cum >= p_cut {
            keep = k + 1;
            break;
        }
    }

    // Draw within the kept nucleus (renormalized by its retained mass).
    let kept_mass: f64 = probs[..keep].iter().sum();
    let target = rng.next_f64() * kept_mass;
    let mut acc = 0.0;
    for k in 0..keep {
        acc += probs[k];
        if target < acc {
            return order[k];
        }
    }
    order[keep - 1] // floating-point fallback: the least-likely kept token
}

// A max-heap whose root is the WORST retained rank. This reverses the logit
// comparison so replacing the root preserves exactly the old full-sort order.
#[derive(Clone, Copy)]
struct LogitRank {
    id: usize,
    logit: f32,
}

pub(crate) fn top_rank_bytes() -> usize {
    std::mem::size_of::<LogitRank>()
}

impl PartialEq for LogitRank {
    fn eq(&self, other: &Self) -> bool {
        self.id == other.id && self.logit.to_bits() == other.logit.to_bits()
    }
}

impl Eq for LogitRank {}

impl PartialOrd for LogitRank {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for LogitRank {
    fn cmp(&self, other: &Self) -> Ordering {
        other
            .logit
            .total_cmp(&self.logit)
            .then(self.id.cmp(&other.id))
    }
}

/// The `top` highest-logit entries of a next-token distribution `logits`.
///
/// The softmax is taken over the WHOLE row (max-shifted, accumulated in f64 for
/// stability, matching [`sample`] and the numpy oracle) *before* the top-`top`
/// are selected, so each returned probability is the token's true share of the
/// full distribution. Results are ordered by descending logit, ties broken by
/// ascending id — the same total, stable order as the sampler — so rank 1 is
/// always the argmax. `top` is clamped to the row length. Returns
/// `(id_0based, logit, prob)` per rank.
///
/// Public so the synthetic-model golden test can check this extraction against the
/// numpy oracle's final-position row directly (the `no_vocab` synthetic model has
/// no tokenizer, so the text-level [`next_token_logits`](LoadedModel::next_token_logits)
/// cannot run on it).
pub fn top_k_logits(logits: &[f32], top: usize) -> Vec<(usize, f32, f64)> {
    let n = logits.len();
    let keep = top.min(n);
    if keep == 0 {
        return Vec::new();
    }
    // Softmax over the full row, max-shifted, accumulated in f64.
    let max = logits.iter().copied().fold(f32::NEG_INFINITY, f32::max) as f64;
    // Keep the original vocabulary-order f64 reduction, without retaining V
    // exponentials. Recomputing only the selected numerators is deterministic.
    let total: f64 = logits.iter().map(|&v| (v as f64 - max).exp()).sum();

    // O(V log K) comparisons and O(K) rank storage: live top-20 observation must
    // not sort and allocate an entire vocabulary on every generated token.
    let mut ranks = BinaryHeap::with_capacity(keep);
    for (id, &logit) in logits.iter().enumerate() {
        let entry = LogitRank { id, logit };
        if ranks.len() < keep {
            ranks.push(entry);
        } else if let Some(mut worst) = ranks.peek_mut() {
            if entry < *worst {
                *worst = entry;
            }
        }
    }
    ranks
        .into_sorted_vec()
        .into_iter()
        .map(|entry| {
            (
                entry.id,
                entry.logit,
                (entry.logit as f64 - max).exp() / total,
            )
        })
        .collect()
}

/// The byte offset of the earliest `stop` string in `text`, if any.
fn first_stop(text: &str, stop: &[String]) -> Option<usize> {
    stop.iter()
        .filter(|s| !s.is_empty())
        .filter_map(|s| text.find(s.as_str()))
        .min()
}

impl LoadedModel {
    /// Autoregressively generate a continuation of `prompt` (engine-native,
    /// 0-based ids). Greedy when `params.temperature <= 0` — the path the
    /// goldens pin token-for-token — otherwise temperature + nucleus sampling on
    /// the CPU (§7). The prompt itself must fit the context window (else
    /// [`RebirthError::ContextOverflow`]); running out of window mid-generation is
    /// a graceful stop, not an error.
    pub fn generate(
        &self,
        prompt: &[i32],
        params: &GenerateParams,
    ) -> Result<Generation, RebirthError> {
        let _native = crate::domain::NativeGuard::try_acquire("generate")?;
        self.generate_inner(prompt, params, None)
    }

    pub(crate) fn generate_inner(
        &self,
        prompt: &[i32],
        params: &GenerateParams,
        observer: Option<&mut crate::live_capture::LiveObserver<'_>>,
    ) -> Result<Generation, RebirthError> {
        self.check_fits(prompt.len())?;
        if params.max_tokens == 0 {
            return Ok(Generation {
                tokens: Vec::new(),
                text: String::new(),
                stop_reason: StopReason::MaxTokens,
                seed: params.seed,
            });
        }
        if prompt.is_empty() {
            return Err(RebirthError::Generation {
                reason: "empty_prompt".to_string(),
            });
        }
        let n_vocab = self.n_vocab_checked()?;

        // Ingest the prompt in n_batch-sized chunks and take its final-position
        // logits — the shared path with next_token_logits, which also handles the
        // prompt-longer-than-one-batch split. This row is the first sampling step's
        // next-token distribution.
        let logits = self.prompt_last_logits(prompt, n_vocab)?;
        self.continue_generation_observed(logits, prompt.len() as i32, params, None, observer)
    }

    /// The autoregressive sampler loop: from `logits` (the ingested prompt's
    /// final next-token distribution) sample/argmax, decode one continuation
    /// token at a time starting at position `start_pos`, and stop on
    /// EOS/stop-string/window-full/`max_tokens`. Extracted verbatim from
    /// [`generate`](Self::generate) so the multimodal ingest (vision.rs) can
    /// continue with the EXISTING loop from the position
    /// `mtmd_helper_eval_chunks` reports — the text path's behavior is
    /// byte-identical (same code, same order of operations).
    pub(crate) fn continue_generation(
        &self,
        logits: Vec<f32>,
        start_pos: i32,
        params: &GenerateParams,
    ) -> Result<Generation, RebirthError> {
        self.continue_generation_with_constraint(logits, start_pos, params, None)
    }

    fn continue_generation_with_constraint(
        &self,
        logits: Vec<f32>,
        start_pos: i32,
        params: &GenerateParams,
        constraint: Option<&mut Constraint<'_, '_>>,
    ) -> Result<Generation, RebirthError> {
        self.continue_generation_observed(logits, start_pos, params, constraint, None)
    }

    fn continue_generation_observed(
        &self,
        mut logits: Vec<f32>,
        start_pos: i32,
        params: &GenerateParams,
        mut constraint: Option<&mut Constraint<'_, '_>>,
        mut observer: Option<&mut crate::live_capture::LiveObserver<'_>>,
    ) -> Result<Generation, RebirthError> {
        let ctx_len = self.context_length() as usize;
        let vocab = self.vocab_ptr();
        let n_vocab = self.n_vocab_checked()?;
        let mut rng = SplitMix64::new(params.seed);
        let mut out: Vec<i32> = Vec::with_capacity(params.max_tokens);
        let mut stop_reason = StopReason::MaxTokens;
        // One bounded current text snapshot; token ids and the final result use
        // the same sampler/detokenizer as sync. No unbounded event queue.
        let mut async_text = None;
        let mut stream_add_space = false;
        let mut stream = if crate::async_job::streaming() {
            let structured = constraint.is_some();
            let (add_space, clean_spaces) = if !structured && self.has_tokenizer() {
                crate::text_stream::decoder_flags(vocab)
            } else {
                (false, false)
            };
            stream_add_space = add_space;
            Some(crate::text_stream::TextStream::new(
                clean_spaces,
                structured,
                crate::async_job::output_remaining()
                    .ok_or_else(|| crate::async_job::stream_error("invariant"))?,
                &params.stop,
            ))
        } else {
            None
        };

        // `n_past` is the position the next continuation token occupies: the
        // prompt filled 0..start_pos, so continuation i lands at start_pos + i.
        for n_past in (start_pos..).take(params.max_tokens) {
            crate::async_job::checkpoint()?;
            if let Some(state) = constraint.as_deref_mut() {
                if n_past as usize >= ctx_len {
                    return Err(state.error("context budget exhausted", out.len()));
                }
                state.mask(&mut logits, out.len(), params.temperature <= 0.0)?;
            }
            let next = if params.temperature <= 0.0 {
                argmax(&logits)
            } else {
                sample(&logits, params.temperature, params.top_p, &mut rng)
            } as i32;

            if let Some(state) = constraint.as_deref_mut() {
                if !logits[next as usize].is_finite() {
                    return Err(state.error("sampler selected an inadmissible token", out.len()));
                }
            }

            // SAFETY: `vocab` is live for the model's lifetime; `next` is an id in
            // `[0, n_vocab)` (argmax/sample index into a vocab-width row).
            if unsafe { ffi::llama_vocab_is_eog(vocab, next) } {
                if let Some(state) = constraint.as_deref_mut() {
                    return Err(
                        state.error("unexpected end-of-generation before completion", out.len())
                    );
                }
                stop_reason = StopReason::EndOfGeneration;
                break;
            }
            out.push(next);
            crate::async_job::sampled(out.len())?;
            if let Some(observer) = observer.as_deref_mut() {
                let snapshot = self
                    .live_capture()
                    .snapshot(out.len(), next, n_past as u32)?;
                observer(snapshot, &logits)?;
                self.live_capture()
                    .advance(n_past as u32, out.len() == params.max_tokens)?;
                crate::async_job::checkpoint()?;
            }
            if stream.is_some() {
                crate::async_job::stream_token(next, out.len())?;
            }
            if crate::async_job::output_remaining().is_some() && self.has_tokenizer() {
                // Bound every intermediate output before allocating the next
                // result; includes stop suffixes and invalid UTF-8 replacement.
                async_text = Some(self.decode_tokens(&out, false, false)?);
            }

            if let Some(state) = constraint.as_deref_mut() {
                state.accept(next, out.len())?;
                let remaining = STRUCTURED_MAX_OUTPUT_BYTES - state.bytes.len();
                let piece = self
                    .token_piece_bounded(next, remaining, 0)
                    .map_err(|why| state.error(why, out.len()))?;
                state.bytes.extend_from_slice(&piece);
                if let Some(text) = state.complete(out.len())? {
                    if let Some(stream) = &stream {
                        crate::async_job::stream_text(stream.finish(&text)?)?;
                    }
                    return Ok(Generation {
                        tokens: out,
                        text,
                        stop_reason: StopReason::EndOfGeneration,
                        seed: params.seed,
                    });
                }
                if let Some(stream) = &mut stream {
                    crate::async_job::stream_text(stream.push(&piece)?)?;
                }
                if state.bytes.len() == STRUCTURED_MAX_OUTPUT_BYTES {
                    return Err(state.error("output byte budget exhausted", out.len()));
                }
                // Completion on the last allowed token succeeds above; an
                // unfinished object fails without an unnecessary decode.
                if out.len() == params.max_tokens {
                    return Err(state.error("token budget exhausted", out.len()));
                }
            }

            if !params.stop.is_empty() && self.has_tokenizer() {
                let text = match &async_text {
                    Some(text) => text.clone(),
                    None => self.decode_tokens(&out, false, false)?,
                };
                if let Some(cut) = first_stop(&text, &params.stop) {
                    if let Some(stream) = &stream {
                        crate::async_job::stream_text(stream.finish(&text[..cut])?)?;
                    }
                    return Ok(Generation {
                        tokens: out,
                        text: text[..cut].to_string(),
                        stop_reason: StopReason::StopString,
                        seed: params.seed,
                    });
                }
            }

            // Keep the existing whole-snapshot stop timing above, including
            // provisional lossy replacements. Only then publish stable bytes.
            if constraint.is_none() && self.has_tokenizer() {
                if let Some(stream) = &mut stream {
                    let limit = crate::async_job::output_remaining()
                        .ok_or_else(|| crate::async_job::stream_error("invariant"))?;
                    let lstrip = i32::from(stream_add_space && out.len() == 1);
                    let piece = self
                        .token_piece_bounded(next, limit, lstrip)
                        .map_err(|why| {
                            if why == "output byte budget exhausted" {
                                crate::async_job::output_budget_error(limit.saturating_add(1))
                            } else {
                                crate::async_job::stream_error("invariant")
                            }
                        })?;
                    crate::async_job::stream_text(stream.push(&piece)?)?;
                }
            }

            // No room to place another token? Stop before an out-of-range decode.
            if n_past as usize >= ctx_len {
                stop_reason = StopReason::ContextFull;
                break;
            }
            // One continuation token, decoded at its own position n_past into the
            // accumulated KV cache (not a fresh position-0 ingest, so this is a
            // direct single-batch decode — trivially within n_batch — not a
            // decode_chunked call). Its logits land at output slot 0.
            self.decode(&[next], n_past, true)?;
            crate::async_job::checkpoint()?;
            logits = self.logits_ith(0, n_vocab)?;
        }

        if let Some(state) = constraint {
            return Err(state.error(
                format!("{} before JSON completion", stop_reason.as_str()),
                out.len(),
            ));
        }

        // Detokenize the continuation only when the model carries a tokenizer;
        // the numeric synthetic test model has a vocabulary but no tokenizer, so
        // it produces token ids with no text form.
        let text = if let Some(text) = async_text {
            text
        } else if self.has_tokenizer() {
            self.decode_tokens(&out, false, false)?
        } else {
            String::new()
        };
        if let Some(stream) = &stream {
            crate::async_job::stream_text(stream.finish(&text)?)?;
        }
        Ok(Generation {
            tokens: out,
            text,
            stop_reason,
            seed: params.seed,
        })
    }

    /// Generate a continuation of a text `prompt`. When `chat`, the prompt is
    /// wrapped as a user turn with the model's chat template; otherwise it is a
    /// raw completion. Tokenization mirrors llama.cpp's own usage: a templated
    /// prompt is always parsed for special tokens; whether the tokenizer ALSO adds
    /// the model's BOS is decided by the template source — an embedded Jinja
    /// template bakes its own BOS in (`add_special = false`), while the D-021
    /// builtin fallback omits it (`add_special = true`), both carried on the
    /// returned [`TemplatedPrompt`]. A raw completion adds the model's default
    /// special tokens. Requires a tokenizer (the synthetic model has none — its
    /// generation is driven by ids through [`generate`](Self::generate)).
    pub fn generate_prompt(
        &self,
        prompt: &str,
        chat: bool,
        params: &GenerateParams,
    ) -> Result<Generation, RebirthError> {
        let _native = crate::domain::NativeGuard::try_acquire("generate_prompt")?;
        self.require_tokenizer()?;
        let (text, add_special, parse_special) = self.resolve_prompt_text(prompt, chat)?;
        let prompt_ids = self.tokenize(&text, add_special, parse_special)?;
        self.generate(&prompt_ids, params)
    }

    /// Generate under a precompiled schema, with fresh grammar state per prompt.
    /// This shares the ordinary prompt ingest and continuation sampler.
    pub fn generate_prompts_structured(
        &self,
        prompts: &[String],
        chat: bool,
        params: &GenerateParams,
        schema: &CompiledSchema,
    ) -> Result<Vec<Generation>, RebirthError> {
        let _native = crate::domain::NativeGuard::try_acquire("generate_prompts_structured")?;
        if prompts.is_empty()
            || prompts.len() > STRUCTURED_MAX_PROMPTS
            || prompts
                .iter()
                .any(|p| p.len() > STRUCTURED_MAX_PROMPT_BYTES)
            || prompts.iter().map(String::len).sum::<usize>() > STRUCTURED_MAX_TOTAL_PROMPT_BYTES
        {
            return Err(RebirthError::Schema {
                reason: "prompt budget exceeded".into(),
                schema_path: String::new(),
            });
        }
        self.require_tokenizer()?;
        let template = Grammar::new(self, schema)?;
        let mut output = Vec::with_capacity(prompts.len());
        let mut bytes = 0;
        for (i, prompt) in prompts.iter().enumerate() {
            crate::async_job::prompt_started(i + 1)?;
            let mut state = Constraint::new(&template, schema, i + 1, params)?;
            let generation = self.generate_prompt_constrained(prompt, chat, params, &mut state)?;
            if generation.text.len() > STRUCTURED_MAX_TOTAL_OUTPUT_BYTES - bytes {
                return Err(
                    state.error("call output byte budget exceeded", generation.tokens.len())
                );
            }
            bytes += generation.text.len();
            crate::async_job::prompt_completed(generation.text.len())?;
            crate::async_job::stream_prompt_end(generation.stop_reason.as_str())?;
            output.push(generation);
        }
        Ok(output)
    }

    fn generate_prompt_constrained(
        &self,
        prompt: &str,
        chat: bool,
        params: &GenerateParams,
        state: &mut Constraint<'_, '_>,
    ) -> Result<Generation, RebirthError> {
        let (text, add_special, parse_special) =
            self.resolve_prompt_text_for_output(prompt, chat, true)?;
        // A chat template may expand user text; reject before tokenizing a large
        // expansion. The cap applies to the materialized native prompt too.
        if text.len() > STRUCTURED_MAX_PROMPT_BYTES {
            return Err(state.error("templated prompt byte budget exceeded", 0));
        }
        let ids = self.tokenize(&text, add_special, parse_special)?;
        self.check_fits(ids.len())?;
        if ids.is_empty() {
            return Err(state.error("empty tokenized prompt", 0));
        }
        let n_vocab = self.n_vocab_checked()?;
        let logits = self.prompt_last_logits(&ids, n_vocab)?;
        self.continue_generation_with_constraint(logits, ids.len() as i32, params, Some(state))
    }

    /// Assemble actual token bytes without lossy UTF-8 conversion. A token can
    /// end inside a code point; validation happens only at grammar completion.
    fn token_piece_bounded(
        &self,
        id: i32,
        remaining: usize,
        lstrip: i32,
    ) -> Result<Vec<u8>, &'static str> {
        let mut bytes = vec![0u8; remaining.min(32)];
        loop {
            // SAFETY: id came from this vocabulary's masked candidates; the
            // engine writes at most the supplied slice length, or returns -size.
            let n = unsafe {
                ffi::llama_token_to_piece(
                    self.vocab_ptr(),
                    id,
                    bytes.as_mut_ptr().cast::<c_char>(),
                    bytes.len() as i32,
                    lstrip,
                    false,
                )
            };
            if n >= 0 {
                if n as usize > bytes.len() {
                    return Err("invalid native token piece length");
                }
                bytes.truncate(n as usize);
                return Ok(bytes);
            }
            let need = n.checked_neg().ok_or("invalid native token piece length")? as usize;
            if need > remaining {
                return Err("output byte budget exhausted");
            }
            if need <= bytes.len() {
                return Err("invalid native token piece sizing");
            }
            // Keep capacity within the byte limit, including stream scratch.
            bytes = vec![0; need];
        }
    }

    /// Resolve a user prompt into the exact text the tokenizer receives plus
    /// its `(add_special, parse_special)` flags: the chat template (with the
    /// D-021 builtin fallback carried on [`TemplatedPrompt`]) when `chat`, the
    /// raw completion otherwise. Extracted from
    /// [`generate_prompt`](Self::generate_prompt) so the multimodal path
    /// (vision.rs) templates its marker-bearing prompt identically — one
    /// resolution, no drift.
    pub(crate) fn resolve_prompt_text(
        &self,
        prompt: &str,
        chat: bool,
    ) -> Result<(String, bool, bool), RebirthError> {
        self.resolve_prompt_text_for_output(prompt, chat, false)
    }

    /// Schema chat uses Spark's official non-thinking opener so JSON begins at
    /// the first generated token. Tokenization and prompt ingest stay shared.
    fn resolve_prompt_text_for_output(
        &self,
        prompt: &str,
        chat: bool,
        structured: bool,
    ) -> Result<(String, bool, bool), RebirthError> {
        if chat {
            let templated = self.apply_chat_template_for_output(
                &[ChatMessage::user(prompt)],
                true,
                structured,
            )?;
            Ok((templated.text, templated.add_special, true))
        } else {
            Ok((prompt.to_string(), true, false))
        }
    }
}

// --- chat templates -------------------------------------------------------

/// A chat turn: a role (`"system"` / `"user"` / `"assistant"`) and its content.
/// The R layer builds these from `llm_generate()`'s prompt (and future message
/// forms); the engine only formats them with the model's template.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChatMessage {
    pub role: String,
    pub content: String,
}

impl ChatMessage {
    /// A `user`-role message (the common case for `llm_generate(prompt)`).
    pub fn user(content: impl Into<String>) -> Self {
        ChatMessage {
            role: "user".to_string(),
            content: content.into(),
        }
    }
}

impl LoadedModel {
    /// The model's built-in chat template (the GGUF `tokenizer.chat_template`),
    /// or `None` if it carries none.
    pub fn chat_template(&self) -> Option<String> {
        let _native = crate::domain::NativeGuard::acquire("chat_template");
        // SAFETY: `model_ptr` is a live model; a non-null return is a
        // NUL-terminated string owned by the model, valid for its lifetime.
        let ptr = unsafe { ffi::llama_model_chat_template(self.model_ptr(), std::ptr::null()) };
        if ptr.is_null() {
            return None;
        }
        // SAFETY: non-null, NUL-terminated, model-owned.
        Some(
            unsafe { std::ffi::CStr::from_ptr(ptr) }
                .to_string_lossy()
                .into_owned(),
        )
    }

    /// Format `messages` with the model's own chat template, ending with the
    /// assistant-turn opener when `add_assistant`. Errors if the model carries no
    /// chat template (use `chat = FALSE` for a raw completion).
    ///
    /// The model's embedded `tokenizer.chat_template` is tried first (the common
    /// case — e.g. Qwen's chatml, which b9726 detects). If it is present but the
    /// applier cannot recognize it (some modern models' Jinja, e.g. Gemma 4's),
    /// this falls back to the architecture's builtin template (D-021); see
    /// [`resolve_and_apply_template`]. The returned [`TemplatedPrompt`] carries how
    /// the result must be tokenized (the builtin fallback omits the leading BOS).
    pub fn apply_chat_template(
        &self,
        messages: &[ChatMessage],
        add_assistant: bool,
    ) -> Result<TemplatedPrompt, RebirthError> {
        let _native = crate::domain::NativeGuard::try_acquire("apply_chat_template")?;
        self.apply_chat_template_for_output(messages, add_assistant, false)
    }

    fn apply_chat_template_for_output(
        &self,
        messages: &[ChatMessage],
        add_assistant: bool,
        structured: bool,
    ) -> Result<TemplatedPrompt, RebirthError> {
        let embedded = if crate::async_job::output_remaining().is_some() {
            // SAFETY: checked model_ptr belongs to the currently bound model;
            // template bytes are immutable and remain model-owned during copy.
            let ptr = unsafe { ffi::llama_model_chat_template(self.model_ptr(), std::ptr::null()) };
            if ptr.is_null() {
                None
            } else {
                // SAFETY: non-null template is NUL-terminated by llama.cpp.
                let bytes = unsafe { std::ffi::CStr::from_ptr(ptr) }.to_bytes();
                if lossy_utf8_len(bytes) > crate::async_job::ASYNC_MAX_ARGUMENT_BYTES {
                    return Err(RebirthError::Argument {
                        argument: "prompt".into(),
                        reason: "async model template exceeds 16 MiB".into(),
                    });
                }
                Some(lossy_utf8_exact(bytes))
            }
        } else {
            self.chat_template()
        };
        resolve_and_apply_template(
            embedded.as_deref(),
            &self.architecture(),
            messages,
            add_assistant,
            structured,
        )
    }
}

/// A chat prompt formatted for the model, plus how it must be tokenized. Embedded
/// Jinja chat templates bake in the leading BOS token (`{{ bos_token }}`), but the
/// llama.cpp builtin templates used by the D-021 fallback omit it, so a
/// builtin-formatted prompt must be tokenized with the tokenizer adding the model's
/// special tokens. Getting this wrong is not cosmetic: a Gemma prompt without its
/// BOS decodes into degenerate output (it echoes the turn markers instead of
/// answering).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TemplatedPrompt {
    /// The formatted prompt text (already carrying the turn markers).
    pub text: String,
    /// Whether the tokenizer must add the model's special tokens (BOS/EOS): `true`
    /// only when the builtin fallback was used (it omits the BOS an embedded
    /// template would carry); `false` for the embedded template, which supplies its
    /// own BOS. Consumed as `add_special` by [`LoadedModel::generate_prompt`].
    pub add_special: bool,
}

/// The llama.cpp builtin chat-template name to use when a model's own embedded
/// template is present but the applier cannot detect it, keyed on the model
/// architecture (`general.architecture`) — the D-021 fallback. Deliberately small
/// and explicit: only families whose builtin format is a settled match for the
/// arch; `None` = no known builtin, so the caller surfaces the original error
/// rather than mis-format.
///
/// The builtin names are verified present at b9726 in `src/llama-chat.cpp`'s
/// `LLM_CHAT_TEMPLATES` map: `"gemma"` (line 44), `"chatml"` (line 29), `"llama3"`
/// (line 54). The applier accepts either a builtin name or a Jinja string as its
/// first argument, so passing the name re-selects the builtin format.
fn arch_builtin_template(arch: &str) -> Option<&'static str> {
    match arch {
        // Gemma family: all share the `<start_of_turn>user\n...<end_of_turn>\n
        // <start_of_turn>model\n` builtin (LLM_CHAT_TEMPLATE_GEMMA). Gemma 4's
        // embedded Jinja is NOT detected by b9726 (its string lacks the
        // `<start_of_turn>` literal the applier keys on at llama-chat.cpp:155), so
        // this fallback is what makes chat = TRUE work for it (spike-confirmed).
        "gemma" | "gemma2" | "gemma3" | "gemma4" => Some("gemma"),
        // Qwen family: chatml (`<|im_start|>role\n...<|im_end|>`).
        "qwen2" | "qwen3" | "qwen35" => Some("chatml"),
        // Llama family: the Llama-3 header format. `general.architecture` is
        // "llama" for both Llama 2 and Llama 3 GGUFs and cannot disambiguate them;
        // this fallback only fires when the embedded template is undetectable
        // (Llama 2/3 embedded templates ARE detected today), so in practice it is
        // reached only by newer llama-arch models, for which Llama 3 is the right
        // default.
        "llama" => Some("llama3"),
        _ => None,
    }
}

/// Format `messages`, preferring the model's `embedded` chat template and falling
/// back to the architecture's builtin when the embedded one is present but the
/// applier cannot detect it (D-021). Free of any model so it is unit-testable.
///
/// - `embedded` present and applies cleanly → used unchanged (the common path;
///   Qwen's chatml is detected today, so its formatting is untouched), with
///   `add_special = false` (an embedded Jinja template carries its own BOS).
/// - `embedded` present but the applier rejects it (returns < 0) → retry with
///   [`arch_builtin_template`]`(arch)`; on success return `add_special = true` (the
///   builtin omits the BOS, so the tokenizer must add it). If there is no mapping
///   or the builtin also fails, surface the original classed error — never a silent
///   mis-format.
/// - `embedded` absent (`None`) → the model declares no chat contract; error with
///   the same "use chat = FALSE" message as before (a builtin fallback here would
///   format a base model that intentionally carries no template).
/// - Spark's two pinned official template spellings use the narrow D-032
///   single-user-turn formatter. Unknown Spark templates fail explicitly.
fn resolve_and_apply_template(
    embedded: Option<&str>,
    arch: &str,
    messages: &[ChatMessage],
    add_assistant: bool,
    structured: bool,
) -> Result<TemplatedPrompt, RebirthError> {
    let Some(tmpl) = embedded else {
        return Err(RebirthError::Generation {
            reason: "the model carries no chat template; use chat = FALSE".to_string(),
        });
    };
    if arch == "spark2_5" {
        return apply_spark_template(tmpl, messages, add_assistant, structured);
    }
    match apply_template(tmpl, messages, add_assistant) {
        Ok(text) => Ok(TemplatedPrompt {
            text,
            add_special: false,
        }),
        Err(embedded_err) => match arch_builtin_template(arch) {
            Some(builtin) => apply_template(builtin, messages, add_assistant)
                .map(|text| TemplatedPrompt {
                    text,
                    add_special: true,
                })
                .map_err(|_| embedded_err),
            None => Err(embedded_err),
        },
    }
}

// The author ships both a standalone Jinja file and a compact tokenizer-config
// spelling at revision 0bcb35678590218655dff3765b9e61c83b35e9c4. The model's
// embedded template must match one in full; marker detection would silently
// overwrite custom formatting. These source fixtures ship in the R tarball.
const SPARK_CHAT_TEMPLATE: &str = include_str!("../tests/fixtures/spark/chat_template.jinja");
const SPARK_TOKENIZER_TEMPLATE: &str =
    include_str!("../tests/fixtures/spark/tokenizer-chat-template.jinja");

fn apply_spark_template(
    template: &str,
    messages: &[ChatMessage],
    add_assistant: bool,
    structured: bool,
) -> Result<TemplatedPrompt, RebirthError> {
    if template.as_bytes().contains(&0)
        || messages
            .iter()
            .any(|m| m.role.as_bytes().contains(&0) || m.content.as_bytes().contains(&0))
    {
        return Err(RebirthError::Generation {
            reason: "a chat message or template contains an interior NUL byte".to_string(),
        });
    }
    if template != SPARK_CHAT_TEMPLATE && template != SPARK_TOKENIZER_TEMPLATE {
        return Err(RebirthError::Generation {
            reason: "the Spark chat template does not match a supported official template; use chat = FALSE for custom formatting".to_string(),
        });
    }
    let [message] = messages else {
        return Err(RebirthError::Generation {
            reason: "Spark chat formatting supports exactly one user message".to_string(),
        });
    };
    if message.role != "user" {
        return Err(RebirthError::Generation {
            reason: "Spark chat formatting supports exactly one user message".to_string(),
        });
    }
    // Independent Jinja-rendered fixtures pin capitalization, line endings,
    // turn markers, whitespace preservation and both official thinking modes.
    let mut text = String::from(concat!(
        "<｜start▁of▁sentence｜><|System|>\nyou are a helpful assistant.",
        "<｜end▁of▁sentence｜><｜start▁of▁sentence｜><|User|>"
    ));
    text.push_str(&message.content);
    text.push_str("<｜end▁of▁sentence｜>");
    if add_assistant {
        text.push_str("<｜start▁of▁sentence｜><|Bot|>");
        text.push_str(if structured { "</think>" } else { "<think>" });
    }
    Ok(TemplatedPrompt {
        text,
        // The official format carries the BOS turn markers itself. The caller
        // still parses special tokens; it must not prepend another BOS.
        add_special: false,
    })
}

/// Format `messages` with an explicit llama.cpp template string. Free of any
/// model so it is unit-testable; [`LoadedModel::apply_chat_template`] supplies
/// the model's own template. `tmpl` must be one of the templates llama.cpp
/// recognizes (it is not a general Jinja engine), else this errors.
fn apply_template(
    tmpl: &str,
    messages: &[ChatMessage],
    add_assistant: bool,
) -> Result<String, RebirthError> {
    let _native = crate::domain::NativeGuard::try_acquire("chat formatting")?;
    use std::ffi::CString;

    let nul = |_| RebirthError::Generation {
        reason: "a chat message or template contains an interior NUL byte".to_string(),
    };
    let tmpl_c = CString::new(tmpl).map_err(nul)?;
    // The C `llama_chat_message` array borrows these CStrings, so they must
    // outlive the call — keep them owned here for the whole function.
    let owned: Vec<(CString, CString)> = messages
        .iter()
        .map(|m| {
            Ok((
                CString::new(m.role.as_str())?,
                CString::new(m.content.as_str())?,
            ))
        })
        .collect::<Result<_, std::ffi::NulError>>()
        .map_err(nul)?;
    let chat: Vec<ffi::llama_chat_message> = owned
        .iter()
        .map(|(r, c)| ffi::llama_chat_message {
            role: r.as_ptr(),
            content: c.as_ptr(),
        })
        .collect();

    // Two-pass sizing: the docs recommend ~2x the message bytes; a return larger
    // than the buffer is the exact length to re-allocate to.
    let msg_bytes: usize = messages
        .iter()
        .map(|m| m.role.len() + m.content.len())
        .sum();
    let mut cap = (msg_bytes * 2 + 64).max(256);
    loop {
        if crate::async_job::output_remaining().is_some()
            && cap > crate::async_job::ASYNC_MAX_ARGUMENT_BYTES
        {
            return Err(RebirthError::Argument {
                argument: "prompt".into(),
                reason: "async templated prompt exceeds 16 MiB".into(),
            });
        }
        let mut buf = vec![0u8; cap];
        // SAFETY: `tmpl_c` and the CStrings behind `chat` outlive the call;
        // `buf`/`cap` are consistent; the engine writes at most `cap` bytes.
        let n = unsafe {
            ffi::llama_chat_apply_template(
                tmpl_c.as_ptr(),
                chat.as_ptr(),
                chat.len(),
                add_assistant,
                buf.as_mut_ptr().cast::<c_char>(),
                cap as i32,
            )
        };
        if n < 0 {
            return Err(RebirthError::Generation {
                reason: format!(
                    "llama_chat_apply_template failed ({n}); the model's template may be unsupported"
                ),
            });
        }
        let n = n as usize;
        if n > cap {
            cap = n;
            continue;
        }
        buf.truncate(n);
        if crate::async_job::output_remaining().is_some() {
            if lossy_utf8_len(&buf) > crate::async_job::ASYNC_MAX_ARGUMENT_BYTES {
                return Err(RebirthError::Argument {
                    argument: "prompt".into(),
                    reason: "async templated prompt exceeds 16 MiB".into(),
                });
            }
            return Ok(lossy_utf8_exact(&buf));
        }
        return Ok(String::from_utf8_lossy(&buf).into_owned());
    }
}

#[cfg(test)]
mod tests {
    // Rust PR job; no model. Enforces the actual retained UTF-8 result bound,
    // including lossy expansion before a String is allocated.
    #[test]
    fn async_output_sizing_rejects_before_allocating_over_budget() {
        assert_eq!(super::lossy_utf8_len(b"hello"), 5);
        assert_eq!(super::lossy_utf8_len(&[0xff, 0xfe]), 6);
        assert_eq!(super::lossy_utf8_len(&[0xe2, 0x82]), 3);
        for bytes in [
            b"valid".as_slice(),
            &[0xff, 0xfe],
            &[0xe2, 0x82],
            &[b'a', 0xff, b'b'],
        ] {
            let text = super::lossy_utf8_exact(bytes);
            assert_eq!(text, String::from_utf8_lossy(bytes));
            assert_eq!(
                text.capacity(),
                text.len(),
                "bounded String must not grow geometrically"
            );
        }
        let result = super::bounded_output_buffer(8, 10, |_, _| -11);
        assert!(matches!(result, Err(crate::RebirthError::Oom { .. })));
        let result = super::bounded_output_buffer(8, 10, |_, _| i32::MIN);
        assert!(matches!(result, Err(crate::RebirthError::Internal { .. })));
        let result = super::bounded_output_buffer(2, 2, |ptr, _| {
            // SAFETY: the bounded helper supplied exactly two writable bytes.
            unsafe {
                *ptr = 0xff;
                *ptr.add(1) = 0xfe;
            }
            2
        });
        assert!(matches!(result, Err(crate::RebirthError::Oom { .. })));
        let exact = super::bounded_output_buffer(2, 2, |ptr, _| {
            // SAFETY: the bounded helper supplied exactly two writable bytes.
            unsafe {
                *ptr = b'o';
                *ptr.add(1) = b'k';
            }
            2
        })
        .unwrap();
        assert_eq!(exact, b"ok");
    }

    // CI: pinned-model nightly after its checksum gate; ordinary cargo jobs have
    // no model and skip this fixture. Controlled logits isolate context/grammar
    // boundaries without relying on the model to prefer a particular answer.
    #[test]
    fn structured_context_boundary_and_masked_sampling_model() {
        let Ok(path) = std::env::var("RELM_TEST_MODEL_QWEN") else {
            return;
        };
        let _native = crate::NativeGuard::try_acquire("structured test").unwrap();
        let model = crate::load(crate::LoadRequest {
            path: path.into(),
            context_length: 64,
            gpu_layers: None,
            backend: crate::BackendKind::Cpu,
            mmap: true,
            projector: None,
        })
        .unwrap();
        let schema = crate::CompiledSchema::compile(
            r#"{"type":"object","properties":{},"required":[],"additionalProperties":false}"#,
        )
        .unwrap();
        let template = crate::structured::Grammar::new(&model, &schema).unwrap();
        let params = super::GenerateParams {
            max_tokens: 1,
            temperature: 0.0,
            top_p: 1.0,
            seed: 123,
            stop: Vec::new(),
        };
        let ids = model.tokenize("{}", false, false).unwrap();
        assert_eq!(
            ids.len(),
            1,
            "pinned Qwen fixture must encode {{}} as one token"
        );
        let mut logits = vec![f32::NEG_INFINITY; model.n_vocab_checked().unwrap()];
        logits[ids[0] as usize] = 0.0;
        // Both paths must identify the same argmax, including logit ties. The
        // full mask is also the probability-preserving path for sampling.
        for tied in [false, true] {
            let mut full_logits: Vec<f32> = (0..model.n_vocab_checked().unwrap())
                .map(|i| {
                    if tied {
                        if i % 2 == 0 {
                            -0.0
                        } else {
                            0.0
                        }
                    } else {
                        ((i * 17) % 997) as f32
                    }
                })
                .collect();
            let mut greedy_logits = full_logits.clone();
            let mut full_mask =
                crate::structured::Constraint::new(&template, &schema, 1, &params).unwrap();
            let mut greedy_mask =
                crate::structured::Constraint::new(&template, &schema, 1, &params).unwrap();
            full_mask.mask(&mut full_logits, 0, false).unwrap();
            greedy_mask.mask(&mut greedy_logits, 0, true).unwrap();
            assert_eq!(super::argmax(&full_logits), super::argmax(&greedy_logits));
        }
        let context = model.context_length() as i32;
        let mut full = crate::structured::Constraint::new(&template, &schema, 1, &params).unwrap();
        let error = model
            .continue_generation_with_constraint(logits.clone(), context, &params, Some(&mut full))
            .unwrap_err();
        assert!(matches!(error, crate::RebirthError::StructuredOutput {
            generated_tokens: 0, partial_bytes, .. } if partial_bytes.is_empty()));
        let mut last = crate::structured::Constraint::new(&template, &schema, 1, &params).unwrap();
        let output = model
            .continue_generation_with_constraint(logits, context - 1, &params, Some(&mut last))
            .unwrap();
        assert_eq!(output.text, "{}");
        assert_eq!(output.tokens.len(), 1); // Last context position AND token budget.
        let mut masked =
            crate::structured::Constraint::new(&template, &schema, 1, &params).unwrap();
        let logits = vec![f32::NEG_INFINITY; model.n_vocab_checked().unwrap()];
        let error = model
            .continue_generation_with_constraint(logits, 0, &params, Some(&mut masked))
            .unwrap_err();
        assert!(
            matches!(error, crate::RebirthError::StructuredOutput { reason, generated_tokens: 0, .. }
            if reason == "no admissible token")
        );
    }

    use super::{
        apply_template, arch_builtin_template, resolve_and_apply_template, top_k_logits,
        ChatMessage, RebirthError, SPARK_CHAT_TEMPLATE, SPARK_TOKENIZER_TEMPLATE,
    };

    // Model-free, runs in the ordinary macOS/Linux cargo PR jobs. Expected
    // bytes were rendered independently by Jinja2 from both immutable official
    // template sources, never by this Rust formatter.
    #[test]
    fn spark_templates_match_official_single_user_turn_fixtures() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../tests/fixtures/spark/single-user-turn.json"
        ))
        .unwrap();
        let cases = fixture["cases"].as_array().unwrap();
        assert_eq!(cases.len(), 10);
        for template in [SPARK_CHAT_TEMPLATE, SPARK_TOKENIZER_TEMPLATE] {
            for case in cases {
                let prompt = case["prompt"].as_str().unwrap();
                let add_assistant = case["add_assistant"].as_bool().unwrap();
                let structured = case["structured"].as_bool().unwrap();
                let formatted = resolve_and_apply_template(
                    Some(template),
                    "spark2_5",
                    &[ChatMessage::user(prompt)],
                    add_assistant,
                    structured,
                )
                .unwrap();
                assert_eq!(
                    formatted.text.as_bytes(),
                    case["rendered"].as_str().unwrap().as_bytes(),
                    "fixture {}",
                    case["name"]
                );
                assert!(!formatted.add_special, "the tokenizer must not add a BOS");
                assert!(formatted.text.starts_with(
                    "<｜start▁of▁sentence｜><|System|>\nyou are a helpful assistant."
                ));
                assert_eq!(
                    formatted.text.matches("<｜start▁of▁sentence｜>").count(),
                    if add_assistant { 3 } else { 2 },
                    "exactly one start marker per official turn"
                );
            }
        }
    }

    #[test]
    fn spark_rejects_missing_modified_and_unknown_templates() {
        let changed_system = SPARK_CHAT_TEMPLATE.replace(
            "you are a helpful assistant.",
            "You are a helpful assistant.",
        );
        let changed_control = SPARK_CHAT_TEMPLATE.replace("default(true)", "default(false)");
        let trailing_byte = format!("{SPARK_CHAT_TEMPLATE} ");
        for template in [
            None,
            Some(""),
            Some("chatml"),
            Some("<｜start▁of▁sentence｜><|Bot|><think>"),
            Some(changed_system.as_str()),
            Some(changed_control.as_str()),
            Some(trailing_byte.as_str()),
        ] {
            for structured in [false, true] {
                let error = resolve_and_apply_template(
                    template,
                    "spark2_5",
                    &[ChatMessage::user("Hello.")],
                    true,
                    structured,
                )
                .unwrap_err();
                assert!(matches!(error, RebirthError::Generation { reason }
                    if reason.contains("template") && reason.contains("chat = FALSE")));
            }
        }
    }

    #[test]
    fn spark_rejects_unsupported_message_shapes_and_nul_bytes() {
        for messages in [
            Vec::new(),
            vec![ChatMessage::user("One"), ChatMessage::user("Two")],
            vec![ChatMessage {
                role: "system".into(),
                content: "Policy".into(),
            }],
            vec![ChatMessage {
                role: "assistant".into(),
                content: "Answer".into(),
            }],
            vec![ChatMessage {
                role: "tool".into(),
                content: "Result".into(),
            }],
            vec![ChatMessage {
                role: "unknown".into(),
                content: "Text".into(),
            }],
        ] {
            let error = resolve_and_apply_template(
                Some(SPARK_CHAT_TEMPLATE),
                "spark2_5",
                &messages,
                true,
                false,
            )
            .unwrap_err();
            assert!(matches!(error, RebirthError::Generation { reason }
                if reason.contains("exactly one user message")));
        }
        for (template, message) in [
            (
                format!("{SPARK_CHAT_TEMPLATE}\0"),
                ChatMessage::user("Hello."),
            ),
            (
                SPARK_CHAT_TEMPLATE.to_string(),
                ChatMessage::user("Hello\0world"),
            ),
            (
                SPARK_CHAT_TEMPLATE.to_string(),
                ChatMessage {
                    role: "user\0".into(),
                    content: "Hello.".into(),
                },
            ),
        ] {
            let error =
                resolve_and_apply_template(Some(&template), "spark2_5", &[message], true, true)
                    .unwrap_err();
            assert!(matches!(error, RebirthError::Generation { reason } if reason.contains("NUL")));
        }
    }

    #[test]
    fn structured_formatting_preserves_non_spark_embedded_and_fallback_behavior() {
        for (template, architecture) in [("chatml", "qwen2"), ("unsupported", "gemma4")] {
            let messages = [ChatMessage::user("Unicode: café 😀\n")];
            let ordinary =
                resolve_and_apply_template(Some(template), architecture, &messages, true, false)
                    .unwrap();
            let structured =
                resolve_and_apply_template(Some(template), architecture, &messages, true, true)
                    .unwrap();
            assert_eq!(ordinary, structured);
        }
    }

    // [MODEL] RELM_TEST_MODEL_SPARK points to the checksummed D-032 GGUF.
    // Runs locally and in the opt-in Spark CPU job, never downloads in PR CI.
    // No inference: validates the real vocabulary and shared prompt flags.
    #[test]
    fn spark_loaded_model_matches_official_prompt_bytes_and_special_token_ids() {
        let Ok(path) = std::env::var("RELM_TEST_MODEL_SPARK") else {
            eprintln!("[MODEL] skipped: RELM_TEST_MODEL_SPARK is not set");
            return;
        };
        let model = crate::load(crate::LoadRequest {
            path: path.into(),
            context_length: 512,
            gpu_layers: None,
            backend: crate::BackendKind::Cpu,
            mmap: true,
            projector: None,
        })
        .unwrap();
        assert_eq!(model.architecture(), "spark2_5");
        assert_eq!(model.chat_template().as_deref(), Some(SPARK_CHAT_TEMPLATE));
        assert_eq!(
            model
                .encode("<｜start▁of▁sentence｜>", false, true)
                .unwrap()
                .ids,
            [0]
        );
        assert_eq!(
            model
                .encode("<｜end▁of▁sentence｜>", false, true)
                .unwrap()
                .ids,
            [1]
        );
        assert_eq!(
            model.encode("<think></think>", false, true).unwrap().ids,
            [3, 4]
        );
        assert_eq!(
            model.decode_tokens(&[3, 4], false, false).unwrap(),
            "<think></think>"
        );

        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../tests/fixtures/spark/single-user-turn.json"
        ))
        .unwrap();
        for case in fixture["cases"].as_array().unwrap() {
            if !case["add_assistant"].as_bool().unwrap() {
                continue;
            }
            let structured = case["structured"].as_bool().unwrap();
            let prompt = case["prompt"].as_str().unwrap();
            let (text, add_special, parse_special) = model
                .resolve_prompt_text_for_output(prompt, true, structured)
                .unwrap();
            assert_eq!(text, case["rendered"].as_str().unwrap());
            assert!(!add_special);
            assert!(parse_special);
            let ids = model.tokenize(&text, add_special, parse_special).unwrap();
            let reference_ids = model
                .encode(case["rendered"].as_str().unwrap(), false, true)
                .unwrap()
                .ids;
            assert_eq!(ids, reference_ids);
            assert_eq!(ids.first(), Some(&0));
            assert_eq!(ids.iter().filter(|&&id| id == 0).count(), 3);
            assert_eq!(ids.iter().filter(|&&id| id == 1).count(), 2);
            assert_eq!(ids.last(), Some(if structured { &4 } else { &3 }));
            if !structured {
                assert_eq!(
                    model.resolve_prompt_text(prompt, true).unwrap(),
                    (text, false, true)
                );
            }
        }
        let raw = "<｜start▁of▁sentence｜>Raw completion.";
        for structured in [false, true] {
            let (text, add_special, parse_special) = model
                .resolve_prompt_text_for_output(raw, false, structured)
                .unwrap();
            assert_eq!(
                (text.as_str(), add_special, parse_special),
                (raw, true, false)
            );
            let ids = model.tokenize(&text, add_special, parse_special).unwrap();
            assert_eq!(ids, model.encode(raw, true, false).unwrap().ids);
            assert!(
                !ids.contains(&0),
                "raw completion must not parse a literal BOS marker"
            );
        }
    }

    #[test]
    fn top_k_logits_orders_by_descending_logit_with_full_vocab_softmax() {
        // Deliberately unsorted input; ids as (0-based) positions.
        let logits = [0.0f32, 3.0, 1.0, 2.0, -1.0];
        let picks = top_k_logits(&logits, 3);
        // Rank order by descending logit: id 1 (3.0), id 3 (2.0), id 2 (1.0).
        let ids: Vec<usize> = picks.iter().map(|&(i, _, _)| i).collect();
        assert_eq!(ids, vec![1, 3, 2]);
        // Logits carried through verbatim, in rank order.
        let ls: Vec<f32> = picks.iter().map(|&(_, l, _)| l).collect();
        assert_eq!(ls, vec![3.0, 2.0, 1.0]);

        // Probabilities are the softmax over the WHOLE row (not the top-3), so they
        // match a full-row softmax and sum to < 1 (mass sits in the dropped tail).
        let max = logits.iter().copied().fold(f32::NEG_INFINITY, f32::max) as f64;
        let denom: f64 = logits.iter().map(|&v| (v as f64 - max).exp()).sum();
        for &(i, _, p) in &picks {
            let want = (logits[i] as f64 - max).exp() / denom;
            assert!((p - want).abs() < 1e-12, "prob[{i}] {p} vs {want}");
        }
        let kept_mass: f64 = picks.iter().map(|&(_, _, p)| p).sum();
        assert!(
            kept_mass < 1.0,
            "top-3 mass {kept_mass} must exclude the tail"
        );
    }

    #[test]
    fn top_k_logits_breaks_ties_by_ascending_id_and_clamps_top() {
        // Three tied top logits: ascending id resolves the order deterministically.
        let logits = [5.0f32, 5.0, 5.0, 1.0];
        let picks = top_k_logits(&logits, 2);
        let ids: Vec<usize> = picks.iter().map(|&(i, _, _)| i).collect();
        assert_eq!(ids, vec![0, 1], "ties resolve to the lowest ids");

        // `top` beyond the vocabulary is clamped to the row length (no panic, no pad).
        let all = top_k_logits(&logits, 999);
        assert_eq!(all.len(), 4);
        // `top = 0` yields nothing.
        assert!(top_k_logits(&logits, 0).is_empty());
    }

    /// Download-free Rust CI. Literal pre-F6a full-sort implementation is the
    /// independent algorithmic comparator; oracle tests separately pin numerics.
    #[test]
    fn top_k_heap_matches_full_sort_bits_and_boundaries() {
        fn reference(logits: &[f32], top: usize) -> Vec<(usize, f32, f64)> {
            if top.min(logits.len()) == 0 {
                return Vec::new();
            }
            let max = logits.iter().copied().fold(f32::NEG_INFINITY, f32::max) as f64;
            let exps: Vec<f64> = logits.iter().map(|&v| (v as f64 - max).exp()).collect();
            let total: f64 = exps.iter().sum();
            let mut ids: Vec<usize> = (0..logits.len()).collect();
            ids.sort_unstable_by(|&a, &b| logits[b].total_cmp(&logits[a]).then(a.cmp(&b)));
            ids.into_iter()
                .take(top)
                .map(|id| (id, logits[id], exps[id] / total))
                .collect()
        }
        let mut rng = super::SplitMix64::new(41);
        let mut cases = vec![
            vec![],
            vec![3.0],
            vec![5.0; 129],
            vec![-0.0, 0.0, 0.0, -0.0, -1.0, 1.0],
            vec![f32::MAX, -f32::MAX, 0.0, f32::MIN_POSITIVE],
            vec![f32::INFINITY, 2.0, f32::NEG_INFINITY, f32::INFINITY],
            vec![f32::NEG_INFINITY; 4],
            vec![
                f32::NAN,
                f32::from_bits(0x7fc00001),
                f32::from_bits(0xffc00001),
                3.0,
                -0.0,
            ],
        ];
        for n in [2, 19, 20, 21, 127, 128, 129, 4096] {
            // Quantized random values force ties across the selection boundary.
            cases.push(
                (0..n)
                    .map(|_| (rng.next_u64() % 41) as f32 - 20.0)
                    .collect(),
            );
        }
        for values in cases {
            for top in [
                0,
                1,
                2,
                5,
                20,
                128,
                values.len(),
                values.len() + 1,
                usize::MAX,
            ] {
                let actual = top_k_logits(&values, top);
                let expected = reference(&values, top);
                assert_eq!(actual.len(), expected.len());
                for (a, e) in actual.iter().zip(&expected) {
                    assert_eq!(a.0, e.0, "rank id n={} top={top}", values.len());
                    assert_eq!(a.1.to_bits(), e.1.to_bits(), "raw logit bits");
                    if e.2.is_nan() {
                        assert!(a.2.is_nan());
                    } else {
                        assert_eq!(
                            a.2.to_bits(),
                            e.2.to_bits(),
                            "full-vocabulary probability bits n={} top={top}",
                            values.len()
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn split_mix64_is_deterministic_and_advances() {
        let mut a = super::SplitMix64::new(123);
        let mut b = super::SplitMix64::new(123);
        assert_eq!(a.next_u64(), b.next_u64());
        let first = a.next_u64();
        assert_ne!(first, a.next_u64(), "the generator advances");
        // Uniforms stay in [0, 1).
        for _ in 0..1000 {
            let u = a.next_f64();
            assert!((0.0..1.0).contains(&u));
        }
    }

    #[test]
    fn apply_template_formats_chatml() {
        // "chatml" is one of llama.cpp's recognized template names, so this needs
        // no model file: it exercises the FFI marshalling and the two-pass sizing.
        let messages = vec![
            ChatMessage {
                role: "system".to_string(),
                content: "Be concise.".to_string(),
            },
            ChatMessage::user("Ciao"),
        ];
        let out = apply_template("chatml", &messages, true).expect("chatml applies");
        assert!(out.contains("<|im_start|>system"), "system turn: {out:?}");
        assert!(out.contains("Be concise."), "system content: {out:?}");
        assert!(out.contains("<|im_start|>user"), "user turn: {out:?}");
        assert!(out.contains("Ciao"), "user content: {out:?}");
        // add_assistant opens the assistant turn for generation to continue.
        assert!(
            out.trim_end().ends_with("<|im_start|>assistant"),
            "assistant opener: {out:?}"
        );
    }

    #[test]
    fn apply_template_rejects_an_unsupported_template() {
        let messages = vec![ChatMessage::user("hi")];
        // A template string llama.cpp does not recognize returns an error, not a
        // panic — the boundary maps it to a classed relm_error_generation.
        let result = apply_template("not-a-real-template-xyz", &messages, true);
        assert!(result.is_err());
    }

    #[test]
    fn arch_builtin_template_maps_the_known_families() {
        // D-021: the arch -> builtin-name fallback map, small and explicit.
        for arch in ["gemma", "gemma2", "gemma3", "gemma4"] {
            assert_eq!(arch_builtin_template(arch), Some("gemma"), "arch {arch}");
        }
        for arch in ["qwen2", "qwen3", "qwen35"] {
            assert_eq!(arch_builtin_template(arch), Some("chatml"), "arch {arch}");
        }
        assert_eq!(arch_builtin_template("llama"), Some("llama3"));
        // Anything without a settled builtin maps to None -> the caller surfaces
        // the original error rather than mis-format.
        for arch in ["bert", "mamba", "qwen2moe", "", "gemma-embedding"] {
            assert_eq!(arch_builtin_template(arch), None, "arch {arch:?}");
        }
    }

    #[test]
    fn resolve_template_prefers_a_working_embedded_template_unchanged() {
        // Invariant (D-021): when the model's embedded template applies, behavior
        // is UNCHANGED — the arch is not even consulted. "chatml" stands in for a
        // detectable embedded template; the arch is deliberately gemma4 (whose
        // fallback would be "gemma") to prove the embedded template wins.
        let messages = vec![ChatMessage::user("Ciao")];
        let out = resolve_and_apply_template(Some("chatml"), "gemma4", &messages, true, false)
            .expect("embedded chatml applies");
        assert!(
            out.text.contains("<|im_start|>user"),
            "chatml used: {out:?}"
        );
        assert!(
            !out.text.contains("<start_of_turn>"),
            "the gemma fallback must NOT be taken when the embedded template works: {out:?}"
        );
        // An embedded template carries its own BOS, so the tokenizer must NOT add one.
        assert!(!out.add_special, "embedded template => add_special = false");
    }

    #[test]
    fn resolve_template_falls_back_to_gemma_for_a_gemma4_model() {
        // The spike case: a gemma4 model whose embedded Jinja b9726 cannot detect.
        // An undetectable embedded string stands in for it; the arch fallback must
        // select the "gemma" builtin and format the turn correctly.
        let messages = vec![ChatMessage::user("What colours are there?")];
        let out = resolve_and_apply_template(
            Some("not-a-real-template-xyz"),
            "gemma4",
            &messages,
            true,
            false,
        )
        .expect("the gemma4 arch fallback applies the gemma builtin");
        assert!(
            out.text.contains("<start_of_turn>user"),
            "gemma user turn: {out:?}"
        );
        assert!(
            out.text.trim_end().ends_with("<start_of_turn>model"),
            "gemma assistant opener: {out:?}"
        );
        // The builtin gemma template omits the leading BOS, so the tokenizer must
        // add it — else a Gemma prompt decodes into degenerate output.
        assert!(
            out.add_special,
            "builtin fallback => add_special = true (BOS)"
        );
    }

    #[test]
    fn resolve_template_falls_back_to_chatml_for_qwen() {
        // A qwen-family model whose embedded template is undetectable falls back to
        // chatml. (In practice Qwen's embedded chatml IS detected today, so this is
        // the defensive path; the map covers qwen2/qwen3/qwen35.)
        let messages = vec![ChatMessage::user("hi")];
        for arch in ["qwen2", "qwen3", "qwen35"] {
            let out = resolve_and_apply_template(Some("<<garbage>>"), arch, &messages, true, false)
                .unwrap_or_else(|_| panic!("chatml fallback applies for {arch}"));
            assert!(
                out.text.contains("<|im_start|>user"),
                "chatml used for {arch}: {out:?}"
            );
            assert!(
                out.add_special,
                "builtin fallback => add_special = true ({arch})"
            );
        }
    }

    #[test]
    fn resolve_template_surfaces_the_original_error_without_a_fallback() {
        // An undetectable embedded template on an architecture with no builtin
        // mapping raises the original classed error — never a silent mis-format.
        let messages = vec![ChatMessage::user("hi")];
        let err = resolve_and_apply_template(
            Some("not-a-real-template-xyz"),
            "bert",
            &messages,
            true,
            false,
        )
        .expect_err("no fallback -> the embedded error is surfaced");
        assert!(matches!(err, RebirthError::Generation { .. }));
    }

    #[test]
    fn resolve_template_errors_when_the_model_has_no_template() {
        // No embedded template at all: the model declares no chat contract, so the
        // "use chat = FALSE" error is preserved (no builtin fallback here).
        let messages = vec![ChatMessage::user("hi")];
        let err = resolve_and_apply_template(None, "gemma4", &messages, true, false)
            .expect_err("a model with no chat template errors");
        match err {
            RebirthError::Generation { reason } => {
                assert!(reason.contains("chat = FALSE"), "message: {reason:?}");
            }
            other => panic!("expected a generation error, got {other:?}"),
        }
    }
}
