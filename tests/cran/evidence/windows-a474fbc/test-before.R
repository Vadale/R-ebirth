# F1 regression: runs in R-CMD-check without a model or download. Launch a fresh
# R process with the current path helpers (also works under pkgload, where the
# installed package may be older), reproducing two first traces in one directory.
test_that("custom spill paths remain distinct across live R sessions", {
  root <- tempfile("relm-shared-spill-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE, force = TRUE), add = TRUE)
  script <- file.path(root, "child.R")
  result <- file.path(root, "child-path.rds")
  helpers <- c("next_spill_path", "next_trace_id", "spill_session_dir", "spill_root_dir")
  dump(helpers, file = script, envir = asNamespace("relm"))
  cat(
    "\n.relm_state <- new.env(parent = emptyenv())\n",
    "args <- commandArgs(trailingOnly = TRUE)\n",
    "saveRDS(next_spill_path(args[[1L]]), args[[2L]])\n",
    file = script, append = TRUE
  )

  # Reset only the historical filename counter to make this a first-trace
  # collision regression even when other tests have already used this session.
  old_counter <- .relm_state$counter
  .relm_state$counter <- NULL
  on.exit(.relm_state$counter <- old_counter, add = TRUE)
  parent_path <- next_spill_path(root)
  writeLines("live parent trace", parent_path)
  status <- system2(
    file.path(R.home("bin"), "Rscript"),
    c("--vanilla", shQuote(script), shQuote(root), shQuote(result)),
    stdout = FALSE, stderr = FALSE
  )
  expect_identical(status, 0L)
  child_path <- readRDS(result)
  expect_false(identical(parent_path, child_path))
  expect_identical(dirname(child_path), root)
  expect_false(file.exists(child_path))
  expect_identical(readLines(parent_path), "live parent trace")
})

test_that("spill path allocation is lazy and does not alter the user's RNG", {
  set.seed(1729)
  before <- .Random.seed
  root <- tempfile("relm-lazy-spill-")
  paths <- replicate(10L, next_spill_path(root))
  expect_length(unique(paths), 10L)
  expect_false(dir.exists(root))
  expect_false(any(file.exists(paths)))
  expect_identical(.Random.seed, before)
})
