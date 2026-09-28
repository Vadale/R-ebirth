#!/usr/bin/env Rscript
# Trusted process launcher only: no test controls are exposed by product HTTP/CLI.
args <- commandArgs(TRUE)
stopifnot(length(args) == 7L)
root <- normalizePath(args[1], mustWork = TRUE)
library <- normalizePath(args[2], mustWork = TRUE)
.libPaths(c(library, .Library), include.site = FALSE)
Sys.umask('0077')
source(file.path(root, 'examples', 'funding-service', 'common.R'))
source(file.path(svc_module, 'runtime.R'))
control <- app_read_json(args[6])
action <- args[7]
if (action == 'stop') {
  svc_stop(args[3])
} else if (action == 'start') {
  if (nzchar(args[5])) {
    prepared <- svc_environment(args[5])
  } else {
    pins <- svc_pins()
    versions <- setNames(lapply(pins$package, function(package) {
      actual <- read.dcf(file.path(find.package(package), 'DESCRIPTION'), 'Version')[[1]]
      stopifnot(identical(actual, pins$version[pins$package == package]))
      actual
    }), pins$package)
    config <- app_config(file.path(root, 'examples', 'funding-extraction', 'config.json'))
    config$backend <- 'cpu'; config$context <- 4096L; config$max_tokens <- 768L
    identity <- list(fixture = TRUE, packages = versions, sources = svc_sources(),
                     config_sha256 = app_digest(config))
    if (!is.null(control$identity_override)) identity$fixture_revision <- control$identity_override
    prepared <- list(path = dirname(args[6]), library = library,
      manifest = list(fixture = TRUE, packages = versions, model = list(alias = 'deterministic-fixture')),
      model = '', config = config, identity = identity, contract = svc_contract())
  }
  svc_run(prepared, args[3], port = as.integer(args[4]), test_config = control)
} else stop('Unknown fixture launcher action')
