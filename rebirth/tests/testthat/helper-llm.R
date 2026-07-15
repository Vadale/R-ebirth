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

# Which machine is this, for the purposes of a bit-exact float pin?
#
# WHY THIS EXISTS (hard rule 8d; D-026 fourth addendum). A float golden belongs
# to the machine that recorded it, so a pin like the T2 pooled embedding has to
# know whether it is home. The first version of that check asked the OPERATOR --
# `RELM_VISION_RECORDING_MACHINE=1` -- which is an echoed assertion, exactly the
# shape rule 8d forbids, and it had the failure mode rule 8d predicts: the pin
# ran nowhere, because nobody remembers an env var. This derives the answer from
# the machine instead.
#
# WHY THE CPU MODEL AND NOT THE ARCH. `Darwin && arm64` was the original gate and
# it was wrong: a non-M4 arm64 runner (same OS, same arch, same n_threads -- relm
# never sets it, so it is 4 everywhere) measured `max |d| = 6.05e-3` against the
# M4-recorded pin. The reason is below the arch: ggml's CPU backend keeps
# GGML_ACCELERATE on for macOS (build.rs) and dispatches on runtime CPU features
# (`ggml_cpu_has_sme`, `ggml_cpu_has_sve`) -- and SME exists on the M4 but not on
# earlier Apple Silicon. Two arm64 machines therefore do not run the same
# instructions, and float equality was never promised across them.
#
# WHAT THIS DOES AND DOES NOT GUARANTEE. It is a machine IDENTITY, not a proof of
# float equivalence: it cannot know that a compiler or Accelerate update changed
# the arithmetic under a stable CPU name. That case is safe by direction -- the
# fingerprint matches, the pin runs, and it FAILS loudly, which is the outcome we
# want from a golden. The dangerous direction (a pin silently not running) is the
# one this closes. Kept as a readable string rather than a hash so a skip message
# says something a human can act on.
machine_fingerprint <- function() {
  info <- Sys.info()
  cpu <- tryCatch(
    {
      if (identical(info[["sysname"]], "Darwin")) {
        system2("sysctl", c("-n", "machdep.cpu.brand_string"),
          stdout = TRUE, stderr = FALSE
        )[1]
      } else if (file.exists("/proc/cpuinfo")) {
        line <- grep("^model name", readLines("/proc/cpuinfo"), value = TRUE)[1]
        if (is.na(line)) NA_character_ else trimws(sub("^model name\\s*:", "", line))
      } else {
        NA_character_
      }
    },
    error = function(e) NA_character_,
    warning = function(w) NA_character_
  )
  if (length(cpu) != 1L || is.na(cpu) || !nzchar(cpu)) cpu <- "unknown-cpu"
  paste(info[["sysname"]], info[["machine"]], cpu, sep = " | ")
}

# The fingerprint of the machine a golden was recorded on, or NA if unrecorded.
# Sidecar rather than a header line: these goldens are parsed as bare numbers.
golden_machine <- function(name) {
  p <- vision_golden_path(paste0(name, ".machine"))
  if (!file.exists(p)) {
    return(NA_character_)
  }
  line <- grep("^\\s*(#|$)", readLines(p), value = TRUE, invert = TRUE)[1]
  if (is.na(line)) NA_character_ else trimws(line)
}

# Skip unless this machine recorded `name`. The gate a bit-exact float pin needs.
skip_if_not_recording_machine <- function(name) {
  recorded <- golden_machine(name)
  here <- machine_fingerprint()
  skip_if_not(
    !is.na(recorded),
    sprintf("no machine fingerprint recorded for '%s' (see the golden-update skill)", name)
  )
  skip_if_not(
    identical(recorded, here),
    sprintf(
      "exact float pin: recorded on [%s], this is [%s] -- different machines do not agree bit-for-bit",
      recorded, here
    )
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
