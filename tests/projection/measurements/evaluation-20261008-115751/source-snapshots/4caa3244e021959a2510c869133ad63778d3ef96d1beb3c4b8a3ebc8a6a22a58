#' Generate text from a model
#'
#' Autoregressively continues each `prompt`. With `chat = TRUE` (the default) the
#' prompt is wrapped as a user turn using the model's own chat template, so the
#' formatting matches what the model was trained on; with `chat = FALSE` the
#' prompt is completed verbatim.
#'
#' @details
#' Decoding is greedy when `temperature = 0` — the exact, reproducible path — and
#' temperature + nucleus (top-p) sampling otherwise. Sampling is drawn on the CPU
#' from a seeded generator, so a run is fully reproducible: the same `seed` and
#' arguments produce the same text across runs and sessions. When `seed = NULL`
#' a seed is drawn (from R's RNG, so `set.seed()` makes even that reproducible)
#' and **recorded** — the seed actually used is always returned as
#' `attr(result, "seed")`, so any generation can be replayed.
#'
#' Without a schema, generation stops at `max_tokens`, at the model's
#' end-of-generation token, or
#' as soon as one of the `stop` strings appears (the output is truncated just
#' before it). A prompt longer than the model's context window raises
#' `relm_error_context_overflow`, whose message states by how much.
#'
#' With the supported Spark-X2.5 chat template, ordinary chat opens the response
#' with the author's `<think>` marker. Generated reasoning text and closing
#' markers are returned as generated and count toward `max_tokens`. With a
#' `schema`, chat instead uses the author's `</think>` non-thinking opener, so
#' the JSON constraint starts at the first generated token. This does not strip
#' or repair model output. Spark chat supports the pinned official template and
#' the existing single user turn; custom templates require `chat = FALSE` and
#' caller-supplied formatting. Other models keep their existing chat behavior.
#'
#' @section Background generation:
#' `async = TRUE` requires optional packages later (>= 1.4.8) and promises
#' (>= 1.5.0), and returns a promise resolving to the same named character vector
#' and seed attribute. Generation runs on a native worker using the loaded model.
#' Only one native job may run per R process; competing native operations raise
#' `relm_error_busy`. Ordinary R calculations and metadata printing remain usable.
#' R validation and admission precede the omitted-seed draw. Execution errors
#' reject the promise with their classed conditions. Use [llm_cancel()] to request
#' cooperative cancellation, or [close()][close.llm] to close the handle.
#'
#' Optional `on_progress(state)` runs on R's thread with a fresh one-row
#' `data.frame`: integer columns `prompt_id`, `prompts_completed`, `prompts_total`,
#' `generated_tokens`, `max_tokens`, then character `phase` (`"prefill"`,
#' `"generate"`, `"complete"`). Snapshots are coalesced and may skip intermediate
#' states; generated tokens count the current prompt, including removed stop
#' suffixes. Success delivers one final `complete` snapshot before resolving.
#' A callback error requests cancellation and rejects with `relm_error_callback`,
#' retaining the original condition in `parent`. Callback return values are ignored.
#'
#' One timer checks progress at a 50 ms target interval on the global event loop.
#' Callbacks normally run at the interactive prompt. In scripts, attach handlers
#' with `promises::then()` and pump `later::run_now()` until your handler records
#' completion. A long R expression delays delivery; a slow callback can block R.
#' Dropping the promise or handle does not cancel a pending job. Namespace
#' shutdown requests cancellation and joins the worker. The native library stays
#' mapped so retained external-pointer finalizers can run safely. Forced
#' `dyn.unload()` while external pointers remain alive is unsupported.
#'
#' Async accepts at most 128 prompts, 1 MiB UTF-8 per prompt, 16 MiB total copied
#' text (including names, stop strings, schema and image paths), and 8192 tokens
#' per prompt. A separate 16 MiB descriptor budget bounds retained string/vector
#' overhead, including empty strings. Output is limited to 8 MiB UTF-8 per call (`relm_error_oom`);
#' existing stricter schema and image limits also apply. Nothing is truncated
#' or retried to satisfy these bounds. Native cancellation is cooperative and
#' may wait for an in-flight decode or image encoder call to finish.
#' The 8 MiB output cap measures UTF-8 text bytes, not resident memory: copied
#' inputs, templates, token vectors, transient output buffers and R character
#' objects need additional storage. Existing model/context, sampler/grammar and
#' vision working memory are separate from these transport limits.
#'
#' @section Token streaming:
#' Supply `on_token = function(batch) ...` to receive nonempty plain data frames
#' on R's thread. Each dispatch contains at most 64 rows and 64 KiB of text.
#' The columns, in order, are integer `event_id`, character `event`, integer
#' `prompt_id`, integer `token_pos`, integer `token_id`, character `text`, double
#' `elapsed`, character `finish_reason`, and logical `validated`. Event IDs are
#' contiguous across the call; prompt IDs and vocabulary token IDs are 1-based.
#'
#' `event = "token"` records each sampled non-EOG token, including tokens later
#' removed with a stop suffix or sampled at context exhaustion. `token_pos` is
#' its generated position. `event = "text"` carries a nonempty committed UTF-8
#' delta; concatenating these per prompt reproduces the successful returned
#' string exactly. Tokens and text chunks need not correspond one-to-one.
#' `event = "prompt_end"` records `finish_reason` (`"length"`, `"stop"`,
#' `"stop_string"`, or `"context_full"`). Non-token rows have missing token
#' fields; non-text rows have empty `text`; non-end rows have empty
#' `finish_reason`. `elapsed` is nonnegative monotonic production time in seconds
#' since submission. `validated` is missing for ordinary generation, `FALSE`
#' for structured token/text, and `TRUE` for a successful structured prompt end.
#' Structured text is provisional until that prompt's independent schema
#' validation succeeds; this validates format, not factual accuracy.
#'
#' Alternatively, supply a writable binary base `file()` connection to an empty
#' regular local file at position zero. Append, text, compressed, raw, socket,
#' pipe and device connections are rejected. relm neither opens nor closes the
#' connection. Do not independently seek, write, truncate or replace its file
#' until settlement. CSV contains one header, UTF-8 bytes, LF delimiters, comma
#' separators and no row names. Character fields are always quoted; embedded
#' quotes are doubled. Missing numeric/logical fields are empty; elapsed uses
#' round-trip numeric precision independently of print options. Read it with:
#' \preformatted{
#' read.csv(path, fileEncoding = "UTF-8", check.names = FALSE,
#'   na.strings = character(),
#'   colClasses = c("integer", "character", "integer", "integer", "integer",
#'                 "character", "numeric", "character", "logical"))
#' }
#' The connection is flushed after batches and before success; no atomic commit
#' or disk-durability guarantee is made. Failed calls may leave a delivered
#' prefix or an incomplete record. Successful settlement establishes completion.
#'
#' Streaming retains the execution reservation until all batches are delivered.
#' Native operations from every `on_token`, including the last, see busy; final
#' `on_progress` runs after release. Closing the model before release abandons
#' delivery and rejects an otherwise successful result with
#' `relm_error_cancelled`, reason `stream_closed`. A token/progress callback error
#' or interrupt rejects with `relm_error_callback`, identifying `callback` and
#' preserving the original `parent`. Connection and representation failures use
#' `relm_error_stream`, with `reason`, `prompt_id`, `event_id` and `parent` when
#' available. The first consumer failure takes precedence over subsequent native
#' errors; once a native failure is observed, remaining events are discarded.
#'
#' A slow consumer applies backpressure to a queue bounded at 256 rows and
#' 256 KiB text, with text chunks at most 16 KiB. Callbacks and file writes run
#' synchronously on R and can block it. Batch boundaries and elapsed times vary
#' across runs. Consumer side effects remain on failure, and caller-retained
#' batches are outside relm's memory estimate. `on_token = NULL` retains the
#' ordinary async behavior without a stream queue.
#'
#' @section Live state observation:
#' `on_state = function(state) ...` observes each sampled non-EOG token on the
#' same generation context. It requires `async = TRUE`, one text prompt,
#' `max_tokens <= 1024`, no images and no schema. The named list contains `step`,
#' `logits` and `trace`; return `invisible(NULL)` to continue. Call [llm_cancel()]
#' from the callback to stop before another token is sampled. Cancellation still
#' rejects the promise, and callbacks can block R while they run.
#'
#' `step` is one plain data-frame row: integer `state_id`, `prompt_id`,
#' `token_pos`, `token_id`, `context_pos`, `source_pos`, character `source`,
#' double `elapsed`, followed by integer `steering_revision`,
#' `applied_after_state` and `effective_source_pos`. Let P be the actual
#' templated prompt token count and k the
#' generated position. The sampled token belongs at `context_pos = P + k`;
#' the forward pass selecting it came from `source_pos = P + k - 1`.
#' `source` is `"prompt"` for the first state and `"generated"` thereafter.
#' Positions and vocabulary IDs are 1-based. A last sampled token may remain
#' undecoded at a context/stop boundary; the state describes its valid source.
#'
#' `logits` has [llm_logits()]'s six columns, raw logits and full-vocabulary
#' softmax probabilities before temperature/top-p sampling. `top = 0` disables
#' this table. `trace` is a bounded `relm_trace` for one source position, with
#' `position_space = "model_context"`, `prompt_token_count` and `state_id`
#' attributes. Its token positions identify the source, not the sampled token.
#' `layers = integer()` captures no activations; `NULL` explicitly selects all
#' blocks. Selected residuals include interventions already applied to the handle.
#'
#' A callback may instead return exactly
#' `list(steer = data.frame(intervention = 1L, coef = 0))` to change coefficients
#' of existing steering entries. Indices address `m$interventions` (including
#' intervening ablation entries); only steering entries may be updated. Partial
#' replies retain other coefficients; an empty table or unchanged values do not
#' advance the revision. Replies are validated atomically, including finite
#' float32-range coefficients and finite summed layer vectors. Invalid replies
#' reject with `relm_error_callback`, `callback = "on_state"`,
#' `reason = "state_reply"`, preserving the original condition as `parent`.
#'
#' A changed reply to state k affects the decode of token k and sampling of
#' token k+1, never the already sampled token k or historical KV entries.
#' `attr(state, "steering")` is a worker-produced data frame with integer
#' `intervention`, integer `layer` and double `coef`, sorted by original index.
#' Its coefficients and the three audit columns describe the adapters actually
#' used for the reported state. Baseline audit values are 0, 0 and 1. A change
#' from state k advances the revision and becomes effective at source position
#' P+k; a terminal reply has no promised later-state receipt. Zero removes that
#' entry's contribution. Ablation still follows steering.
#'
#' The original adapters are restored before model ownership returns, including
#' cancellation and failure. The R handle and other handles are unchanged; a
#' subsequent fresh generation uses the original coefficients. Changing back
#' during a running generation does not undo its earlier effects on KV history.
#' Direction, layer and ablation changes are unavailable in this reply protocol.
#'
#' One state waits for acknowledgement. All earlier token events are delivered
#' before `on_state`; the current token/text events and the next decode follow
#' the callback. No state is emitted for EOG. Removed stop-suffix tokens still
#' have states. Inside the callback the handle remains busy; other native model
#' operations are unavailable, while pure R calculations and lazy trace reads
#' remain possible. A 5 ms polling target replaces the ordinary 50 ms target
#' only for live calls; delivery depends on R's event loop.
#'
#' State materialization is bounded by the smaller of `relm.trace_budget` and
#' 32 MiB, including metadata and conversion accounting. Oversized activations
#' spill to completed Arrow files when `spill = TRUE`; otherwise admission
#' raises `relm_error_oom`. A single activation vector is limited to 1 MiB f32,
#' capture/writer transport to 8 MiB plus accounted scratch, and conservative
#' whole-call spill output to 2 GiB / 1024 files. Bounds do not cover model/KV
#' memory, allocator overhead or objects retained/copied by user code. Managed
#' files survive job/model closure until session cleanup; custom directories
#' remain caller-managed. Callback failures retain their original condition
#' in `relm_error_callback`, with `callback = "on_state"`.
#'
#' @section Structured output:
#' Supply `schema` as JSON text to constrain text generation to a bounded subset
#' of JSON Schema 2020-12. The root must be a non-nullable object with explicit
#' `properties`, `required` listing every property exactly once, and
#' `additionalProperties: false`. Nested objects follow the same rules. Supported
#' values are bounded strings (`maxLength`, optional `minLength`), non-nullable
#' string enums, integers with explicit `minimum` and `maximum` in the signed
#' 32-bit range, booleans, null, and nullable versions of these types. Nullable
#' enums, arrays, fractional numbers and all other keywords (including
#' annotations) are rejected. Optional root `$schema` must be
#' `"https://json-schema.org/draft/2020-12/schema"`.
#'
#' The schema is compiled once per call; each prompt uses fresh grammar state
#' and the same scalar seed. Every successful element is complete, independently
#' validated JSON text. Keys are generated in UTF-8 lexicographic order. String
#' lengths count decoded Unicode scalar values; duplicate keys and invalid
#' Unicode are rejected. Describe the task and fields in the prompt: a schema
#' constrains output structure, not factual correctness.
#'
#' Nonempty `stop` or image collections cannot be combined with a schema. Empty
#' collections count as absent, and vision handles may make text-only structured
#' requests. Generation returns when the root object is complete, including on
#' the last allowed token. It does not retry, repair or return incomplete JSON.
#' Malformed, unsupported or oversized schemas raise `relm_error_schema` with
#' `reason` and `schema_path` (a JSON pointer). Generation failure raises
#' `relm_error_structured_output` with `reason`, 1-based `prompt_id`, `seed`,
#' `generated_tokens` and bounded `partial_bytes` (a raw vector). The first
#' failed prompt aborts the call; no partial result vector is returned. Input
#' context overflow retains `relm_error_context_overflow`.
#'
#' Hard limits: schema text 64 KiB, nesting 8, schema nodes 128, 16 properties
#' per object and 64 total; 32 enum members of at most 128 Unicode scalar values;
#' string `maxLength` 2048; compiled grammar 512 KiB and 65536 elements. A call
#' accepts at most 128 prompts, 1 MiB per prompt and 16 MiB total UTF-8 input,
#' with `max_tokens <= 8192`. Temperature must be finite and fit a 32-bit float;
#' an explicit seed must be finite and less than `2^64` (subject to R's numeric
#' precision). Output is limited to 64 KiB per prompt and 8 MiB
#' per call. `schema = NULL` preserves ordinary text and vision generation.
#'
#' @section Image input (vision models):
#' On a handle loaded with [llm()]'s `projector` argument, `images` attaches
#' image files to each prompt: a **list parallel to `prompt`**, where
#' `images[[i]]` is a character vector of image file paths for prompt `i`
#' (`character(0)` for none). A bare character vector is treated as
#' `list(images)` — one image set — and pairs with a single prompt; with
#' several prompts it is recycled across all of them with a warning (an empty
#' vector is the same as `NULL`: no images, no warning). Each
#' prompt's images are inserted **before** its text. Exactly three file
#' formats are accepted: **JPEG, PNG, BMP** (anything else — GIF and audio
#' included — is rejected before any decode with `relm_error_image`). Size
#' limits, enforced before decoding: at most 64 MB per file by default
#' (override with `options(relm.image_max_bytes = )`; hard ceiling
#' 2147483647 bytes), each dimension between 1 and 16384 pixels, and at most
#' 33554432 total pixels. Images on a handle loaded without a projector raise
#' `relm_error_image`; the combined text+image token count must fit
#' `context_length` (`relm_error_context_overflow` states by how much).
#'
#' One content restriction applies to an image-bearing prompt: the literal
#' string `"<__media__>"` (the engine's internal media marker) is reserved —
#' relm inserts one marker per image before the text, so a literal marker in
#' the prompt would corrupt the image placement, and the call raises
#' `relm_error_argument` naming `prompt`. Prompts without images may contain
#' the string freely (it is ordinary text there).
#'
#' @param m An `llm` handle from [llm()].
#' @param prompt A character vector of prompts; the result has one element per
#'   prompt and preserves `names(prompt)`.
#' @param max_tokens Single positive integer: the maximum number of tokens to
#'   generate per prompt.
#' @param temperature Single non-negative number. `0` is greedy (deterministic);
#'   higher values sample more diversely.
#' @param top_p Single number in `(0, 1]`: nucleus sampling keeps the most
#'   probable tokens whose cumulative probability reaches `top_p`.
#' @param seed `NULL` (draw and record a seed) or a single non-negative whole
#'   number for a reproducible run.
#' @param chat Single logical. `TRUE` applies the model's chat template; `FALSE`
#'   completes the raw prompt. If the model's embedded template cannot be detected
#'   by the engine (e.g. some Gemma models), a built-in template for the model's
#'   architecture is used instead; if neither applies, a classed error is raised
#'   rather than mis-formatting the prompt.
#' @param stop `NULL`, or a character vector of stop sequences that end
#'   generation.
#' @param images `NULL` (default: text-only, unchanged) or the image file
#'   paths to attach to each prompt — a list parallel to `prompt`, or a bare
#'   character vector for a single prompt. Accepted formats: JPEG, PNG, BMP.
#'   Requires a handle loaded with `llm(projector = )`; see the *Image input*
#'   section.
#' @param schema `NULL` (default) or one non-NA UTF-8 string containing JSON
#'   Schema text in the supported profile. This is JSON text, not a file path or
#'   R list; one schema applies to every prompt. See *Structured output*.
#' @param async One nonmissing logical. `FALSE` returns synchronously; `TRUE`
#'   returns a promises promise backed by native background generation.
#' @param on_progress `NULL` or a function accepting one progress data frame.
#'   Requires `async = TRUE`; see *Background generation*.
#' @param on_token `NULL`, a function accepting one event data frame, or an
#'   already-open writable binary base `file()` connection. Requires
#'   `async = TRUE`; see *Token streaming*.
#' @param on_state `NULL` or a function receiving one live state; requires
#'   background text-only generation. Return NULL to continue or a coefficient
#'   reply for existing steering entries; see *Live state observation*.
#' @param layers Live capture block indices: integer() for logits only, NULL for
#'   all blocks, or unique valid 1-based indices.
#' @param components Live capture components, using [llm_trace()]'s meanings.
#' @param top Number of raw logit summaries per live state, from 0 through
#'   min(128, vocabulary size).
#' @param spill Whether over-budget live activations may spill to Arrow files.
#' @param spill_dir NULL for managed session storage, or a custom directory.
#'   Capture arguments require a non-NULL `on_state`.
#' @return A character vector the same length as `prompt` (names preserved), each
#'   element the generated continuation. The seed used is attached as
#'   `attr(result, "seed")`. With `async = TRUE`, a promise resolving to that vector.
#' @seealso [llm()], [llm_tokens()]
#' @examplesIf nzchar(Sys.getenv("RELM_TEST_MODEL_QWEN"))
#' m <- llm(Sys.getenv("RELM_TEST_MODEL_QWEN"))
#' llm_generate(m, "In one sentence, what is R?", max_tokens = 40, seed = 1)
#' schema <- paste0('{"type":"object","properties":{"answer":',
#'   '{"type":"string","enum":["yes","no"]}},',
#'   '"required":["answer"],"additionalProperties":false}')
#' llm_generate(m, 'Is R a programming language? Return an object with "answer".',
#'   schema = schema, max_tokens = 64, temperature = 0, seed = 1)
#' close(m)
#' @examplesIf nzchar(Sys.getenv("RELM_TEST_MODEL_VLM")) && nzchar(Sys.getenv("RELM_TEST_MMPROJ_VLM"))
#' # Image input (requires a projector -- see llm()).
#' m <- llm(Sys.getenv("RELM_TEST_MODEL_VLM"),
#'   projector = Sys.getenv("RELM_TEST_MMPROJ_VLM")
#' )
#' img <- file.path(tempdir(), "square.png")
#' png(img, width = 224, height = 224)
#' par(mar = c(0, 0, 0, 0))
#' plot.new()
#' rect(0.3, 0.3, 0.7, 0.7, col = "red", border = NA)
#' dev.off()
#' llm_generate(m, "What color is the square?",
#'   images = img,
#'   max_tokens = 16, temperature = 0
#' )
#' close(m)
#' @export
llm_generate <- function(m, prompt, max_tokens = 256, temperature = 0.8,
                         top_p = 0.95, seed = NULL, chat = TRUE, stop = NULL,
                         images = NULL, schema = NULL, async = FALSE,
                         on_progress = NULL, on_token = NULL, on_state = NULL,
                         layers = integer(), components = "residual", top = 20L,
                         spill = TRUE, spill_dir = NULL) {
  if (!inherits(m, "llm")) {
    abort_argument("m", "`m` must be an `llm` handle returned by llm().")
  }
  ensure_open(m)

  if (!is.logical(async) || length(async) != 1L || is.na(async)) {
    abort_argument("async", "`async` must be one nonmissing logical value.")
  }
  if (!is.null(on_progress) && (!is.function(on_progress) || !async)) {
    abort_argument("on_progress", "`on_progress` must be NULL or a function, and requires `async = TRUE`.")
  }
  stream <- stream_validate_sink(on_token, async)

  if (!is.null(schema) || async) {
    # Complex numbers satisfy is.numeric() but cannot enter the ordered real
    # comparisons below. Keep the ordinary generation path unchanged.
    scalars <- list(max_tokens = max_tokens, temperature = temperature,
      top_p = top_p, seed = seed)
    for (argument in names(scalars)) {
      if (is.complex(scalars[[argument]])) {
        abort_argument(argument, sprintf("`%s` must be a real number.", argument))
      }
    }
  }

  if (!is.character(prompt) || length(prompt) == 0L || anyNA(prompt)) {
    abort_argument(
      "prompt",
      "`prompt` must be a non-empty character vector without NA."
    )
  }
  # Reject before normalize_images() can replicate an image-list row for every
  # prompt. The complete byte/descriptor checks still run before native copies.
  if (async && length(prompt) > relm_async_max_prompts) {
    abort_argument("prompt", "Async generation accepts at most 128 prompts per call.")
  }
  if (!is_count(max_tokens) || max_tokens < 1L || max_tokens > .Machine$integer.max) {
    abort_argument("max_tokens", "`max_tokens` must be a single positive integer.")
  }
  if (!is.numeric(temperature) || length(temperature) != 1L || is.na(temperature) ||
    temperature < 0) {
    abort_argument(
      "temperature",
      "`temperature` must be a single non-negative number (0 = greedy)."
    )
  }
  if (!is.numeric(top_p) || length(top_p) != 1L || is.na(top_p) ||
    top_p <= 0 || top_p > 1) {
    abort_argument("top_p", "`top_p` must be a single number in (0, 1].")
  }
  if (!is.logical(chat) || length(chat) != 1L || is.na(chat)) {
    abort_argument("chat", "`chat` must be a single logical value (TRUE or FALSE).")
  }
  if (!is.null(stop) && (!is.character(stop) || anyNA(stop))) {
    abort_argument("stop", "`stop` must be NULL or a character vector without NA.")
  }
  stop_seqs <- if (is.null(stop)) character(0) else stop

  if (!is.null(schema)) {
    if (!is.character(schema) || length(schema) != 1L || is.na(schema)) {
      abort_argument("schema", "`schema` must be NULL or one non-NA UTF-8 string of JSON text.")
    }
    # Bound the supplied bytes before any encoding conversion or native copy.
    if (nchar(schema, type = "bytes") > relm_structured_max_schema_bytes) {
      relm_abort("relm_error_schema", "`schema` exceeds the 64 KiB limit.",
        list(reason = "schema_bytes", schema_path = ""))
    }
    if (Encoding(schema) == "bytes" || !validUTF8(schema)) {
      relm_abort("relm_error_schema", "`schema` must contain valid UTF-8 text.",
        list(reason = "invalid_utf8", schema_path = ""))
    }
    schema <- enc2utf8(schema)
    if (nchar(schema, type = "bytes") > relm_structured_max_schema_bytes) {
      relm_abort("relm_error_schema", "`schema` exceeds the 64 KiB UTF-8 limit.",
        list(reason = "schema_bytes", schema_path = ""))
    }
    if (length(prompt) > relm_structured_max_prompts) {
      abort_argument("prompt", "Structured generation accepts at most 128 prompts per call.")
    }
    prompt_bytes <- nchar(prompt, type = "bytes")
    if (any(prompt_bytes > relm_structured_max_prompt_bytes) ||
      sum(prompt_bytes) > relm_structured_max_total_prompt_bytes) {
      abort_argument("prompt", "Structured prompts are limited to 1 MiB each and 16 MiB per call.")
    }
    if (any(Encoding(prompt) == "bytes") || !all(validUTF8(prompt))) {
      abort_argument("prompt", "Structured prompts must contain valid UTF-8 text.")
    }
    prompt <- enc2utf8(prompt)
    prompt_bytes <- nchar(prompt, type = "bytes")
    if (any(prompt_bytes > relm_structured_max_prompt_bytes) ||
      sum(prompt_bytes) > relm_structured_max_total_prompt_bytes) {
      abort_argument("prompt", "Structured prompts are limited to 1 MiB each and 16 MiB per call in UTF-8.")
    }
    if (max_tokens > relm_structured_max_tokens) {
      abort_argument("max_tokens", "Structured generation requires `max_tokens <= 8192`.")
    }
    if (!is.finite(temperature) || temperature > relm_structured_max_temperature) {
      abort_argument("temperature", "Structured generation requires a finite temperature that fits a 32-bit float.")
    }
    if (length(stop_seqs) > 0L) {
      abort_argument("stop", "`stop` must be empty when `schema` is supplied.")
    }
    # Unlike a malformed pairing, a completely empty list carries no images.
    if (is.list(images) && length(images) == 0L) images <- NULL
  }

  # Images (WP-V2, D-026): normalize the pairing (relm_error_argument), then —
  # only when a prompt actually carries images — validate the byte-cap option
  # (argument domain, so a broken option is caught even before the vision
  # checks) and require a vision handle + existing files (relm_error_image).
  # NULL images leaves the pre-WP-V2 text path untouched.
  image_sets <- normalize_images(images, length(prompt))
  has_images <- !is.null(image_sets) && any(lengths(image_sets) > 0L)
  if (!is.null(schema) && has_images) {
    abort_argument("images", "Image-bearing requests cannot be combined with `schema`.")
  }
  live <- live_validate_arguments(m, prompt, max_tokens, async, on_state,
    layers, components, top, spill, spill_dir, schema, has_images)
  check_prompt_markers(prompt, image_sets, arg_name = "prompt")
  max_bytes <- if (has_images) image_max_bytes() else relm_image_max_bytes_default
  if (async) {
    checked <- async_validate_inputs(prompt, stop_seqs, schema, image_sets,
      max_tokens, temperature, seed)
    prompt <- checked$prompt
    stop_seqs <- checked$stop
    schema <- checked$schema
    image_sets <- checked$images
  }
  check_images_usable(m, image_sets)
  if (async) {
    async_check_dependencies()
    # Admission precedes the omitted-seed draw. This reaches no model pointer
    # and performs no inference; the native submit repeats the admission check.
    relm_check(rebirth_async_ready(m$ptr))
    live <- live_prepare(live, m, prompt, max_tokens)
    if (!is.null(live)) {
      # Live metadata shares the ordinary aggregate text/descriptor limits.
      # Count the normalized config before drawing an omitted seed; native
      # submission repeats this complete check before owning string copies.
      async_validate_inputs(prompt, stop_seqs, schema, image_sets,
        max_tokens, temperature, seed, live_config_strings(live$native_config))
    }
  }

  if (is.null(seed)) {
    # Draw from R's RNG so set.seed() makes even an unspecified seed reproducible.
    seed_val <- as.double(sample.int(.Machine$integer.max, 1L))
  } else {
    if (!is.numeric(seed) || length(seed) != 1L || is.na(seed) ||
      seed < 0 || seed != round(seed)) {
      abort_argument(
        "seed",
        "`seed` must be NULL or a single non-negative whole number."
      )
    }
    if (!is.null(schema) && (!is.finite(seed) || seed >= relm_structured_seed_limit)) {
      abort_argument("seed", "Structured generation requires a finite seed less than 2^64.")
    }
    seed_val <- as.double(seed)
  }

  if (async) {
    return(async_generate(m, prompt, chat, as.integer(max_tokens),
      as.double(temperature), as.double(top_p), seed_val, stop_seqs,
      image_sets, max_bytes, schema, on_progress, stream, live))
  }

  out <- if (!is.null(schema)) {
    payload <- relm_check(rebirth_generate_structured(
      m$ptr, prompt, chat,
      as.integer(max_tokens), as.double(temperature), as.double(top_p),
      seed_val, schema
    ))
    payload$text
  } else vapply(
    seq_along(prompt),
    function(i) {
      imgs <- if (is.null(image_sets)) character(0) else path.expand(image_sets[[i]])
      payload <- relm_check(rebirth_generate(
        m$ptr, prompt[[i]], chat,
        as.integer(max_tokens), as.double(temperature), as.double(top_p),
        seed_val, stop_seqs, imgs, max_bytes
      ))
      payload$text
    },
    character(1),
    USE.NAMES = FALSE
  )

  names(out) <- names(prompt)
  attr(out, "seed") <- seed_val
  out
}

# D-030 bounds duplicated at the native boundary; Rust tests twin-pin these
# decimal literals so neither side can silently drift.
relm_structured_max_schema_bytes <- 65536
relm_structured_max_prompts <- 128
relm_structured_max_prompt_bytes <- 1048576
relm_structured_max_total_prompt_bytes <- 16777216
relm_structured_max_tokens <- 8192
relm_structured_max_temperature <- 3.4028234663852886e38
relm_structured_seed_limit <- 18446744073709551616
