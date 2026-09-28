#!/usr/bin/env Rscript
script <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[[1L]])
source(file.path(dirname(normalizePath(script)), "app.R"))
app_cli({
  args <- app_options(commandArgs(TRUE), c("environment", "relm-library", "model", "model-alias", "model-sha256"))
  environment <- if (is.null(args$environment)) ".funding-extraction/environment" else args$environment
  prepared <- app_setup(environment, args$model, args[["model-alias"]],
                        args[["model-sha256"]], args[["relm-library"]])
  cat(sprintf("Prepared environment: %s\nModel SHA256: %s\nSetup seconds: %s\n",
              normalizePath(environment), prepared$model$sha256, prepared$setup_elapsed_seconds))
})
