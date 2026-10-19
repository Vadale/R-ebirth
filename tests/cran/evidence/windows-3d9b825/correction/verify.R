# Verify the actual subprocess helper and inspect retained Windows output only.
repo <- getwd()
out <- "/home/grauk/Work/relm-phase9/vignette-check-correction"
artifact <- "/home/grauk/Work/relm-phase9/ci-3d9b825/artifact/_temp/vignette-library"
expr <- parse("tests/cran/vignette-library.R")
main_body <- as.list(expr[[1]][[3]][[3]])[-1L]
helper <- Filter(function(x) is.call(x) && identical(x[[1]], as.name("<-")) && identical(x[[2]], as.name("run")), main_body)[[1]]
check_call <- Filter(function(x) is.call(x) && identical(x[[1]], as.name("run")) && identical(x[[2]], "check"), main_body)[[1]]
stopifnot(identical(check_call$env, "_R_CHECK_VIGNETTES_SKIP_RUN_MAYBE_=FALSE"))
e <- new.env(); e$r <- file.path(R.home("bin"), "R")
eval(helper, e)
setwd(out)
parent <- Sys.getenv("_R_CHECK_VIGNETTES_SKIP_RUN_MAYBE_", unset=NA_character_)
e$run("child-environment", c("--vanilla", "--slave", "-e", shQuote("stopifnot(identical(Sys.getenv('_R_CHECK_VIGNETTES_SKIP_RUN_MAYBE_'), 'FALSE')); cat('CHILD_CHECK_ENV_PASS\\n')")), env=check_call$env)
stopifnot(identical(Sys.getenv("_R_CHECK_VIGNETTES_SKIP_RUN_MAYBE_", unset=NA_character_), parent))
# Retain the installed R implementation that explains the missing log line.
r_check <- deparse(tools:::.check_packages, width.cutoff=120L)
keep <- sort(unique(unlist(lapply(grep("skip_run_maybe", r_check, fixed=TRUE), function(i) seq(max(1,i-1), min(length(r_check),i+4))))))
writeLines(c(R.version.string, r_check[keep]), "r-check-vignette-policy.txt")
# The Windows pure-R probe has no native code; execute its saved script once
# on Linux without reinstalling, rendering or calling any relm/model functions.
.libPaths(c(file.path(artifact, "relmvignetteprobe.Rcheck"), .libPaths()))
options(warn=2)
script <- file.path(artifact, "relmvignetteprobe.Rcheck/relmvignetteprobe/doc/probe.R")
result <- capture.output(sys.source(script, new.env()))
stopifnot(identical(result, "TEMPORARY_LIBRARY_RENDER_OK"))
writeLines(result, "retained-script.log")
for (name in c("anatomy-lab", "topics-without-python", "vision")) {
  stopifnot(length(parse(file.path(artifact,paste0(name,".R")))) > 0L)
  stopifnot(!length(readLines(file.path(artifact,paste0(name,".R.log")))))
}
cat("VIGNETTE_CHECK_CORRECTION_PASS child_env=1 parent_unchanged=1 retained_script=1 parsed_scripts=3 native_builds=0 models=0\n")
