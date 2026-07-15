# WP8a: llm_download(). A network + filesystem surface, so per-commit CI must
# exercise it WITHOUT hitting the network. The single network call is isolated in
# fetch_url(); every test below mocks it with a local fixture (or seeds the cache
# directly), so resolve/verify/cache/fail-closed/dir-creation all run offline in
# the ordinary `devtools::test()` / R CMD check suite. The only test that really
# downloads is the [MODEL] end-to-end one, gated on RELM_DOWNLOAD_E2E so it
# runs only on the founder's Mac and never in per-commit CI.

# Write `content` to a fresh temp file; return its path and lower-case SHA256.
make_fixture <- function(content = "relm-download-fixture-bytes") {
  p <- tempfile(fileext = ".gguf")
  writeBin(charToRaw(content), p)
  list(path = p, sha256 = tolower(unname(tools::sha256sum(p))))
}

# A fetch_url() stand-in that "downloads" by copying a local fixture to `dest`.
copy_fetch <- function(fixture_path) {
  function(url, dest, quiet, call = NULL) {
    stopifnot(file.copy(fixture_path, dest, overwrite = TRUE))
    invisible(dest)
  }
}

# --- argument validation (offline; runs in per-commit CI) -------------------

test_that("llm_download() rejects a non-string model", {
  expect_error(llm_download(42), class = "relm_error_argument")
  expect_error(llm_download(c("a", "b")), class = "relm_error_argument")
  expect_error(llm_download(NA_character_), class = "relm_error_argument")
  expect_error(llm_download(""), class = "relm_error_argument")
  cnd <- tryCatch(llm_download(42), condition = function(c) c)
  expect_identical(cnd$argument, "model")
})

test_that("llm_download() validates dir and quiet before touching the network", {
  expect_error(
    llm_download("qwen2.5-0.5b-instruct-q8_0", dir = 1),
    class = "relm_error_argument"
  )
  expect_error(
    llm_download("qwen2.5-0.5b-instruct-q8_0", dir = c("a", "b")),
    class = "relm_error_argument"
  )
  expect_error(
    llm_download("qwen2.5-0.5b-instruct-q8_0", dir = NA_character_),
    class = "relm_error_argument"
  )
  expect_error(
    llm_download("qwen2.5-0.5b-instruct-q8_0", quiet = "yes"),
    class = "relm_error_argument"
  )
  expect_error(
    llm_download("qwen2.5-0.5b-instruct-q8_0", quiet = NA),
    class = "relm_error_argument"
  )
})

# --- the registry (offline; runs in per-commit CI) --------------------------

