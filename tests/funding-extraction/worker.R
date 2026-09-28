#!/usr/bin/env Rscript
# Process test driver only. Never loads a model: the application engine is injected.
args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) %in% c(4L, 5L))
.libPaths(c(normalizePath(args[[2L]], mustWork = TRUE), .libPaths()))
if (length(args) == 5L && identical(args[[5L]], "preload-outside")) {
  # Deliberate negative fixture: the real runner must reject this namespace,
  # even after the prepared library is prepended below.
  loadNamespace("jsonlite")
}
snapshot_library <- file.path(args[[4L]], "library")
if (dir.exists(snapshot_library)) .libPaths(c(snapshot_library, .libPaths()))
source(file.path(args[[1L]], "examples", "funding-extraction", "app.R"))
control <- jsonlite::fromJSON(args[[3L]], simplifyVector = FALSE)

write_meta <- function(value) {
  json <- jsonlite::toJSON(value, auto_unbox = TRUE, null = "null", digits = NA)
  writeBin(charToRaw(enc2utf8(as.character(json))), control$result)
}

canonical_bytes <- function(value) {
  encoded <- app_canonical(value)
  if (is.raw(encoded)) return(encoded)
  stopifnot(is.character(encoded), length(encoded) == 1L, !is.na(encoded))
  charToRaw(enc2utf8(encoded))
}

append_attempt <- function(value) {
  connection <- file(control$attempts, open = "ab")
  on.exit(close(connection))
  writeBin(c(canonical_bytes(value), as.raw(10L)), connection)
}

fixture_engine <- function(prepared, config) {
  stopifnot(is.list(prepared), is.list(config))
  list(
    generate = function(prompt, seed) {
      append_attempt(list(kind = "generate", prompt = prompt, seed = seed))
      if (!is.null(control$error_seed) && identical(as.numeric(seed), as.numeric(control$error_seed))) {
        stop(structure(list(message = "Controlled fixture engine failure", call = NULL),
          class = c("fixture_engine_error", "error", "condition")))
      }
      output <- control$output_text[[as.character(seed)]]
      stopifnot(is.character(output), length(output) == 1L)
      output
    },
    close = function() append_attempt(list(kind = "close"))
  )
}

checkpoint <- function(stage, id) {
  if (!is.null(control$pause_stage) && identical(stage, control$pause_stage) &&
      identical(id, control$pause_id)) {
    # The parent owns the deadline and kills/reaps only its own child process.
    writeBin(canonical_bytes(list(stage = stage, id = id, pid = Sys.getpid())), control$marker)
    repeat Sys.sleep(0.1)
  }
}

main <- function() {
  action <- control$action
  if (identical(action, "canonical")) {
    value <- app_read_json(control$input)
    writeBin(canonical_bytes(value), control$output)
    write_meta(list(sha256 = unname(app_sha256(control$output))))
  } else if (identical(action, "read")) {
    app_read_json(control$input)
    write_meta(list(read = TRUE))
  } else if (identical(action, "environment")) {
    prepared <- app_environment(control$environment)
    write_meta(list(path = prepared$path, library = prepared$library,
      model = prepared$model, manifest = prepared$manifest))
  } else if (identical(action, "recover")) {
    app_recover_lock(control$output, control$nonce,
      confirm_owner_stopped = isTRUE(control$confirm_owner_stopped))
    write_meta(list(recovered = TRUE))
  } else if (identical(action, "run")) {
    result <- app_run(control$config, control$environment, control$output,
      engine_factory = fixture_engine, checkpoint = checkpoint)
    stopifnot(is.data.frame(result))
    write_meta(list(rows = nrow(result), columns = as.list(names(result))))
  } else {
    stop("Unknown test worker action")
  }
}

tryCatch(main(), error = function(error) {
  write_meta(list(error_class = as.list(class(error)), message = conditionMessage(error)))
  message(conditionMessage(error))
  quit(save = "no", status = 23L, runLast = FALSE)
})
