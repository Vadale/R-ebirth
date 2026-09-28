#!/usr/bin/env Rscript
script <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[[1L]])
source(file.path(dirname(normalizePath(script)), "app.R"))
app_cli({
  args <- app_options(commandArgs(TRUE), c("environment", "config", "output", "recover-lock"), "confirm-owner-stopped")
  environment <- if (is.null(args$environment)) ".funding-extraction/environment" else args$environment
  output <- if (is.null(args$output)) ".funding-extraction/run" else args$output
  if (!is.null(args[["recover-lock"]])) {
    .libPaths(c(file.path(environment, "library"), .libPaths()))
    path <- app_recover_lock(output, args[["recover-lock"]], isTRUE(args[["confirm-owner-stopped"]]))
    cat(sprintf("Abandoned lock preserved at %s. Run again without recovery options.\n", path))
  } else {
    if (!is.null(args[["confirm-owner-stopped"]])) app_abort("Recovery confirmation requires --recover-lock.")
    config <- if (is.null(args$config)) file.path(dirname(script), "config.json") else args$config
    result <- app_run(config, environment, output)
    summary <- attr(result, "run_summary")
    cat(sprintf("Documents: %d; processed: %d; reused: %d; valid: %d; invalid: %d; errors: %d\n",
                summary$documents, summary$processed, summary$reused, summary$success, summary$invalid, summary$errors))
    cat(sprintf("Results: %s\n", normalizePath(file.path(output, "results.csv"))))
    # A complete run with failed documents remains resumable, but is not silent success.
    if (summary$errors + summary$invalid > 0L) quit(save = "no", status = 2L)
  }
})
