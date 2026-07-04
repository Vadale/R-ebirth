# WP0 smoke test. Real behavioural tests arrive with the first real functions
# (WP1 onward), each alongside its approved API-GRAMMAR entry and its goldens.

test_that("the rebirth namespace loads with its compiled library", {
  # library(rebirth) in tests/testthat.R has already run; reaching here means
  # the package installed and its extendr-registered shared object loaded.
  expect_true("rebirth" %in% loadedNamespaces())
})

test_that("no functions are exported yet (spec-first / API-GRAMMAR gate)", {
  # The scaffold must export nothing until each function's API-GRAMMAR entry is
  # approved. This guard is expected to be updated when WP1 exports llm().
  expect_length(getNamespaceExports("rebirth"), 0L)
})
