# Actual foreground RStudio console gate; refuses to touch a populated session.
stopifnot(Sys.getenv("RSTUDIO") == "1", !"relm" %in% loadedNamespaces(),
  length(setdiff(ls(.GlobalEnv, all.names=TRUE), ".Random.seed")) == 0L)
saveRDS(list(globals=ls(.GlobalEnv, all.names=TRUE),
  seed=get0(".Random.seed", .GlobalEnv), library=.libPaths(), search=search(),
  pid=Sys.getpid(), session=sessionInfo()), "/private/tmp/relm-wp10/rstudio/preflight.rds")
.relm_wp10_acceptance <- local({
  a <- new.env(parent=globalenv())
  a$root <- "/private/tmp/relm-wp10/rstudio"
  a$status <- "preparing"
  a$probe <- NULL
  a$error <- NULL
  a$state <- NULL
  a$started_at <- as.numeric(Sys.time())
  .libPaths(c("/private/tmp/relm-wp10/library", "/private/tmp/relm-service/library", .libPaths()))
  library(relm)
  stopifnot(normalizePath(find.package("relm")) == "/private/tmp/relm-wp10/library/relm",
    "on_token" %in% names(formals(llm_generate)))
  a$receipt <- function() {
    d <- a$state
    value <- list(status=a$status, pid=Sys.getpid(), started_at=a$started_at,
      version=as.character(packageVersion("relm")), library=find.package("relm"),
      rstudio_version=as.character(rstudioapi::versionInfo()$version),
      probe=a$probe, error=a$error,
      generation_seconds=if (!is.null(d)) d$finished else NULL,
      submission_seconds=if (!is.null(d)) d$submission_seconds else NULL,
      first_batch_seconds=if (!is.null(d)) d$first_batch else NULL,
      heartbeats=if (!is.null(d)) d$heartbeats else NULL,
      tokens=if (!is.null(d)) d$total_tokens else NULL)
    jsonlite::write_json(value, file.path(a$root, "status.tmp"),
      auto_unbox=TRUE, pretty=TRUE, null="null")
    stopifnot(file.rename(file.path(a$root, "status.tmp"),file.path(a$root,"status.json")))
  }
  a$receipt()
  source("/Users/alessandrovadala/DOCUDESK/R-ebirth/tests/demos/demo-streaming.R", local=a)
  a$model <- llm("/Users/alessandrovadala/Library/Caches/org.R-project.R/R/relm/qwen2.5-0.5b-instruct-q8_0.gguf",
    backend="cpu", context_length=2048)
  a$state <- a$start_streaming_demo(a$model, draw=TRUE)
  a$status <- "running"
  a$observed <- promises::then(a$state$observed, function(unused) {
    d <- a$state
    good <- identical(d$status,"completed") && d$finished >= 5 &&
      d$heartbeats >= 10L && !is.null(a$probe) && isTRUE(a$probe$was_running) &&
      isTRUE(a$probe$native_running) && a$probe$tokens_delivered > 0L &&
      identical(a$probe$value,2) && a$probe$elapsed < 0.5 &&
      is.finite(d$first_batch) && d$first_batch < d$finished
    a$status <- if (good) "passed" else "failed"
    if (!good) a$error <- "Foreground stream/probe/heartbeat acceptance gate failed."
    saveRDS(list(events=d$events, statistics=d$statistics, text=d$text,
      value=d$value, duration=d$finished, submission=d$submission_seconds),
      file.path(a$root,"result.rds"))
    if (!is.null(d$events)) write.csv(d$events,file.path(a$root,"events.csv"),row.names=FALSE)
    close(a$model)
    a$receipt()
    cat("WP10_RSTUDIO_COMPLETE:",a$status,"\n")
    NULL
  }, function(error) {
    a$status <- "failed"; a$error <- conditionMessage(error)
    close(a$model); a$receipt(); NULL
  })
  a$receipt()
  cat("WP10_RSTUDIO_RUNNING: submit the independent 1 + 1 probe now.\n")
  a
})
