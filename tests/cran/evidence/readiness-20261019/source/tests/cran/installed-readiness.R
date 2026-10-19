# Inspect the new production installation without repeating model acceptance.
args <- commandArgs(TRUE)
stopifnot(length(args) == 3L)
library(relm)
stopifnot(normalizePath(find.package('relm')) == normalizePath(args[[1L]]))
ns <- asNamespace('relm'); source_env <- new.env(parent = ns)
for (file in sort(list.files(file.path(args[[2L]], 'R'), full.names = TRUE))) sys.source(file, source_env)
functions <- Filter(function(n) is.function(source_env[[n]]), ls(source_env, all.names = TRUE))
for (n in functions) stopifnot(exists(n, ns, inherits = FALSE),
  identical(body(source_env[[n]]), body(ns[[n]])), identical(formals(source_env[[n]]), formals(ns[[n]])))
usage <- capture.output(codetools::checkUsagePackage('relm'), type = 'output')
stopifnot(length(usage) == 0L)
registered <- names(getDLLRegisteredRoutines('relm')$.Call)
stopifnot(!any(grepl('selftest', registered, fixed = TRUE)),
          identical(relm:::rebirth_available_backends(), 'cpu'))
profile <- relm:::rebirth_projection_allocation_profile()
stopifnot(length(profile) == 27L, all(is.finite(unlist(profile))))
for (file in c('AUTHORS', 'THIRD-PARTY-NOTICES', 'RUST-NOTICES')) {
  stopifnot(identical(readBin(file.path(args[[1L]], file), 'raw', n = 1000000L),
                      readBin(file.path(args[[2L]], 'inst', file), 'raw', n = 1000000L)))
}
saveRDS(list(functions = functions, registered = registered, profile = profile,
             version = as.character(packageVersion('relm')), session = sessionInfo(),
             loads = 0L, inference = 0L), args[[3L]])
cat(sprintf('CRAN_INSTALLED_READINESS_OK functions=%d profile=27 hooks=0 notices=3 model_loads=0 inference=0\n', length(functions)))
