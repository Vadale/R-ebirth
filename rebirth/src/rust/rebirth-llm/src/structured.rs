//! Bounded constrained-generation state (D-030); no R or filesystem side effects.
use std::ffi::{c_char, c_void, CString};
use std::marker::PhantomData;
use std::ptr::NonNull;

use crate::{ffi, CompiledSchema, GenerateParams, LoadedModel, RebirthError};

pub const STRUCTURED_MAX_SCHEMA_BYTES: usize = 65536;
pub const STRUCTURED_MAX_PROMPTS: usize = 128;
pub const STRUCTURED_MAX_PROMPT_BYTES: usize = 1048576;
pub const STRUCTURED_MAX_TOTAL_PROMPT_BYTES: usize = 16777216;
pub const STRUCTURED_MAX_TOKENS: usize = 8192;
pub const STRUCTURED_MAX_OUTPUT_BYTES: usize = 65536;
pub const STRUCTURED_MAX_TOTAL_OUTPUT_BYTES: usize = 8388608;
const MAX_GRAMMAR_BYTES: usize = 524288;
const MAX_GRAMMAR_ELEMENTS: usize = 65536;

extern "C" {
    fn relm_grammar_new(
        vocab: *const ffi::llama_vocab,
        text: *const c_char,
        limit: usize,
    ) -> *mut c_void;
    fn relm_grammar_mask(handle: *mut c_void, logits: *mut f32, n: usize, greedy: bool) -> i32;
    fn relm_grammar_complete(handle: *mut c_void) -> i32;
    fn relm_grammar_accept(handle: *mut c_void, token: i32) -> i32;
    fn relm_grammar_free(handle: *mut c_void);
    fn relm_grammar_clone(handle: *const c_void) -> *mut c_void;
    #[cfg(test)]
    fn relm_grammar_check(text: *const c_char, chars: *const u32, n: usize, limit: usize) -> i32;
}

pub(crate) struct Grammar<'m> {
    ptr: NonNull<c_void>,
    // The sampler borrows the model vocabulary and must never outlive it.
    _model: PhantomData<&'m LoadedModel>,
}

impl<'m> Grammar<'m> {
    pub(crate) fn new(
        model: &'m LoadedModel,
        schema: &CompiledSchema,
    ) -> Result<Self, RebirthError> {
        let error = || RebirthError::Schema {
            reason: "native grammar initialization failed or exceeded its element bound".into(),
            schema_path: String::new(),
        };
        if schema.grammar().len() > MAX_GRAMMAR_BYTES {
            return Err(error());
        }
        let text = CString::new(schema.grammar()).map_err(|_| error())?;
        // SAFETY: the live model owns the vocabulary for 'm; text is NUL-terminated
        // and copied by the engine. The C++ bridge catches allocation exceptions.
        let ptr =
            unsafe { relm_grammar_new(model.vocab_ptr(), text.as_ptr(), MAX_GRAMMAR_ELEMENTS) };
        Ok(Self {
            ptr: NonNull::new(ptr).ok_or_else(error)?,
            _model: PhantomData,
        })
    }

    fn fresh(&self) -> Result<Self, RebirthError> {
        // SAFETY: source stays live throughout the copy; llama owns the clone's
        // independent grammar state. The caller only clones the unused template.
        let ptr = unsafe { relm_grammar_clone(self.ptr.as_ptr()) };
        Ok(Self {
            ptr: NonNull::new(ptr).ok_or_else(|| RebirthError::Schema {
                reason: "could not allocate per-prompt grammar state".into(),
                schema_path: String::new(),
            })?,
            _model: PhantomData,
        })
    }
}

impl Drop for Grammar<'_> {
    fn drop(&mut self) {
        // SAFETY: unique owner of a live bridge allocation; freed exactly once.
        unsafe { relm_grammar_free(self.ptr.as_ptr()) };
    }
}

pub(crate) struct Constraint<'m, 's> {
    grammar: Grammar<'m>,
    schema: &'s CompiledSchema,
    pub(crate) bytes: Vec<u8>,
    prompt_id: usize,
    seed: u64,
}

impl<'m, 's> Constraint<'m, 's> {
    pub(crate) fn new(
        template: &Grammar<'m>,
        schema: &'s CompiledSchema,
        prompt_id: usize,
        params: &GenerateParams,
    ) -> Result<Self, RebirthError> {
        if params.max_tokens == 0
            || params.max_tokens > STRUCTURED_MAX_TOKENS
            || !params.stop.is_empty()
        {
            return Err(RebirthError::Schema {
                reason: "constrained generation requires 1..8192 tokens and no stop sequences"
                    .into(),
                schema_path: String::new(),
            });
        }
        Ok(Self {
            grammar: template.fresh()?,
            schema,
            bytes: Vec::new(),
            prompt_id,
            seed: params.seed,
        })
    }

    pub(crate) fn error(&self, reason: impl Into<String>, generated_tokens: usize) -> RebirthError {
        RebirthError::StructuredOutput {
            reason: reason.into(),
            prompt_id: self.prompt_id,
            seed: self.seed,
            generated_tokens,
            partial_bytes: self.bytes.clone(),
        }
    }