test_that("the model registry is well-formed (https, 64-hex sha256, unique aliases)", {
  reg <- relm:::model_registry()
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

test_that("resolve_model() fails closed on a malformed registry SHA256", {
  # LOW-1 (security-auditor): a re-packaged / hand-edited registry whose hash is
  # not 64-hex must NOT downgrade to an unverified download. The runtime guard in
  # resolve_model() rejects it, independent of the ship-time well-formedness test.
  bad <- data.frame(
    alias = "bogus", url = "https://example.org/bogus.gguf", sha256 = "not-a-real-hash",
    size_bytes = "1", license = "X", notes = "", stringsAsFactors = FALSE
  )
  local_mocked_bindings(model_registry = function() bad)
  expect_error(relm:::resolve_model("bogus"), class = "relm_error_download")
  cnd <- tryCatch(relm:::resolve_model("bogus"), condition = function(c) c)
  expect_identical(cnd$sha256, "not-a-real-hash")
})

test_that("the CI-integration alias pins the same SHA256 the nightly workflow uses", {
  # Twin-pin (recurring-guard f): keep in sync with the MODEL_SHA256 in
  # .github/workflows/nightly-demo-A.yaml and nightly-model-tolerance.yaml.
  # The .github tree is not shipped in the built package, so this asserts the
  # registry against the documented literal rather than reading the YAML.
  reg <- relm:::model_registry()
  row <- reg[reg$alias == "qwen2.5-0.5b-instruct-q8_0", , drop = FALSE]
  expect_identical(nrow(row), 1L)
  expect_identical(
    row$sha256,
    "ca59ca7f13d0e15a8cfa77bd17e65d24f6844b554a7b6c12e07a5f89ff76844e"
  )
})

test_that("the vision aliases pin the same SHA256s the nightly vision workflow uses", {
  # Twin-pin (recurring-guard f), same pattern and reason as the 0.5B alias
  # above: keep in sync with MODEL_SHA256 / MMPROJ_SHA256 in
  # .github/workflows/nightly-vision-golden.yaml. Registry and workflow are the
  # two places the D-026.8 vision pins are written down; if they drift, the
  # nightly verifies a different pair than llm_download() hands the user, and
  # the [MODEL] gate silently stops covering the shipped default. The model and
  # its projector are pinned independently — a matched pair is the contract.
  reg <- relm:::model_registry()

  model <- reg[reg$alias == "qwen2-vl-2b-instruct-q4_k_m", , drop = FALSE]
  expect_identical(nrow(model), 1L)
  expect_identical(
    model$sha256,
    "5745685d2e607a82a0696c1118e56a2a1ae0901da450fd9cd4f161c6b62867d7"
  )

  mmproj <- reg[reg$alias == "qwen2-vl-2b-instruct-mmproj-f16", , drop = FALSE]
  expect_identical(nrow(mmproj), 1L)
  expect_identical(
    mmproj$sha256,
    "ecb20cabcdd8dbc277de06bd6eb980aeb2adfaaba9f199a434e328d205675d03"
  )

  # Both come from one immutable HF revision: a moved revision would invalidate
  # the pins above, so pin the revision the URLs must carry as well.
  expect_true(all(grepl(
    "/resolve/bb307c036e8a1ed7b663bbd0c35b41c4c9294cfd/",
    c(model$url, mmproj$url),
    fixed = TRUE
  )))
})

# --- resolve_model() (offline; runs in per-commit CI) -----------------------

test_that("resolve_model() maps a known alias to its pinned URL and checksum", {
  spec <- relm:::resolve_model("qwen2.5-0.5b-instruct-q8_0")
  expect_identical(spec$source, "alias")
  expect_match(spec$url, "^https://huggingface\\.co/Qwen/")
  expect_match(spec$url, "\\.gguf$")
  expect_identical(nchar(spec$sha256), 64L)
})

test_that("resolve_model() rejects an unknown alias and lists the known ones", {
  cnd <- tryCatch(relm:::resolve_model("no-such-model"), condition = function(c) c)
  expect_s3_class(cnd, "relm_error_download")
  expect_match(conditionMessage(cnd), "qwen2.5-0.5b-instruct-q8_0")
  expect_true("qwen2.5-0.5b-instruct-q8_0" %in% cnd$known_aliases)
})

test_that("resolve_model() accepts an https URL but with no expected checksum", {
  spec <- relm:::resolve_model("https://example.org/some/model.gguf")
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
    cnd <- tryCatch(relm:::resolve_model(u), condition = function(c) c)
    expect_s3_class(cnd, "relm_error_download")
    expect_match(conditionMessage(cnd), "HTTPS", ignore.case = TRUE)
  }
})

test_that("basename_from_url() derives the filename and strips query/fragment", {
  expect_identical(relm:::basename_from_url("https://h/a/b/model.gguf"), "model.gguf")
  expect_identical(
    relm:::basename_from_url("https://h/model.gguf?download=true"), "model.gguf"
  )
  expect_identical(relm:::basename_from_url("https://h/model.gguf#x"), "model.gguf")
})

test_that("download_verify() rejects a URL whose file name would escape the directory", {
  dir <- tempfile("dlcache-")
  on.exit(unlink(dir, recursive = TRUE, force = TRUE), add = TRUE)
  cnd <- tryCatch(
    relm:::download_verify("https://example.org/foo/..", NA_character_, dir, quiet = TRUE),
    condition = function(c) c
  )
  expect_s3_class(cnd, "relm_error_download")
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
    relm:::download_verify("https://x/model.gguf", fx$sha256, dir, quiet = TRUE)
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
    relm:::download_verify("https://x/model.gguf", wrong, dir, quiet = TRUE),
    condition = function(c) c
  )
  expect_s3_class(cnd, "relm_error_download")
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
    fetch_url = function(url, dest, quiet, call = NULL) {
      called <<- TRUE
      stop("fetch_url must not be called on a verified cache hit")
    }
  )
  path <- relm:::download_verify("https://x/model.gguf", fx$sha256, dir, quiet = TRUE)
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
    fetch_url = function(url, dest, quiet, call = NULL) {
      called <<- TRUE
      stopifnot(file.copy(fx$path, dest, overwrite = TRUE))
      invisible(dest)
    }
  )
  path <- relm:::download_verify("https://x/model.gguf", fx$sha256, dir, quiet = TRUE)
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

  path <- relm:::download_verify("https://x/model.gguf", fx$sha256, dir, quiet = TRUE)
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
    path <- relm:::download_verify(
      "https://x/model.gguf", NA_character_, dir, quiet = FALSE
    ),
    "unverified"
  )
  expect_true(file.exists(path))
  expect_identical(tolower(unname(tools::sha256sum(path))), fx$sha256)
})

