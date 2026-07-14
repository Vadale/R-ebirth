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

/// Mirror of `struct mtmd_context_params` (tools/mtmd/mtmd.h L86-107, tag
/// b9726 — the multimodal library vendored by WP-V1, D-026). Returned **by
/// value** from `mtmd_context_params_default()`, so the layout rules at the
/// top of this file apply: same field order, C `enum` = `c_int`, callback
/// fields opaque pointers. Field-by-field against the initializer in
/// tools/mtmd/mtmd.cpp L240-256. Re-validate on every `vendor-bump`.
#[repr(C)]
pub struct mtmd_context_params {
    pub use_gpu: bool,
    pub print_timings: bool,
    pub n_threads: c_int,
    /// Deprecated upstream in favor of `media_marker`; defaults to NULL.
    pub image_marker: *const c_char,
    pub media_marker: *const c_char,
    /// `enum llama_flash_attn_type` (llama.h L186-190).
    pub flash_attn_type: c_int,
    pub warmup: bool,
    pub image_min_tokens: c_int,
    pub image_max_tokens: c_int,
    /// `ggml_backend_sched_eval_callback`; NULL default (T3 vision-tower
    /// tracing is out of scope, D-026 — WP-V2 never sets it).
    pub cb_eval: *mut c_void,
    pub cb_eval_user_data: *mut c_void,
    pub batch_max_tokens: i32,
}

/// Opaque handle: `struct mtmd_context` (mtmd.h L61; never dereferenced).
#[repr(C)]
pub struct mtmd_context {
    _opaque: [u8; 0],
}

/// Opaque handle: `struct mtmd_bitmap` (mtmd.h L62; never dereferenced).
#[repr(C)]
pub struct mtmd_bitmap {
    _opaque: [u8; 0],
}

/// Opaque handle: `struct mtmd_input_chunk` (mtmd.h L64; never dereferenced).
#[repr(C)]
pub struct mtmd_input_chunk {
    _opaque: [u8; 0],
}

/// `MTMD_INPUT_CHUNK_TYPE_TEXT` (mtmd.h L54-58, first enumerator = 0): the
/// only chunk type the T2 embed loop handles itself; everything else is
/// delegated to the upstream single-chunk helper. Re-validate on vendor-bump.
pub const MTMD_INPUT_CHUNK_TYPE_TEXT: c_int = 0;

/// Opaque handle: `struct mtmd_input_chunks` (mtmd.h L65; never dereferenced).
#[repr(C)]
pub struct mtmd_input_chunks {
    _opaque: [u8; 0],
}

/// Mirror of `struct mtmd_input_text` (mtmd.h L68-72, tag b9726): the prompt
/// text (with the media markers already inserted) plus how it is tokenized.
/// Passed by pointer to `mtmd_tokenize`; the borrowed C string must outlive
/// the call.
#[repr(C)]
pub struct mtmd_input_text {
    pub text: *const c_char,
    pub add_special: bool,
    pub parse_special: bool,
}

/// Mirror of `struct mtmd_helper_bitmap_wrapper` (mtmd-helper.h L34-37, tag
/// b9726): returned **by value** from `mtmd_helper_bitmap_init_from_buf`. Two
/// pointers, same layout rules as the param structs above. `video_ctx` is
/// populated only by the video branch, which is compiled out (`MTMD_VIDEO=OFF`,
/// build.rs), so it is always null for the image inputs this crate passes.
#[repr(C)]
pub struct mtmd_helper_bitmap_wrapper {
    pub bitmap: *mut mtmd_bitmap,
    pub video_ctx: *mut c_void,
}

