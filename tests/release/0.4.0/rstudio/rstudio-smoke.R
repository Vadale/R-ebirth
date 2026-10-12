# Run as a fresh RStudio background job; never import or export the user's workspace.
root <- "/private/tmp/relm-release-0.4.0"
repo <- "/Users/alessandrovadala/DOCUDESK/R-ebirth"
.libPaths(c(file.path(root, "packaging-r-path", "library"), "/Users/alessandrovadala/Library/R/arm64/4.5/library", "/private/tmp/relm-service/library", .libPaths()))
library(jsonlite)
receipt <- list(status = "running", pid = Sys.getpid(), started_at = as.character(Sys.time()),
                stages = list(), rstudio_environment = Sys.getenv(c("RSTUDIO", "RSTUDIO_SESSION_PORT")))
save_receipt <- function() {
  write_json(receipt, file.path(root, "rstudio-status.tmp"), auto_unbox = TRUE, pretty = TRUE, null = "null")
  stopifnot(file.rename(file.path(root, "rstudio-status.tmp"), file.path(root, "rstudio-status.json")))
}
stage <- function(name, code) {
  receipt$stage <<- name
  save_receipt()
  value <- force(code)
  receipt$stages[[name]] <<- list(status = "passed", finished_at = as.character(Sys.time()))
  save_receipt()
  value
}
warnings <- list()
save_receipt()
tryCatch(withCallingHandlers({
  stopifnot(identical(Sys.getenv("RSTUDIO"), "1"))
  stopifnot(as.character(packageVersion("relm")) == "0.4.0",
            normalizePath(find.package("relm")) == file.path(root, "packaging-r-path", "library", "relm"))
  receipt$package <- list(version = as.character(packageVersion("relm")), path = find.package("relm"))
  writeLines(capture.output(sessionInfo()), file.path(root, "rstudio-session.txt"))
  setwd(repo)
  Sys.setenv(RELM_DEMO_NO_AUTORUN = "1")
  model <- "/Users/alessandrovadala/Library/Caches/org.R-project.R/R/relm/qwen2.5-0.5b-instruct-q8_0.gguf"
  stopifnot(file.exists(model))
  stage("readme-quickstart-and-schema", {
    lines <- readLines(file.path(root, "packaging-r-path", "relm", "README.md"))
    starts <- which(lines == "```r")
    blocks <- lapply(starts, function(i) {
      finish <- which(seq_along(lines) > i & lines == "```")[1L]
      lines[seq.int(i + 1L, finish - 1L)]
    })
    stopifnot(length(blocks) == 4L, any(grepl("install.packages", blocks[[1L]], fixed = TRUE)))
    scope <- new.env(parent = globalenv())
    # README explicitly says to load m using the later quickstart first.
    # Keep each block verbatim, then drain the async result before close(m).
    for (block_index in c(3L, 2L, 4L)) {
      block <- blocks[[block_index]]
      for (expression in parse(text = block)) {
        result <- withVisible(eval(expression, envir = scope))
        if (result$visible) print(result$value)
      }
      if (block_index == 2L) {
        settled <- FALSE
        error <- NULL
        value <- NULL
        observer <- promises::then(scope$pending,
          onFulfilled = function(x) { value <<- x; settled <<- TRUE },
          onRejected = function(e) { error <<- e; settled <<- TRUE })
        deadline <- Sys.time() + 120
        while (!settled && Sys.time() < deadline) later::run_now(0.05)
        if (!settled) { relm::llm_cancel(scope$m); stop("README async deadline") }
        if (!is.null(error)) stop(error)
        saveRDS(value, file.path(root, "readme-async.rds"))
      }
    }
    saveRDS(list(embeddings = scope$emb, trace = scope$tr),
      file.path(root, "readme-observations.rds"))
    stopifnot(nrow(scope$emb) == 3L, all(is.finite(scope$emb)),
              all(abs(rowSums(scope$emb^2) - 1) < 1e-5), nrow(scope$tr) > 0L)
  })
  stage("demo-A", {
    source("tests/demos/demo-A-anatomy-lab.R")
    result <- run_demo_A(model, plot_file = file.path(root, "demo-A.png"), extended = FALSE)
    stopifnot(is.finite(result$best_auc), result$best_auc >= 0.70,
              result$steer$shift_up > result$steer$shift_down)
    saveRDS(result, file.path(root, "demo-A.rds"))
    receipt$demo_A <- list(best_auc = result$best_auc, best_layer = result$best_layer,
                           shift_up = result$steer$shift_up, shift_down = result$steer$shift_down,
                           scope = "Historical exploratory demo; recorded nightly gates, no inferential claim")
  })
  stage("demo-B-reproducibility", {
    source("tests/demos/demo-B-topics.R")
    stopifnot(isTRUE(run_demo_B_reproducible(model, seed = 20240707L)))
    receipt$demo_B <- list(seed = 20240707L, corpus_size = nrow(demo_B_data()),
                           scope = "Full fixed corpus, duplicate embeddings and identical seeded clustering, labels and statistics")
  })
  receipt$status <- "passed"
}, warning = function(w) {
  warnings[[length(warnings) + 1L]] <<- list(stage = receipt$stage,
    message = conditionMessage(w), call = deparse(conditionCall(w)))
  saveRDS(warnings, file.path(root, "rstudio-warnings.rds"))
  # Retain ordinary warning output; do not muffle diagnostics.
}), error = function(error) {
  receipt$status <<- "failed"
  receipt$error <<- conditionMessage(error)
  message("Release smoke failed: ", conditionMessage(error))
})
receipt$warning_count <- length(warnings)
receipt$finished_at <- as.character(Sys.time())
save_receipt()
if (receipt$status != "passed") stop(receipt$error)
