local({
  before <- readRDS('/private/tmp/relm-wp9/rstudio/preflight.rds')
  stopifnot(identical(.relm_wp9_acceptance$status, 'passed'))
  later::run_now(0.1)
  if ('package:relm' %in% setdiff(search(), before$search)) {
    detach('package:relm', unload = FALSE, character.only = TRUE)
  }
  .libPaths(before$library)
  added <- setdiff(ls(.GlobalEnv, all.names = TRUE), before$globals)
  stopifnot(all(added %in% c('.relm_wp9_acceptance', 'a', 'root',
    'elapsed', 'started', 'value', 'was_running')))
  rm(list = added, envir = .GlobalEnv)
  if (!is.null(before$seed)) assign('.Random.seed', before$seed, .GlobalEnv)
  result <- list(globals_restored = identical(ls(.GlobalEnv, all.names = TRUE), before$globals),
    seed_restored = identical(get0('.Random.seed', .GlobalEnv), before$seed),
    library_restored = identical(.libPaths(), before$library),
    search_restored = identical(search(), before$search),
    dll_retained = 'relm' %in% loadedNamespaces())
  stopifnot(result$globals_restored, result$seed_restored,
    result$library_restored, result$search_restored)
  jsonlite::write_json(result, '/private/tmp/relm-wp9/rstudio/restoration.json',
    pretty = TRUE, auto_unbox = TRUE)
  cat('WP9_RSTUDIO_WORKSPACE_RESTORED\n')
})
