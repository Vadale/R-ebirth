#' Inspect the next-token distribution
#'
#' Runs a forward pass over each `prompt` and returns the model's distribution for
#' the single token that would come next: the `top` most likely candidates, ranked
#' from most to least probable. This is the raw material behind generation — the
#' first token [llm_generate()] would pick (greedily) is exactly this table's
#' rank-1 token.
#'
#' @details
#' Each prompt is treated as raw text (no chat template is applied — wrap it
#' yourself if you want the chat framing) and tokenized the way `chat = FALSE`
#' generation is. The distribution is read at the final position, so it answers
#' "what token does the model expect immediately after this text?". Probabilities
#' are the softmax over the **whole** vocabulary, computed before the `top`
#' candidates are selected, so each `prob` is the token's true share of the full
#' distribution: the returned probabilities are correct but (being only the head of
#' the distribution) sum to less than 1.
#'
#' The result is one long-format `data.frame` with `top` rows per prompt, stacked
#' in prompt order. Within each prompt the rows are ordered by descending logit,
#' so `rank == 1` is the most likely next token; `logit` and `prob` are therefore
#' non-increasing down the ranks. Token ids are **1-based** (like every index in
#' `rebirth`, and like [llm_tokens()]), so `token_id` round-trips through
#' `llm_tokens(m, token_id, decode = TRUE)`.
#'
#' Active interventions on `m` (from [llm_steer()]/[llm_ablate()]) apply, so
#' `llm_logits()` is the direct way to read how a steer or an ablation reshapes the
#' next-token distribution.
#'
#' The model must carry a tokenizer; a `no_vocab` model (such as the in-repo
#' synthetic model) raises `rebirth_error_tokenize`. No model ships inside the
#' package yet, so the runnable example is guarded by the `REBIRTH_TEST_MODEL_QWEN`
#' environment variable — point it at a local Qwen2.5 GGUF to run it.
#'
#' @param m An `llm` handle from [llm()].
#' @param prompt A character vector of prompts; the result has `top` rows per
#'   prompt, and `prompt_id` is the 1-based index into `prompt`.
#' @param top Single positive integer: how many top candidates to return per prompt
#'   (clamped to the vocabulary size). Default 20.
#' @return A base `data.frame` with `top` rows per prompt and columns
#'   `prompt_id` (int, 1-based index into `prompt`), `rank` (int, 1 = most likely),
#'   `token_id` (int, 1-based), `token` (chr, the token piece), `logit` (dbl), and
#'   `prob` (dbl, softmax over the full vocabulary).
#' @seealso [llm()], [llm_generate()], [llm_tokens()]
#' @examplesIf nzchar(Sys.getenv("REBIRTH_TEST_MODEL_QWEN"))
#' m <- llm(Sys.getenv("REBIRTH_TEST_MODEL_QWEN"))
#' llm_logits(m, "The capital of France is", top = 5)
#' close(m)
#' @export
llm_logits <- function(m, prompt, top = 20) {
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
  if (!is_count(top) || top < 1L || top > .Machine$integer.max) {
    abort_argument("top", "`top` must be a single positive integer.")
  }
  top_i <- as.integer(top)

  blocks <- lapply(seq_along(prompt), function(i) {
    payload <- rebirth_check(rebirth_logits(m$ptr, prompt[[i]], top_i))
    n <- length(payload$token_id)
    data.frame(
      prompt_id = rep.int(i, n),
      rank = seq_len(n),
      token_id = as.integer(payload$token_id),
      token = payload$token,
      logit = payload$logit,
      prob = payload$prob,
      stringsAsFactors = FALSE
    )
  })

  out <- do.call(rbind, blocks)
  row.names(out) <- NULL
  out
}
