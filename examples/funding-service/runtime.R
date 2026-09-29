# Single-user service adapter (D-034). HTTP and process transport belong to
# Plumber/httpuv/callr. This file owns one admission slot and durable tickets.
svc_abort <- function(message, kind = "service") app_abort(message, kind)
svc_now <- function() proc.time()[["elapsed"]]
svc_stamp <- function() format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC")
svc_birth <- function(handle) sprintf("%.6f", as.numeric(ps::ps_create_time(handle)))
svc_process <- function(pid = Sys.getpid()) {
  handle <- ps::ps_handle(pid)
  list(pid = as.integer(pid), birth = svc_birth(handle))
}
svc_confirm_ended <- function(handle) {
  # Darwin task inspection may fail just before exit becomes observable. Retry
  # only this error path, keeping the original creation-time-aware handle. A
  # permission error or unknown state is never evidence that a process ended.
  ended <- function() tryCatch({
    if (!ps::ps_is_running(handle)) return(TRUE)
    ps::ps_status(handle) %in% c("zombie", "dead")
  }, error = function(err) FALSE)
  if (ended()) return(TRUE)
  for (attempt in seq_len(2L)) {
    Sys.sleep(.05)
    if (ended()) return(TRUE)
  }
  FALSE
}
svc_running <- function(handle) {
  if (!ps::ps_is_running(handle)) return(FALSE)
  status <- tryCatch(ps::ps_status(handle), error = function(err) {
    if (svc_confirm_ended(handle)) return("dead")
    svc_abort("Cannot establish process liveness.", "ownership")
  })
  !status %in% c("zombie", "dead")
}
svc_alive <- function(identity) {
  if (is.null(identity)) return(FALSE)
  if (!is.list(identity) || !is.numeric(identity$pid) || length(identity$pid) != 1L ||
      identity$pid < 1 || !is.character(identity$birth) || length(identity$birth) != 1L ||
      !grepl("^[0-9]+\\.[0-9]{6}$", identity$birth)) svc_abort("Invalid process ownership record.", "ownership")
  if (!identity$pid %in% ps::ps_pids()) return(FALSE)
  handle <- tryCatch(ps::ps_handle(identity$pid), error = function(e) {
    if (!identity$pid %in% ps::ps_pids()) return(NULL)
    svc_abort("Cannot establish process ownership.", "ownership")
  })
  if (is.null(handle)) return(FALSE)
  if (identical(unname(Sys.info()[["sysname"]]), "Linux")) {
    # ps caches a measured boot-clock offset separately in each R process.
    # Compare the persisted creation-time handle using ps's native identity
    # semantics, not newly formatted absolute timestamps. Keep the fresh
    # handle above: a live process whose stat cannot be read is still an error.
    handle <- ps::ps_handle(identity$pid,
      time = as.POSIXct(as.numeric(identity$birth), origin = "1970-01-01"))
    return(svc_running(handle))
  }
  identical(svc_birth(handle), identity$birth) && svc_running(handle)
}
svc_private_dir <- function(path) {
  app_no_symlink(path)
  if (!dir.exists(path) && !dir.create(path, recursive = FALSE, mode = "0700"))
    svc_abort("Cannot create private service directory.", "filesystem")
  Sys.chmod(path, "0700")
  normalizePath(path, mustWork = TRUE)
}
svc_hash <- function(value, directory, bytes = FALSE) {
  path <- tempfile(".hash-", tmpdir = directory)
  on.exit(unlink(path), add = TRUE)
  writeBin(if (bytes) value else charToRaw(app_canonical(value)), path)
  Sys.chmod(path, "0600")
  app_sha256(path)
}
svc_seal <- function(value, directory) {
  value$record_sha256 <- svc_hash(value, directory)
  value
}
svc_verify_seal <- function(value, directory) {
  if (!is.list(value) || is.null(value$record_sha256) ||
      !identical(value$record_sha256, svc_hash(value[setdiff(names(value), "record_sha256")], directory)))
    svc_abort("A service record failed its integrity check.", "integrity")
  invisible(value)
}
svc_read <- function(path, limit = 131072L) {
  app_no_symlink(path)
  app_parse_json(app_read_text(path, limit))
}
svc_write <- function(value, path, replace = FALSE, before = NULL, after = NULL) {
  app_write_atomic(value, path, replace, before, after)
  Sys.chmod(path, "0600")
  invisible(value)
}
svc_tree_bytes <- function(path, live_ipc = FALSE) {
  fail <- function() svc_abort("Cannot account for service storage.", if (live_ipc) "ipc" else "filesystem")
  if (live_ipc && (!dir.exists(path) || file.access(path, 5L) != 0L)) fail()
  files <- list.files(path, all.files = TRUE, no.. = TRUE, recursive = TRUE, full.names = TRUE, include.dirs = TRUE)
  if (!length(files)) return(0)
  if (any(nzchar(Sys.readlink(files), keepNA = TRUE), na.rm = TRUE)) svc_abort("Symbolic links are forbidden in the service store.", "filesystem")
  info <- file.info(files)
  sizes <- info$size
  directories <- which(!is.na(info$isdir) & info$isdir)
  if (anyNA(sizes[directories]) || any(file.access(files[directories], 5L) != 0L)) fail()
  sizes[directories] <- 0
  if (anyNA(sizes)) {
    if (!live_ipc) fail()
    for (i in which(is.na(sizes))) {
      # Worker/callr temporary files are concurrently consumed. A failed stat
      # alone is not proof of deletion: reject a still-existing file and require
      # a statable, accessible containing ancestor before accepting absence.
      file <- files[[i]]
      if (file.exists(file) || isTRUE(nzchar(Sys.readlink(file), keepNA = TRUE))) fail()
      ancestor <- dirname(file)
      repeat {
        info <- file.info(ancestor)
        if (!is.na(info$isdir)) {
          if (!isTRUE(info$isdir) || is.na(info$size) || file.access(ancestor, 5L) != 0L ||
              isTRUE(nzchar(Sys.readlink(ancestor), keepNA = TRUE))) fail()
          break
        }
        if (file.exists(ancestor) || isTRUE(nzchar(Sys.readlink(ancestor), keepNA = TRUE)) ||
            identical(ancestor, path) || identical(dirname(ancestor), ancestor)) fail()
        ancestor <- dirname(ancestor)
      }
      if (file.exists(file) || isTRUE(nzchar(Sys.readlink(file), keepNA = TRUE))) fail()
      sizes[[i]] <- 0
    }
  }
  sum(sizes)
}
svc_document <- function(doc, limits) {
  app_object(doc, c("id", "target", "text", "seed"), "service request")
  id <- app_string(doc$id, "id", limit = limits$request_id_bytes)
  if (!grepl("^[A-Za-z0-9][A-Za-z0-9_-]*$", id)) svc_abort("Invalid request ID.", "input")
  doc$target <- app_string(doc$target, "target", limit = limits$target_bytes)
  doc$text <- app_string(doc$text, "text", limit = limits$document_text_bytes)
  doc$seed <- app_integer(doc$seed, "seed")
  doc
}
svc_record_name <- function(id) paste0(paste(sprintf("%02x", as.integer(charToRaw(id))), collapse = ""), ".json")
svc_checkpoint <- function(e, stage, id) {
  fail <- e$test$fail_publication
  if (is.character(fail)) fail <- list(stage = fail)
  if (!is.null(fail) && identical(fail$stage, stage) &&
      (is.null(fail$id) || identical(fail$id, id))) svc_abort("Injected publication failure.", "filesystem")
  hook <- e$test$checkpoint
  if (!is.null(hook) && identical(hook$stage, stage) &&
      (is.null(hook$id) || identical(hook$id, id))) {
    if (!is.null(hook$marker)) writeLines(stage, hook$marker)
    if (!is.null(hook$release)) while (!file.exists(hook$release)) Sys.sleep(.02)
  }
}
svc_owner_write <- function(e) {
  value <- list(format_version = 1L, host = unname(Sys.info()[["nodename"]]),
    nonce = e$nonce, frontend = e$frontend, worker = e$worker_identity,
    service_identity = e$identity)
  svc_write(value, file.path(e$store, "store.lock", "owner.json"), replace = TRUE)
}
svc_epoch_clean <- function(e, path) {
  app_no_symlink(path)
  owner <- svc_read(file.path(path, "owner.json"))
  if (!identical(owner$service_identity, e$identity) ||
      !identical(owner$epoch, basename(path)) || !grepl("^[a-f0-9]{32}$", owner$epoch) ||
      is.null(owner$frontend) || is.null(owner$worker))
    svc_abort("Cannot establish ownership of an IPC epoch.", "ownership")
  if (svc_alive(owner$worker)) svc_abort("An IPC epoch still has a live worker.", "ownership")
  if (!identical(owner$nonce, e$nonce) && svc_alive(owner$frontend))
    svc_abort("An IPC epoch belongs to a live frontend.", "ownership")
  svc_tree_bytes(path)
  unlink(path, recursive = TRUE)
  if (dir.exists(path)) svc_abort("Cannot remove a dead owned IPC epoch.", "filesystem")
}
svc_store_open <- function(e) {
  if (!dir.exists(e$store)) {
    if (!dir.exists(dirname(e$store))) svc_abort("Create the store parent directory first.", "filesystem")
    svc_private_dir(e$store)
  }
  e$store <- svc_private_dir(e$store)
  # All starters take this guard, including a starter that finds no lock. A
  # recovery cannot otherwise distinguish the old lock from a new live lock
  # installed between reading owner.json and renaming its containing directory.
  # A crash during ownership transfer leaves the guard for operator inspection;
  # it is never removed merely because time passed or its PID disappeared.
  guard <- file.path(e$store, ".ownership-guard")
  app_no_symlink(guard)
  if (!dir.create(guard, mode = "0700")) svc_abort("Service ownership transfer is already in progress or requires inspection.", "ownership")
  guarded <- TRUE
  on.exit(if (guarded) unlink(guard, recursive = TRUE), add = TRUE)
  svc_write(list(nonce = e$nonce, frontend = e$frontend), file.path(guard, "owner.json"))
  lock <- file.path(e$store, "store.lock")
  app_no_symlink(lock)
  if (dir.exists(lock)) {
    previous <- svc_read(file.path(lock, "owner.json"))
    if (!identical(previous$host, unname(Sys.info()[["nodename"]])) ||
        !identical(previous$service_identity, e$identity) ||
        !is.character(previous$nonce) || !grepl("^[a-f0-9]{32}$", previous$nonce))
      svc_abort("The service lock is foreign or corrupt.", "ownership")
    if (svc_alive(previous$frontend)) svc_abort("The service store already has a live owner.", "ownership")
    until <- svc_now() + e$limits$worker_death_seconds
    while (svc_alive(previous$worker) && svc_now() < until) Sys.sleep(.05)
    if (svc_alive(previous$worker)) svc_abort("The previous supervised worker is still alive.", "ownership")
    stale <- file.path(e$store, paste0(".retired-lock-", previous$nonce))
    if (file.exists(stale) || !file.rename(lock, stale)) svc_abort("Concurrent lock recovery refused.", "ownership")
    if (!dir.create(lock, mode = "0700")) svc_abort("A concurrent frontend acquired the store.", "ownership")
    unlink(stale, recursive = TRUE)
  } else if (!dir.create(lock, mode = "0700")) svc_abort("Cannot acquire the service store.", "ownership")
  e$locked <- TRUE
  svc_owner_write(e)
  unlink(guard, recursive = TRUE)
  if (dir.exists(guard)) svc_abort("Cannot finish service ownership transfer.", "filesystem")
  guarded <- FALSE
  manifest <- list(format_version = 1L, contract_version = e$prepared$contract$contract_version,
    identity = e$prepared$identity, service_identity = e$identity)
  manifest_path <- file.path(e$store, "service.json")
  if (file.exists(manifest_path)) {
    if (!identical(app_canonical(svc_read(manifest_path, 1048576L)), app_canonical(manifest)))
      svc_abort("Service identity changed; use a new store.", "stale")
  } else {
    entries <- list.files(e$store, all.files = TRUE, no.. = TRUE)
    if (any(entries != "store.lock" & !grepl("^\\.tmp-[a-f0-9]{32}$", entries)))
      svc_abort("Refusing a non-service or nonempty store.", "integrity")
    svc_write(manifest, manifest_path)
  }
  for (name in c("admissions", "results", "runtime")) svc_private_dir(file.path(e$store, name))
  epochs <- list.files(file.path(e$store, "runtime"), all.files = TRUE, no.. = TRUE, full.names = TRUE)
  for (epoch in epochs) svc_epoch_clean(e, epoch)
  for (area in c("admissions", "results")) {
    entries <- list.files(file.path(e$store, area), all.files = TRUE, no.. = TRUE)
    valid <- grepl("^(?:[a-f0-9]{2}){1,64}\\.json$|^\\.tmp-[a-f0-9]{32}$", entries, perl = TRUE)
    if (any(!valid)) svc_abort("Unknown file in service records.", "integrity")
  }
  admissions <- list.files(file.path(e$store, "admissions"), pattern = "^[a-f0-9].*\\.json$", full.names = TRUE)
  for (path in admissions) {
    record <- svc_read(path, e$limits$terminal_record_bytes)
    svc_verify_seal(record, e$store)
    app_object(record, c("format_version", "id", "input", "input_sha256", "service_identity",
      "admitted_at", "worker_epoch", "record_sha256"), "admission")
    doc <- svc_document(record$input, e$limits)
    if (!identical(record$format_version, 1L) || !identical(record$id, doc$id) ||
        !identical(basename(path), svc_record_name(doc$id)) ||
        !identical(record$service_identity, e$identity) ||
        !identical(record$input_sha256, svc_hash(doc, e$store)) ||
        !is.character(record$worker_epoch) || !grepl("^[a-f0-9]{32}$", record$worker_epoch))
      svc_abort("A service admission is corrupt or stale.", "integrity")
    assign(record$id, record, envir = e$admissions)
  }
  results <- list.files(file.path(e$store, "results"), pattern = "^[a-f0-9].*\\.json$", full.names = TRUE)
  for (path in results) {
    record <- svc_read(path, e$limits$terminal_record_bytes)
    if (!exists(record$id, envir = e$admissions, inherits = FALSE)) svc_abort("Orphan terminal record.", "integrity")
    admission <- get(record$id, envir = e$admissions)
    svc_terminal_check(e, record, admission)
    if (!identical(basename(path), svc_record_name(record$id))) svc_abort("Misnamed terminal record.", "integrity")
    assign(record$id, record, envir = e$results)
  }
  for (id in ls(e$admissions)) {
    if (!exists(id, envir = e$results, inherits = FALSE)) {
      admission <- get(id, envir = e$admissions)
      svc_publish(e, admission, list(state = "interrupted", output = NULL, raw_output = NULL,
        error = svc_error("frontend_restarted"), elapsed_ms = 0L))
    }
  }
  e$store_bytes <- svc_tree_bytes(e$store) - svc_tree_bytes(file.path(e$store, "runtime"))
}
svc_error <- function(reason, class = "service_error_interrupted") {
  list(class = class, reason = reason,
       message = switch(reason, output_limit = "Generated output exceeded the service output contract.",
         storage = "The service could not publish the result.", "The extraction did not complete."))
}
svc_terminal_check <- function(e, record, admission) {
  svc_verify_seal(record, e$store)
  required <- c("format_version", "id", "admission_sha256", "input_sha256", "service_identity",
    "worker_epoch", "state", "output", "raw_output", "error", "elapsed_ms", "record_sha256")
  overflow <- isTRUE(record$raw_truncated)
  app_object(record, c(required, if (overflow) c("raw_truncated", "raw_bytes", "raw_sha256", "raw_prefix")), "terminal record")
  app_integer(record$elapsed_ms, "elapsed milliseconds")
  app_string(record$state, "terminal state", limit = 32L)
  if (!identical(record$format_version, 1L) || !identical(record$id, admission$id) ||
      !identical(record$admission_sha256, admission$record_sha256) ||
      !identical(record$input_sha256, admission$input_sha256) ||
      !identical(record$service_identity, e$identity) ||
      !identical(record$worker_epoch, admission$worker_epoch) ||
      !record$state %in% c("success", "invalid", "error", "interrupted"))
    svc_abort("A terminal record is corrupt or stale.", "integrity")
  if (!is.null(record$raw_output)) app_string(record$raw_output, "raw output", empty = TRUE, limit = e$limits$raw_output_bytes)
  if (overflow) {
    if (!identical(record$state, "error") || !is.null(record$output) || !is.null(record$raw_output) ||
        !identical(record$error$reason, "output_limit") ||
        !is.character(record$raw_sha256) || length(record$raw_sha256) != 1L || !grepl("^[a-f0-9]{64}$", record$raw_sha256))
      svc_abort("Invalid bounded output failure.", "integrity")
    app_integer(record$raw_bytes, "raw byte count")
    if (!is.null(record$raw_prefix)) app_string(record$raw_prefix, "raw prefix", empty = TRUE, limit = e$limits$overflow_prefix_bytes)
    metadata <- record; metadata["raw_prefix"] <- list("")
    if (nchar(app_canonical(metadata), type = "bytes") > e$limits$overflow_metadata_bytes)
      svc_abort("Output failure metadata exceeds its bound.", "integrity")
  }
  if (record$state == "success") {
    app_validate_output(record$output, admission$input$text)
    if (!is.null(record$error) || !identical(app_canonical(app_parse_json(record$raw_output)), app_canonical(record$output)))
      svc_abort("Successful output disagrees with its raw result.", "integrity")
  } else {
    if (!is.null(record$output)) svc_abort("Failure contains accepted output.", "integrity")
    app_object(record$error, c("class", "reason", "message"), "terminal error")
    app_string(record$error$class, "error class", limit = 128L)
    app_string(record$error$reason, "error reason", limit = 64L)
    app_string(record$error$message, "error message", limit = 256L)
  }
  invisible(record)
}
svc_publish <- function(e, admission, value) {
  base <- list(format_version = 1L, id = admission$id, admission_sha256 = admission$record_sha256,
    input_sha256 = admission$input_sha256, service_identity = e$identity, worker_epoch = admission$worker_epoch)
  value <- value[intersect(names(value), c("state", "output", "raw_output", "error", "elapsed_ms",
    "raw_truncated", "raw_bytes", "raw_sha256", "raw_prefix"))]
  record <- svc_seal(c(base, value), e$store)
  if (nchar(app_canonical(record), type = "bytes") > e$limits$terminal_record_bytes) {
    raw <- if (is.null(value$raw_output)) "" else value$raw_output
    bytes <- charToRaw(raw)
    record <- svc_seal(c(base, list(state = "error", output = NULL, raw_output = NULL,
      error = svc_error("output_limit", "service_error_output_limit"), elapsed_ms = value$elapsed_ms,
      raw_truncated = TRUE, raw_bytes = length(bytes), raw_sha256 = svc_hash(bytes, e$store, TRUE),
      raw_prefix = svc_prefix(raw, e$limits$overflow_prefix_bytes))), e$store)
  }
  if (nchar(app_canonical(record), type = "bytes") > e$limits$terminal_record_bytes)
    svc_abort("Bounded failure record exceeds storage limits.", "filesystem")
  svc_terminal_check(e, record, admission)
  svc_write(record, file.path(e$store, "results", svc_record_name(admission$id)),
    before = function() svc_checkpoint(e, "before_terminal_rename", admission$id),
    after = function() svc_checkpoint(e, "after_terminal_rename", admission$id))
  assign(admission$id, record, envir = e$results)
  e$store_bytes <- e$store_bytes + nchar(app_canonical(record), type = "bytes")
  invisible(record)
}
svc_prefix <- function(raw, limit) {
  if (is.na(iconv(raw, from = "UTF-8", to = "UTF-8"))) return(NULL)
  bytes <- charToRaw(enc2utf8(raw))
  bytes <- head(bytes, limit)
  while (length(bytes)) {
    text <- rawToChar(bytes)
    if (!is.na(iconv(text, from = "UTF-8", to = "UTF-8"))) return(text)
    bytes <- head(bytes, -1L)
  }
  ""
}

