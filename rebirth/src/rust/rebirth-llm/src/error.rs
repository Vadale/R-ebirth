//! The engine's error type, mirroring `API-GRAMMAR.md` §6 / `ARCHITECTURE.md` §8.
//!
//! `rebirth-llm` is R-free: it returns `Result<_, RebirthError>` and never
//! constructs an R condition. The `rebirth-ffi` boundary maps each variant to a
//! classed R condition (`class`, `message`, structured fields). Keeping the
//! class strings here lets the boundary stay a mechanical translation.

use std::fmt;

/// A recoverable engine error with the structured fields the R layer surfaces.
///
/// Each variant maps 1:1 onto a `relm_error_*` R condition class (see
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
    /// Embedding failed. Unlike the other engine errors this has several distinct
    /// causes — `pooling = "model"` is unavailable (the model defines no pooling,
    /// or is a reranker with a RANK head), or an input does not fit the context
    /// window — each needing its own guidance (and, for the over-long case, the
    /// two specific sizes). So the full, already-actionable message is composed at
    /// the failure site and carried in `reason`; `Display` presents it verbatim,
    /// and the R condition surfaces it as the structured `reason` field.
    Embed { reason: String },
    /// Activation tracing failed inside the engine: a requested component has no
    /// tensor for the model's architecture, a tapped tensor had an unexpected
    /// shape/dtype, or the trace decode failed. `reason` carries the full,
    /// already-actionable message (composed at the failure site, like `Embed`).
    Trace { reason: String },
    /// An intervention (`llm_steer`/`llm_ablate`) failed: the model's architecture
    /// lacks the `build_cvec` residual choke point, a native setter rejected the
    /// buffer, or a dimension/layer was invalid. `reason` carries the full,
    /// already-actionable message (composed at the failure site, like `Trace`).
    Intervention { reason: String },
    /// An image / vision failure (WP-V2, D-026): the projector failed to load or
    /// does not match the model at `llm(projector=)` time, or an image file was
    /// rejected by the pre-decode gate (unsupported format, over a size cap) or
    /// failed to decode. `reason` carries the full, already-actionable message
    /// (composed at the failure site, like `Embed`). The optional fields mirror
    /// the structured R condition fields (API-GRAMMAR section 6): `path` for a
    /// per-file failure, `expected`/`actual` for the mmproj-model embedding-size
    /// mismatch (both sizes are named — reject-not-clamp, hard rule 8b).
    Image {
        reason: String,
        path: Option<String>,
        expected: Option<i32>,
        actual: Option<i32>,
    },
    /// A capture whose predicted in-memory size exceeds the budget, raised BEFORE
    /// the capture is allocated when `spill = false` (the 16 GB rule; API-GRAMMAR
    /// section 4). The R validation layer raises the same class pre-boundary for
    /// the length-known filters; this covers the `positions = "all"` case, whose
    /// exact size is known only after tokenization. `estimate_bytes`/`budget_bytes`
    /// are the two sizes; `suggestion` names the filters that would fit.
    Oom {
        estimate_bytes: u64,
        budget_bytes: u64,
        suggestion: String,
    },
    /// An unexpected internal failure (e.g. a caught Rust panic). Always a bug.
    Internal { context: String },
}

impl RebirthError {
    /// The specific R condition class for this error (the leaf of the
    /// `c(<specific>, "relm_error", "error", "condition")` hierarchy).
    pub fn class(&self) -> &'static str {
        match self {
            RebirthError::ModelLoad { .. } => "relm_error_model_load",
            RebirthError::Backend { .. } => "relm_error_backend",
            RebirthError::Closed => "relm_error_closed",
            RebirthError::Tokenize { .. } => "relm_error_tokenize",
            RebirthError::Generation { .. } => "relm_error_generation",
            RebirthError::ContextOverflow { .. } => "relm_error_context_overflow",
            RebirthError::Embed { .. } => "relm_error_embed",
            RebirthError::Trace { .. } => "relm_error_trace",
            RebirthError::Intervention { .. } => "relm_error_intervention",
            RebirthError::Image { .. } => "relm_error_image",
            RebirthError::Oom { .. } => "relm_error_oom",
            RebirthError::Internal { .. } => "relm_error_internal",
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
            // The message is composed at the failure site (see the variant doc):
            // each embedding cause needs distinct guidance, so `reason` already
            // holds a complete what-happened -> cause -> what-to-try message.
            RebirthError::Embed { reason } => write!(f, "{reason}"),
            // Like `Embed`, the trace causes need distinct guidance (unsupported
            // component/architecture vs a shape mismatch), so `reason` already holds
            // a complete what-happened -> cause -> what-to-try message.
            RebirthError::Trace { reason } => write!(f, "{reason}"),
            // Like `Trace`, the intervention causes need distinct guidance
            // (unsupported architecture vs a rejected buffer vs an invalid
            // dimension/layer), so `reason` already holds a complete message.
            RebirthError::Intervention { reason } => write!(f, "{reason}"),
            // Like `Embed`, each image failure (unsupported format vs a size cap
            // vs a decode failure vs a projector mismatch) needs its own guidance,
            // so `reason` already holds a complete message.
            RebirthError::Image { reason, .. } => write!(f, "{reason}"),
            RebirthError::Oom {
                estimate_bytes,
                budget_bytes,
                suggestion,
            } => write!(
                f,
                "This trace would need about {} in memory, over the {} budget. {suggestion} \
                 Or set spill = TRUE to stream it to disk, or raise \
                 options(relm.trace_budget=).",
                human_bytes(*estimate_bytes),
                human_bytes(*budget_bytes)
            ),
            RebirthError::Internal { context } => write!(
                f,
                "Internal error in the relm engine: {context}. \
                 This is a bug; please report it with the steps to reproduce."
            ),
        }
    }
}

impl std::error::Error for RebirthError {}

/// A compact human-readable byte size (e.g. `"6.1 GB"`), mirroring the R
/// `format_bytes()` used for the pre-boundary OOM message so both estimate sites
/// read the same. Only the OOM message needs it.
fn human_bytes(n: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut value = n as f64;
    let mut i = 0;
    while value >= 1024.0 && i < UNITS.len() - 1 {
        value /= 1024.0;
        i += 1;
    }
    if i == 0 {
        format!("{n} {}", UNITS[0])
    } else {
        format!("{value:.1} {}", UNITS[i])
    }
}

#[cfg(test)]
mod tests {
    use super::human_bytes;

    // Twin-pin (Hard rule 8f): human_bytes() and the R format_bytes() format the same
    // byte sizes for the two halves of the OOM story -- the engine message built here
    // vs the R-side predictive pre-check (trace.R). These sentinels are asserted with
    // the identical expected strings by the R twin in tests/testthat/test-llm-print.R
    // ("format_bytes twin-pins ..."), so if either formula drifts (a changed unit
    // threshold or precision) one side fails and the OOM message can't silently diverge.
    #[test]
    fn human_bytes_twin_pins_the_r_format_bytes() {
        assert_eq!(human_bytes(0), "0 B");
        assert_eq!(human_bytes(512), "512 B");
        assert_eq!(human_bytes(1023), "1023 B");
        assert_eq!(human_bytes(1024), "1.0 KB");
        assert_eq!(human_bytes(531_000_000), "506.4 MB");
        assert_eq!(human_bytes(4_400_000_000), "4.1 GB");
        assert_eq!(human_bytes(5_000_000_000_000), "4.5 TB");
    }
}
