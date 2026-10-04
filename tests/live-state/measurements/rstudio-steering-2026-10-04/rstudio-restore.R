# Run only after the foreground acceptance has settled; no inference here.
local({
  a <- get(".relm_f6b_acceptance", envir = .GlobalEnv, inherits = FALSE)
  stopifnot(a$status %in% c("passed", "failed"), is.null(relm:::.relm_async$job))
  pre <- a$preflight
  if (is.function(a$timer)) a$timer()
  close(a$model)
  close(a$base)
  for (device in setdiff(grDevices::dev.list(), pre$devices)) grDevices::dev.off(device)
  .libPaths(pre$library)
  if (is.null(pre$seed)) {
    if (exists(".Random.seed", .GlobalEnv, inherits = FALSE)) rm(".Random.seed", envir = .GlobalEnv)
  } else assign(".Random.seed", pre$seed, envir = .GlobalEnv)
  stopifnot(identical(search(), pre$search), identical(.libPaths(), pre$library))
  root <- a$root
  rm(".relm_f6b_acceptance", envir = .GlobalEnv)
  stopifnot(identical(ls(.GlobalEnv, all.names = TRUE), pre$globals))
  saveRDS(list(restored = TRUE, globals = ls(.GlobalEnv, all.names = TRUE),
    search = search(), library = .libPaths(), devices = grDevices::dev.list()),
    file.path(root, "restored.rds"))
})
