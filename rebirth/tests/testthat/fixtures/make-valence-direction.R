#!/usr/bin/env Rscript
# Provenance script for `valence-direction.csv` -- the committed valence steering
# direction the WP5 acceptance fixture (`test-llm-steer-valence.R`) steers along.
#
# This is the ONLY sanctioned way to (re)generate the artifact (golden discipline,
# CLAUDE.md / the `golden-update` skill): no value in `valence-direction.csv` is
# hand-edited; this script emits every one. Regeneration requires a documented
# reason (a new/updated pinned model, or a deliberate method change).
#
# METHOD (contrastive activation / diff-in-means). On the BASE, un-intervened model
# we trace the residual stream at one mid-late layer for a set of clearly positive-
# affect sentences and a matched set of clearly negative-affect sentences, average
# each set's last-token residual, and take (mean positive - mean negative). That
# difference points, in residual space, from negative toward positive valence, so
# adding a positive multiple of it during generation biases the output positive and
# a negative multiple biases it negative. The vector is L2-normalised so the
# fixture's `coef` is the only magnitude knob. This is the standard steering-vector
# construction (Turner et al. 2023, "Activation Addition"; Rimsky et al. 2024,
# "Contrastive Activation Addition"); the contrast sentences and this code are
# ORIGINAL to this project (no third-party corpus or lexicon).
#
# The direction is a MODEL-DERIVED artifact, produced on the founder's Metal Mac
# from Qwen2.5-0.5B-Instruct Q8_0. Regenerating on another machine reproduces the
# METHOD, not the exact bytes -- small floating-point differences across backends
# are expected (as for every [MODEL] golden). The committed file's SHA256 therefore
# pins the exact bytes the fixture was calibrated against; the fixture asserts
# SEMANTIC behaviour (a valence shift), never bit-exact values, and checks the
# SHA256 only to catch accidental edits.
#
# USAGE (from the repo root, with the pinned CI model available):
#   REBIRTH_TEST_MODEL_QWEN=/path/to/qwen2.5-0.5b-instruct-q8_0.gguf \
#     Rscript rebirth/tests/testthat/fixtures/make-valence-direction.R
# It prints the artifact's SHA256; paste that into DIRECTION_SHA256 in the fixture.

# --- configuration (kept in lock-step with test-llm-steer-valence.R) ---------

# 1-based API transformer block the direction is derived at AND steered at. Layer
# 18 of Qwen2.5-0.5B's 24 (mid-late) was selected by a documented layer x coef
# sweep as the cleanest, most robust valence-shift site (2026-07-06); the fixture
# steers at this same layer with coef 10.
DIRECTION_LAYER <- 18L

# --- contrast sentences (ORIGINAL to this project) ---------------------------
# Clearly positive- vs negative-affect sentences, matched in structure/topic so the
# diff-in-means isolates VALENCE rather than topic.
POSITIVE_CONTRAST <- c(
  "I feel wonderful and full of joy today.",
  "This is a beautiful, happy, and delightful moment.",
  "Everything is going great and I am grateful and hopeful.",
  "What a lovely, cheerful, and peaceful morning it is.",
  "I am delighted; life feels bright, warm, and full of love.",
  "The news was excellent and it filled everyone with hope and joy.",
  "She smiled warmly, feeling calm, kind, and thankful.",
  "It was a fantastic, pleasant, and comfortable day."
)
NEGATIVE_CONTRAST <- c(
  "I feel terrible and full of despair today.",
  "This is an ugly, miserable, and dreadful moment.",
  "Everything is going wrong and I am fearful and hopeless.",
  "What a gloomy, bitter, and painful morning it is.",
  "I am devastated; life feels dark, cold, and full of grief.",
  "The news was awful and it filled everyone with fear and sadness.",
  "He frowned bitterly, feeling anxious, cruel, and resentful.",
  "It was a horrible, dreary, and distressing day."
)

# --- helpers -----------------------------------------------------------------

# Absolute path of this script, whether run via `Rscript` (--file=) or `source()`.
this_script_path <- function() {
  ca <- commandArgs(FALSE)
  f <- sub("^--file=", "", ca[grepl("^--file=", ca)])
  if (length(f) == 1L && nzchar(f)) {
    return(normalizePath(f, mustWork = FALSE))
  }
  of <- sys.function(0L) # fallback: sourced with chdir
  srcfile <- attr(attr(of, "srcref"), "srcfile")
  if (!is.null(srcfile) && nzchar(srcfile$filename)) {
    return(normalizePath(srcfile$filename, mustWork = FALSE))
  }
  # Last resort: assume the canonical location relative to the repo root.
  normalizePath("rebirth/tests/testthat/fixtures/make-valence-direction.R",
                mustWork = FALSE)
}

# --- derive ------------------------------------------------------------------

main <- function() {
  out_path <- file.path(dirname(this_script_path()), "valence-direction.csv")

  model_path <- Sys.getenv("REBIRTH_TEST_MODEL_QWEN")
  if (!nzchar(model_path) || !file.exists(model_path)) {
    stop("Set REBIRTH_TEST_MODEL_QWEN to the Qwen2.5-0.5B-Instruct Q8_0 GGUF path.")
  }

  # Load the package from source so the script runs against the working tree.
  if (requireNamespace("devtools", quietly = TRUE) &&
      file.exists("rebirth/DESCRIPTION")) {
    suppressMessages(devtools::load_all("rebirth", quiet = TRUE))
  } else {
    library(rebirth)
  }

  m <- llm(model_path)
  on.exit(close(m), add = TRUE)
  stopifnot(
    identical(m$architecture, "qwen2"),
    DIRECTION_LAYER >= 1L, DIRECTION_LAYER <= m$layers
  )

  mean_residual <- function(prompts) {
    tr <- llm_trace(
      m, prompts,
      layers = DIRECTION_LAYER, positions = "last", components = "residual"
    )
    colMeans(as.matrix(tr, layer = DIRECTION_LAYER, component = "residual"))
  }

  pos_mean <- mean_residual(POSITIVE_CONTRAST)
  neg_mean <- mean_residual(NEGATIVE_CONTRAST)
  direction <- pos_mean - neg_mean
  norm <- sqrt(sum(direction^2))
  stopifnot(is.finite(norm), norm > 0)
  direction <- direction / norm # L2-normalised
  stopifnot(length(direction) == m$hidden_size, all(is.finite(direction)))

  header <- c(
    "# valence-direction.csv -- WP5 steering-direction artifact (ORIGINAL to R-ebirth).",
    "# Generated by fixtures/make-valence-direction.R -- do NOT hand-edit (golden discipline).",
    sprintf(
      "# model: %s (%s, %d layers, hidden %d)",
      basename(model_path), m$architecture, m$layers, m$hidden_size
    ),
    sprintf(
      "# method: diff-in-means of last-token residual, API layer %d, L2-normalised",
      DIRECTION_LAYER
    ),
    sprintf(
      "# contrast sentences: %d positive / %d negative (original to this project)",
      length(POSITIVE_CONTRAST), length(NEGATIVE_CONTRAST)
    ),
    sprintf("# date: %s", format(Sys.Date())),
    "neuron,value"
  )
  body <- sprintf("%d,%.17g", seq_along(direction), direction)
  writeLines(c(header, body), out_path)

  sha <- unname(tools::sha256sum(out_path))
  cat(sprintf("wrote %s (%d neurons, unit L2 norm)\n", out_path, length(direction)))
  cat(sprintf("SHA256: %s\n", sha))
  cat("-> paste this SHA256 into DIRECTION_SHA256 in test-llm-steer-valence.R\n")
  invisible(sha)
}

main()
