# Trusted callr worker entry points. No model or engine closure leaves this R
# process, and only the frontend publishes application records.
svc_worker_guard <- function(code) {
  tryCatch(withCallingHandlers(code,
    warning = function(w) invokeRestart("muffleWarning"),
    message = function(m) invokeRestart("muffleMessage")), error = function(e) {
      cls <- class(e)
      cls <- cls[grepl("^(relm_error_|funding_error_)[A-Za-z0-9_]+$", cls)]
      list(worker_error = TRUE, error = list(
        class = if (length(cls)) cls[[1L]] else "service_error_inference",
        reason = "inference", message = "The extraction could not be completed."))
    })
}

svc_worker_flood <- function() {
  piece <- paste(rep("x", 16384L), collapse = "")
  repeat { cat(piece); cat(piece, file = stderr()); flush.console() }
}

svc_worker_init <- function(prepared, identity, test_config = NULL) {
  svc_worker_guard({
    native <- is.null(test_config) || identical(test_config$worker$mode, "native")
    if (native) {
      checked <- svc_environment(prepared$path)
      if (!identical(app_canonical(checked$identity), app_canonical(prepared$identity)))
        app_abort("The worker environment changed.", "environment")
      prepared <- checked
    }
    fixture <- if (is.null(test_config$worker)) list() else test_config$worker
    if (isTRUE(fixture$init_flood)) svc_worker_flood()
    if (!is.null(fixture$init_delay_seconds)) Sys.sleep(fixture$init_delay_seconds)
    if (isTRUE(fixture$init_fail)) app_abort("Injected initialization failure.", "environment")
    engine <- if (native) app_engine(prepared, prepared$config) else NULL
    assign(".svc_worker", list(prepared = prepared, identity = identity,
      engine = engine, test_config = test_config), envir = .GlobalEnv)
    list(ready = TRUE, identity = identity, pid = Sys.getpid(),
         tempdir = normalizePath(tempdir()), callr_tmpdir = Sys.getenv("CALLR_TMPDIR"))
  })
}

svc_worker_raw_hash <- function(bytes) {
  file <- tempfile("raw-hash-", tmpdir = Sys.getenv("CALLR_TMPDIR"))
  on.exit(unlink(file), add = TRUE)
  writeBin(bytes, file)
  app_sha256(file)
}

svc_worker_prefix <- function(raw, limit = 4096L) {
  if (is.na(iconv(raw, from = "UTF-8", to = "UTF-8"))) return(NULL)
  bytes <- charToRaw(enc2utf8(raw))
  if (length(bytes) <= limit) return(enc2utf8(raw))
  bytes <- bytes[seq_len(limit)]
  while (length(bytes)) {
    value <- rawToChar(bytes)
    if (!is.na(iconv(value, from = "UTF-8", to = "UTF-8"))) return(value)
    bytes <- head(bytes, -1L)
  }
  ""
}

svc_worker_fixture <- function(doc, config, test_config) {
  fixture <- utils::modifyList(if (is.null(test_config$worker)) list() else test_config$worker,
                              if (is.null(test_config$request_modes[[doc$id]])) list() else test_config$request_modes[[doc$id]])
  mode <- if (is.null(fixture$mode)) "success" else fixture$mode
  if (!is.null(fixture$delay_seconds)) Sys.sleep(fixture$delay_seconds)
  if (mode == "pause") {
    if (!is.null(fixture$release_file)) {
      while (!file.exists(fixture$release_file)) Sys.sleep(.05)
    } else repeat Sys.sleep(1)
  }
  if (mode == "crash") quit(save = "no", status = 86L, runLast = FALSE)
  if (mode == "flood") svc_worker_flood()
  if (mode == "ipc_flood") {
    con <- file(file.path(tempdir(), "injected-ipc-flood"), "wb")
    on.exit(close(con), add = TRUE)
    for (i in seq_len(66L)) writeBin(raw(1048576L), con)
    flush(con)
    repeat Sys.sleep(1)
  }
  if (mode == "error") app_abort("Injected inference failure.", "fixture")
  if (mode == "echo") return(app_canonical(doc))
  if (mode == "temp_echo") return(app_canonical(list(tempdir = tempdir(),
    environment = as.list(Sys.getenv(c("CALLR_TMPDIR", "TMPDIR", "TMP", "TEMP"))))))
  if (!is.null(fixture$raw)) return(fixture$raw)
  if (mode == "invalid") return("{invalid json")
  if (mode == "overflow") return(paste(rep("\001", 65536L), collapse = ""))
  app_canonical(list(amount_usd = NULL, amount_qualifier = "not_stated",
    duration_years = NULL, conditional_on_funds = NULL,
    evidence = list(amount_usd = NULL, amount_qualifier = NULL,
                    duration_years = NULL, conditional_on_funds = NULL)))
}

