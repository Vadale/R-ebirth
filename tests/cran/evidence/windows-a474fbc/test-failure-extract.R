# Extracted from test-llm-trace-spill-session.R:34

# setup ------------------------------------------------------------------------
library(testthat)
test_env <- simulate_test_env(package = "relm", path = "..")
attach(test_env, warn.conflicts = FALSE)

# test -------------------------------------------------------------------------
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
