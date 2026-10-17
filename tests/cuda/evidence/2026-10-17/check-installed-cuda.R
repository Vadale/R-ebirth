args <- commandArgs(TRUE)
stopifnot(length(args) == 4L)
library(relm)
stopifnot(normalizePath(find.package('relm')) == normalizePath(args[[1L]]))
ns <- asNamespace('relm'); source_env <- new.env(parent = ns)
for (p in sort(list.files(file.path(args[[2L]], 'R'), full.names = TRUE))) sys.source(p, source_env)
functions <- Filter(function(n) is.function(source_env[[n]]), ls(source_env, all.names = TRUE))
for (n in functions) stopifnot(exists(n, ns, inherits = FALSE),
  identical(body(source_env[[n]]), body(ns[[n]])),
  identical(formals(source_env[[n]]), formals(ns[[n]])))
codetools::checkUsagePackage('relm')
registered <- names(getDLLRegisteredRoutines('relm')$.Call)
stopifnot(!any(grepl('selftest', registered, fixed = TRUE)))
backends <- relm:::rebirth_available_backends()
stopifnot(identical(sort(backends), c('cpu', 'cuda')))
profile <- relm:::rebirth_projection_allocation_profile()
stopifnot(length(profile) == 27L, profile$cpp_access_frame_bytes == 77,
  profile$runtime_bytes == 5072, profile$ffi_registry_bytes == 32,
  profile$ffi_fixed_bytes == profile$ffi_response_bytes + profile$ffi_registry_bytes + 160)
saveRDS(list(functions = functions, registered = registered, backends = backends,
  profile = profile, library = find.package('relm'), session = sessionInfo()),
  file.path(args[[4L]], 'installed-binding.rds'))
write.csv(data.frame(field = names(profile), value = unlist(profile, use.names = FALSE)),
  file.path(args[[4L]], 'compiled-profile.csv'), row.names = FALSE)
cat('CUDA_INSTALLED_BINDING_OK functions=', length(functions), ' profile=27 fixtures=0\n', sep = '')
result <- testthat::test_dir(file.path(args[[3L]], 'rebirth/tests/testthat'),
  filter = '^(boundary|llm-load)$', package = 'relm', load_package = 'installed',
  reporter = 'summary', stop_on_failure = FALSE)
saveRDS(result, file.path(args[[4L]], 'boundary-tests.rds'))
counts <- as.data.frame(result)
write.csv(counts[c('file','test','nb','failed','skipped','error','warning','passed')],
  file.path(args[[4L]], 'boundary-tests.csv'), row.names = FALSE)
stopifnot(!any(counts$failed > 0), !any(counts$error))
cat('CUDA_INSTALLED_BOUNDARY_OK cases=', nrow(counts), ' expectations=', sum(counts$passed),
  ' skips=', sum(counts$skipped), '\n', sep = '')
