#!/usr/bin/env Rscript
# Actual ps creation-time handles: one-shot inspection or 100-ms owned-tree RSS.
args <- commandArgs(TRUE)
.libPaths(c(normalizePath(args[1], mustWork = TRUE), .Library), include.site = FALSE)
Sys.umask('0077')
inspect <- function(pid, expected_birth = NULL, read_details = NULL) {
  tryCatch({
    handle <- ps::ps_handle(as.integer(pid))
    birth <- as.numeric(ps::ps_create_time(handle))
    if (!is.null(expected_birth) && !identical(birth, expected_birth)) return(list(pid = as.integer(pid), alive = FALSE))
    if (ps::ps_status(handle) %in% c('zombie', 'dead')) return(list(pid = as.integer(pid), alive = FALSE))
    if (!is.null(read_details)) return(read_details(handle))
    list(pid = ps::ps_pid(handle), birth = birth,
         ppid = ps::ps_ppid(handle), rss = unname(ps::ps_memory_info(handle)[['rss']]),
         alive = ps::ps_is_running(handle))
  }, error = function(e) {
    ended <- function() tryCatch({
      if (!as.integer(pid) %in% ps::ps_pids()) return(TRUE)
      current <- ps::ps_handle(as.integer(pid))
      (!is.null(expected_birth) && !identical(as.numeric(ps::ps_create_time(current)), expected_birth)) ||
        ps::ps_status(current) %in% c('zombie', 'dead')
    }, error = function(e) FALSE)
    gone <- ended()
    # Darwin may deny task inspection between exit and zombie publication.
    # Only a confirmed end/reuse may become a missing sample; live denial fails.
    for (attempt in 1:2) {
      if (gone) break
      Sys.sleep(.05)
      gone <- ended()
    }
    if (!gone) stop('Cannot inspect a live process: ', conditionMessage(e))
    list(pid = as.integer(pid), alive = FALSE)
  })
}
child_tree <- function(parent, read_handle = ps::ps_handle, read_map = NULL) {
  # ps 1.9.3's Linux ps_handle can raise untyped ENOENT after its PID map
  # snapshot. Adapt only the selected child's handle read, never the namespace.
  children <- ps::ps_children
  scope <- new.env(parent = environment(children))
  missing <- FALSE
  scope$ps_handle <- function(pid) tryCatch(read_handle(pid), error = function(e) {
    # A successful retry is not enough: preserve the original error unless this
    # specific child is independently confirmed absent or a zombie/dead process.
    inspect(pid, read_details = function(h) stop(e))
    missing <<- TRUE
    stop(structure(list(message = 'Confirmed child termination during discovery', call = NULL),
                   class = c('no_such_process', 'error', 'condition')))
  })
  if (!is.null(read_map)) scope$ps_ppid_map <- read_map
  environment(children) <- scope
  handles <- children(parent, recursive = TRUE)
  list(children = handles, missing = missing)
}
discover <- function(parent, read_children = child_tree) {
  # ps_children ends by re-reading the parent, which can exit during discovery.
  # Verify that original identity ended; a live or unknown denial still fails.
  inspect(ps::ps_pid(parent), as.numeric(ps::ps_create_time(parent)), function(h) {
    tree <- read_children(h)
    list(alive = TRUE, children = tree$children, missing = tree$missing)
  })
}
sample_line <- function(index, elapsed, rss, identities) {
  sprintf('%d,%.15g,%.0f,"%s"', index, elapsed, rss, gsub('"', '""', identities, fixed = TRUE))
}
record_sample_error <- function(path, message) {
  # Keep the original failure when later teardown also loses a process.
  if (!file.exists(path)) writeLines(message, path)
}
if (args[2] == 'self-test') {
  pid <- Sys.getpid()
  birth <- as.numeric(ps::ps_create_time(ps::ps_handle(pid)))
  denied <- tryCatch(inspect(pid, birth, function(h) stop('injected live denial')), error = identity)
  stopifnot(inherits(denied, 'error'), grepl('Cannot inspect a live process', conditionMessage(denied)))
  reused <- inspect(pid, birth - 1, function(h) stop('A reused PID must never be inspected'))
  stopifnot(identical(reused$alive, FALSE))
  parent <- ps::ps_handle(pid)
  denied_tree <- tryCatch(discover(parent, function(h) stop('injected live tree denial')), error = identity)
  stopifnot(inherits(denied_tree, 'error'), grepl('Cannot inspect a live process', conditionMessage(denied_tree)))
  reused_tree <- discover(ps::ps_handle(pid, time = as.POSIXct(birth - 1, origin = '1970-01-01')),
                          function(h) stop('A reused tree must never be inspected'))
  stopifnot(identical(reused_tree$alive, FALSE))
  child <- processx::process$new('/bin/sleep', '60')
  tryCatch({
    child_pid <- child$get_pid()
    denied_child <- tryCatch(child_tree(parent, read_handle = function(pid) {
      if (pid == child_pid) stop('injected live child denial')
      ps::ps_handle(pid)
    }), error = identity)
    stopifnot(inherits(denied_child, 'error'), grepl('Cannot inspect a live process', conditionMessage(denied_child)))
    original_map <- get('ps_ppid_map', envir = environment(ps::ps_children))
    map <- original_map()
    stopifnot(any(map$pid == child_pid & map$ppid == Sys.getpid()))
    child$kill(); child$wait(timeout = 2000)
    unadapted <- ps::ps_children
    environment(unadapted) <- list2env(list(ps_ppid_map = function() map),
                                      parent = environment(unadapted))
    before <- tryCatch(unadapted(parent, recursive = TRUE), error = identity)
    if (Sys.info()[['sysname']] == 'Linux') {
      stopifnot(inherits(before, 'os_error'), identical(before$errno, 2L))
      cat('PASS: unadapted Linux ps 1.9.3 reproduces the child-discovery os_error\n')
    }
    missing_child <- child_tree(parent, read_map = function() map)
    stopifnot(isTRUE(missing_child$missing), !child$is_alive(),
              !child_pid %in% vapply(missing_child$children, ps::ps_pid, integer(1)),
              ps::ps_is_running(parent))
  }, finally = if (child$is_alive()) child$kill())
  child <- processx::process$new(Sys.which('Rscript'), c('--vanilla', '-e', 'Sys.sleep(60)'))
  tryCatch({
    child_pid <- child$get_pid()
    child_birth <- as.numeric(ps::ps_create_time(ps::ps_handle(child_pid)))
    ended <- inspect(child_pid, child_birth, function(h) {
      child$kill(); child$wait(timeout = 2000)
      stop('injected error concurrent with confirmed process death')
    })
    stopifnot(identical(ended$alive, FALSE), !child$is_alive())
  }, finally = if (child$is_alive()) child$kill())
  child <- processx::process$new(Sys.which('Rscript'), c('--vanilla', '-e', 'Sys.sleep(60)'))
  tryCatch({
    child_handle <- ps::ps_handle(child$get_pid())
    ended_tree <- discover(child_handle, function(h) {
      child$kill(); child$wait(timeout = 2000)
      stop('injected tree error concurrent with confirmed parent death')
    })
    stopifnot(identical(ended_tree$alive, FALSE), !child$is_alive())
  }, finally = if (child$is_alive()) child$kill())
  identities <- '[{"pid":123,"birth":123.456,"note":"quote\\\"comma,","alive":true}]'
  expected <- data.frame(sample = 17L, elapsed_seconds = 15559.123000001,
                         rss_bytes = 1077256192, identities = identities)
  legacy <- character()
  old_connection <- textConnection('legacy', 'w', local = TRUE)
  write.table(expected, old_connection, sep = ',', row.names = FALSE, qmethod = 'double')
  close(old_connection)
  compact <- c(legacy[1], sample_line(expected$sample, expected$elapsed_seconds,
                                     expected$rss_bytes, expected$identities))
  stopifnot(identical(read.csv(text = paste(legacy, collapse = '\n')),
                      read.csv(text = paste(compact, collapse = '\n'))))
  error_path <- tempfile('relm-first-sampler-error-')
  tryCatch({
    record_sample_error(error_path, 'original sampling gap')
    record_sample_error(error_path, 'later teardown disappearance')
    stopifnot(identical(readLines(error_path), 'original sampling gap'))
  }, finally = unlink(error_path))
  cat('PASS: live inspection/tree/child denials fail, reused PIDs are excluded, actual parent/child death is missing, CSV encoding matches, first error is retained; no service gate executed\n')
  quit(save = 'no')
}
if (args[2] == 'inspect') {
  cat(jsonlite::toJSON(lapply(args[-(1:2)], inspect), auto_unbox = TRUE, null = 'null', digits = 16))
  quit(save = 'no')
}
stopifnot(args[2] == 'sample', length(args) == 6L)
parent <- ps::ps_handle(as.integer(args[3]))
known <- list(parent)
connection <- file(args[4], open = 'wt')
on.exit(close(connection))
writeLines('sample,elapsed_seconds,rss_bytes,identities', connection)
diagnostic_path <- Sys.getenv('RELM_SAMPLER_DIAGNOSTICS', '')
diagnostics <- nzchar(diagnostic_path)
if (diagnostics) {
  if (!startsWith(diagnostic_path, '/')) stop('RELM_SAMPLER_DIAGNOSTICS must be an absolute CSV path')
  if (normalizePath(diagnostic_path, mustWork = FALSE) %in% normalizePath(args[4:6], mustWork = FALSE)) {
    stop('Diagnostic CSV must be separate from sampler evidence and control files')
  }
  diagnostic_connection <- file(diagnostic_path, open = 'wt')
  diagnostic_columns <- c('sample', 'tick_start_seconds', 'discovery_end_seconds',
                          'rss_end_seconds', 'write_end_seconds', 'discovery_cpu_seconds',
                          'rss_cpu_seconds', 'write_cpu_seconds', 'iteration_cpu_seconds',
                          'interval_cpu_seconds', 'gc_user_seconds', 'gc_system_seconds',
                          'gc_elapsed_seconds', 'wake_lateness_seconds', 'sample_gap_seconds',
                          'discovered_children', 'known_processes', 'sampled_processes')
  writeLines(paste(diagnostic_columns, collapse = ','), diagnostic_connection)
  flush(diagnostic_connection)
  gc_previous <- gc.time(TRUE)
  diagnostic_previous_cpu <- sum(proc.time()[1:2])
}
start <- proc.time()[['elapsed']]
index <- 0L
previous <- NULL
while (!file.exists(args[5])) {
  if (diagnostics) {
    tick_point <- proc.time()
    wake_lateness <- max(0, tick_point[['elapsed']] - start - index * .1)
    discovered_children <- 0L
  }
  discovery_missing <- FALSE
  if (ps::ps_is_running(parent)) {
    tree <- discover(parent)
    discovery_missing <- !isTRUE(tree$alive) || isTRUE(tree$missing)
    if (diagnostics) discovered_children <- length(tree$children)
    known <- c(known, tree$children)
    keys <- vapply(known, function(h) paste(ps::ps_pid(h), as.numeric(ps::ps_create_time(h))), '')
    known <- known[!duplicated(keys)]
  }
  known <- Filter(function(h) isTRUE(ps::ps_is_running(h)), known)
  if (diagnostics) discovery_point <- proc.time()
  values <- lapply(known, function(h) inspect(ps::ps_pid(h), as.numeric(ps::ps_create_time(h))))
  if (discovery_missing || any(!vapply(values, function(x) isTRUE(x$alive), logical(1)))) {
    # A death between ps calls is visible as a missing sample, never imputed.
    record_sample_error(args[6], 'process disappeared while sampling')
  }
  rss <- sum(vapply(values, function(x) if (is.null(x$rss)) 0 else x$rss, numeric(1)))
  encoded <- as.character(jsonlite::toJSON(values, auto_unbox = TRUE, digits = 16))
  if (diagnostics) rss_point <- proc.time()
  elapsed <- proc.time()[['elapsed']] - start
  if (!is.null(previous) && elapsed - previous > .2) record_sample_error(args[6], 'missed an entire100ms sampling period')
  index <- index + 1L
  writeLines(sample_line(index, elapsed, rss, encoded), connection)
  flush(connection)
  if (diagnostics) {
    write_point <- proc.time()
    gc_now <- gc.time()
    # Phase endpoints are relative to sampler start. Interval CPU/GC also
    # include the preceding diagnostic write and sleep, exposing their cost.
    metrics <- c(tick_point[['elapsed']] - start, discovery_point[['elapsed']] - start,
                 rss_point[['elapsed']] - start, write_point[['elapsed']] - start,
                 sum(discovery_point[1:2] - tick_point[1:2]),
                 sum(rss_point[1:2] - discovery_point[1:2]),
                 sum(write_point[1:2] - rss_point[1:2]),
                 sum(write_point[1:2] - tick_point[1:2]),
                 sum(write_point[1:2]) - diagnostic_previous_cpu,
                 (gc_now - gc_previous)[1:3], wake_lateness,
                 if (is.null(previous)) 0 else elapsed - previous)
    counts <- c(discovered_children, length(known),
                sum(vapply(values, function(x) isTRUE(x$alive), logical(1))))
    writeLines(paste(c(index, sprintf('%.9f', metrics), counts), collapse = ','), diagnostic_connection)
    flush(diagnostic_connection)
    gc_previous <- gc_now
    diagnostic_previous_cpu <- sum(write_point[1:2])
  }
  previous <- elapsed
  Sys.sleep(max(0, start + index * .1 - proc.time()[['elapsed']]))
}
if (diagnostics) close(diagnostic_connection)