extern "C" {
    // --- multimodal / libmtmd (WP-V1 + WP-V2, D-026) ---
    // The T1 (llm(projector=) + llm_generate(images=)) surface, kept to the
    // D-006 minimum: exactly the symbols the vision module calls. Deliberately
    // NOT declared, per the WP-V1 security audit's binding requirements
    // (docs/audit-wp-v1-mtmd-2026-07-14.md section 5):
    //   - `mtmd_helper_bitmap_init_from_file` (req 2: its C-side re-read of the
    //     path reopens the audio-magic sniff via a TOCTOU/symlink swap — the
    //     buffer variant below receives the exact bytes Rust already gated);
    //   - `mtmd_bitmap_init` / `mtmd_bitmap_init_from_audio` (req 6: raw
    //     dimension/PCM entry points that bypass the decode whose dims they
    //     must match — the memcpy length contract at mtmd.cpp L42-48);
    //   - `mtmd_helper_video_*` (req 6: `GGML_ASSERT(false)` abort stubs in an
    //     MTMD_VIDEO=OFF build, mtmd-helper.cpp L1034/L1044).

    /// mtmd.h L111. By-value defaults; ABI-pinned by the smoke test below.
    pub fn mtmd_context_params_default() -> mtmd_context_params;

    /// mtmd.h L109: the built-in media marker (`"<__media__>"`), a static
    /// engine-owned string. One marker per image is prepended to the prompt.
    pub fn mtmd_default_marker() -> *const c_char;

    /// mtmd.h L115-117: load an mmproj GGUF and bind the vision encoder to the
    /// already-loaded text model (shares the model pointer — no double-load).
    /// Returns NULL on any failure; the constructor validates the projector's
    /// embedding size against `llama_model_n_embd_inp(text_model)` itself
    /// (mtmd.cpp L370-375) and every `std::exception` is caught internally
    /// (mtmd.cpp L798-803), logged through `mtmd_log_set`.
    pub fn mtmd_init_from_file(
        mmproj_fname: *const c_char,
        text_model: *const llama_model,
        ctx_params: mtmd_context_params,
    ) -> *mut mtmd_context;

    /// mtmd.h L119.
    pub fn mtmd_free(ctx: *mut mtmd_context);

    /// mtmd.h L129: whether the loaded projector has a vision encoder (an
    /// audio-only mmproj loads fine but must be rejected for image input).
    pub fn mtmd_support_vision(ctx: *const mtmd_context) -> bool;

    /// mtmd.h L311: route libmtmd/clip logging through `log_callback` (NULL
    /// restores stderr). Installed once with a capturing ERROR-level filter so
    /// a projector-load / tokenize failure reason can be surfaced on the
    /// classed R condition instead of spraying the console.
    pub fn mtmd_log_set(log_callback: Option<GgmlLogCallback>, user_data: *mut c_void);

    /// mtmd-helper.h L55: decode one image from an in-memory file buffer (stb)
    /// into an owned RGB bitmap. THE single decode gateway (audit req 2): the
    /// buffer is the exact byte vector Rust read and gated (magic allow-list +
    /// size/dimension caps), so the audio sniff inside can never fire. Returns
    /// a by-value wrapper whose `bitmap` is NULL on failure.
    pub fn mtmd_helper_bitmap_init_from_buf(
        ctx: *mut mtmd_context,
        buf: *const u8,
        len: usize,
        placeholder: bool,
    ) -> mtmd_helper_bitmap_wrapper;

    /// mtmd.h L163.
    pub fn mtmd_bitmap_free(bitmap: *mut mtmd_bitmap);

    /// mtmd.h L202/L203/L204/L205: the caller-owned chunk-list lifecycle
    /// `mtmd_tokenize` fills.
    pub fn mtmd_input_chunks_init() -> *mut mtmd_input_chunks;
    pub fn mtmd_input_chunks_size(chunks: *const mtmd_input_chunks) -> usize;
    pub fn mtmd_input_chunks_get(
        chunks: *const mtmd_input_chunks,
        idx: usize,
    ) -> *const mtmd_input_chunk;
    pub fn mtmd_input_chunks_free(chunks: *mut mtmd_input_chunks);

    /// mtmd.h L214: the chunk's token count (KV-cache slots); summed over all
    /// chunks it is the combined text+image length checked against `n_ctx`.
    pub fn mtmd_input_chunk_get_n_tokens(chunk: *const mtmd_input_chunk) -> usize;

    /// mtmd.h L211: the chunk's kind — `enum mtmd_input_chunk_type` (mtmd.h
    /// L54-58: TEXT = 0, IMAGE = 1, AUDIO = 2). The T2 embed loop branches on
    /// TEXT vs media; the constant below pins the only value compared against.
    pub fn mtmd_input_chunk_get_type(chunk: *const mtmd_input_chunk) -> c_int;

    /// mtmd.h L212: the text chunk's token array (chunk-owned, valid while the
    /// chunk list lives), its length written to `n_tokens_output`. The T2 embed
    /// path decodes these through the crate's own flag-all `Batch` so every
    /// text position yields a per-token embedding row (the upstream helper
    /// flags none — see vision.rs / docs/wp-v3-embed-spike.md).
    pub fn mtmd_input_chunk_get_tokens_text(
        chunk: *const mtmd_input_chunk,
        n_tokens_output: *mut usize,
    ) -> *const llama_token;

    /// mtmd.h L218: the chunk's POSITION advance — equal to its token count
    /// for text, but smaller for M-RoPE image chunks (qwen-vl), which is why
    /// `n_past` accounting must use this, never the token count (matching
    /// mtmd-helper.cpp L331/L378).
    pub fn mtmd_input_chunk_get_n_pos(chunk: *const mtmd_input_chunk) -> llama_pos;

    /// mtmd.h L269-273: split the marker-bearing prompt into text/image chunks.
    /// Returns 0 on success, 1 on a marker/bitmap count mismatch, 2 on an image
    /// preprocessing error; exceptions are caught internally (mtmd.cpp L1424-1435).
    pub fn mtmd_tokenize(
        ctx: *mut mtmd_context,
        output: *mut mtmd_input_chunks,
        text: *const mtmd_input_text,
        bitmaps: *const *const mtmd_bitmap,
        n_bitmaps: usize,
    ) -> i32;

    /// mtmd-helper.h L74-81: the tested upstream interleaved ingest — decodes
    /// text chunks with `llama_decode` and image chunks with
    /// `mtmd_encode_chunk` -> `mtmd_get_output_embd` -> `llama_decode`,
    /// chunking BOTH by `n_batch` internally and handling the gemma3
    /// non-causal mask + qwen-vl M-RoPE positions (never reimplemented in
    /// Rust — the D-012 fails-silent trap; hard rule 8a chokepoint for this
    /// path). Returns 0 on success; writes the position after the last
    /// ingested token to `new_n_past`.
    pub fn mtmd_helper_eval_chunks(
        ctx: *mut mtmd_context,
        lctx: *mut llama_context,
        chunks: *const mtmd_input_chunks,
        n_past: llama_pos,
        seq_id: llama_seq_id,
        n_batch: i32,
        logits_last: bool,
        new_n_past: *mut llama_pos,
    ) -> i32;

    /// mtmd-helper.h L85-92: `mtmd_helper_eval_chunks` for ONE chunk. The T2
    /// embed path delegates each IMAGE chunk here unchanged (upstream owns the
    /// M-RoPE 2-D positions + the gemma3 non-causal toggle) while decoding the
    /// text chunks itself with all positions flagged for per-token rows — the
    /// mechanism the WP-V3 spike fixed (docs/wp-v3-embed-spike.md).
    pub fn mtmd_helper_eval_chunk_single(
        ctx: *mut mtmd_context,
        lctx: *mut llama_context,
        chunk: *const mtmd_input_chunk,
        n_past: llama_pos,
        seq_id: llama_seq_id,
        n_batch: i32,
        logits_last: bool,
        new_n_past: *mut llama_pos,
    ) -> i32;

    /// llama.h L563: the model's INPUT embedding width — what an mmproj must
    /// produce per image token (mtmd.h L284-287). Used to name the expected
    /// size on the mmproj-model mismatch condition. (mtmd.h exposes NO dim
    /// getter for the projector side: `clip_n_mmproj_embd` takes a `clip_ctx`
    /// the C API never surfaces — mtmd.h L61 keeps `mtmd_context` opaque and
    /// `n_embd_out()` is a private C++ member, mtmd.cpp L746-753 — so the
    /// projector's actual size is taken from the engine's own mismatch check,
    /// see vision.rs.)
    pub fn llama_model_n_embd_inp(model: *const llama_model) -> i32;

    /// stb_image.h L494 (impl L7734), compiled into libmtmd by mtmd-helper.cpp
    /// L32-33 with external linkage (`STBIDEF` = `extern`: STB_IMAGE_STATIC is
    /// not defined; symbol presence verified with `nm -gU libmtmd.a` ->
    /// `T _stbi_info_from_memory`). Parses ONLY the image header from the
    /// buffer — no pixel allocation — writing the dimensions to `x`/`y`;
    /// returns 1 on success, 0 on failure. The audit req-3 pre-decode
    /// dimension probe: it runs on the same gated buffer BEFORE
    /// `mtmd_helper_bitmap_init_from_buf`, so no oversized decode ever starts.
    pub fn stbi_info_from_memory(
        buffer: *const u8,
        len: c_int,
        x: *mut c_int,
        y: *mut c_int,
        comp: *mut c_int,
    ) -> c_int;
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

    /// WP-V1's ABI guard for the new by-value `mtmd_context_params` (the D-011
    /// `context_params` test's mirror for libmtmd): the struct is obtained and
    /// passed by value, so a reordered or misaligned `#[repr(C)]` mirror
    /// surfaces as *wrong default values*, not a link error. Every field's
    /// b9726 default (tools/mtmd/mtmd.cpp L240-256) is pinned by value, plus
    /// the total size. Model-free; runs per-commit in CI (`cargo test`) and
    /// doubles as the link-time proof that libmtmd.a is produced and linked.
    #[test]
    fn mtmd_context_params_defaults_have_the_expected_abi() {
        // SAFETY: default params are a plain by-value C struct we only read.
        let p = unsafe { mtmd_context_params_default() };
        assert!(p.use_gpu, "use_gpu default is true");
        assert!(p.print_timings, "print_timings default is true");
        assert_eq!(p.n_threads, 4, "n_threads default is 4");
        assert!(
            p.image_marker.is_null(),
            "image_marker (deprecated) is null"
        );
        assert!(
            !p.media_marker.is_null(),
            "media_marker default is non-null"
        );
        // SAFETY: media_marker is a static NUL-terminated string owned by the
        // engine (mtmd_default_marker(), mtmd.cpp L227-229).
        let marker = unsafe { std::ffi::CStr::from_ptr(p.media_marker) };
        assert_eq!(
            marker.to_str().expect("media_marker is valid UTF-8"),
            "<__media__>",
            "media_marker default is mtmd_default_marker()"
        );
        assert_eq!(p.flash_attn_type, -1, "LLAMA_FLASH_ATTN_TYPE_AUTO");
        assert!(p.warmup, "warmup default is true");
        assert_eq!(p.image_min_tokens, -1, "image_min_tokens default is -1");
        assert_eq!(p.image_max_tokens, -1, "image_max_tokens default is -1");
        assert!(p.cb_eval.is_null(), "cb_eval default is null");
        assert!(
            p.cb_eval_user_data.is_null(),
            "cb_eval_user_data default is null"
        );
        assert_eq!(p.batch_max_tokens, 1024, "batch_max_tokens default is 1024");

        // Size pin: catches a vendor-bump reordering/appending fields even where
        // the value checks would still pass by coincidence.
        assert_eq!(
            core::mem::size_of::<mtmd_context_params>(),
            64,
            "mtmd_context_params size drifted from b9726; re-verify the #[repr(C)] mirror"
        );
    }
}