    pub(crate) fn mask(
        &mut self,
        logits: &mut [f32],
        count: usize,
        greedy: bool,
    ) -> Result<(), RebirthError> {
        if logits.iter().any(|x| x.is_nan() || *x == f32::INFINITY) {
            return Err(self.error("nonfinite model logits", count));
        }
        // SAFETY: the bridge owns its sampler, and the slice is live and writable
        // for its entire length. The bridge checks vocabulary size and ordering.
        let result = unsafe {
            relm_grammar_mask(
                self.grammar.ptr.as_ptr(),
                logits.as_mut_ptr(),
                logits.len(),
                greedy,
            )
        };
        if result != 0 {
            return Err(self.error("native grammar mask failed", count));
        }
        if !logits.iter().any(|x| x.is_finite()) {
            return Err(self.error("no admissible token", count));
        }
        Ok(())
    }

    pub(crate) fn accept(&mut self, token: i32, count: usize) -> Result<(), RebirthError> {
        // SAFETY: caller selected this in-range token from the masked vocabulary;
        // grammar state has not changed since that mask operation.
        if unsafe { relm_grammar_accept(self.grammar.ptr.as_ptr(), token) } != 0 {
            return Err(self.error("native grammar accept failed", count));
        }
        Ok(())
    }

    pub(crate) fn complete(&mut self, count: usize) -> Result<Option<String>, RebirthError> {
        // SAFETY: live unique sampler; the bridge probes EOG with neutral logits,
        // without accepting a token or changing the grammar state.
        match unsafe { relm_grammar_complete(self.grammar.ptr.as_ptr()) } {
            0 => Ok(None),
            1 => {
                self.schema
                    .validate(&self.bytes)
                    .map_err(|why| self.error(why, count))?;
                let text = std::str::from_utf8(&self.bytes)
                    .map_err(|_| self.error("invalid UTF-8 output", count))?;
                Ok(Some(text.to_owned()))
            }
            _ => Err(self.error("native grammar completion check failed", count)),
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    pub(crate) fn accepts(schema: &CompiledSchema, text: &str) -> bool {
        let grammar = CString::new(schema.grammar()).unwrap();
        let chars: Vec<u32> = text.chars().map(u32::from).collect();
        // SAFETY: both buffers remain live; scalar values come from valid Rust
        // chars. The independent C++ parser/automaton does no model inference.
        let status = unsafe {
            relm_grammar_check(
                grammar.as_ptr(),
                chars.as_ptr(),
                chars.len(),
                MAX_GRAMMAR_ELEMENTS,
            )
        };
        assert_ne!(
            status,
            -1,
            "GBNF must compile within bounds: {}",
            schema.grammar()
        );
        status == 1
    }

    // CI: ordinary cargo job, model/download-free. Pins generated grammar against
    // the actual b9726 automaton, independently of the relm schema validator.
    #[test]
    fn native_grammar_accepts_only_complete_profile_values() {
        let schema = CompiledSchema::compile(r#"{"type":"object","properties":{"i":{"type":"integer","minimum":-12,"maximum":123},"s":{"type":["string","null"],"maxLength":2}},"required":["i","s"],"additionalProperties":false}"#).unwrap();
        for text in [
            r#"{"i":-12,"s":null}"#,
            r#"{"i":123,"s":"é😀"}"#,
            r#"{"i":0,"s":"\u00e9\ud83d\ude00"}"#,
        ] {
            assert!(accepts(&schema, text), "{text}");
            schema.validate(text.as_bytes()).unwrap();
        }
        for text in [
            r#"{"i":124,"s":null}"#,
            r#"{"i":-13,"s":null}"#,
            r#"{"i":1.0,"s":null}"#,
            r#"{"i":1,"s":"abc"}"#,
            r#"{"i":1,"s":"\ud800"}"#,
            r#"{"i":1,"s":null"#,
        ] {
            assert!(!accepts(&schema, text), "{text}");
        }
    }

    #[test]
    fn structured_limits_twin_pin_r_validation() {
        let source = include_str!("../../../../R/generate.R");
        assert!(source.contains("relm_structured_max_temperature <- 3.4028234663852886e38"));
        assert_eq!(3.4028234663852886e38_f64, f32::MAX as f64);
        assert!(source.contains("relm_structured_seed_limit <- 18446744073709551616"));
        assert_eq!(18446744073709551616_f64, u64::MAX as f64);
        assert_eq!(STRUCTURED_MAX_SCHEMA_BYTES, crate::schema::SCHEMA_MAX_BYTES);
        assert_eq!(MAX_GRAMMAR_BYTES, crate::schema::GRAMMAR_MAX_BYTES);
        for (name, value) in [
            ("schema_bytes", STRUCTURED_MAX_SCHEMA_BYTES),
            ("prompts", STRUCTURED_MAX_PROMPTS),
            ("prompt_bytes", STRUCTURED_MAX_PROMPT_BYTES),
            ("total_prompt_bytes", STRUCTURED_MAX_TOTAL_PROMPT_BYTES),
            ("tokens", STRUCTURED_MAX_TOKENS),
        ] {
            assert!(
                source.contains(&format!("relm_structured_max_{name} <- {value}")),
                "{name}"
            );
        }
    }
}
