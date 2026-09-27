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
#' @return A character vector the same length as `prompt` (names preserved), each
#'   element the generated continuation. The seed used is attached as
#'   `attr(result, "seed")`.
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
                         images = NULL, schema = NULL) {
  if (!inherits(m, "llm")) {
    abort_argument("m", "`m` must be an `llm` handle returned by llm().")
  }
  ensure_open(m)

  if (!is.null(schema)) {
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
  check_prompt_markers(prompt, image_sets, arg_name = "prompt")
  max_bytes <- if (has_images) image_max_bytes() else relm_image_max_bytes_default
  check_images_usable(m, image_sets)

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