test_that("download_verify() re-fetches a bare URL even if a same-named file exists", {
  # LOW-4: two different bare URLs sharing a basename must not collide. An
  # unverifiable bare URL never reuses an existing same-named cached file --
  # it always re-fetches, so it can never return another URL's stale bytes.
  fx <- make_fixture("the-correct-bytes-for-this-url")
  dir <- tempfile("dlcache-")
  dir.create(dir)
  on.exit(unlink(dir, recursive = TRUE, force = TRUE), add = TRUE)
  writeBin(charToRaw("stale-bytes-from-a-different-url"), file.path(dir, "model.gguf"))

  fetched <- FALSE
  local_mocked_bindings(fetch_url = function(url, dest, quiet, call = NULL) {
    fetched <<- TRUE
    stopifnot(file.copy(fx$path, dest, overwrite = TRUE))
    invisible(dest)
  })
  path <- relm:::download_verify("https://x/model.gguf", NA_character_, dir, quiet = TRUE)
  expect_true(fetched) # did NOT silently reuse the stale cached file
  expect_identical(tolower(unname(tools::sha256sum(path))), fx$sha256)
})

test_that("download_verify() surfaces a network failure as relm_error_download", {
  dir <- tempfile("dlcache-")
  on.exit(unlink(dir, recursive = TRUE, force = TRUE), add = TRUE)
  local_mocked_bindings(
    fetch_url = function(url, dest, quiet, call = NULL) {
      relm:::abort_download("Download failed for test", list(url = url))
    }
  )
  cnd <- tryCatch(
    relm:::download_verify("https://x/model.gguf", NA_character_, dir, quiet = TRUE),
    condition = function(c) c
  )
  expect_s3_class(cnd, "relm_error_download")
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
  expect_s3_class(cnd, "relm_error_download")
  expect_identical(nchar(cnd$expected), 64L)
  expect_identical(cnd$actual, fx$sha256)
  expect_false(file.exists(file.path(dir, "qwen2.5-0.5b-instruct-q8_0.gguf")))
})

# --- [MODEL] real end-to-end download (founder's Mac only) ------------------

test_that("[MODEL] llm_download() fetches and verifies the pinned 0.5B end-to-end", {
  # Gated: set RELM_DOWNLOAD_E2E=1 to actually download ~644 MB over the
  # network. Never runs in per-commit CI (which is model-free and offline).
  skip_if_not(
    nzchar(Sys.getenv("RELM_DOWNLOAD_E2E")),
    "set RELM_DOWNLOAD_E2E=1 to run the real network download"
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
