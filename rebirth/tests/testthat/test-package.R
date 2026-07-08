# WP0 smoke test. Real behavioural tests arrive with the first real functions
# (WP1 onward), each alongside its approved API-GRAMMAR entry and its goldens.

test_that("the relm namespace loads with its compiled library", {
  # library(relm) in tests/testthat.R has already run; reaching here means
  # the package installed and its extendr-registered shared object loaded.
  expect_true("relm" %in% loadedNamespaces())
})

test_that("only API-GRAMMAR-approved functions are exported (spec-first gate)", {
  # Every export must have an approved API-GRAMMAR entry. This guard grows one
  # approved entry at a time; the internal .Call wrappers and helpers stay
  # unexported. WP1: llm(). WP2 (API-GRAMMAR section 3): llm_tokens(),
  # llm_generate(). WP3: llm_embed(). WP4 (API-GRAMMAR section 4): llm_trace().
  # WP5 (API-GRAMMAR section 4): llm_steer(), llm_ablate(). WP (API-GRAMMAR
  # section 4): llm_logits(). WP8a (API-GRAMMAR section 3): llm_download().
  expect_setequal(
    getNamespaceExports("relm"),
    c(
      "llm", "llm_tokens", "llm_generate", "llm_embed", "llm_trace",
      "llm_steer", "llm_ablate", "llm_logits", "llm_download"
    )
  )
})

test_that("the WP4 relm_trace S3 methods are registered (API-GRAMMAR section 2/4)", {
  # print/summary/as.matrix on `relm_trace`, plus print on its summary object.
  for (m in c(
    "print.relm_trace", "summary.relm_trace",
    "as.matrix.relm_trace", "print.summary.relm_trace"
  )) {
    expect_true(
      exists(m, envir = asNamespace("relm"), inherits = FALSE),
      info = m
    )
  }
  expect_false(is.null(getS3method("print", "relm_trace", optional = TRUE)))
  expect_false(is.null(getS3method("summary", "relm_trace", optional = TRUE)))
  expect_false(is.null(getS3method("as.matrix", "relm_trace", optional = TRUE)))
})

test_that("the WP1 S3 methods are registered (API-GRAMMAR section 3)", {
  # print/summary/close on `llm`, plus print on the summary object.
  for (m in c("print.llm", "summary.llm", "close.llm", "print.summary.llm")) {
    expect_true(
      exists(m, envir = asNamespace("relm"), inherits = FALSE),
      info = m
    )
  }
  expect_false(is.null(getS3method("close", "llm", optional = TRUE)))
  expect_false(is.null(getS3method("print", "llm", optional = TRUE)))
  expect_false(is.null(getS3method("summary", "llm", optional = TRUE)))
  expect_false(is.null(getS3method("print", "summary.llm", optional = TRUE)))
})