svc_worker_extract <- function(doc, input_sha256, epoch) {
  started <- proc.time()[["elapsed"]]
  value <- svc_worker_guard({
    state <- get(".svc_worker", envir = .GlobalEnv, inherits = FALSE)
    raw <- if (!is.null(state$engine)) {
      generated <- state$engine$generate(app_prompt(state$prepared$config, doc), doc$seed)
      fault <- state$test_config$request_modes[[doc$id]]
      if (identical(fault$mode, "post_generate_invalid")) fault$raw else generated
    } else svc_worker_fixture(doc, state$prepared$config, state$test_config)
    if (!is.character(raw) || length(raw) != 1L || is.na(raw))
      app_abort("Generation did not return one string.", "output")
    bytes <- charToRaw(raw)
    raw_bytes <- length(bytes)
    raw_hash <- svc_worker_raw_hash(bytes)
    limits <- state$prepared$contract$limits
    prefix <- svc_worker_prefix(raw, limits$overflow_prefix_bytes)
    # Bound serialization before handing the result to callr. The frontend also
    # measures the complete terminal envelope after adding its own metadata.
    if (raw_bytes > limits$raw_output_bytes || is.na(iconv(raw, from = "UTF-8", to = "UTF-8"))) {
      list(state = "error", output = NULL, raw_output = NULL,
        error = list(class = "service_error_output_limit", reason = "output_limit",
                     message = "Generated output exceeded the service output contract."),
        raw_truncated = TRUE, raw_bytes = raw_bytes, raw_sha256 = raw_hash, raw_prefix = prefix)
    } else {
      parsed <- tryCatch({ x <- app_parse_json(raw); app_validate_output(x, doc$text); x }, error = function(e) NULL)
      result <- list(state = if (is.null(parsed)) "invalid" else "success", output = parsed,
        raw_output = enc2utf8(raw), error = if (is.null(parsed))
          list(class = "service_error_invalid_output", reason = "validation",
               message = "Generated output did not pass the extraction checks.") else NULL)
      result
    }
  })
  if (isTRUE(value$worker_error)) value <- list(state = "error", output = NULL,
    raw_output = NULL, error = value$error)
  result <- c(list(id = doc$id, input_sha256 = input_sha256, epoch = epoch), value,
              list(elapsed_ms = as.integer(round(1000 * (proc.time()[["elapsed"]] - started)))))
  fixture <- get(".svc_worker", envir = .GlobalEnv)$test_config
  mode <- fixture$request_modes[[doc$id]]$mode
  if (is.null(mode)) mode <- fixture$worker$mode
  if (identical(mode, "wrong_epoch")) result$epoch <- paste(rep("0", 32L), collapse = "")
  result
}

svc_worker_close <- function() {
  svc_worker_guard({
    if (exists(".svc_worker", envir = .GlobalEnv, inherits = FALSE)) {
      state <- get(".svc_worker", envir = .GlobalEnv)
      if (!is.null(state$engine)) state$engine$close()
      rm(".svc_worker", envir = .GlobalEnv)
    }
    list(closed = TRUE)
  })
}
