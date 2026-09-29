root <- "/private/tmp/relm-release-0.3.0"
.libPaths(c(file.path(root, "library"), "/private/tmp/relm-service/library", .libPaths()))
setwd("/Users/alessandrovadala/DOCUDESK/R-ebirth")
Sys.setenv(RELM_DEMO_NO_AUTORUN = "1")
model <- "/Users/alessandrovadala/Library/Caches/org.R-project.R/R/relm/qwen2.5-0.5b-instruct-q8_0.gguf"
warnings_seen <- list()
receipt <- list(status = "running", pid = Sys.getpid(), purpose = "Classify the 30 warnings from the successful RStudio smoke; no changed acceptance gates")
save_receipt <- function() jsonlite::write_json(receipt, file.path(root, "demo-warning-status.json"), auto_unbox = TRUE, pretty = TRUE)
save_receipt()
stage <- "setup"
tryCatch(withCallingHandlers({
  source("tests/demos/demo-A-anatomy-lab.R")
  source("tests/demos/demo-B-topics.R")
  stage <- "demo-A"
  a <- run_demo_A(model, plot_file = file.path(root, "demo-A-warning-audit.png"))
  stopifnot(a$best_auc >= .7, a$steer$shift_up > a$steer$shift_down)
  stage <- "demo-B"
  stopifnot(isTRUE(run_demo_B_reproducible(model, seed = 20240707L)))
  receipt$status <- "passed"
}, warning = function(w) {
  warnings_seen[[length(warnings_seen) + 1L]] <<- list(stage = stage, message = conditionMessage(w),
      call = paste(deparse(conditionCall(w)), collapse = " "))
  invokeRestart("muffleWarning")
}), error = function(e) { receipt$status <<- "failed"; receipt$error <<- conditionMessage(e) })
receipt$warnings <- warnings_seen
receipt$warning_count <- length(warnings_seen)
save_receipt()
if (receipt$status != "passed") stop(receipt$error)
