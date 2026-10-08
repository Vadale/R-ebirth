# Affected installed acceptance for the two F6e review corrections.
# Reuse an operational direction; no efficacy, construction trace or golden replay.
args <- commandArgs(TRUE)
stopifnot(length(args) == 2L)
config <- jsonlite::read_json(args[[1L]], simplifyVector = TRUE)
out <- normalizePath(args[[2L]], mustWork = TRUE)
library(relm)
stopifnot(normalizePath(find.package('relm')) == config$library,
  unname(tools::sha256sum(getLoadedDLLs()[['relm']][['path']])) == config$dll_sha256,
  unname(tools::sha256sum(config$model)) == config$model_sha256)
expected <- c('installed_binding', 'original_loaded', 'zero_constructed',
  'zero_live_identity', 'zero_live_capture_identity', 'registry_sequential_gc',
  'registry_simultaneous', 'registry_compaction', 'original_survives_gc', 'owners_closed')
rows <- data.frame(case = character(), status = character())
check <- function(name, ok) {
  stopifnot(identical(name, expected[[nrow(rows) + 1L]]), isTRUE(ok))
  rows[nrow(rows) + 1L, ] <<- list(name, 'passed')
  write.csv(rows, file.path(out, 'cases.csv'), row.names = FALSE)
  cat('F6E_INSTALLED_REVIEW_CASE ', name, '\n', sep = ''); flush.console()
}
counts <- list(load = 0L, derive = 0L, generate = 0L, trace = 0L, logits = 0L, tokenize = 0L)
count <- function(kind) {
  counts[[kind]] <<- counts[[kind]] + 1L
  saveRDS(counts, file.path(out, 'attempts.rds'))
}
profiles <- list()
profile <- function(label) {
  p <- relm:::rebirth_projection_allocation_profile()
  stopifnot(is.list(p), length(p) == 27L,
    p$ffi_registry_bytes >= 32, (p$ffi_registry_bytes - 32) %% 16 == 0,
    p$ffi_fixed_bytes == p$ffi_response_bytes + p$ffi_registry_bytes + 160)
  profiles[[label]] <<- p
  saveRDS(profiles, file.path(out, 'registry-profiles.rds'))
  (p$ffi_registry_bytes - 32) / 16
}
observe <- function(promise) {
  x <- new.env(parent = emptyenv())
  x$done <- FALSE; x$error <- NULL; x$value <- NULL; x$settlements <- 0L
  promises::then(promise, function(v) {
    x$value <- v; x$done <- TRUE; x$settlements <- x$settlements + 1L; NULL
  }, function(e) {
    x$error <- e; x$done <- TRUE; x$settlements <- x$settlements + 1L; NULL
  })
  deadline <- proc.time()[['elapsed']] + 120
  while (!x$done && proc.time()[['elapsed']] < deadline) later::run_now(.05, loop = later::global_loop())
  stopifnot(x$done, is.null(x$error), x$settlements == 1L, is.null(relm:::.relm_async$job))
  x$value
}
main <- function() {
  check('installed_binding', all(c('later', 'promises') %in% loadedNamespaces()) ||
    (requireNamespace('later', quietly = TRUE) && requireNamespace('promises', quietly = TRUE)))
  relm:::rebirth_available_backends()
  shim <- dyn.load(config$logger)
  stopifnot(.C('f6e_log_start', getLoadedDLLs()[['relm']][['path']],
    file.path(out, 'native-placement.log'), status = integer(1), PACKAGE = shim[['name']])$status == 0L)
  on.exit(stopifnot(.C('f6e_log_stop', status = integer(1), PACKAGE = shim[['name']])$status == 0L), add = TRUE)
  count('load')
  m <- llm(config$model, backend = 'cpu', context_length = 512L)
  on.exit({
    for (name in c('z', 'h', 'q')) if (exists(name, inherits = FALSE)) close(get(name))
    if (exists('many', inherits = FALSE)) invisible(lapply(many, close))
    close(m)
  }, add = TRUE, after = FALSE)
  check('original_loaded', m$hidden_size == 896L && m$layers == 24L && identical(m$interventions, list()))
  d <- readRDS(config$direction)
  record <- readRDS(config$captures)$context$model
  derive <- function() {
    count('derive')
    llm_apply_direction(m, d, record, coef = 0, max_bytes = 64 * 1024^2, operator = 'project')
  }
  prompt <- '11, 12, 13, 14, 15,'
  live <- function(handle, label) {
    states <- list(); events <- list()
    count('generate')
    value <- observe(llm_generate(handle, prompt, chat = FALSE, max_tokens = 2L,
      temperature = 0, top_p = .95, seed = 1047L, async = TRUE,
      layers = 12L, components = 'mlp_out', top = 3L, spill = FALSE,
      on_state = function(s) { states[[length(states) + 1L]] <<- s; NULL },
      on_token = function(e) { events[[length(events) + 1L]] <<- e; NULL }))
    answer <- list(states = states, events = do.call(rbind, events), value = value)
    saveRDS(answer, file.path(out, paste0(label, '.rds')))
    stopifnot(length(states) == 2L)
    answer
  }
  baseline <- live(m, 'baseline-live')
  z <- derive()
  check('zero_constructed', length(z$interventions) == 1L &&
    identical(z$interventions[[1L]]$kind, 'project') && z$interventions[[1L]]$coef == 0 &&
    profile('zero_live_owner') == 2)
  zero <- live(z, 'zero-live')
  check('zero_live_identity', identical(zero$value, baseline$value) &&
    identical(zero$events$token_id[zero$events$event == 'token'],
              baseline$events$token_id[baseline$events$event == 'token']))
  coordinates <- list()
  for (i in seq_len(2L)) {
    a <- baseline$states[[i]]; b <- zero$states[[i]]
    av <- as.numeric(as.matrix(a$trace, 12L, 'mlp_out'))
    bv <- as.numeric(as.matrix(b$trace, 12L, 'mlp_out'))
    stopifnot(length(av) == 896L, identical(av, bv), all(is.finite(av)),
      identical(a$step$token_id, b$step$token_id), identical(a$step$source_pos, b$step$source_pos),
      identical(a$step$state_id, b$step$state_id), a$step$steering_revision == 0L,
      b$step$steering_revision == 0L, identical(attr(a$trace, 'prompts'), attr(b$trace, 'prompts')))
    coordinates[[i]] <- data.frame(state = i, neuron = seq_along(av), original = av, zero = bv)
  }
  coordinates <- do.call(rbind, coordinates)
  write.csv(coordinates, file.path(out, 'zero-live-coordinates.csv'), row.names = FALSE)
  check('zero_live_capture_identity', nrow(coordinates) == 1792L)
  close(z); rm(z); invisible(gc())
  caps <- numeric(8L)
  for (i in seq_len(8L)) {
    h <- derive()
    caps[[i]] <- profile(paste0('sequential_', i))
    # Alternate explicit close and actual GC finalization of an open owner.
    if (i %% 2L == 0L) close(h)
    rm(h); invisible(gc())
  }
  check('registry_sequential_gc', identical(caps, rep(2, 8L)))
  many <- vector('list', 3L); live_caps <- numeric(3L)
  for (i in seq_len(3L)) {
    many[[i]] <- derive()
    live_caps[[i]] <- profile(paste0('simultaneous_', i))
  }
  check('registry_simultaneous', identical(live_caps, as.double(2:4)))
  invisible(lapply(many, close)); rm(many); invisible(gc())
  q <- derive()
  check('registry_compaction', profile('compacted') == 2)
  close(q); rm(q); invisible(gc())
  count('generate')
  again <- llm_generate(m, prompt, chat = FALSE, max_tokens = 2L,
    temperature = 0, top_p = .95, seed = 1047L)
  saveRDS(again, file.path(out, 'original-after-gc.rds'))
  check('original_survives_gc', identical(again, baseline$value))
  close(m)
  check('owners_closed', relm:::rebirth_handle_is_closed(m$ptr) && is.null(relm:::.relm_async$job))
  stopifnot(identical(rows$case, expected), identical(counts,
    list(load = 1L, derive = 13L, generate = 3L, trace = 0L, logits = 0L, tokenize = 0L)))
  jsonlite::write_json(list(status = 'awaiting_owner_verification', cases = 10L,
    coordinates = 1792L, attempts = counts, actual_gc_calls = 11L,
    gc_finalized_open_candidates = 4L, max_simultaneous_derived = 3L,
    scope = 'Installed zero plus live capture and real GC registry reuse; no efficacy, timing or new independent numerical accuracy'),
    file.path(out, 'receipt.json'), auto_unbox = TRUE, pretty = TRUE)
  cat('F6E_INSTALLED_REVIEW_COMPLETE cases=10 coordinates=1792 load_attempts=1 derive_attempts=13 generation_attempts=3\n')
}
main()
