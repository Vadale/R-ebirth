# WP8a: llm_download(). A network + filesystem surface, so per-commit CI must
# exercise it WITHOUT hitting the network. The single network call is isolated in
# fetch_url(); every test below mocks it with a local fixture (or seeds the cache
# directly), so resolve/verify/cache/fail-closed/dir-creation all run offline in
# the ordinary `devtools::test()` / R CMD check suite. The only test that really
# downloads is the [MODEL] end-to-end one, gated on REBIRTH_DOWNLOAD_E2E so it
# runs only on the founder's Mac and never in per-commit CI.

# Write `content` to a fresh temp file; return its path and lower-case SHA256.
make_fixture <- function(content = "rebirth-download-fixture-bytes") {
  p <- tempfile(fileext = ".gguf")
  writeBin(charToRaw(content), p)
  list(path = p, sha256 = tolower(unname(tools::sha256sum(p))))
}

# A fetch_url() stand-in that "downloads" by copying a local fixture to `dest`.
copy_fetch <- function(fixture_path) {
  function(url, dest, quiet) {
    stopifnot(file.copy(fixture_path, dest, overwrite = TRUE))
    invisible(dest)
  }
}

# --- argument validation (offline; runs in per-commit CI) -------------------

test_that("llm_download() rejects a non-string model", {
  expect_error(llm_download(42), class = "rebirth_error_argument")
  expect_error(llm_download(c("a", "b")), class = "rebirth_error_argument")
  expect_error(llm_download(NA_character_), class = "rebirth_error_argument")
  expect_error(llm_download(""), class = "rebirth_error_argument")
  cnd <- tryCatch(llm_download(42), condition = function(c) c)
  expect_identical(cnd$argument, "model")
})

test_that("llm_download() validates dir and quiet before touching the network", {
  expect_error(
    llm_download("qwen2.5-0.5b-instruct-q8_0", dir = 1),
    class = "rebirth_error_argument"
  )
  expect_error(
    llm_download("qwen2.5-0.5b-instruct-q8_0", dir = c("a", "b")),
    class = "rebirth_error_argument"
  )
  expect_error(
    llm_download("qwen2.5-0.5b-instruct-q8_0", dir = NA_character_),
    class = "rebirth_error_argument"
  )
  expect_error(
    llm_download("qwen2.5-0.5b-instruct-q8_0", quiet = "yes"),
    class = "rebirth_error_argument"
  )
  expect_error(
    llm_download("qwen2.5-0.5b-instruct-q8_0", quiet = NA),
    class = "rebirth_error_argument"
  )
})

# --- the registry (offline; runs in per-commit CI) --------------------------

test_that("the model registry is well-formed (https, 64-hex sha256, unique aliases)", {
  reg <- rebirth:::model_registry()
  expect_true(all(
    c("alias", "url", "sha256", "size_bytes", "license", "notes") %in% names(reg)
  ))
  expect_gt(nrow(reg), 0L)
  expect_identical(anyDuplicated(reg$alias), 0L)
  expect_true(all(grepl("^https://", reg$url)))
  expect_true(all(grepl("^[0-9a-f]{64}$", reg$sha256)))
  expect_true(all(grepl("^[0-9]+$", reg$size_bytes)))
  expect_false(anyNA(reg$license))
})

test_that("the CI-integration alias pins the same SHA256 the nightly workflow uses", {
  # Twin-pin (recurring-guard f): keep in sync with the MODEL_SHA256 in
  # .github/workflows/nightly-demo-A.yaml and nightly-model-tolerance.yaml.
  # The .github tree is not shipped in the built package, so this asserts the
  # registry against the documented literal rather than reading the YAML.
  reg <- rebirth:::model_registry()
  row <- reg[reg$alias == "qwen2.5-0.5b-instruct-q8_0", , drop = FALSE]
  expect_identical(nrow(row), 1L)
  expect_identical(
    row$sha256,
    "ca59ca7f13d0e15a8cfa77bd17e65d24f6844b554a7b6c12e07a5f89ff76844e"
  )
})

# --- resolve_model() (offline; runs in per-commit CI) -----------------------

test_that("resolve_model() maps a known alias to its pinned URL and checksum", {
  spec <- rebirth:::resolve_model("qwen2.5-0.5b-instruct-q8_0")
  expect_identical(spec$source, "alias")
  expect_match(spec$url, "^https://huggingface\\.co/Qwen/")
  expect_match(spec$url, "\\.gguf$")
  expect_identical(nchar(spec$sha256), 64L)
})

test_that("resolve_model() rejects an unknown alias and lists the known ones", {
  cnd <- tryCatch(rebirth:::resolve_model("no-such-model"), condition = function(c) c)
  expect_s3_class(cnd, "rebirth_error_download")
  expect_match(conditionMessage(cnd), "qwen2.5-0.5b-instruct-q8_0")
  expect_true("qwen2.5-0.5b-instruct-q8_0" %in% cnd$known_aliases)
})

