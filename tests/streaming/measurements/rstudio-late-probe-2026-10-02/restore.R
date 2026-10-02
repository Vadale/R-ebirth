local({
  before <- readRDS("/private/tmp/relm-wp10/rstudio/preflight.rds")
  stopifnot(.relm_wp10_acceptance$status %in% c("passed","failed"))
  if ("package:relm" %in% setdiff(search(),before$search)) {
    detach("package:relm", unload=FALSE, character.only=TRUE)
  }
  .libPaths(before$library)
  added <- setdiff(ls(.GlobalEnv,all.names=TRUE), before$globals)
  stopifnot(all(added %in% c(".relm_wp10_acceptance", ".Random.seed")))
  rm(list=added,envir=.GlobalEnv)
  if (!is.null(before$seed)) assign(".Random.seed",before$seed,.GlobalEnv)
  result <- list(globals_restored=identical(ls(.GlobalEnv,all.names=TRUE),before$globals),
    seed_restored=identical(get0(".Random.seed",.GlobalEnv),before$seed),
    library_restored=identical(.libPaths(),before$library),
    search_restored=identical(search(),before$search),
    dll_retained="relm" %in% loadedNamespaces())
  stopifnot(result$globals_restored,result$seed_restored,result$library_restored,result$search_restored)
  jsonlite::write_json(result,"/private/tmp/relm-wp10/rstudio/restoration.json",pretty=TRUE,auto_unbox=TRUE)
  cat("WP10_RSTUDIO_WORKSPACE_RESTORED\n")
})