svc_event <- function(e, event, id = NULL, reason = NULL) {
  path <- file.path(e$store, "events.jsonl")
  app_no_symlink(path)
  line <- paste0(app_canonical(list(time = svc_stamp(), event = event, id = id,
    reason = reason, epoch = if (is.null(e$worker_identity)) NULL else e$worker_identity$epoch)), "\n")
  if (!svc_diagnostic_space(e, nchar(line, type = "bytes"))) return(invisible(NULL))
  cat(line, file = path, append = TRUE)
  Sys.chmod(path, "0600")
  e$store_bytes <- e$store_bytes + nchar(line, type = "bytes")
}
svc_diagnostic_space <- function(e, bytes) {
  # Keep a terminal-publication reserve even when idle. Monitoring and fault
  # logging must not grow an otherwise quiescent store past its fixed quota.
  if (e$store_bytes + bytes + e$limits$store_admission_floor_bytes > e$limits$store_limit_bytes) {
    if (!e$state %in% c("stopping", "stopped")) svc_fault(e, "store_capacity")
    return(FALSE)
  }
  TRUE
}
svc_status_value <- function(e) list(format_version = 1L, service_identity = e$identity,
  nonce = e$nonce, state = e$state, frontend = e$frontend, worker = e$worker_identity,
  fault_reason = e$fault, fault_class = e$fault_class,
  supervisor = e$supervisor, port = e$port, active_id = if (is.null(e$active)) NULL else e$active$id,
  dispatch_count = e$dispatch_count, accepted = length(ls(e$admissions)),
  terminal = length(ls(e$results)), restart_attempts = length(e$restart_failures), rss_bytes = e$rss, peak_rss_bytes = e$peak_rss,
  updated_at = svc_stamp())
