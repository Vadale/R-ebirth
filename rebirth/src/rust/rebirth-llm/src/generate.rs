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
/// to `n_tokens`; we only ever write the documented fields.
struct Batch {
    raw: ffi::llama_batch,
    capacity: i32,
}

impl Batch {
    fn new(n_tokens: i32) -> Result<Self, RebirthError> {
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
    /// (generation) or every token does (teacher-forced scoring).
    fn fill(&mut self, tokens: &[i32], start_pos: i32, logits_last_only: bool) {
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

impl LoadedModel {
    /// Tokenize `text` into engine-native (0-based) ids plus their display
    /// pieces. `add_special` adds the model's BOS/EOS if it is configured to;
    /// `parse_special` treats special-token markup in `text` as tokens.
    pub fn encode(
        &self,
        text: &str,
        add_special: bool,
        parse_special: bool,
    ) -> Result<Encoding, RebirthError> {
        if !self.has_tokenizer() {
            return Err(RebirthError::Tokenize {
                reason: "the model carries no tokenizer (no_vocab)".to_string(),
            });
        }
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
        if !self.has_tokenizer() {
            return Err(RebirthError::Tokenize {
                reason: "the model carries no tokenizer (no_vocab)".to_string(),
            });
        }
        self.validate_ids(ids)?;
        if ids.is_empty() {
            return Ok(String::new());
        }
        // Two-pass sizing: a negative return is minus the required byte length.
        let vocab = self.vocab_ptr();
        let mut cap = ids.len() * 8 + 16;
        loop {
            let mut buf = vec![0u8; cap];
            // SAFETY: `vocab` is live; `ids` is a valid slice; `buf`/`cap` are
            // consistent. The engine writes at most `cap` bytes (no NUL).
            let n = unsafe {
                ffi::llama_detokenize(
                    vocab,
                    ids.as_ptr(),
                    ids.len() as i32,
                    buf.as_mut_ptr().cast::<c_char>(),
                    cap as i32,
                    remove_special,
                    unparse_special,
                )
            };
            if n < 0 {
                cap = (-n) as usize;
                continue;
            }
            buf.truncate(n as usize);
            // Lossy: a well-formed id sequence detokenizes to valid UTF-8; lossy
            // only guards against a caller passing a mid-character id subset.
            return Ok(String::from_utf8_lossy(&buf).into_owned());
        }
    }

    /// Reject ids outside `[0, n_vocab)` before they reach the engine (a bad id
    /// could otherwise trip an assert). Engine-native (0-based) ids.
    fn validate_ids(&self, ids: &[i32]) -> Result<(), RebirthError> {
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

    fn tokenize(
        &self,
        text: &str,
        add_special: bool,
        parse_special: bool,
    ) -> Result<Vec<i32>, RebirthError> {
        let vocab = self.vocab_ptr();
        let bytes = text.as_bytes();
        // Generous first guess; +8 covers any added special tokens on an empty
        // or tiny input. A negative return is minus the exact count needed.
        let mut cap = bytes.len() + 8;
        loop {
            let mut tokens = vec![0i32; cap];
            // SAFETY: `vocab` is live; `bytes` outlives the call; `tokens`/`cap`
            // are consistent. Passing an explicit length (not NUL-terminated)
            // handles interior NUL bytes in `text`.
            let n = unsafe {
                ffi::llama_tokenize(
                    vocab,
                    bytes.as_ptr().cast::<c_char>(),
                    bytes.len() as i32,
                    tokens.as_mut_ptr(),
                    cap as i32,
                    add_special,
                    parse_special,
                )
            };
            if n < 0 {
                cap = (-n) as usize;
                continue;
            }
            tokens.truncate(n as usize);
            return Ok(tokens);
        }
    }

    /// The display piece for a single engine-native id. Lossy: a single token
    /// may be a partial UTF-8 byte sequence; round-trip correctness comes from
    /// [`decode_tokens`](Self::decode_tokens) on the whole id vector, not from
    /// concatenating pieces.
    fn token_piece(&self, id: i32) -> Result<String, RebirthError> {
        let vocab = self.vocab_ptr();
        let mut cap = 32usize;
        loop {
            let mut buf = vec![0u8; cap];
            // SAFETY: `vocab` is live; `buf`/`cap` are consistent. `lstrip = 0`,
            // `special = true` so control tokens render as their text.
            let n = unsafe {
                ffi::llama_token_to_piece(
                    vocab,
                    id,
                    buf.as_mut_ptr().cast::<c_char>(),
                    cap as i32,
                    0,
                    true,
                )
            };
            if n < 0 {
                cap = (-n) as usize;
                continue;
            }
            buf.truncate(n as usize);
            return Ok(String::from_utf8_lossy(&buf).into_owned());
        }
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

    /// Guard: reject a token sequence that cannot fit the context window.
    fn check_fits(&self, n_tokens: usize) -> Result<(), RebirthError> {
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

    /// Decode `tokens` starting at `start_pos` and return the raw decode status.
    /// The batch requests logits per `logits_last_only`.
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

    /// Teacher-forced logits at every position of `tokens` (no sampling). This is
    /// the exact-value oracle path: the numpy reference computes the same rows.
    pub fn logits_for_tokens(&self, tokens: &[i32]) -> Result<Logits, RebirthError> {
        self.check_fits(tokens.len())?;
        let n_vocab = self.n_vocab() as usize;
        if n_vocab == 0 {
            return Err(RebirthError::Generation {
                reason: "model has empty vocabulary".to_string(),
            });
        }
        self.clear_memory();
        self.decode(tokens, 0, false)?;

        let mut values = Vec::with_capacity(tokens.len() * n_vocab);
        for i in 0..tokens.len() {
            values.extend_from_slice(&self.logits_ith(i as i32, n_vocab)?);
        }
        Ok(Logits {
            values,
            seq_len: tokens.len(),
            n_vocab,
        })
    }
}