test_that("resolve_model() accepts an https URL but with no expected checksum", {
  spec <- rebirth:::resolve_model("https://example.org/some/model.gguf")
  expect_identical(spec$source, "url")
  expect_identical(spec$url, "https://example.org/some/model.gguf")
  expect_true(is.na(spec$sha256))
})

test_that("resolve_model() rejects non-HTTPS URLs (http/ftp/file)", {
  for (u in c(
    "http://example.org/m.gguf",
    "ftp://example.org/m.gguf",
    "file:///tmp/m.gguf"
  )) {
    cnd <- tryCatch(rebirth:::resolve_model(u), condition = function(c) c)
    expect_s3_class(cnd, "rebirth_error_download")
    expect_match(conditionMessage(cnd), "HTTPS", ignore.case = TRUE)
  }
})

test_that("basename_from_url() derives the filename and strips query/fragment", {
  expect_identical(rebirth:::basename_from_url("https://h/a/b/model.gguf"), "model.gguf")
  expect_identical(
    rebirth:::basename_from_url("https://h/model.gguf?download=true"), "model.gguf"
  )
  expect_identical(rebirth:::basename_from_url("https://h/model.gguf#x"), "model.gguf")
})

test_that("download_verify() rejects a URL whose file name would escape the directory", {
  dir <- tempfile("dlcache-")
  on.exit(unlink(dir, recursive = TRUE, force = TRUE), add = TRUE)
  cnd <- tryCatch(
    rebirth:::download_verify("https://example.org/foo/..", NA_character_, dir, quiet = TRUE),
    condition = function(c) c
  )
  expect_s3_class(cnd, "rebirth_error_download")
  # nothing was written (the guard fires before any fetch)
  expect_length(list.files(dir, all.files = TRUE, no.. = TRUE), 0L)
})

# --- download_verify(): the fail-closed core (offline; per-commit CI) -------

test_that("download_verify() verifies the checksum and returns the destination path", {
  fx <- make_fixture()
  dir <- tempfile("dlcache-")
  on.exit(unlink(dir, recursive = TRUE, force = TRUE), add = TRUE)
  local_mocked_bindings(fetch_url = copy_fetch(fx$path))

  path <- expect_no_message(
    rebirth:::download_verify("https://x/model.gguf", fx$sha256, dir, quiet = TRUE)
  )
  expect_true(file.exists(path))
  expect_identical(basename(path), "model.gguf")
  expect_identical(tolower(unname(tools::sha256sum(path))), fx$sha256)
  # no leftover partial files
  expect_length(list.files(dir, pattern = "\\.part$"), 0L)
})

test_that("download_verify() is fail-closed on a checksum mismatch: file deleted + classed error", {
  fx <- make_fixture()
  dir <- tempfile("dlcache-")
  on.exit(unlink(dir, recursive = TRUE, force = TRUE), add = TRUE)
  wrong <- paste(rep("0", 64), collapse = "")
  local_mocked_bindings(fetch_url = copy_fetch(fx$path))

  cnd <- tryCatch(
    rebirth:::download_verify("https://x/model.gguf", wrong, dir, quiet = TRUE),
    condition = function(c) c
  )
  expect_s3_class(cnd, "rebirth_error_download")
  expect_identical(cnd$expected, wrong)
  expect_identical(cnd$actual, fx$sha256)
  expect_identical(cnd$url, "https://x/model.gguf")
  # fail-closed: NOTHING left at the destination, and no leftover partial file
  expect_false(file.exists(file.path(dir, "model.gguf")))
  expect_length(list.files(dir, pattern = "\\.part$"), 0L)
})

test_that("download_verify() skips the download on a verified cache hit", {
  fx <- make_fixture()
  dir <- tempfile("dlcache-")
  dir.create(dir, recursive = TRUE)
  on.exit(unlink(dir, recursive = TRUE, force = TRUE), add = TRUE)
  file.copy(fx$path, file.path(dir, "model.gguf"))

  called <- FALSE
  local_mocked_bindings(
    fetch_url = function(url, dest, quiet) {
      called <<- TRUE
      stop("fetch_url must not be called on a verified cache hit")
    }
  )
  path <- rebirth:::download_verify("https://x/model.gguf", fx$sha256, dir, quiet = TRUE)
  expect_false(called)
  expect_identical(path, file.path(dir, "model.gguf"))
})

test_that("download_verify() re-downloads when the cached file is corrupt", {
  fx <- make_fixture()
  dir <- tempfile("dlcache-")
  dir.create(dir, recursive = TRUE)
  on.exit(unlink(dir, recursive = TRUE, force = TRUE), add = TRUE)
  writeBin(charToRaw("this is not the model"), file.path(dir, "model.gguf"))

  called <- FALSE
  local_mocked_bindings(
    fetch_url = function(url, dest, quiet) {
      called <<- TRUE
      stopifnot(file.copy(fx$path, dest, overwrite = TRUE))
      invisible(dest)
    }
  )
  path <- rebirth:::download_verify("https://x/model.gguf", fx$sha256, dir, quiet = TRUE)
  expect_true(called)
  expect_identical(tolower(unname(tools::sha256sum(path))), fx$sha256)
})

