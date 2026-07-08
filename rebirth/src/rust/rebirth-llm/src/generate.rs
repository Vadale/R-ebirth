//! Tokenization, teacher-forced logits, and token-level generation.
//!
//! The engine wrapper for WP2. Everything here operates on plain Rust types
//! (token-id slices, strings, `Vec<f32>` logits) so the crate stays R-free
//! (ARCHITECTURE.md §2). The determinism contract (§7) is honored by drawing
//! every sampled token on the CPU from the returned logits with a dedicated
//! seeded RNG (`SplitMix64` below) — the GPU backend never selects a token, so
//! backend non-determinism cannot enter the output.

use std::os::raw::c_char;

use crate::engine::LoadedModel;
use crate::error::RebirthError;
use crate::ffi;

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
        self.require_tokenizer()?;
        self.validate_ids(ids)?;
        if ids.is_empty() {
            return Ok(String::new());
        }
        let vocab = self.vocab_ptr();
        // First guess ~8 bytes/token; sized_buffer grows on the engine's request.
        let buf = sized_buffer::<u8>(ids.len() * 8 + 16, |ptr, cap| {
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
        });
        // Lossy: a well-formed id sequence detokenizes to valid UTF-8; lossy only
        // guards against a caller passing a mid-character id subset.
        Ok(String::from_utf8_lossy(&buf).into_owned())
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
        let vocab = self.vocab_ptr();
        let bytes = text.as_bytes();
        // Generous first guess; +8 covers any added special tokens on an empty or
        // tiny input. sized_buffer grows to the exact count if the engine asks.
        let tokens = sized_buffer::<i32>(bytes.len() + 8, |ptr, cap| {
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
        });
        Ok(tokens)
    }

    /// The display piece for a single engine-native id. Lossy: a single token
    /// may be a partial UTF-8 byte sequence; round-trip correctness comes from
    /// [`decode_tokens`](Self::decode_tokens) on the whole id vector, not from
    /// concatenating pieces.
    fn token_piece(&self, id: i32) -> Result<String, RebirthError> {
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
    fn clear_memory(&self) {
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
    /// an empty vocabulary (nothing could be scored or sampled).
    fn n_vocab_checked(&self) -> Result<usize, RebirthError> {
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
        let status = unsafe { ffi::llama_decode(self.ctx_ptr(), std::ptr::read(&batch.raw)) };
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
            let end = (start + n_batch).min(tokens.len());
            self.decode(&tokens[start..end], start as i32, logits_last_only)?;
            on_chunk(start, end - start)?;
            start = end;
        }
        Ok(())
    }

    /// Copy the logit row the engine stored for output slot `ith`.
    fn logits_ith(&self, ith: i32, n_vocab: usize) -> Result<Vec<f32>, RebirthError> {
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
    let exps: Vec<f64> = logits.iter().map(|&v| (v as f64 - max).exp()).collect();
    let total: f64 = exps.iter().sum();

    // Descending by logit; ties by ascending index for a total, stable order
    // (total_cmp handles any -0.0/NaN without a panic).
    let mut order: Vec<usize> = (0..n).collect();
    order.sort_unstable_by(|&a, &b| logits[b].total_cmp(&logits[a]).then(a.cmp(&b)));
    order
        .into_iter()
        .take(keep)
        .map(|i| (i, logits[i], exps[i] / total))
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
        let ctx_len = self.context_length() as usize;

        // Ingest the prompt in n_batch-sized chunks and take its final-position
        // logits — the shared path with next_token_logits, which also handles the
        // prompt-longer-than-one-batch split. This row is the first sampling step's
        // next-token distribution.
        let mut logits = self.prompt_last_logits(prompt, n_vocab)?;

        let vocab = self.vocab_ptr();
        let mut rng = SplitMix64::new(params.seed);
        let mut out: Vec<i32> = Vec::with_capacity(params.max_tokens);
        let mut stop_reason = StopReason::MaxTokens;

        // `n_past` is the position the next continuation token occupies: the
        // prompt filled 0..prompt.len(), so continuation i lands at prompt.len()+i.
        for n_past in (prompt.len() as i32..).take(params.max_tokens) {
            let next = if params.temperature <= 0.0 {
                argmax(&logits)
            } else {
                sample(&logits, params.temperature, params.top_p, &mut rng)
            } as i32;

            // SAFETY: `vocab` is live for the model's lifetime; `next` is an id in
            // `[0, n_vocab)` (argmax/sample index into a vocab-width row).
            if unsafe { ffi::llama_vocab_is_eog(vocab, next) } {
                stop_reason = StopReason::EndOfGeneration;
                break;
            }
            out.push(next);

            if !params.stop.is_empty() && self.has_tokenizer() {
                let text = self.decode_tokens(&out, false, false)?;
                if let Some(cut) = first_stop(&text, &params.stop) {
                    return Ok(Generation {
                        tokens: out,
                        text: text[..cut].to_string(),
                        stop_reason: StopReason::StopString,
                        seed: params.seed,
                    });
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
            logits = self.logits_ith(0, n_vocab)?;
        }

        // Detokenize the continuation only when the model carries a tokenizer;
        // the numeric synthetic test model has a vocabulary but no tokenizer, so
        // it produces token ids with no text form.
        let text = if self.has_tokenizer() {
            self.decode_tokens(&out, false, false)?
        } else {
            String::new()
        };
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
        self.require_tokenizer()?;
        let (text, add_special, parse_special) = if chat {
            let templated = self.apply_chat_template(&[ChatMessage::user(prompt)], true)?;
            (templated.text, templated.add_special, true)
        } else {
            (prompt.to_string(), true, false)
        };
        let prompt_ids = self.tokenize(&text, add_special, parse_special)?;
        self.generate(&prompt_ids, params)
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
        let embedded = self.chat_template();
        resolve_and_apply_template(
            embedded.as_deref(),
            &self.architecture(),
            messages,
            add_assistant,
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
fn resolve_and_apply_template(
    embedded: Option<&str>,
    arch: &str,
    messages: &[ChatMessage],
    add_assistant: bool,
) -> Result<TemplatedPrompt, RebirthError> {
    let Some(tmpl) = embedded else {
        return Err(RebirthError::Generation {
            reason: "the model carries no chat template; use chat = FALSE".to_string(),
        });
    };
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

/// Format `messages` with an explicit llama.cpp template string. Free of any
/// model so it is unit-testable; [`LoadedModel::apply_chat_template`] supplies
/// the model's own template. `tmpl` must be one of the templates llama.cpp
/// recognizes (it is not a general Jinja engine), else this errors.
fn apply_template(
    tmpl: &str,
    messages: &[ChatMessage],
    add_assistant: bool,
) -> Result<String, RebirthError> {
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
        return Ok(String::from_utf8_lossy(&buf).into_owned());
    }
}

#[cfg(test)]
mod tests {
    use super::{
        apply_template, arch_builtin_template, resolve_and_apply_template, top_k_logits,
        ChatMessage, RebirthError,
    };

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
        let out = resolve_and_apply_template(Some("chatml"), "gemma4", &messages, true)
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
        let out =
            resolve_and_apply_template(Some("not-a-real-template-xyz"), "gemma4", &messages, true)
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
            let out = resolve_and_apply_template(Some("<<garbage>>"), arch, &messages, true)
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
        let err =
            resolve_and_apply_template(Some("not-a-real-template-xyz"), "bert", &messages, true)
                .expect_err("no fallback -> the embedded error is surfaced");
        assert!(matches!(err, RebirthError::Generation { .. }));
    }

    #[test]
    fn resolve_template_errors_when_the_model_has_no_template() {
        // No embedded template at all: the model declares no chat contract, so the
        // "use chat = FALSE" error is preserved (no builtin fallback here).
        let messages = vec![ChatMessage::user("hi")];
        let err = resolve_and_apply_template(None, "gemma4", &messages, true)
            .expect_err("a model with no chat template errors");
        match err {
            RebirthError::Generation { reason } => {
                assert!(reason.contains("chat = FALSE"), "message: {reason:?}");
            }
            other => panic!("expected a generation error, got {other:?}"),
        }
    }
}
