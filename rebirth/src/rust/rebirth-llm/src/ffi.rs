//! Hand-written FFI to the vendored llama.cpp C API at the pinned tag (`b9726`).
//!
//! No bindgen (DECISIONS.md D-006): the surface is small and reviewed by hand
//! against `src/llama.cpp/include/llama.h` at this exact tag. Every safe wrapper
//! in `engine.rs` is the sole caller of a declaration here, so the linker
//! verifies each symbol name at build time.
//!
//! # Layout invariants (read before touching the two param structs)
//!
//! `llama_model_load_from_file` and `llama_init_from_model` take their params
//! **by value**, and we obtain those params from the matching
//! `*_default_params()` getter (also by value). The Rust structs below must
//! therefore reproduce the C layout at this tag exactly: `#[repr(C)]` with the
//! same field order, sizes, and trailing-bool packing. Both were validated
//! field-by-field against the `*_default_params()` initializers in
//! `src/llama-model.cpp` / `src/llama-context.cpp`. A C `enum` is `c_int`; every
//! object/function-pointer field is one pointer wide (we only ever read the
//! defaults or set NULL, so callback fields are typed as opaque `*mut c_void` —
//! a data pointer and a function pointer are the same width on every target this
//! crate builds for). Do not reorder, and re-validate on every `vendor-bump`.

use std::ffi::c_void;
use std::os::raw::{c_char, c_int};

/// Opaque handle: `struct llama_model` (never dereferenced from Rust).
#[repr(C)]
pub struct llama_model {
    _opaque: [u8; 0],
}

/// Opaque handle: `struct llama_context`.
#[repr(C)]
pub struct llama_context {
    _opaque: [u8; 0],
}

/// Opaque handle: `struct llama_vocab`.
#[repr(C)]
pub struct llama_vocab {
    _opaque: [u8; 0],
}

/// Opaque `struct ggml_tensor` (WP4). Never dereferenced from Rust — the tap only
/// hands it to the accessors below. The scheduler passes one to the eval callback
/// per graph node.
#[repr(C)]
pub struct ggml_tensor {
    _opaque: [u8; 0],
}

/// The scheduler eval callback (`ggml-backend.h` L314, tag b9726):
/// `bool (*)(struct ggml_tensor * t, bool ask, void * user_data)`. `ask = true`
/// asks "observe this node?"; `ask = false` fires after the node is computed and
/// synchronized ("data ready"), and returning `false` cancels the rest of the
/// compute. Installed on a context via the `cb_eval`/`cb_eval_user_data` params.
pub type GgmlSchedEvalCallback =
    extern "C" fn(t: *mut ggml_tensor, ask: bool, user_data: *mut c_void) -> bool;

// The names below mirror the llama.h typedefs verbatim (like the structs above),
// so the FFI surface reads 1:1 against the header; hence the snake_case allow.
#[allow(non_camel_case_types)]
/// `llama_token` / `llama_pos` / `llama_seq_id` are all `int32_t` (llama.h l.68-70).
pub type llama_token = i32;
#[allow(non_camel_case_types)]
pub type llama_pos = i32;
#[allow(non_camel_case_types)]
pub type llama_seq_id = i32;

#[allow(non_camel_case_types)]
/// `llama_memory_t` = `struct llama_memory_i *` (opaque; never dereferenced).
pub type llama_memory_t = *mut c_void;

/// Mirror of `struct llama_batch` (llama.h, tag b9726). Passed **by value** to
/// `llama_decode`; allocated/freed by `llama_batch_init`/`llama_batch_free`, so
/// the only fields we write are `n_tokens`, `token`, `pos`, `n_seq_id`,
/// `seq_id`, and `logits` (all heap arrays sized by the engine).
#[repr(C)]
pub struct llama_batch {
    pub n_tokens: i32,
    pub token: *mut llama_token,
    pub embd: *mut f32,
    pub pos: *mut llama_pos,
    pub n_seq_id: *mut i32,
    pub seq_id: *mut *mut llama_seq_id,
    pub logits: *mut i8,
}

/// Mirror of `struct llama_model_params` (llama.h, tag b9726).
#[repr(C)]
pub struct llama_model_params {
    pub devices: *mut c_void,
    pub tensor_buft_overrides: *const c_void,
    pub n_gpu_layers: i32,
    pub split_mode: c_int,
    pub main_gpu: i32,
    pub tensor_split: *const f32,
    pub progress_callback: *mut c_void,
    pub progress_callback_user_data: *mut c_void,
    pub kv_overrides: *const c_void,
    pub vocab_only: bool,
    pub use_mmap: bool,
    pub use_direct_io: bool,
    pub use_mlock: bool,
    pub check_tensors: bool,
    pub use_extra_bufts: bool,
    pub no_host: bool,
    pub no_alloc: bool,
}

