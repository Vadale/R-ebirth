#!/usr/bin/env Rscript
# Independent process-lifecycle regressions. No model or HTTP service is loaded.
args <- commandArgs(TRUE)
if (!length(args)) stop('Supply the approved service library, then optional --runtime FILE or --case NAME.')
.libPaths(c(normalizePath(args[[1L]], mustWork = TRUE), .Library), include.site = FALSE)
script <- sub('^--file=', '', grep('^--file=', commandArgs(FALSE), value = TRUE)[[1L]])
root <- normalizePath(file.path(dirname(script), '..', '..'), mustWork = TRUE)
options <- list(runtime = file.path(root, 'examples', 'funding-service', 'runtime.R'), case = NULL)
remaining <- args[-1L]
if (length(remaining)) {
  stopifnot(length(remaining) %% 2L == 0L)
  for (i in seq(1L, length(remaining), by = 2L)) {
    key <- sub('^--', '', remaining[[i]])
    stopifnot(key %in% names(options))
    options[[key]] <- remaining[[i + 1L]]
  }
}
source(file.path(root, 'examples', 'funding-service', 'common.R'))
source(options$runtime)

main <- function() {
  work <- tempfile('relm-process-rss-')
  dir.create(work, mode = '0700')
  on.exit(unlink(work, recursive = TRUE), add = TRUE)
  count <- 0L
  check <- function(name, expression) {
    if (!is.null(options$case) && options$case != name) return(invisible(NULL))
    force(expression)
    count <<- count + 1L
    cat('PASS:', name, '\n')
  }
  ownership_error <- function(expression) {
    value <- tryCatch(force(expression), error = identity)
    stopifnot(inherits(value, 'funding_error_ownership'))
  }
  # Bind namespace lookup only inside copies of the real product closures.
  # No function body or installed ps namespace is rewritten.
  product <- function(ps_overrides = list(), bindings = list()) {
    original <- environment(svc_rss)
    local <- new.env(parent = original)
    for (name in ls(original, pattern = '^svc_')) {
      value <- get(name, original)
      if (is.function(value)) {
        environment(value) <- local
        assign(name, value, local)
      }
    }
    local[['::']] <- function(package, name) {
      package <- as.character(substitute(package)); name <- as.character(substitute(name))
      if (package == 'ps' && name %in% names(ps_overrides)) return(ps_overrides[[name]])
      getExportedValue(package, name)
    }
    for (name in names(bindings)) assign(name, bindings[[name]], local)
    local
  }
  state <- function() {
    e <- new.env(parent = emptyenv())
    e$frontend <- svc_process(); e$started <- svc_now(); e$store <- work
    e$worker_identity <- NULL; e$dispatch_count <- 0L; e$store_bytes <- 0
    e$rss <- 0; e$peak_rss <- 0; e$rss_budget <- 1073741824; e$state <- 'ready'
    e$limits <- list(store_admission_floor_bytes = 65536, store_limit_bytes = 1048576)
    e
  }
  delayed_death <- function(status_failure = FALSE, persistent = FALSE, unknown = FALSE) {
    event <- new.env(parent = emptyenv())
    event$failed <- FALSE; event$waited <- 0
    wait <- function(seconds) {
      event$waited <- event$waited + seconds
      stopifnot(event$waited <= .100000001)
    }
    operations <- list(
      ps_children = function(...) list(),
      ps_is_running = function(handle) {
        if (unknown && event$failed) stop('injected unknown process identity')
        persistent || !event$failed || event$waited < .05
      },
      ps_status = function(handle) {
        if (status_failure) {
          event$failed <- TRUE
          stop('injected status denial before exit publication')
        }
        'running'
      },
      ps_memory_info = function(handle) {
        event$failed <- TRUE
        stop('injected memory denial before exit publication')
      })
    list(code = product(operations, list(Sys.sleep = wait)), event = event)
  }
  handle <- ps::ps_handle(Sys.getpid())

  check('persisted-owner-identity', {
    owner <- svc_process()
    stopifnot(svc_alive(owner))
    stale <- owner; stale$birth <- sprintf('%.6f', as.numeric(owner$birth) - 1)
    stopifnot(!svc_alive(stale), svc_running(handle))
  })
  check('owner-live-read-denial', {
    local <- product(list(ps_handle = function(pid, time = NULL) {
      if (is.null(time)) stop('injected live stat denial')
      ps::ps_handle(pid, time = time)
    }))
    ownership_error(local$svc_alive(svc_process()))
  })
  check('independent-owner-reader', {
    owner <- svc_process()
    observed <- callr::r(function(root, runtime, owner) {
      source(file.path(root, 'examples', 'funding-service', 'common.R'))
      source(runtime)
      stale <- owner; stale$birth <- sprintf('%.6f', as.numeric(owner$birth) - 1)
      list(alive = svc_alive(owner), stale_alive = svc_alive(stale),
           recorded_birth = owner$birth, observed_birth = svc_birth(ps::ps_handle(owner$pid)))
    }, args = list(root, normalizePath(options$runtime), owner), libpath = .libPaths(),
    system_profile = FALSE, user_profile = FALSE)
    stopifnot(isTRUE(observed$alive), identical(observed$stale_alive, FALSE))
    cat(as.character(jsonlite::toJSON(observed, auto_unbox = TRUE)), '\n')
  })
  if (identical(unname(Sys.info()[['sysname']]), 'Linux')) check('owner-boot-offset', {
    owner <- svc_process()
    # Model the per-R-process CLOCK_REALTIME/CLOCK_MONOTONIC offset in the
    # pinned ps reader. The real library still checks each handle's identity.
    fresh <- function(pid, time = NULL) {
      if (is.null(time)) time <- ps::ps_create_time(ps::ps_handle(pid)) + .000002
      ps::ps_handle(pid, time = time)
    }
    observed <- fresh(owner$pid)
    stopifnot(ps::ps_is_running(observed), !identical(svc_birth(observed), owner$birth))
    local <- product(list(ps_handle = fresh))
    stopifnot(local$svc_alive(owner))
    stale <- owner; stale$birth <- sprintf('%.6f', as.numeric(owner$birth) - 1)
    stopifnot(!local$svc_alive(stale))
  })

  check('rss-race', {
    fixture <- delayed_death(); e <- state()
    fixture$code$svc_rss(e)
    stopifnot(e$rss == 0, e$state == 'ready', file.exists(file.path(work, 'rss.csv')),
              fixture$event$waited > 0, fixture$event$waited <= .100000001)
  })
  check('liveness-race', {
    fixture <- delayed_death(status_failure = TRUE)
    stopifnot(identical(fixture$code$svc_running(handle), FALSE),
              fixture$event$waited > 0, fixture$event$waited <= .100000001)
  })
  check('live-rss-denial', {
    fixture <- delayed_death(persistent = TRUE)
    ownership_error(fixture$code$svc_rss(state()))
    stopifnot(fixture$event$waited <= .100000001)
  })
  check('unknown-rss-identity', {
    fixture <- delayed_death(unknown = TRUE)
    ownership_error(fixture$code$svc_rss(state()))
  })
  check('live-status-denial', {
    fixture <- delayed_death(status_failure = TRUE, persistent = TRUE)
    ownership_error(fixture$code$svc_running(handle))
    stopifnot(fixture$event$waited <= .100000001)
  })
  check('actual-live-denial', {
    stopifnot(svc_running(handle))
    local <- product(list(ps_children = function(...) list(),
                          ps_memory_info = function(h) stop('injected live memory denial')))
    ownership_error(local$svc_rss(state()))
    stopifnot(svc_running(handle))
  })
  check('actual-stale-birth', {
    stale <- ps::ps_handle(Sys.getpid(), time = ps::ps_create_time(handle) - 1)
    # The actual pinned ps reader must reject bytes belonging to a replacement
    # identity. Do not fake a successful read that bypasses ps's handle checks.
    local <- product(list(ps_children = function(...) list(), ps_handle = function(pid) stale))
    e <- state(); local$svc_rss(e)
    stopifnot(e$rss == 0, svc_running(handle))
  })
  check('actual-live-rss', {
    local <- product(list(ps_children = function(...) list()))
    e <- state(); local$svc_rss(e)
    stopifnot(is.finite(e$rss), e$rss > 0, e$state == 'ready')
  })
  check('actual-child-death', {
    child <- processx::process$new(Sys.which('Rscript'), c('--vanilla', '-e', 'Sys.sleep(60)'))
    tryCatch({
      owned <- ps::ps_handle(child$get_pid())
      local <- product(list(ps_children = function(...) list(), ps_memory_info = function(h) {
        child$kill(); child$wait(timeout = 2000)
        stop('injected read error concurrent with actual child death')
      }))
      e <- state(); e$frontend <- svc_process(child$get_pid())
      local$svc_rss(e)
      stopifnot(e$rss == 0, !child$is_alive(), !svc_running(owned))
    }, finally = if (child$is_alive()) child$kill())
  })
  stopifnot(count > 0L)
  cat(sprintf('PASS: %d process RSS/liveness regressions; no model loaded\n', count))
}
main()