svc_status_write <- function(e, force = FALSE) {
  if (force || svc_now() - e$status_at >= 1) {
    svc_write(svc_status_value(e), file.path(e$store, "status.json"), replace = TRUE)
    e$status_at <- svc_now()
  }
}
svc_fault <- function(e, reason, condition = NULL) {
  e$state <- "faulted"
  e$fault <- reason
  if (!is.null(condition)) {
    classes <- class(condition)
    classes <- classes[grepl("^(funding_error_|service_error_)[A-Za-z0-9_]{1,80}$", classes)]
    e$fault_class <- if (length(classes)) classes[[1L]] else "service_error_runtime"
  }
}
svc_retire <- function(e, reason) {
  if (!is.null(e$retiring)) return(invisible(NULL))
  e$retiring <- svc_now()
  if (!e$state %in% c("stopping", "faulted")) e$state <- "restarting"
  if (!is.null(e$active)) {
    active <- e$active
    if (!e$storage_fault) tryCatch({
      svc_publish(e, active, list(state = "interrupted", output = NULL, raw_output = NULL,
        error = svc_error(reason), elapsed_ms = as.integer(round(1000 * (svc_now() - e$operation_at)))))
      e$active <- NULL
    }, error = function(err) { e$storage_fault <- TRUE; svc_fault(e, "storage", err) })
  }
  if (e$operation == "initialization") {
    e$restart_failures <- c(e$restart_failures[e$restart_failures >= svc_now() - e$limits$restart_window_seconds], svc_now())
    if (length(e$restart_failures) >= e$limits$restart_attempts) svc_fault(e, "restart_limit")
  }
  if (!is.null(e$worker) && !isTRUE(e$test$unreapable)) tryCatch(e$worker$kill(), error = function(err) svc_fault(e, "kill_failed"))
  invisible(NULL)
}
svc_start_worker <- function(e) {
  if (!is.null(e$worker)) svc_abort("A worker must be dead before replacement.", "ownership")
  epoch <- app_nonce()
  ipc <- svc_private_dir(file.path(e$store, "runtime", epoch))
  e$worker_identity <- NULL
  e$operation <- "initialization"; e$operation_at <- svc_now(); e$diagnostic_bytes <- 0
  e$epoch <- epoch; e$retiring <- NULL
  e$state <- if (e$ever_ready) "restarting" else "starting"
  # callr serializes in the frontend too, so redirect its private temporary
  # directory before constructing the child and before every subsequent call.
  Sys.setenv(CALLR_TMPDIR = ipc)
  environment <- Sys.getenv()
  strip <- names(environment)[grepl("^(OTEL_|R_PROFILE|R_ENVIRON|R_LIBS|CALLR_)", names(environment))]
  previous <- environment[strip]
  if (length(strip)) Sys.unsetenv(strip)
  on.exit({ if (length(previous)) do.call(Sys.setenv, as.list(previous)); Sys.setenv(CALLR_TMPDIR = ipc) }, add = TRUE)
  Sys.setenv(CALLR_TMPDIR = ipc)
  svc_write(list(epoch = epoch, nonce = e$nonce, frontend = e$frontend, worker = NULL,
    service_identity = e$identity), file.path(ipc, "owner.json"))
  child_env <- c(CALLR_TMPDIR = ipc, TMPDIR = ipc, TMP = ipc, TEMP = ipc,
    OTEL_SDK_DISABLED = "true")
  options <- callr::r_session_options(libpath = c(e$prepared$library, .Library),
    system_profile = FALSE, user_profile = FALSE, env = child_env,
    stdout = "|", stderr = "|", extra = list(supervise = TRUE))
  e$worker <- callr::r_session$new(options = options, wait = FALSE)
  if (!e$worker$is_supervised()) svc_abort("Worker supervision is required.", "ownership")
  e$worker_identity <- c(svc_process(e$worker$get_pid()), list(epoch = epoch, ipc_dir = ipc))
  svc_write(list(epoch = epoch, nonce = e$nonce, frontend = e$frontend, worker = e$worker_identity,
    service_identity = e$identity), file.path(ipc, "owner.json"), replace = TRUE)
  svc_owner_write(e)
  e$initializing <- FALSE
  svc_status_write(e, TRUE)
}
svc_initialize_call <- function(e) {
  e$initializing <- TRUE
  Sys.setenv(CALLR_TMPDIR = e$worker_identity$ipc_dir)
  e$worker$call(function(module, prepared, identity, test_config) {
    source(file.path(module, "common.R"), local = .GlobalEnv)
    source(file.path(module, "worker.R"), local = .GlobalEnv)
    svc_worker_init(prepared, identity, test_config)
  }, args = list(module = svc_module, prepared = e$prepared,
                 identity = e$identity, test_config = e$test), package = FALSE)
}
svc_worker_event <- function(e, event, source_epoch = e$epoch) {
  if (is.null(event)) return(invisible(NULL))
  if (!identical(source_epoch, e$epoch) || !is.null(e$retiring)) return(invisible(NULL))
  if (event$code %in% c(500L, 501L, 502L)) { svc_retire(e, "worker_exit"); return(invisible(NULL)) }
  if (event$code == 201L) { svc_initialize_call(e); return(invisible(NULL)) }
  # Worker wrappers muffle ordinary conditions and return a bounded error list.
  # Any raw callr condition is a protocol failure, not an arbitrary object to log.
  if (event$code != 200L) { svc_retire(e, "worker_protocol"); return(invisible(NULL)) }
  if (!is.null(event$error)) { svc_retire(e, "worker_protocol"); return(invisible(NULL)) }
  value <- event$result
  if (e$operation == "initialization") {
    if (!is.list(value) || !isTRUE(value$ready) || !identical(value$identity, e$identity) ||
        !identical(value$pid, e$worker_identity$pid) ||
        !startsWith(value$tempdir, paste0(e$worker_identity$ipc_dir, "/")) ||
        !identical(value$callr_tmpdir, e$worker_identity$ipc_dir)) {
      svc_retire(e, "initialization_failed"); return(invisible(NULL))
    }
    e$operation <- "idle"
    if (!e$state %in% c("stopping", "faulted")) e$state <- "ready"
    e$ever_ready <- TRUE
    svc_event(e, "ready"); svc_status_write(e, TRUE)
    cat("READY ", e$port, "\n", sep = ""); flush.console()
  } else if (e$operation == "shutdown") {
    if (!is.null(e$worker)) e$worker$kill()
    e$retiring <- svc_now()
  } else if (e$operation == "request") {
    active <- e$active
    if (is.null(active) || !is.list(value) ||
        !identical(value$id, active$id) || !identical(value$input_sha256, active$input_sha256) ||
        !identical(value$epoch, e$epoch) ||
        !value$state %in% c("success", "invalid", "error")) {
      svc_retire(e, "worker_protocol"); return(invisible(NULL))
    }
    svc_publish(e, active, value)
    svc_event(e, "terminal", active$id, value$state)
    e$active <- NULL; e$operation <- "idle"
    if (!e$state %in% c("stopping", "faulted")) e$state <- "ready"
    svc_status_write(e, TRUE)
  }
  invisible(NULL)
}
svc_rss <- function(e) {
  children <- ps::ps_children(ps::ps_handle(e$frontend$pid), recursive = TRUE)
  handles <- c(list(ps::ps_handle(e$frontend$pid)), children)
  values <- vapply(handles, function(handle) tryCatch(as.double(ps::ps_memory_info(handle)[["rss"]]), error = function(err) {
    # A child that exited between enumeration and sampling contributes no live
    # RSS. Permission/inspection errors for a live process must fail closed.
    if (svc_confirm_ended(handle)) return(0)
    svc_abort("Cannot sample a live owned process.", "ownership")
  }), numeric(1))
  e$supervisor <- NULL
  for (handle in children) {
    if (tryCatch(grepl("supervisor", ps::ps_name(handle)), error = function(err) FALSE))
      e$supervisor <- list(pid = ps::ps_pid(handle), birth = svc_birth(handle))
  }
  e$rss <- sum(values); e$peak_rss <- max(e$peak_rss, e$rss)
  path <- file.path(e$store, "rss.csv")
  header <- if (!file.exists(path)) "elapsed_ms,rss_bytes,worker_pid,epoch,dispatch_count\n" else ""
  line <- paste(as.integer(round((svc_now() - e$started) * 1000)), sprintf("%.0f", e$rss),
    if (is.null(e$worker_identity)) "" else e$worker_identity$pid,
    if (is.null(e$worker_identity)) "" else e$worker_identity$epoch, e$dispatch_count, sep = ",")
  if (svc_diagnostic_space(e, nchar(header, type = "bytes") + nchar(line, type = "bytes") + 1)) {
    cat(header, line, "\n", file = path, append = TRUE, sep = "")
    Sys.chmod(path, "0600")
    e$store_bytes <- e$store_bytes + nchar(header, type = "bytes") + nchar(line, type = "bytes") + 1
  }
  if (e$rss > e$rss_budget) { svc_fault(e, "memory_limit"); svc_retire(e, "memory_limit") }
}
svc_begin_stop <- function(e) {
  if (e$state == "stopping") return(invisible(NULL))
  e$state <- "stopping"; e$stop_at <- svc_now()
  svc_status_write(e, TRUE)
}
svc_tick <- function(e) {
  if (e$finished) return(invisible(NULL))
  tryCatch({
    late <- e$test$late_completion_file
    if (!is.null(late) && file.exists(late)) {
      value <- svc_read(late)
      if (is.null(value$epoch)) value$epoch <- value$worker_epoch
      unlink(late)
      svc_worker_event(e, list(code = 200L, result = value, error = NULL), value$epoch)
    }
    stop_path <- file.path(e$store, "stop.json")
    if (file.exists(stop_path)) {
      request <- svc_read(stop_path)
      if (!identical(request$nonce, e$nonce) || !identical(app_canonical(request$frontend), app_canonical(e$frontend)))
        svc_abort("Stop request does not match the live owner.", "ownership")
      svc_begin_stop(e)
    }
    if (!is.null(e$worker)) {
      # Never read a result from a retired epoch, even if completion won a race
      # with kill. Epoch validity is checked again before terminal publication.
      if (is.null(e$retiring)) {
        io <- e$worker$poll_io(0)
        remaining <- e$limits$diagnostic_drain_bytes_per_tick
        for (stream in c("output", "error")) {
          if (remaining > 0 && identical(unname(io[[stream]]), "ready")) {
            bytes <- if (stream == "output") e$worker$read_output_bytes(remaining) else e$worker$read_error_bytes(remaining)
            count <- length(bytes); remaining <- remaining - count
            e$diagnostic_bytes <- e$diagnostic_bytes + count
          }
        }
        if (e$diagnostic_bytes > e$limits$worker_diagnostic_bytes) svc_retire(e, "diagnostic_limit")
        if (is.null(e$retiring) && svc_tree_bytes(e$worker_identity$ipc_dir, live_ipc = TRUE) > e$limits$epoch_ipc_bytes)
          svc_retire(e, "ipc_limit")
        if (is.null(e$retiring) && e$operation %in% c("initialization", "request")) {
          deadline <- if (e$operation == "initialization") e$limits$worker_start_seconds else e$limits$request_deadline_seconds
          if (svc_now() - e$operation_at >= deadline) svc_retire(e, "deadline")
        }
        if (is.null(e$retiring) && !e$worker$is_alive()) svc_retire(e, "worker_exit")
        if (is.null(e$retiring) && identical(e$worker$poll_process(0), "ready")) svc_worker_event(e, e$worker$read())
      }
      if (!is.null(e$retiring)) {
        if (!e$worker$is_alive()) {
          path <- e$worker_identity$ipc_dir
          e$worker$cleanup()
          svc_epoch_clean(e, path)
          e$worker <- NULL; e$worker_identity <- NULL; e$retiring <- NULL; e$operation <- "idle"
          svc_owner_write(e)
          if (!e$state %in% c("faulted", "stopping")) svc_start_worker(e)
        } else if (svc_now() - e$retiring >= e$limits$worker_death_seconds) svc_fault(e, "unconfirmed_death")
      }
    }
    if (e$state == "stopping") {
      if (is.null(e$worker)) { e$finished <- TRUE; e$state <- "stopped" }
      else if (!is.null(e$active) && svc_now() - e$stop_at >= e$limits$graceful_drain_seconds) svc_retire(e, "stopped")
      else if (is.null(e$active) && is.null(e$retiring) && e$operation != "shutdown") {
        if (e$operation == "idle") {
          e$operation <- "shutdown"
          e$worker$call(function() svc_worker_close(), package = FALSE)
        } else svc_retire(e, "stopped")
      }
      if (svc_now() - e$stop_at >= e$limits$graceful_drain_seconds && is.null(e$retiring) && !is.null(e$worker)) svc_retire(e, "stopped")
    }
    svc_rss(e)
    svc_status_write(e)
  }, error = function(err) {
    e$storage_fault <- inherits(err, "funding_error_filesystem") || e$storage_fault
    svc_fault(e, if (e$storage_fault) "storage" else if (inherits(err, "funding_error_ipc")) "ipc_accounting" else "runtime", err)
    try(svc_retire(e, if (e$storage_fault) "storage" else "worker_protocol"), silent = TRUE)
  })
  if (!e$finished) later::later(function() svc_tick(e), e$limits$control_poll_ms / 1000)
  invisible(NULL)
}