/// Mirror of `struct llama_context_params` (llama.h, tag b9726).
#[repr(C)]
pub struct llama_context_params {
    pub n_ctx: u32,
    pub n_batch: u32,
    pub n_ubatch: u32,
    pub n_seq_max: u32,
    pub n_rs_seq: u32,
    pub n_outputs_max: u32,
    pub n_threads: i32,
    pub n_threads_batch: i32,
    pub ctx_type: c_int,
    pub rope_scaling_type: c_int,
    pub pooling_type: c_int,
    pub attention_type: c_int,
    pub flash_attn_type: c_int,
    pub rope_freq_base: f32,
    pub rope_freq_scale: f32,
    pub yarn_ext_factor: f32,
    pub yarn_attn_factor: f32,
    pub yarn_beta_fast: f32,
    pub yarn_beta_slow: f32,
    pub yarn_orig_ctx: u32,
    pub defrag_thold: f32,
    pub cb_eval: *mut c_void,
    pub cb_eval_user_data: *mut c_void,
    pub type_k: c_int,
    pub type_v: c_int,
    pub abort_callback: *mut c_void,
    pub abort_callback_data: *mut c_void,
    pub embeddings: bool,
    pub offload_kqv: bool,
    pub no_perf: bool,
    pub op_offload: bool,
    pub swa_full: bool,
    pub kv_unified: bool,
    pub samplers: *mut c_void,
    pub n_samplers: usize,
    pub ctx_other: *mut c_void,
}

/// `ggml_log_callback`: `void (*)(enum ggml_log_level, const char *, void *)`.
pub type GgmlLogCallback = extern "C" fn(level: c_int, text: *const c_char, user_data: *mut c_void);

/// Mirror of `struct llama_chat_message` (llama.h l.436): a role/content turn.
/// Both are borrowed NUL-terminated C strings that must outlive the apply call.
#[repr(C)]
pub struct llama_chat_message {
    pub role: *const c_char,
    pub content: *const c_char,
}

