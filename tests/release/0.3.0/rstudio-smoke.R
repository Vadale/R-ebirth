# Run as a fresh RStudio background job; never import or export the user's workspace.
root <- "/private/tmp/relm-release-0.3.0"
repo <- "/Users/alessandrovadala/DOCUDESK/R-ebirth"
.libPaths(c(file.path(root, "library"), "/private/tmp/relm-service/library", .libPaths()))
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
save_receipt()
tryCatch({
  stopifnot(as.character(packageVersion("relm")) == "0.3.0",
            normalizePath(find.package("relm")) == file.path(root, "library", "relm"))
  receipt$package <- list(version = as.character(packageVersion("relm")), path = find.package("relm"))
  writeLines(capture.output(sessionInfo()), file.path(root, "rstudio-session.txt"))
  setwd(repo)
  Sys.setenv(RELM_DEMO_NO_AUTORUN = "1")
  model <- "/Users/alessandrovadala/Library/Caches/org.R-project.R/R/relm/qwen2.5-0.5b-instruct-q8_0.gguf"
  stopifnot(file.exists(model))
  stage("readme-quickstart-and-schema", {
    lines <- readLines(file.path(repo, "rebirth", "README.md"))
    starts <- which(lines == "```r")
    blocks <- lapply(starts, function(i) {
      finish <- which(seq_along(lines) > i & lines == "```")[1L]
      lines[seq.int(i + 1L, finish - 1L)]
    })
    stopifnot(length(blocks) == 3L, any(grepl("install.packages", blocks[[1L]], fixed = TRUE)))
    scope <- new.env(parent = globalenv())
    for (block in blocks[2:3]) {
      for (expression in parse(text = block)) {
        result <- withVisible(eval(expression, envir = scope))
        if (result$visible) print(result$value)
      }
    }
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
}, error = function(error) {
  receipt$status <<- "failed"
  receipt$error <<- conditionMessage(error)
  message("Release smoke failed: ", conditionMessage(error))
})
receipt$finished_at <- as.character(Sys.time())
save_receipt()
if (receipt$status != "passed") stop(receipt$error)
