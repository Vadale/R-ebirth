# WP0 smoke test. Real behavioural tests arrive with the first real functions
# (WP1 onward), each alongside its approved API-GRAMMAR entry and its goldens.

test_that("the rebirth namespace loads with its compiled library", {
  # library(rebirth) in tests/testthat.R has already run; reaching here means
  # the package installed and its extendr-registered shared object loaded.
  expect_true("rebirth" %in% loadedNamespaces())
})

test_that("only API-GRAMMAR-approved functions are exported (spec-first gate)", {
  # Every export must have an approved API-GRAMMAR entry. WP1 exports exactly
  # llm(); the internal .Call wrappers and helpers stay unexported. This guard
  # grows one approved entry at a time.
  expect_setequal(getNamespaceExports("rebirth"), "llm")
})

test_that("the WP1 S3 methods are registered (API-GRAMMAR section 3)", {
  # print/summary/close on `llm`, plus print on the summary object.
  for (m in c("print.llm", "summary.llm", "close.llm", "print.summary.llm")) {
    expect_true(
      exists(m, envir = asNamespace("rebirth"), inherits = FALSE),
      info = m
    )
  }
  expect_false(is.null(getS3method("close", "llm", optional = TRUE)))
  expect_false(is.null(getS3method("print", "llm", optional = TRUE)))
  expect_false(is.null(getS3method("summary", "llm", optional = TRUE)))
  expect_false(is.null(getS3method("print", "summary.llm", optional = TRUE)))
})