svc_reply <- function(res, status, value, retry = FALSE) {
  res$status <- as.integer(status)
  res$setHeader("Cache-Control", "no-store")
  res$setHeader("X-Content-Type-Options", "nosniff")
  if (retry) res$setHeader("Retry-After", "1")
  value
}
svc_ticket <- function(e, id, res) {
  if (exists(id, envir = e$results, inherits = FALSE))
    return(svc_reply(res, 200L, get(id, envir = e$results)))
  svc_reply(res, 202L, list(id = id, state = if (!is.null(e$active) && identical(e$active$id, id)) "running" else "accepted",
    status_url = paste0("/v1/extractions/", id)))
}
svc_admit <- function(e, req, res) {
  parsed <- tryCatch(app_parse_json(req$service_body), error = function(err) NULL)
  if (is.null(parsed)) return(svc_reply(res, 400L, list(error = "Malformed JSON request.")))
  if (is.list(parsed)) {
    for (field in c("id", "target", "text")) {
      value <- parsed[[field]]
      limit <- e$limits[[switch(field, id = "request_id_bytes", target = "target_bytes", text = "document_text_bytes")]]
      if (is.character(value) && length(value) == 1L && !is.na(value) && nchar(value, type = "bytes") > limit)
        return(svc_reply(res, 413L, list(error = "A request field exceeds its byte limit.")))
    }
  }
  doc <- tryCatch(svc_document(parsed, e$limits), error = function(err) NULL)
  if (is.null(doc)) return(svc_reply(res, 422L, list(error = "Invalid request fields.")))
  digest <- svc_hash(doc, e$store)
  if (exists(doc$id, envir = e$admissions, inherits = FALSE)) {
    admission <- get(doc$id, envir = e$admissions)
    if (!identical(admission$input_sha256, digest)) return(svc_reply(res, 409L, list(error = "The request ID already has different input.")))
    return(svc_ticket(e, doc$id, res))
  }
  if (e$state == "busy") return(svc_reply(res, 429L, list(error = "The worker is busy."), TRUE))
  if (e$state != "ready" || !is.null(e$active)) return(svc_reply(res, 503L, list(error = "The worker is unavailable."), TRUE))
  if (length(ls(e$admissions)) >= e$limits$accepted_records_per_store ||
      e$store_bytes + e$limits$store_admission_floor_bytes > e$limits$store_limit_bytes) {
    svc_fault(e, "store_capacity")
    return(svc_reply(res, 503L, list(error = "The service store is full."), TRUE))
  }
  e$state <- "busy"; e$operation_at <- svc_now()
  admission <- svc_seal(list(format_version = 1L, id = doc$id, input = doc, input_sha256 = digest,
    service_identity = e$identity, admitted_at = svc_stamp(), worker_epoch = e$epoch), e$store)
  published <- FALSE
  tryCatch({
    svc_write(admission, file.path(e$store, "admissions", svc_record_name(doc$id)),
      before = function() svc_checkpoint(e, "before_admission_rename", doc$id),
      after = function() svc_checkpoint(e, "after_admission_rename", doc$id))
    published <- TRUE
    assign(doc$id, admission, envir = e$admissions)
    e$active <- admission; e$operation <- "request"; e$diagnostic_bytes <- 0
    e$store_bytes <- e$store_bytes + nchar(app_canonical(admission), type = "bytes")
    Sys.setenv(CALLR_TMPDIR = e$worker_identity$ipc_dir)
    e$worker$call(function(doc, digest, epoch) svc_worker_extract(doc, digest, epoch),
      args = list(doc = doc, digest = digest, epoch = e$epoch), package = FALSE)
    e$dispatch_count <- e$dispatch_count + 1L
    svc_event(e, "dispatched", doc$id)
    svc_status_write(e, TRUE)
    svc_ticket(e, doc$id, res)
  }, error = function(err) {
    # A receipt published just before failure remains recoverable even if the
    # local after-rename hook failed. Never report a successful admission here.
    receipt_path <- file.path(e$store, "admissions", svc_record_name(doc$id))
    if (!published && file.exists(receipt_path)) {
      actual <- tryCatch(svc_read(receipt_path), error = function(err) NULL)
      if (!is.null(actual) && identical(app_canonical(actual), app_canonical(admission))) {
        assign(doc$id, admission, envir = e$admissions); e$active <- admission
      }
    }
    e$storage_fault <- inherits(err, "funding_error_filesystem")
    svc_fault(e, if (e$storage_fault) "storage" else "dispatch")
    try(svc_retire(e, if (e$storage_fault) "storage" else "dispatch"), silent = TRUE)
    svc_reply(res, 503L, list(error = "The request could not be dispatched."), TRUE)
  })
}
svc_http_error <- function(status, message) list(status = as.integer(status),
  headers = list("Content-Type" = "application/json", "Cache-Control" = "no-store", "Connection" = "close"),
  body = app_canonical(list(error = message)))