extern "C" {
    // --- backend lifecycle & capabilities (also used by lib.rs) ---
    pub fn llama_backend_init();
    pub fn llama_backend_free();
    pub fn llama_print_system_info() -> *const c_char;
    pub fn llama_supports_gpu_offload() -> bool;
    pub fn llama_supports_mmap() -> bool;
    pub fn llama_supports_mlock() -> bool;
    pub fn llama_max_devices() -> usize;

    /// Route all engine logging through `log_callback`; NULL restores stderr.
    pub fn llama_log_set(log_callback: Option<GgmlLogCallback>, user_data: *mut c_void);

    // --- model & context lifecycle ---
    pub fn llama_model_default_params() -> llama_model_params;
    pub fn llama_context_default_params() -> llama_context_params;
    pub fn llama_model_load_from_file(
        path_model: *const c_char,
        params: llama_model_params,
    ) -> *mut llama_model;
    pub fn llama_model_free(model: *mut llama_model);
    pub fn llama_init_from_model(
        model: *mut llama_model,
        params: llama_context_params,
    ) -> *mut llama_context;
    pub fn llama_free(ctx: *mut llama_context);

    // --- metadata getters ---
    pub fn llama_n_ctx(ctx: *const llama_context) -> u32;
    /// The maximum tokens a single `llama_decode` batch may carry (a prompt
    /// longer than this must be decoded in chunks).
    pub fn llama_n_batch(ctx: *const llama_context) -> u32;
    pub fn llama_model_n_layer(model: *const llama_model) -> i32;
    pub fn llama_model_n_embd(model: *const llama_model) -> i32;
    pub fn llama_model_n_ctx_train(model: *const llama_model) -> i32;
    pub fn llama_model_n_params(model: *const llama_model) -> u64;
    pub fn llama_model_size(model: *const llama_model) -> u64;
    pub fn llama_model_meta_val_str(
        model: *const llama_model,
        key: *const c_char,
        buf: *mut c_char,
        buf_size: usize,
    ) -> i32;
    pub fn llama_model_desc(model: *const llama_model, buf: *mut c_char, buf_size: usize) -> i32;
    pub fn llama_model_get_vocab(model: *const llama_model) -> *const llama_vocab;
    pub fn llama_vocab_n_tokens(vocab: *const llama_vocab) -> i32;
    /// `enum llama_vocab_type`; `0` = `LLAMA_VOCAB_TYPE_NONE` (no tokenizer).
    pub fn llama_vocab_type(vocab: *const llama_vocab) -> c_int;
    /// Whether `token` ends generation (EOS/EOT/etc.); stops the decode loop.
    pub fn llama_vocab_is_eog(vocab: *const llama_vocab, token: llama_token) -> bool;

    // --- tokenization ---
    pub fn llama_tokenize(
        vocab: *const llama_vocab,
        text: *const c_char,
        text_len: i32,
        tokens: *mut llama_token,
        n_tokens_max: i32,
        add_special: bool,
        parse_special: bool,
    ) -> i32;
    pub fn llama_token_to_piece(
        vocab: *const llama_vocab,
        token: llama_token,
        buf: *mut c_char,
        length: i32,
        lstrip: i32,
        special: bool,
    ) -> i32;
    pub fn llama_detokenize(
        vocab: *const llama_vocab,
        tokens: *const llama_token,
        n_tokens: i32,
        text: *mut c_char,
        text_len_max: i32,
        remove_special: bool,
        unparse_special: bool,
    ) -> i32;

    // --- chat templates ---
    /// The model's built-in chat template (`name = NULL` for the default), or
    /// NULL if the GGUF carries none. Owned by the model.
    pub fn llama_model_chat_template(
        model: *const llama_model,
        name: *const c_char,
    ) -> *const c_char;
    /// Format `chat` with `tmpl` (a recognized template, not arbitrary Jinja).
    /// Returns the formatted byte length; a value > `length` means re-alloc and
    /// retry; a negative value is an error.
    pub fn llama_chat_apply_template(
        tmpl: *const c_char,
        chat: *const llama_chat_message,
        n_msg: usize,
        add_ass: bool,
        buf: *mut c_char,
        length: i32,
    ) -> i32;

    // --- decoding & logits ---
    pub fn llama_batch_init(n_tokens: i32, embd: i32, n_seq_max: i32) -> llama_batch;
    pub fn llama_batch_free(batch: llama_batch);
    pub fn llama_decode(ctx: *mut llama_context, batch: llama_batch) -> i32;
    pub fn llama_get_logits_ith(ctx: *mut llama_context, i: i32) -> *mut f32;

    // --- embeddings (WP3) ---
    /// Per-token embedding for output slot `i` (the post-final-norm hidden state,
    /// "result_norm") when the context was created with `pooling_type = NONE`.
    /// Points at `n_embd` f32 owned by the context, valid until the next decode.
    /// NULL for an invalid slot (llama.h b9726 l.1025).
    ///
    /// Deliberately NOT declared (keeps the D-006 minimal FFI surface): the WP3
    /// strategy (D-011) sets `embeddings = true` at context creation and pools in
    /// Rust over these per-token rows, so `llama_set_embeddings` (a runtime toggle)
    /// and `llama_get_embeddings_seq` / `llama_pooling_type` (engine-side pooling)
    /// are all unneeded — the model's own pooling is read from GGUF metadata via
    /// the already-declared `llama_model_meta_val_str`.
    pub fn llama_get_embeddings_ith(ctx: *mut llama_context, i: i32) -> *mut f32;

    // --- activation taps (WP4) ---
    // The minimal accessor surface (D-006 / D-012): the opaque `ggml_tensor` above
    // plus these four getters. No `ggml_tensor` struct mirror, and deliberately NOT
    // `ggml_backend_tensor_set` (that is WP5 ablation, D-012). The tap matches by
    // name, checks the shape, and copies the host-side data — read-only.
    /// The tensor's graph name, e.g. `"l_out-7"` (ggml.h L865). Owned by the graph;
    /// valid for the duration of the callback.
    pub fn ggml_get_name(t: *const ggml_tensor) -> *const c_char;
    /// Total element count of the tensor (ggml.h L736); for a captured hidden-state
    /// tensor this is `n_tokens * n_embd`.
    pub fn ggml_nelements(t: *const ggml_tensor) -> i64;
    /// Total byte size of the tensor's storage (ggml.h L738); `nelements * 4` for
    /// the F32 hidden states the tap reads.
    pub fn ggml_nbytes(t: *const ggml_tensor) -> usize;
    /// Copy `size` bytes of the tensor's data to `data` (host memcpy on Apple-silicon
    /// shared memory; ggml-backend.h L93). Called at `ask = false`, after the
    /// scheduler has synchronized, so the data is ready.
    pub fn ggml_backend_tensor_get(
        t: *const ggml_tensor,
        data: *mut c_void,
        offset: usize,
        size: usize,
    );

    // --- interventions (WP5, D-012/D-016) ---
    // Both setters take pointers + lengths (no struct-mirror change), so the
    // size-160 ABI test above still covers everything WP5 relies on. The buffers
    // are Rust-owned, copied synchronously by the engine, and never retained past
    // the call. `ggml_backend_tensor_set` stays undeclared: ablation is a native
    // graph op (`x*mask + add`), not a host tensor write (D-012).
    /// Steering — the native control vector (zero patch; llama.h L694). `data` is
    /// an `n_embd x n_layer` F32 buffer laid out "from layer 1" (llama-adapter.cpp
    /// L124-131), so engine layer `il`'s vector sits at offset `n_embd*(il-1)` and
    /// the buffer has no row for layer 0. Returns 0 on success, -1 on n_embd
    /// mismatch; a NULL `data` clears the vector.
    pub fn llama_set_adapter_cvec(
        ctx: *mut llama_context,
        data: *const f32,
        len: usize,
        n_embd: i32,
        il_start: i32,
        il_end: i32,
    ) -> i32;

    /// Ablation — the WP5 vendored patch's public C API (rebirth-prefixed, added
    /// by `patches/0001-rebirth-wp5-ablation-intervene.diff`). `mask` and `add` are
    /// `n_embd x n_layer` F32 buffers from layer 0 (full coverage) so `build_cvec`
    /// applies `x*mask + add` after the control vector. A NULL `mask` clears the
    /// intervention. Returns 0 on success, -1 on n_embd mismatch. Copied
    /// synchronously.
    pub fn rebirth_set_intervene(
        ctx: *mut llama_context,
        mask: *const f32,
        add: *const f32,
        len: usize,
        n_embd: i32,
        il_start: i32,
        il_end: i32,
    ) -> i32;

    // --- KV-cache / memory ---
    pub fn llama_get_memory(ctx: *const llama_context) -> llama_memory_t;
    pub fn llama_memory_clear(mem: llama_memory_t, data: bool);
}

