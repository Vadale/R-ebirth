#' Embed text with a model
#'
#' Encodes each string in `x` into a fixed-length numeric vector, returning a base
#' `matrix` with one row per input and one column per embedding dimension (so the
#' matrix is `length(x)` by the model's `hidden_size`).
#'
#' @details
#' Each input is tokenized (with the model's begin/end-of-sequence markers) and run
#' through a forward pass in a dedicated embeddings-mode context; the per-token
#' hidden states are then pooled into one vector per input by `pooling`. `"mean"`
#' averages the token vectors, `"last"` takes the final token's vector, and
#' `"model"` uses the model's own pooling when the GGUF defines one (a purely
#' generative model such as Qwen2.5 defines none, so `"model"` raises
#' `relm_error_embed` asking for `"mean"` or `"last"`).
#'
#' With `normalize = TRUE` (the default) each row is L2-normalized to a unit
#' vector, so the dot product of two rows is their cosine similarity. A zero vector
#' is returned unchanged (never `NaN`). `normalize` is validated and its effect is
#' explicit — there is no silent normalization.
#'
#' The model must carry a tokenizer; a `no_vocab` model raises
#' `relm_error_tokenize`. No model ships inside the package yet (the in-repo
#' synthetic model has no tokenizer), so the runnable example is guarded by the
#' `RELM_TEST_MODEL_QWEN` environment variable — point it at a local Qwen2.5
#' GGUF to run it.
#'
#' Embedding an **intervened** handle (from [llm_steer()]/[llm_ablate()]) raises
#' `relm_error_embed`: interventions currently apply to generation and logits
#' only, and the embedding context does not inherit them, so returning base vectors
#' labeled as intervened would be silent mislabeling. Embed the original handle.
#'
#' @param m An `llm` handle from [llm()].
#' @param x A character vector of one or more non-empty strings to embed; `NA` and
#'   empty strings (`""`) are rejected. `names(x)` become the row names.
#' @param pooling How to reduce each input's per-token vectors to one vector:
#'   `"mean"` (average), `"last"` (final token), or `"model"` (the model's own
#'   pooling when the GGUF defines one; otherwise an error asking for
#'   `"mean"`/`"last"`).
#' @param normalize Single logical. `TRUE` (default) L2-normalizes each row so
#'   rows are unit vectors and dot products are cosine similarities.
#' @return A numeric `matrix`, `length(x)` rows by the model's embedding size
#'   (columns), with row names `names(x)` when set, else the input positions as
#'   characters.
#' @seealso [llm()], [llm_tokens()], [llm_generate()]
#' @examplesIf nzchar(Sys.getenv("RELM_TEST_MODEL_QWEN"))
#' m <- llm(Sys.getenv("RELM_TEST_MODEL_QWEN"))
#' e <- llm_embed(m, c(a = "cats and dogs", b = "domestic pets"))
#' dim(e)
#' close(m)
#' @export
llm_embed <- function(m, x, pooling = c("mean", "last", "model"), normalize = TRUE) {
  if (!inherits(m, "llm")) {
    abort_argument("m", "`m` must be an `llm` handle returned by llm().")
  }
  ensure_open(m)
  guard_not_intervened(
    m, "relm_error_embed",
    "Embedding an intervened handle is not yet supported"
  )
  pooling <- match.arg(pooling)
  if (!is.character(x) || length(x) == 0L || anyNA(x)) {
    abort_argument("x", "`x` must be a non-empty character vector without NA.")
  }
  if (any(!nzchar(x))) {
    abort_argument(
      "x",
      "`x` must not contain empty strings (\"\"); every element needs text to embed."
    )
  }
  if (!is.logical(normalize) || length(normalize) != 1L || is.na(normalize)) {
    abort_argument(
      "normalize",
      "`normalize` must be a single logical value (TRUE or FALSE)."
    )
  }

  payload <- relm_check(rebirth_embed(m$ptr, x, pooling, normalize))
  mat <- matrix(
    payload$values,
    nrow = payload$n_rows, ncol = payload$n_embd, byrow = TRUE
  )
  rownames(mat) <- if (!is.null(names(x))) names(x) else as.character(seq_along(x))
  mat
}
