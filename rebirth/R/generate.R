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
#' `rebirth_error_context_overflow`, whose message states by how much.
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
#' @return A character vector the same length as `prompt` (names preserved), each
#'   element the generated continuation. The seed used is attached as
#'   `attr(result, "seed")`.
#' @seealso [llm()], [llm_tokens()]
#' @examplesIf nzchar(Sys.getenv("REBIRTH_TEST_MODEL_QWEN"))
#' m <- llm(Sys.getenv("REBIRTH_TEST_MODEL_QWEN"))
#' llm_generate(m, "In one sentence, what is R?", max_tokens = 40, seed = 1)
#' close(m)
#' @export
llm_generate <- function(m, prompt, max_tokens = 256, temperature = 0.8,
                         top_p = 0.95, seed = NULL, chat = TRUE, stop = NULL) {
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
    prompt,
    function(p) {
      payload <- rebirth_check(rebirth_generate(
        m$ptr, p, chat,
        as.integer(max_tokens), as.double(temperature), as.double(top_p),
        seed_val, stop_seqs
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