#[cfg(test)]
mod tests {
    use super::*;

    /// WP3 is the first code that *writes* `pooling_type`, `attention_type`, and
    /// `embeddings` on the by-value `llama_context_params`. D-008 audited these
    /// offsets against `llama.h` b9726; because the struct is obtained and passed
    /// by value from `llama_context_default_params()`, a reordered or misaligned
    /// `#[repr(C)]` mirror surfaces as *wrong default values* here — not a link
    /// error — so this guards the three fields with a value check, not just a
    /// compile check. It re-runs on every CI run and every `vendor-bump`.
    #[test]
    fn context_params_embedding_fields_have_the_expected_abi() {
        // SAFETY: default params are a plain by-value C struct we only read.
        let p = unsafe { llama_context_default_params() };
        assert_eq!(p.pooling_type, -1, "LLAMA_POOLING_TYPE_UNSPECIFIED");
        assert_eq!(p.attention_type, -1, "LLAMA_ATTENTION_TYPE_UNSPECIFIED");
        assert!(!p.embeddings, "embeddings default is false");

        // WP4 is the first code that *writes* the eval-callback fields; pin their
        // b9726 null defaults by value (llama-context.cpp L3466-3467) so a reordered
        // mirror that shifts them surfaces here, and the generation/embedding
        // contexts (which never set them) provably install no callback.
        assert!(p.cb_eval.is_null(), "cb_eval default is null");
        assert!(
            p.cb_eval_user_data.is_null(),
            "cb_eval_user_data default is null"
        );

        // ABI size guard: the value checks above catch any misalignment at or before
        // `embeddings`, but not a future vendor-bump that reorders the layout *after*
        // it (the `samplers`/`n_samplers`/`ctx_other` tail). Pinning the full size
        // catches that too, even though WP3 writes no tail field. Refresh on
        // `vendor-bump` if the field list legitimately changes.
        assert_eq!(
            core::mem::size_of::<llama_context_params>(),
            160,
            "llama_context_params size drifted from b9726; re-verify the #[repr(C)] mirror"
        );
    }
}
