# Runs in ordinary R CI. No model load, inference, download or relm installation.
source("examples/research-workflow/run.R")
root <- tempfile("research-preflight-"); dir.create(root)
on.exit_cleanup <- function() unlink(root, recursive = TRUE)
tryCatch({
  fake <- file.path(root, "not-a-model.gguf"); writeLines("not model data", fake)
  kept <- file.path(root, "kept"); dir.create(kept)
  writeLines("existing result", file.path(kept, "result.txt"))
  expect_error <- function(expr, message) {
    error <- tryCatch({ force(expr); NULL }, error = identity)
    stopifnot(inherits(error, "error"), grepl(message, conditionMessage(error), fixed = TRUE))
  }
  expect_error(research_preflight(file.path(root, "absent"), file.path(root, "new"), "build"), "existing cached GGUF")
  expect_error(research_preflight(root, file.path(root, "new"), "build"), "existing cached GGUF")
  expect_error(research_preflight(fake, kept, "build"), "never overwritten")
  expect_error(research_preflight(fake, fake, "build"), "never overwritten")
  expect_error(research_preflight(fake, file.path(root, "absent", "out"), "build"), "parent directory")
  expect_error(research_preflight(fake, file.path(root, "new"), NA_character_), "engine revision")
  expect_error(research_preflight(fake, file.path(root, "new"), strrep("x", 129)), "engine revision")
  stopifnot(identical(readLines(file.path(kept, "result.txt")), "existing result"),
            identical(sort(list.files(root)), c("kept", "not-a-model.gguf")))
  p <- research_prompts()
  stopifnot(nrow(p) == 6L, !anyDuplicated(p$text), !anyDuplicated(p$id),
            identical(p$split, c(rep("construction", 4), "selection", "evaluation")))
  cat("RESEARCH_PREFLIGHT_OK: seven refusals, retained existing output, six disjoint prompts; zero model calls\n")
}, finally = on.exit_cleanup())
