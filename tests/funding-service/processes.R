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
discover <- function(parent, read_children = function(h) ps::ps_children(h, recursive = TRUE)) {
  # ps_children ends by re-reading the parent, which can exit during discovery.
  # Verify that original identity ended; a live or unknown denial still fails.
  inspect(ps::ps_pid(parent), as.numeric(ps::ps_create_time(parent)), function(h) {
    list(alive = TRUE, children = read_children(h))
  })
}
sample_line <- function(index, elapsed, rss, identities) {
  sprintf('%d,%.15g,%.0f,"%s"', index, elapsed, rss, gsub('"', '""', identities, fixed = TRUE))
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
  cat('PASS: live inspection/tree denials fail, reused PIDs are excluded, actual death is missing, CSV encoding matches; no service gate executed\n')
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
start <- proc.time()[['elapsed']]
index <- 0L
previous <- NULL
while (!file.exists(args[5])) {
  discovery_missing <- FALSE
  if (ps::ps_is_running(parent)) {
    tree <- discover(parent)
    discovery_missing <- !isTRUE(tree$alive)
    known <- c(known, tree$children)
    keys <- vapply(known, function(h) paste(ps::ps_pid(h), as.numeric(ps::ps_create_time(h))), '')
    known <- known[!duplicated(keys)]
  }
  known <- Filter(function(h) isTRUE(ps::ps_is_running(h)), known)
  values <- lapply(known, function(h) inspect(ps::ps_pid(h), as.numeric(ps::ps_create_time(h))))
  if (discovery_missing || any(!vapply(values, function(x) isTRUE(x$alive), logical(1)))) {
    # A death between ps calls is visible as a missing sample, never imputed.
    writeLines('process disappeared while sampling', args[6])
  }
  rss <- sum(vapply(values, function(x) if (is.null(x$rss)) 0 else x$rss, numeric(1)))
  encoded <- as.character(jsonlite::toJSON(values, auto_unbox = TRUE, digits = 16))
  elapsed <- proc.time()[['elapsed']] - start
  if (!is.null(previous) && elapsed - previous > .2) writeLines('missed an entire100ms sampling period', args[6])
  index <- index + 1L
  writeLines(sample_line(index, elapsed, rss, encoded), connection)
  flush(connection)
  previous <- elapsed
  Sys.sleep(max(0, start + index * .1 - proc.time()[['elapsed']]))
}
