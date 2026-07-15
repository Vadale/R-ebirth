# A hand-built `llm` object with metadata set by hand and no real native
# pointer, so print/summary/close *logic* can be tested without a model file
# (the real-model value checks are WP1 Step 8, env-gated). Mirrors new_llm()'s
# shape but skips the boundary and the finalizer.
stub_llm <- function(closed = FALSE, interventions = list(), architecture = "qwen2",
                     projector = NULL) {
  state <- new.env(parent = emptyenv())
  state$closed <- closed
  state$ptr <- NULL
  structure(
    list(
      ptr = NULL,
      state = state,
      path = "/models/Qwen2.5-0.5B-Instruct-Q8_0.gguf",
      architecture = architecture,
      parameters = 494032768,
      quantization = "Q8_0",
      layers = 24L,
      hidden_size = 896L,
      context_length = 4096L,
      backend = "metal",
      projector = projector,
      vision = !is.null(projector),
      interventions = interventions,
      .context_train = 32768L,
      .size_bytes = 531000000,
      .vocab_size = 151936L,
      .description = "qwen2 0.5B Q8_0"
    ),
    class = "llm"
  )
}

# Shared model/fixture path helpers for the vision test files
# (test-llm-vision.R + test-llm-vision-embed.R). Several older test files still
# carry identical file-local copies of the first two, which harmlessly shadow
# these within those files.
synthetic_model_path <- function() {
  p <- testthat::test_path("fixtures", "synthetic-llama-2l.gguf")
  skip_if_not(file.exists(p), "synthetic GGUF fixture is missing")
  p
}

qwen_model_path <- function() {
  p <- path.expand(Sys.getenv("RELM_TEST_MODEL_QWEN"))
  skip_if_not(
    nzchar(p) && file.exists(p),
    "RELM_TEST_MODEL_QWEN is not set to an existing GGUF file"
  )
  p
}

vision_fixture <- function(name) {
  p <- testthat::test_path("fixtures", "vision", name)
  skip_if_not(file.exists(p), sprintf("vision fixture '%s' is missing", name))
  p
}

# The vision goldens live at the REPO root (tests/llm-golden/vision/goldens),
# outside the package tree — three levels above tests/testthat. They are present
# in a repo checkout and absent under R CMD check or an installed package, where
# the caller skips on file.exists(). Written once here so the repo-root walk is
# not hand-rolled per test file; normalized so a failure names an absolute path.
vision_golden_path <- function(name) {
  normalizePath(
    file.path(
      testthat::test_path(), "..", "..", "..",
      "tests", "llm-golden", "vision", "goldens", name
    ),
    mustWork = FALSE
  )
}

# [MODEL] model-path helpers for the WP7.5a modern-model families. Each is gated
# on its own environment variable pointing at a local text-only instruct GGUF, so
# these tests run only on the founder's Mac (Metal) and skip in CI/CRAN, which have
# no such model.
gemma4_model_path <- function() {
  p <- path.expand(Sys.getenv("RELM_TEST_MODEL_GEMMA4"))
  skip_if_not(
    nzchar(p) && file.exists(p),
    "RELM_TEST_MODEL_GEMMA4 is not set to an existing GGUF file"
  )
  p
}

qwen3_model_path <- function() {
  p <- path.expand(Sys.getenv("RELM_TEST_MODEL_QWEN3"))
  skip_if_not(
    nzchar(p) && file.exists(p),
    "RELM_TEST_MODEL_QWEN3 is not set to an existing GGUF file"
  )
  p
}

qwen35_model_path <- function() {
  p <- path.expand(Sys.getenv("RELM_TEST_MODEL_QWEN35"))
  skip_if_not(
    nzchar(p) && file.exists(p),
    "RELM_TEST_MODEL_QWEN35 is not set to an existing GGUF file"
  )
  p
}

