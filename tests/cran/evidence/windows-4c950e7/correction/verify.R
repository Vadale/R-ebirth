out <- "/home/grauk/Work/relm-phase9/vignette-environment-correction"
expr <- parse("tests/cran/vignette-library.R")
body <- as.list(expr[[1]][[3]][[3]])[-1L]
helper <- Filter(function(x) is.call(x) && identical(x[[1]], as.name("<-")) && identical(x[[2]], as.name("run")), body)[[1]]
check_call <- Filter(function(x) is.call(x) && identical(x[[1]], as.name("run")) && identical(x[[2]], "check"), body)[[1]]
stopifnot(isTRUE(check_call$check_scripts))
e <- new.env(); e$r <- file.path(out,"r-windows-front-end-observer")
eval(helper,e)
setwd(out)
key <- "_R_CHECK_VIGNETTES_SKIP_RUN_MAYBE_"
Sys.unsetenv(key)
# system2's Windows implementation places env strings before CMD. Run that
# exact argv through the unchanged R 4.6.1 Windows entry point on Linux.
status <- system2(e$r,c(paste0(key,"=FALSE"),"CMD","check"),stdout="old-order.log",stderr="old-order.log")
stopifnot(identical(status,19L),grepl("inherited_skip=<unset>",readLines("old-order.log"),fixed=TRUE))
for (value in c(NA_character_,"TRUE","FALSE")) {
  if(is.na(value)) Sys.unsetenv(key) else Sys.setenv(`_R_CHECK_VIGNETTES_SKIP_RUN_MAYBE_`=value)
  before<-Sys.getenv(key,unset=NA_character_)
  label<-if(is.na(value)) "unset" else value
  e$run(paste0("corrected-",label),c("CMD","check"),check_scripts=TRUE)
  stopifnot(identical(Sys.getenv(key,unset=NA_character_),before))
  failure <- tryCatch(e$run(paste0("failure-",label),c("CMD","fail"),check_scripts=TRUE),error=identity)
  stopifnot(inherits(failure,"error"),identical(Sys.getenv(key,unset=NA_character_),before))
}
Sys.unsetenv(key)
e$r<-file.path(R.home("bin"),"R")
e$run("real-r-child",c("--vanilla","--slave","-e",shQuote("stopifnot(identical(Sys.getenv('_R_CHECK_VIGNETTES_SKIP_RUN_MAYBE_'), 'FALSE')); cat('REAL_R_CHILD_ENV_PASS')")),check_scripts=TRUE)
stopifnot(is.na(Sys.getenv(key,unset=NA_character_)))
cat("VIGNETTE_ENVIRONMENT_PASS old_order_rejected=1 restored_success=3 restored_failure=3 real_r_child=1 relm_native_builds=0 models=0\n")
