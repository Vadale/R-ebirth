//! The engine's error type, mirroring `API-GRAMMAR.md` §6 / `ARCHITECTURE.md` §8.
//!
//! `rebirth-llm` is R-free: it returns `Result<_, RebirthError>` and never
//! constructs an R condition. The `rebirth-ffi` boundary maps each variant to a
//! classed R condition (`class`, `message`, structured fields). Keeping the
//! class strings here lets the boundary stay a mechanical translation.

use std::fmt;

/// A recoverable engine error with the structured fields the R layer surfaces.
///
/// Each variant maps 1:1 onto a `rebirth_error_*` R condition class (see
/// [`RebirthError::class`]). The fields are exactly what the corresponding R
/// condition carries so callers — and coding models — can branch on them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RebirthError {
    /// The GGUF file is missing, unreadable, truncated, or an unsupported
    /// architecture. `failing_check` names the step that failed.
    ModelLoad { failing_check: String },
    /// The requested backend is not available in this build. `available` lists
    /// the backends that are (comma-separated, R-facing order).
    Backend {
        requested: String,
        available: String,
    },
    /// The handle has been closed (deterministically or by the GC finalizer).
    Closed,
    /// Tokenization or detokenization failed (e.g. the model has no tokenizer,
    /// or an id is outside the vocabulary). `reason` names the failing step.
    Tokenize { reason: String },
    /// Generation failed inside the engine (a `llama_decode` error, a batch that
    /// could not be allocated, etc.). `reason` names the failing step.
    Generation { reason: String },
    /// The prompt (plus any special tokens) is longer than the context window.
    /// `prompt_tokens`/`context_length` give the two sizes; `overflow` is the
    /// excess (`prompt_tokens - context_length`).
    ContextOverflow {
        prompt_tokens: u32,
        context_length: u32,
        overflow: u32,
    },
    /// An unexpected internal failure (e.g. a caught Rust panic). Always a bug.
    Internal { context: String },
}

impl RebirthError {
    /// The specific R condition class for this error (the leaf of the
    /// `c(<specific>, "rebirth_error", "error", "condition")` hierarchy).
    pub fn class(&self) -> &'static str {
        match self {
            RebirthError::ModelLoad { .. } => "rebirth_error_model_load",
            RebirthError::Backend { .. } => "rebirth_error_backend",
            RebirthError::Closed => "rebirth_error_closed",
            RebirthError::Tokenize { .. } => "rebirth_error_tokenize",
            RebirthError::Generation { .. } => "rebirth_error_generation",
            RebirthError::ContextOverflow { .. } => "rebirth_error_context_overflow",
            RebirthError::Internal { .. } => "rebirth_error_internal",
        }
    }
}

impl fmt::Display for RebirthError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // Messages follow API-GRAMMAR §1.8: what happened -> likely cause ->
        // what to try. The R validation layer composes its own messages for the
        // checks it performs before the boundary; these cover the engine side.
        match self {
            RebirthError::ModelLoad { failing_check } => write!(
                f,
                "Failed to load the model (failing check: {failing_check}). \
                 The file may be missing, truncated, or not a supported GGUF. \
                 Verify the path points to a complete GGUF file for a supported architecture."
            ),
            RebirthError::Backend {
                requested,
                available,
            } => write!(
                f,
                "Backend '{requested}' is not available in this build (available: {available}). \
                 Re-run llm() with backend = \"auto\" or one of the available backends."
            ),
            RebirthError::Closed => write!(
                f,
                "This model handle is closed. \
                 Load the model again with llm() to obtain a fresh handle."
            ),
            RebirthError::Tokenize { reason } => write!(
                f,
                "Tokenization failed ({reason}). \
                 The model may lack a tokenizer, or a token id may be outside its vocabulary. \
                 Check the input and that the model file carries a tokenizer."
            ),
            RebirthError::Generation { reason } => write!(
                f,
                "Generation failed ({reason}). \
                 This usually means the engine could not evaluate the prompt. \
                 Try a shorter prompt or reload the model with llm()."
            ),
            RebirthError::ContextOverflow {
                prompt_tokens,
                context_length,
                overflow,
            } => write!(
                f,
                "The prompt is {prompt_tokens} tokens but the context window is {context_length} \
                 ({overflow} too many). \
                 Shorten the prompt, or reload the model with a larger context_length."
            ),
            RebirthError::Internal { context } => write!(
                f,
                "Internal error in the rebirth engine: {context}. \
                 This is a bug; please report it with the steps to reproduce."
            ),
        }
    }
}

impl std::error::Error for RebirthError {}