svc_headers <- function(e, req) {
  headers <- req$HEADERS
  names(headers) <- tolower(names(headers))
  values <- function(name) unname(headers[names(headers) == name])
  host <- values("host")
  if (length(host) != 1L || !host %in% c("127.0.0.1", "localhost", paste0("127.0.0.1:", e$port), paste0("localhost:", e$port)) ||
      length(values("origin"))) return(svc_http_error(403L, "Forbidden Host or Origin."))
  if (length(values("transfer-encoding"))) return(svc_http_error(400L, "Transfer-Encoding is not supported."))
  if (length(values("content-encoding"))) return(svc_http_error(415L, "Content-Encoding is not supported."))
  if (length(values("upgrade"))) return(svc_http_error(400L, "Protocol upgrades are not supported."))
  cl <- values("content-length")
  if (length(cl) > 1L || (length(cl) && (!grepl("^[0-9]+$", cl) || nchar(cl) > 10L)))
    return(svc_http_error(400L, "Invalid Content-Length."))
  count <- if (length(cl)) as.numeric(cl) else 0
  if (count > e$limits$request_body_bytes) return(svc_http_error(413L, "Request body exceeds its byte limit."))
  if (req$REQUEST_METHOD == "POST") {
    if (!length(cl)) return(svc_http_error(411L, "Content-Length is required."))
    media <- values("content-type")
    if (length(media) != 1L || !grepl("^application/json(?:[ ]*;[ ]*charset=[\"]?utf-8[\"]?)?$", tolower(media), perl = TRUE))
      return(svc_http_error(415L, "Use application/json with UTF-8."))
  } else if (count != 0) return(svc_http_error(400L, "This route does not accept a body."))
  NULL
}
svc_router <- function(e) {
  router <- plumber::Plumber$new(filters = list())
  router$setDocs(FALSE); router$setDebug(FALSE); router$setParsers("none")
  router$setSerializer(plumber::serializer_json(auto_unbox = TRUE, null = "null", digits = NA))
  router$setErrorHandler(function(req, res, err) svc_reply(res, 500L, list(error = "The service could not complete this request.")))
  router$handle("GET", "/health/live", function(res) svc_reply(res, 200L,
    list(version = e$prepared$contract$contract_version, state = e$state)))
  router$handle("GET", "/health/ready", function(res) svc_reply(res, if (e$state == "ready") 200L else 503L,
    list(version = e$prepared$contract$contract_version, state = e$state), e$state != "ready"))
  router$handle("POST", "/v1/extractions", function(req, res) svc_admit(e, req, res))
  router$handle("GET", "/v1/extractions/<id>", function(id, res) {
    if (!grepl("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", id) || !exists(id, envir = e$admissions, inherits = FALSE))
      return(svc_reply(res, 404L, list(error = "Unknown request ID.")))
    svc_ticket(e, id, res)
  })
  router
}

