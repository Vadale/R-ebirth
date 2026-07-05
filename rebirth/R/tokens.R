#' Tokenize text, or decode token ids back to text
#'
#' Converts between text and the model's tokens. With `decode = FALSE` (the
#' default) `x` is text and the result is the token ids; with `decode = TRUE`
#' `x` is token ids and the result is the reconstructed string.
#'
#' @details
#' **Encoding** (`decode = FALSE`). `x` is a character vector. Each element is
#' tokenized into a **named integer vector**: the values are the token ids and
#' the names are the token pieces (the text each id renders as). For a single
#' string a named integer vector is returned; for several strings a list of such
#' vectors is returned, preserving `names(x)`. No beginning/end-of-sequence
#' markers are added (you get exactly the tokens of the text); chat formatting is
#' `llm_generate`'s job, not this function's.
#'
#' **Decoding** (`decode = TRUE`). `x` is an integer vector of token ids and the
#' result is a single string. Decoding is UTF-8 correct even when a multi-byte
#' character spans two tokens — always decode the whole id vector rather than
#' concatenating the piece names, which can split a character.
#'
#' Token ids are **1-based** in the R API (like every other index in `rebirth`);
#' subtract 1 to compare them with a raw vocabulary index (llama.cpp / Hugging
#' Face). Encoding and decoding are exact inverses:
#' `llm_tokens(m, llm_tokens(m, txt), decode = TRUE)` reproduces `txt`.
#'
#' The model must carry a tokenizer; a `no_vocab` model raises
#' `rebirth_error_tokenize`.
#'
#' @param m An `llm` handle.
#' @param x For encoding, a character vector; for decoding, an integer vector of
#'   1-based token ids.
#' @param decode Single logical. `FALSE` (default) encodes text to ids; `TRUE`
#'   decodes ids to text.
#' @return Encoding: a named integer vector (single input) or a list of them
#'   (several inputs). Decoding: a single string.
#' @examplesIf nzchar(Sys.getenv("REBIRTH_TEST_MODEL_QWEN"))
#' m <- llm(Sys.getenv("REBIRTH_TEST_MODEL_QWEN"))
#' ids <- llm_tokens(m, "The quick brown fox")
#' ids
#' llm_tokens(m, ids, decode = TRUE)
#' close(m)
#' @export
llm_tokens <- function(m, x, decode = FALSE) {
  if (!inherits(m, "llm")) {
    abort_argument("m", "`m` must be an `llm` handle returned by llm().")
  }
  ensure_open(m)
  if (!is.logical(decode) || length(decode) != 1L || is.na(decode)) {
    abort_argument(
      "decode",
      "`decode` must be a single logical value (TRUE or FALSE)."
    )
  }

  if (decode) {
    llm_decode_ids(m, x)
  } else {
    llm_encode_text(m, x)
  }
}

# Encode a character vector to (named integer vector | list of them).
llm_encode_text <- function(m, x) {
  if (!is.character(x)) {
    rebirth_abort(
      "rebirth_error_tokenize",
      "`x` must be a character vector when decode = FALSE (text to tokenize).",
      list(reason = "x_not_character")
    )
  }
  if (anyNA(x)) {
    rebirth_abort(
      "rebirth_error_tokenize",
      "`x` contains NA; every element must be a string to tokenize.",
      list(reason = "x_has_na")
    )
  }

  out <- lapply(x, function(s) encode_one(m, s))
  if (length(x) == 1L) {
    out[[1L]]
  } else {
    names(out) <- names(x)
    out
  }
}

# Encode a single string to a named integer vector (names = token pieces).
encode_one <- function(m, s) {
  payload <- rebirth_check(rebirth_tokenize(
    m$ptr, s,
    add_special = FALSE, parse_special = TRUE
  ))
  stats::setNames(as.integer(payload$ids), payload$pieces)
}

# Decode a vector of 1-based token ids to a single string.
llm_decode_ids <- function(m, x) {
  if (!is.numeric(x) || anyNA(x) || any(x != round(x)) || any(!is.finite(x))) {
    rebirth_abort(
      "rebirth_error_tokenize",
      "`x` must be a vector of whole token ids when decode = TRUE.",
      list(reason = "ids_not_integer")
    )
  }
  if (length(x) > 0L && any(x < 1L)) {
    rebirth_abort(
      "rebirth_error_tokenize",
      "Token ids are 1-based; every id must be >= 1.",
      list(reason = "ids_not_positive")
    )
  }
  payload <- rebirth_check(rebirth_detokenize(m$ptr, as.integer(x)))
  payload$text
}
