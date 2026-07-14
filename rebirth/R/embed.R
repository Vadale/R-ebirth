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
#' @section Image input (vision models):
#' On a handle loaded with [llm()]'s `projector` argument, `images` embeds each
#' (text, image) pair into one row: a **list parallel to `x`**, where
#' `images[[i]]` is a character vector of image file paths for input `i`
#' (`character(0)` for none), or a bare character vector for a single input
#' (recycled across several inputs with a warning) — the same pairing contract
#' as [llm_generate()]'s `images`. Images are inserted **before** the text.
#' The accepted formats and pre-decode limits are exactly [llm_generate()]'s:
#' **JPEG, PNG, BMP** only, at most 64 MB per file by default
#' (`options(relm.image_max_bytes = )`), dimensions 1--16384 px per side, at
#' most 33554432 total pixels; the literal marker `"<__media__>"` is reserved
#' in an image-bearing input (`relm_error_argument`). An input that carries an
#' image may have empty text (`x = ""`) — the image alone is embedded; empty
#' text without an image is still rejected.
#'
#' Pooling semantics with images: the per-token vectors reduced by `pooling`
#' are those of the **text positions** (including the model's own
#' image-delimiter tokens); the image conditions those vectors through
#' attention. This matches the reference llama.cpp behavior at the pinned
#' engine version — image patch positions expose no per-token hidden states —
#' and text-only inputs are completely unchanged. Images on a handle loaded
#' without a projector raise `relm_error_image`.
#'
#' @param m An `llm` handle from [llm()].
#' @param x A character vector of one or more non-empty strings to embed; `NA` and
#'   empty strings (`""`) are rejected (an empty string is allowed only for an
#'   input that carries at least one image). `names(x)` become the row names.
#' @param pooling How to reduce each input's per-token vectors to one vector:
#'   `"mean"` (average), `"last"` (final token), or `"model"` (the model's own
#'   pooling when the GGUF defines one; otherwise an error asking for
#'   `"mean"`/`"last"`).
#' @param normalize Single logical. `TRUE` (default) L2-normalizes each row so
#'   rows are unit vectors and dot products are cosine similarities.
#' @param images `NULL` (default: text-only, unchanged) or the image file paths
#'   to pair with each input — a list parallel to `x`, or a bare character
#'   vector for a single input. Accepted formats: JPEG, PNG, BMP. Requires a
#'   handle loaded with `llm(projector = )`; see the *Image input* section.
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
llm_embed <- function(m, x, pooling = c("mean", "last", "model"), normalize = TRUE,
                      images = NULL) {
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
  if (!is.logical(normalize) || length(normalize) != 1L || is.na(normalize)) {
    abort_argument(
      "normalize",
      "`normalize` must be a single logical value (TRUE or FALSE)."
    )
  }

  # Images (WP-V3, D-026.5): the same pairing/marker/projector contract as
  # llm_generate(images=), through the same shared helpers (never forked).
  image_sets <- normalize_images(images, length(x))
  check_prompt_markers(x, image_sets)
  has_image <- if (is.null(image_sets)) {
    rep(FALSE, length(x))
  } else {
    lengths(image_sets) > 0L
  }
  # An empty string is embeddable only when its input carries an image (the
  # image alone is embedded); text-only empty strings stay rejected as before.
  if (any(!nzchar(x) & !has_image)) {
    abort_argument(
      "x",
      "`x` must not contain empty strings (\"\"); every element needs text to embed (or an image in `images`)."
    )
  }
  max_bytes <- if (any(has_image)) image_max_bytes() else 64 * 1024^2
  check_images_usable(m, image_sets)

  # All-empty sets (e.g. images = list(character(0))) are a text-only call:
  # send the empty transport so the boundary routes through the unchanged
  # text path (and no projector is required), exactly like images = NULL.
  if (is.null(image_sets) || !any(has_image)) {
    images_flat <- character(0)
    images_lens <- integer(0)
  } else {
    images_flat <- path.expand(as.character(unlist(image_sets, use.names = FALSE)))
    images_lens <- as.integer(lengths(image_sets))
  }

  payload <- relm_check(rebirth_embed(
    m$ptr, x, pooling, normalize, images_flat, images_lens, max_bytes
  ))
  mat <- matrix(
    payload$values,
    nrow = payload$n_rows, ncol = payload$n_embd, byrow = TRUE
  )
  rownames(mat) <- if (!is.null(names(x))) names(x) else as.character(seq_along(x))
  mat
}