svc_run <- function(prepared, store, port = 8765L, test_config = NULL) {
  port <- app_integer(port, "port", 1025L, 65535L)
  previous_umask <- Sys.umask("0077")
  previous_tmp <- Sys.getenv("CALLR_TMPDIR", unset = NA_character_)
  on.exit({ Sys.umask(previous_umask); if (is.na(previous_tmp)) Sys.unsetenv("CALLR_TMPDIR") else Sys.setenv(CALLR_TMPDIR = previous_tmp) }, add = TRUE)
  e <- new.env(parent = emptyenv())
  e$prepared <- prepared; e$store <- path.expand(store); e$port <- port; e$test <- test_config
  e$limits <- prepared$contract$limits
  if (!is.null(test_config$limits)) {
    if (!all(names(test_config$limits) %in% names(e$limits))) svc_abort("Unknown private fixture limit.", "fixture")
    for (name in names(test_config$limits)) {
      value <- test_config$limits[[name]]
      if (!is.numeric(value) || length(value) != 1L || !is.finite(value) || value <= 0) svc_abort("Invalid private fixture limit.", "fixture")
      e$limits[[name]] <- value
    }
  }
  e$nonce <- app_nonce(); e$frontend <- svc_process(); e$worker <- NULL; e$worker_identity <- NULL
  e$supervisor <- NULL; e$epoch <- NULL; e$state <- "starting"; e$active <- NULL; e$operation <- "idle"
  e$retiring <- NULL; e$initializing <- FALSE; e$ever_ready <- FALSE; e$finished <- FALSE; e$locked <- FALSE
  e$storage_fault <- FALSE; e$fault <- NULL; e$fault_class <- NULL; e$restart_failures <- numeric(); e$dispatch_count <- 0L
  e$admissions <- new.env(parent = emptyenv()); e$results <- new.env(parent = emptyenv())
  e$store_bytes <- 0; e$rss <- 0; e$peak_rss <- 0; e$status_at <- -Inf; e$started <- svc_now()
  e$stop_at <- NULL; e$operation_at <- e$started; e$diagnostic_bytes <- 0; e$server <- NULL
  # Identity metadata contains no document content; record hashes below always
  # use the private store, not R's inherited shared temporary directory.
  e$identity <- app_digest(prepared$identity)
  spark <- grepl("spark", if (is.null(prepared$manifest$model$alias)) "" else prepared$manifest$model$alias, ignore.case = TRUE)
  e$rss_budget <- prepared$contract$profiles[[if (spark) "mac_spark" else if (identical(prepared$config$backend, "metal")) "mac_qwen" else "linux_qwen"]]$rss_budget_bytes
  on.exit({
    if (!is.null(e$server)) try(httpuv::stopServer(e$server), silent = TRUE)
    if (!is.null(e$worker)) {
      try(e$worker$kill(), silent = TRUE)
      until <- svc_now() + e$limits$worker_death_seconds
      while (e$worker$is_alive() && svc_now() < until) Sys.sleep(.02)
      if (!e$worker$is_alive()) {
        try(e$worker$cleanup(), silent = TRUE)
        if (!is.null(e$worker_identity)) try(svc_epoch_clean(e, e$worker_identity$ipc_dir), silent = TRUE)
        e$worker <- NULL; e$worker_identity <- NULL
      }
    }
    if (e$locked && is.null(e$worker)) {
      e$state <- "stopped"
      try(svc_status_write(e, TRUE), silent = TRUE)
      lock <- file.path(e$store, "store.lock")
      current <- tryCatch(svc_read(file.path(lock, "owner.json")), error = function(err) NULL)
      if (!is.null(current) && identical(current$nonce, e$nonce)) unlink(lock, recursive = TRUE)
      try(unlink(file.path(e$store, "stop.json")), silent = TRUE)
    }
  }, add = TRUE)
  svc_store_open(e)
  # An old stop record is meaningful only for the previous nonce and is removed
  # under exclusive verified ownership before the new frontend serves requests.
  if (file.exists(file.path(e$store, "stop.json"))) unlink(file.path(e$store, "stop.json"))
  router <- svc_router(e)
  e$server <- httpuv::startServer("127.0.0.1", port, list(
    onHeaders = function(req) svc_headers(e, req),
    call = function(req) {
      early <- svc_headers(e, req)
      if (!is.null(early)) return(early)
      if (req$REQUEST_METHOD == "POST") {
        bytes <- req$rook.input$read(e$limits$request_body_bytes + 1L)
        if (is.character(bytes)) bytes <- charToRaw(bytes)
        if (length(bytes) > e$limits$request_body_bytes) return(svc_http_error(413L, "Request body exceeds its byte limit."))
        if (any(bytes == as.raw(0))) return(svc_http_error(400L, "Malformed JSON request."))
        body <- rawToChar(bytes)
        if (is.na(iconv(body, from = "UTF-8", to = "UTF-8"))) return(svc_http_error(400L, "Malformed UTF-8 request."))
        req$service_body <- body
      }
      router$call(req)
    }))
  tryCatch(svc_start_worker(e), error = function(err) { svc_fault(e, "startup"); svc_retire(e, "initialization_failed") })
  later::later(function() svc_tick(e), 0)
  while (!e$finished) tryCatch(httpuv::service(timeoutMs = e$limits$control_poll_ms),
    interrupt = function(condition) svc_begin_stop(e))
  invisible(svc_status_value(e))
}

