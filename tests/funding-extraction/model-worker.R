# Fresh-process native acceptance worker. Test controls never enter the app CLI.
args <- commandArgs(TRUE)
source(file.path(args[[1L]], "examples/funding-extraction/app.R"))
.libPaths(c(file.path(args[[3L]], "library"), .libPaths()))
checkpoint <- function(stage, id) {
  if (length(args) >= 6L && stage == "before_record_rename" && id == "ace22-purpose") {
    app_write_atomic(list(pid = Sys.getpid(), stage = stage, id = id), args[[6L]])
    repeat Sys.sleep(1)
  }
}
result <- app_run(args[[2L]], args[[3L]], args[[4L]], checkpoint = checkpoint)
cat(app_canonical(attr(result, "run_summary")), "\n")
if (any(result$status == "error")) quit(save = "no", status = 2L)
