# Draft: source from the real foreground RStudio Console only after automated
# F6b acceptance. Source rstudio-probe.R independently while status is running.
stopifnot(Sys.getenv("RSTUDIO") == "1", !"relm" %in% loadedNamespaces(),
  !exists(".relm_f6b_acceptance", envir = .GlobalEnv, inherits = FALSE))
.relm_f6b_acceptance <- local({
  a <- new.env(parent = globalenv())
  a$root <- "/private/tmp/relm-f6b/rstudio"
  dir.create(a$root, recursive = TRUE, showWarnings = FALSE)
  a$preflight <- list(globals = ls(.GlobalEnv, all.names = TRUE),
    seed = get0(".Random.seed", .GlobalEnv), library = .libPaths(), search = search(),
    devices = grDevices::dev.list(), pid = Sys.getpid(), session = sessionInfo())
  saveRDS(a$preflight, file.path(a$root, "preflight.rds"))
  library_path <- normalizePath(Sys.getenv("RELM_F6B_LIBRARY"), mustWork = TRUE)
  model_path <- normalizePath(Sys.getenv("RELM_TEST_MODEL_QWEN"), mustWork = TRUE)
  stopifnot(nzchar(Sys.getenv("RELM_F6B_LIBRARY")), nzchar(Sys.getenv("RELM_TEST_MODEL_QWEN")))
  .libPaths(c(library_path, .libPaths()))
  stopifnot(requireNamespace("relm", quietly = TRUE), requireNamespace("promises", quietly = TRUE),
    requireNamespace("later", quietly = TRUE),
    normalizePath(find.package("relm")) == file.path(library_path, "relm"),
    "interventions" %in% names(formals(relm:::live_reply)))
  a$clock <- function() unname(proc.time()[["elapsed"]])
  a$status <- "preparing"
  a$probe <- a$error <- a$cancel_state <- a$estimate <- a$timer <- NULL
  a$states <- a$tokens <- a$heartbeats <- a$expected_revision <- 0L
  a$current_coef <- 0
  a$last_update <- 0L
  a$events <- vector("list", 1024L)
  a$positions <- rep(NA_integer_, 64L)
  a$scores <- rep(NA_real_, 64L)
  a$receipt <- function() saveRDS(list(status = a$status, pid = Sys.getpid(),
    package = find.package("relm"), version = packageVersion("relm"),
    states = a$states, tokens = a$tokens, revisions = a$expected_revision,
    heartbeats = a$heartbeats, probe = a$probe, error = a$error),
    file.path(a$root, "status.rds"))
  a$base <- relm::llm(model_path, backend = "cpu", context_length = 2048)
  a$model <- relm::llm_steer(a$base, 2L, rep(0.01, a$base$hidden_size), coef = 0)
  a$metadata <- serialize(a$model$interventions, NULL, version = 2)
  a$baseline <- relm::llm_generate(a$model, "1, 2, 3, 4, 5,", chat = FALSE,
    max_tokens = 3L, temperature = 0.7, seed = 6267)
  a$heartbeat <- function() {
    if (identical(a$status, "running")) {
      a$heartbeats <- a$heartbeats + 1L
      a$timer <- later::later(a$heartbeat, 0.02, loop = later::global_loop())
    }
  }
  a$finish <- function(error = NULL) {
    a$duration <- a$clock() - a$started
    if (is.function(a$timer)) a$timer()
    a$error <- error
    rows <- if (a$states) do.call(rbind, a$events[seq_len(a$states)]) else data.frame()
    good <- inherits(error, "relm_error_cancelled") && identical(error$reason, "requested") &&
      !is.null(a$cancel_state) && error$generated_tokens == a$states &&
      a$cancel_state$state_id == a$states && a$tokens == a$states - 1L &&
      a$duration >= 6 && a$heartbeats >= 10L && a$expected_revision >= 2L &&
      all(c(0, 0.5) %in% rows$coef) && !is.null(a$probe) &&
      isTRUE(a$probe$was_running) && isTRUE(a$probe$native_running) &&
      identical(a$probe$value, 2) && a$probe$elapsed < 0.5 &&
      a$probe$states_delivered > 0L && is.null(relm:::.relm_async$job)
    reset <- tryCatch(identical(relm::llm_generate(a$model, "1, 2, 3, 4, 5,",
      chat = FALSE, max_tokens = 3L, temperature = 0.7, seed = 6267), a$baseline), error = identity)
    good <- good && isTRUE(reset) &&
      identical(serialize(a$model$interventions, NULL, version = 2), a$metadata)
    a$status <- if (good) "passed" else "failed"
    saveRDS(list(events = rows, error = error, probe = a$probe, reset = reset,
      duration_seconds = a$duration, submission_seconds = a$submission,
      estimate = a$estimate, metadata = a$metadata), file.path(a$root, "result.rds"))
    write.csv(rows, file.path(a$root, "states.csv"), row.names = FALSE)
    close(a$model)
    close(a$base)
    a$receipt()
    cat("F6B_RSTUDIO_COMPLETE:", a$status, "\n")
    NULL
  }
  a$started <- a$clock()
  a$status <- "running"
  a$promise <- relm::llm_generate(a$model,
    "Count integers from 1 to 1000, separated by commas. Do not explain.",
    max_tokens = 1024L, seed = 6267, temperature = 0, async = TRUE,
    layers = 2L, top = 5L, spill = FALSE,
    on_state = function(state) {
      a$states <- a$states + 1L
      p <- attr(state$trace, "prompt_token_count")
      audit <- attr(state, "steering", exact = TRUE)
      stopifnot(state$step$state_id == a$states, a$tokens == a$states - 1L,
        identical(state$step$steering_revision, a$expected_revision),
        identical(state$step$applied_after_state, a$last_update),
        identical(state$step$effective_source_pos, if (a$last_update) p + a$last_update else 1L),
        identical(audit, data.frame(intervention = 1L, layer = 2L, coef = a$current_coef)))
      if (is.null(a$estimate)) a$estimate <- relm:::.relm_async$job$live$estimate
      bytes <- as.numeric(object.size(state))
      stopifnot(bytes <= a$estimate$materialized_bytes)
      # A displayed neuron score is a mechanism, not a calibrated detector.
      score <- as.matrix(state$trace, layer = 2L)[1L, 1L]
      slot <- (a$states - 1L) %% 64L + 1L
      a$positions[[slot]] <- state$step$source_pos
      a$scores[[slot]] <- score
      a$events[[a$states]] <- cbind(state$step, coef = audit$coef, score = score,
        object_bytes = bytes)
      if (a$states %% 32L == 0L) {
        used <- which(!is.na(a$positions)); used <- used[order(a$positions[used])]
        plot(a$positions[used], a$scores[used], type = "l",
          xlab = "Model-context source position", ylab = "Layer 2, neuron 1 activation",
          main = paste("Live steering; applied coefficient", audit$coef))
      }
      if (!is.null(a$probe) && a$clock() - a$started >= 6 && a$expected_revision >= 2L) {
        a$cancel_state <- state$step
        stopifnot(relm::llm_cancel(a$model))
        return(invisible(NULL))
      }
      if (a$states %% 16L == 0L) {
        a$current_coef <- if (a$current_coef == 0) 0.5 else 0
        a$expected_revision <- a$expected_revision + 1L
        a$last_update <- a$states
        return(list(steer = data.frame(intervention = 1L, coef = a$current_coef)))
      }
      invisible(NULL)
    }, on_token = function(batch) {
      a$tokens <- a$tokens + sum(batch$event == "token")
      invisible(NULL)
    })
  a$submission <- a$clock() - a$started
  a$observed <- promises::then(a$promise, function(value) a$finish(), a$finish)
  a$heartbeat()
  a$receipt()
  cat("F6B_RSTUDIO_RUNNING: source the independent probe from the Console now.\n")
  a
})