# [MODEL] WP-V2 vision pair: a vision-language model GGUF plus its companion
# mmproj (projector) GGUF — the registry default Qwen2-VL-2B-Instruct
# (Apache-2.0, aliases qwen2-vl-2b-instruct-q4_k_m /
# qwen2-vl-2b-instruct-mmproj-f16, D-026.8). Resolution order: the explicit
# environment variable (mirroring RELM_TEST_MODEL_QWEN), else the registry
# alias's file in the default llm_download() cache — so a machine that ran
# llm_download("qwen2-vl-2b-instruct-q4_k_m") needs no env vars. Skips
# otherwise; per-commit CI has no VLM either way.
#
# Fail-closed cache reuse (WP-V4 security audit, F-1): a cache hit is used only
# if the file still matches its registry SHA256. llm_download() verifies on
# download, but nothing re-verifies afterwards — a truncated, half-written or
# swapped cache entry would otherwise feed the [MODEL] goldens a different model
# and be read as a numerical regression rather than a corrupt file. A mismatch
# warns and skips instead. The RELM_TEST_MODEL_VLM / RELM_TEST_MMPROJ_VLM route
# is the founder's explicit local override and is deliberately not hash-gated:
# it is how an unpinned or hand-built VLM is tried. Hashing ~1 GB costs a few
# seconds, so the verdict is memoised for the session — every [MODEL] vision
# test calls this.
vlm_cache_verified <- new.env(parent = emptyenv())

vlm_alias_in_cache <- function(alias) {
  reg <- tryCatch(relm:::model_registry(), error = function(e) NULL)
  if (is.null(reg)) {
    return("")
  }
  row <- reg[reg$alias == alias, , drop = FALSE]
  if (nrow(row) != 1L) {
    return("")
  }
  p <- file.path(tools::R_user_dir("relm", "cache"), basename(row$url))
  if (!file.exists(p)) {
    return("")
  }
  if (!isTRUE(vlm_cache_verified[[alias]])) {
    got <- tolower(unname(tools::sha256sum(p)))
    if (!identical(got, tolower(row$sha256))) {
      warning(
        sprintf(
          "cached '%s' does not match its registry SHA256 (got %s); ignoring it",
          alias, got
        ),
        call. = FALSE
      )
      return("")
    }
    vlm_cache_verified[[alias]] <- TRUE
  }
  p
}

vlm_model_path <- function() {
  p <- path.expand(Sys.getenv("RELM_TEST_MODEL_VLM"))
  if (!nzchar(p) || !file.exists(p)) {
    p <- vlm_alias_in_cache("qwen2-vl-2b-instruct-q4_k_m")
  }
  skip_if_not(
    nzchar(p) && file.exists(p),
    "no VLM: set RELM_TEST_MODEL_VLM or llm_download(\"qwen2-vl-2b-instruct-q4_k_m\")"
  )
  p
}

vlm_mmproj_path <- function() {
  p <- path.expand(Sys.getenv("RELM_TEST_MMPROJ_VLM"))
  if (!nzchar(p) || !file.exists(p)) {
    p <- vlm_alias_in_cache("qwen2-vl-2b-instruct-mmproj-f16")
  }
  skip_if_not(
    nzchar(p) && file.exists(p),
    "no mmproj: set RELM_TEST_MMPROJ_VLM or llm_download(\"qwen2-vl-2b-instruct-mmproj-f16\")"
  )
  p
}

# An open `llm` backed by a real but already-empty native handle
# (rebirth_selftest_new_handle): it drives new_llm()/close()/the closed tag with
# no model file, so the native free is a safe no-op. The metadata values are
# placeholders — the close tests assert on lifecycle, not on metadata.
empty_handle_llm <- function() {
  ptr <- relm:::rebirth_selftest_new_handle()
  payload <- list(
    ok = TRUE, ptr = ptr, architecture = "x", parameters = 1,
    quantization = "q", layers = 1L, hidden_size = 1L, context_length = 1L,
    backend = "cpu", context_train = 1L, size_bytes = 1, vocab_size = 1L,
    description = ""
  )
  relm:::new_llm(payload, "x.gguf")
}
