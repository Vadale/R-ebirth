source("/private/tmp/relm-f6b/rstudio-restore.R")
local({
  root <- "/private/tmp/relm-f6b/rstudio"
  previous <- readRDS(file.path(root,"user-session-before-F6b.rds"))
  check <- new.env(parent=emptyenv())
  load(file.path(root,"user-workspace-before-F6b.RData"),envir=check)
  stopifnot(identical(ls(.GlobalEnv,all.names=TRUE),ls(check,all.names=TRUE)),
    all(vapply(ls(check,all.names=TRUE),function(n)identical(get(n,check),get(n,.GlobalEnv)),logical(1))),
    identical(.libPaths(),previous$library),identical(search(),previous$search))
  for(n in names(previous$environment)) {
    value <- previous$environment[[n]]
    if(is.na(value))Sys.unsetenv(n) else do.call(Sys.setenv,setNames(list(value),n))
  }
  stopifnot(identical(Sys.getenv(names(previous$environment),unset=NA_character_),previous$environment))
  saveRDS(list(restored=TRUE,pid=Sys.getpid(),globals_match=TRUE,seed_match=identical(get0(".Random.seed",.GlobalEnv),previous$seed),
    libraries_match=TRUE,search_match=TRUE,environment_match=TRUE),file.path(root,"user-restoration-verification.rds"))
  cat("F6B_USER_WORKSPACE_RESTORED\n")
})