svc_status <- function(store) {
  store <- normalizePath(store, mustWork = TRUE)
  app_no_symlink(store)
  value <- svc_read(file.path(store, "status.json"))
  value$frontend_alive <- svc_alive(value$frontend)
  value$worker_alive <- svc_alive(value$worker)
  value
}
svc_stop <- function(store) {
  store <- normalizePath(store, mustWork = TRUE)
  app_no_symlink(store)
  lock <- file.path(store, "store.lock", "owner.json")
  if (!file.exists(lock)) return(invisible(svc_status(store)))
  owner <- svc_read(lock)
  if (!identical(owner$host, unname(Sys.info()[["nodename"]]))) svc_abort("Refusing to stop a foreign host's service.", "ownership")
  if (!svc_alive(owner$frontend)) {
    if (svc_alive(owner$worker)) svc_abort("The frontend is dead but its worker is still live.", "ownership")
    return(invisible(svc_status(store)))
  }
  previous <- Sys.umask("0077"); on.exit(Sys.umask(previous), add = TRUE)
  svc_write(list(nonce = owner$nonce, frontend = owner$frontend), file.path(store, "stop.json"), replace = TRUE)
  until <- svc_now() + 15
  while ((svc_alive(owner$frontend) || svc_alive(owner$worker)) && svc_now() < until) Sys.sleep(.05)
  if (svc_alive(owner$frontend) || svc_alive(owner$worker)) svc_abort("Service stop did not complete within 15 seconds.", "stop")
  invisible(svc_status(store))
}
