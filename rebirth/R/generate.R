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
#' Generation stops at `max_tokens`, at the model's end-of-generation token, or
#' as soon as one of the `stop` strings appears (the output is truncated just
#' before it). A prompt longer than the model's context window raises
#' `relm_error_context_overflow`, whose message states by how much.
#'
#' @section Image input (vision models):
#' On a handle loaded with [llm()]'s `projector` argument, `images` attaches
#' image files to each prompt: a **list parallel to `prompt`**, where
#' `images[[i]]` is a character vector of image file paths for prompt `i`
#' (`character(0)` for none). A bare character vector is treated as
#' `list(images)` — one image set — and pairs with a single prompt; with
#' several prompts it is recycled across all of them with a warning. Each
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
#' @return A character vector the same length as `prompt` (names preserved), each
#'   element the generated continuation. The seed used is attached as
#'   `attr(result, "seed")`.
#' @seealso [llm()], [llm_tokens()]
#' @examplesIf nzchar(Sys.getenv("RELM_TEST_MODEL_QWEN"))
#' m <- llm(Sys.getenv("RELM_TEST_MODEL_QWEN"))
#' llm_generate(m, "In one sentence, what is R?", max_tokens = 40, seed = 1)
#' close(m)
#' @export
llm_generate <- function(m, prompt, max_tokens = 256, temperature = 0.8,
                         top_p = 0.95, seed = NULL, chat = TRUE, stop = NULL,
                         images = NULL) {
  if (!inherits(m, "llm")) {
    abort_argument("m", "`m` must be an `llm` handle returned by llm().")
  }
  ensure_open(m)

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

  # Images (WP-V2, D-026): normalize the pairing (relm_error_argument), then —
  # only when a prompt actually carries images — validate the byte-cap option
  # (argument domain, so a broken option is caught even before the vision
  # checks) and require a vision handle + existing files (relm_error_image).
  # NULL images leaves the pre-WP-V2 text path untouched.
  image_sets <- normalize_images(images, length(prompt))
  check_prompt_markers(prompt, image_sets, arg_name = "prompt")
  has_images <- !is.null(image_sets) && any(lengths(image_sets) > 0L)
  max_bytes <- if (has_images) image_max_bytes() else 64 * 1024^2
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
    seed_val <- as.double(seed)
  }

  out <- vapply(
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