test_that("download_verify() creates a missing (nested) destination directory", {
  fx <- make_fixture()
  base <- tempfile("dlroot-")
  on.exit(unlink(base, recursive = TRUE, force = TRUE), add = TRUE)
  dir <- file.path(base, "a", "b", "c")
  expect_false(dir.exists(dir))
  local_mocked_bindings(fetch_url = copy_fetch(fx$path))

  path <- rebirth:::download_verify("https://x/model.gguf", fx$sha256, dir, quiet = TRUE)
  expect_true(dir.exists(dir))
  expect_true(file.exists(path))
})

test_that("download_verify() reports the hash for a bare URL and never claims it verified", {
  fx <- make_fixture()
  dir <- tempfile("dlcache-")
  on.exit(unlink(dir, recursive = TRUE, force = TRUE), add = TRUE)
  local_mocked_bindings(fetch_url = copy_fetch(fx$path))

  path <- NULL
  expect_message(
    path <- rebirth:::download_verify(
      "https://x/model.gguf", NA_character_, dir, quiet = FALSE
    ),
    "unverified"
  )
  expect_true(file.exists(path))
  expect_identical(tolower(unname(tools::sha256sum(path))), fx$sha256)
})

test_that("download_verify() surfaces a network failure as rebirth_error_download", {
  dir <- tempfile("dlcache-")
  on.exit(unlink(dir, recursive = TRUE, force = TRUE), add = TRUE)
  local_mocked_bindings(
    fetch_url = function(url, dest, quiet) {
      rebirth:::abort_download("Download failed for test", list(url = url))
    }
  )
  cnd <- tryCatch(
    rebirth:::download_verify("https://x/model.gguf", NA_character_, dir, quiet = TRUE),
    condition = function(c) c
  )
  expect_s3_class(cnd, "rebirth_error_download")
  expect_false(file.exists(file.path(dir, "model.gguf")))
  expect_length(list.files(dir, pattern = "\\.part$"), 0L)
})

# --- llm_download() end-to-end wiring (offline; per-commit CI) ---------------

test_that("llm_download() returns the destination path invisibly", {
  fx <- make_fixture()
  dir <- tempfile("dlcache-")
  on.exit(unlink(dir, recursive = TRUE, force = TRUE), add = TRUE)
  local_mocked_bindings(fetch_url = copy_fetch(fx$path))

  expect_invisible(
    llm_download("https://example.org/model.gguf", dir = dir, quiet = TRUE)
  )
  path <- llm_download("https://example.org/model.gguf", dir = dir, quiet = TRUE)
  expect_identical(path, file.path(dir, "model.gguf"))
})

test_that("llm_download() enforces the registry checksum through the public API (fail-closed)", {
  # The fixture is not the real model, so its hash cannot match the registry's:
  # this proves the public path pulls the REAL expected hash and deletes on
  # mismatch, without downloading anything.
  fx <- make_fixture()
  dir <- tempfile("dlcache-")
  on.exit(unlink(dir, recursive = TRUE, force = TRUE), add = TRUE)
  local_mocked_bindings(fetch_url = copy_fetch(fx$path))

  cnd <- tryCatch(
    llm_download("qwen2.5-0.5b-instruct-q8_0", dir = dir, quiet = TRUE),
    condition = function(c) c
  )
  expect_s3_class(cnd, "rebirth_error_download")
  expect_identical(nchar(cnd$expected), 64L)
  expect_identical(cnd$actual, fx$sha256)
  expect_false(file.exists(file.path(dir, "qwen2.5-0.5b-instruct-q8_0.gguf")))
})

# --- [MODEL] real end-to-end download (founder's Mac only) ------------------

test_that("[MODEL] llm_download() fetches and verifies the pinned 0.5B end-to-end", {
  # Gated: set REBIRTH_DOWNLOAD_E2E=1 to actually download ~644 MB over the
  # network. Never runs in per-commit CI (which is model-free and offline).
  skip_if_not(
    nzchar(Sys.getenv("REBIRTH_DOWNLOAD_E2E")),
    "set REBIRTH_DOWNLOAD_E2E=1 to run the real network download"
  )
  dir <- tempfile("dl-e2e-")
  on.exit(unlink(dir, recursive = TRUE, force = TRUE), add = TRUE)

  path <- llm_download("qwen2.5-0.5b-instruct-q8_0", dir = dir, quiet = TRUE)
  expect_true(file.exists(path))
  expect_identical(
    tolower(unname(tools::sha256sum(path))),
    "ca59ca7f13d0e15a8cfa77bd17e65d24f6844b554a7b6c12e07a5f89ff76844e"
  )
  # Idempotent second call: cache hit, same path, no re-download, no error.
  path2 <- llm_download("qwen2.5-0.5b-instruct-q8_0", dir = dir, quiet = TRUE)
  expect_identical(path, path2)
})
