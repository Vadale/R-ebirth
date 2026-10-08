x <- yaml::read_yaml('.github/workflows/nightly-memory-safety.yaml')
s <- x$jobs[['asan-ubsan-native']]$steps
stopifnot(length(s)==16L)
gates <- vapply(s,function(z)if(is.null(z[['if']])) '' else z[['if']],character(1))
stopifnot(all(gates[5:8] == "env.SANITIZER_SELECTION != 'projection-only' && env.SANITIZER_SELECTION != 'projection-review-fixes'"),
 all(gates[c(9,10,12)] == "env.SANITIZER_SELECTION == 'projection-only'"),
 gates[[11]] == "env.SANITIZER_SELECTION == 'projection-only' || env.SANITIZER_SELECTION == 'projection-review-fixes'",
 all(gates[13:15] == "env.SANITIZER_SELECTION == 'projection-review-fixes'"),
 gates[[16]] == 'always()',
 grepl("inputs.sanitizer_selection != 'projection-review-fixes'",x$jobs[['valgrind-intervention']][['if']],fixed=TRUE),
 identical(x$on$workflow_dispatch$inputs$sanitizer_selection$default,'full'),
 identical(x$on$schedule[[1]]$cron,'0 3 * * *'),
 identical(s[[3]]$with$toolchain,'nightly-2025-02-01'),
 identical(x$jobs[['asan-ubsan-native']]$env$LLVM_PACKAGE_VERSION,'1:19.1.1-1ubuntu1~24.04.2'))
cat('F6E_REVIEW_WORKFLOW_ROUTING preserved full/scheduled and old projection routes; affected route excludes all old scopes; no remote execution\n')
