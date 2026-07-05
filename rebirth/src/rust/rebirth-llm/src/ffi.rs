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

    // --- KV-cache / memory ---
    pub fn llama_get_memory(ctx: *const llama_context) -> llama_memory_t;
    pub fn llama_memory_clear(mem: llama_memory_t, data: bool);
}
