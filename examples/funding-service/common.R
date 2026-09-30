# Application-only service preparation. No relm exports or implicit installation.
svc_common <- normalizePath(tail(Filter(Negate(is.null),
  lapply(sys.frames(), function(frame) frame$ofile)), 1L)[[1L]], mustWork = TRUE)
svc_module <- dirname(svc_common)
svc_root <- dirname(dirname(svc_module))
source(file.path(svc_root, 'examples', 'funding-extraction', 'app.R'))

svc_contract <- function() {
  x <- app_read_json(file.path(svc_root, 'tests', 'service-contract', 'contract.json'))
  if (!identical(x$status, 'approved') || !identical(x$decision, 'D-034'))
    app_abort('The service contract is not approved.', 'environment')
  x
}

svc_pins <- function() utils::read.csv(file.path(svc_root, 'tests', 'service-contract', 'dependencies.csv'),
                                      stringsAsFactors = FALSE)

svc_library <- function(path) {
  path <- normalizePath(path, mustWork = TRUE)
  app_no_symlink(path)
  .libPaths(c(path, .Library), include.site = FALSE)
  pins <- svc_pins()
  packages <- c(pins$package, 'relm', 'nanoarrow')
  for (pkg in packages) {
    where <- file.path(path, pkg)
    if (!dir.exists(where)) app_abort(paste('Missing prepared package:', pkg), 'environment')
    app_no_symlink(where)
    if (pkg %in% loadedNamespaces() && normalizePath(getNamespaceInfo(asNamespace(pkg), 'path')) != where)
      app_abort(paste('Use a fresh R process; namespace already loaded:', pkg), 'environment')
    version <- read.dcf(file.path(where, 'DESCRIPTION'), 'Version')[[1L]]
    want <- if (pkg == 'relm') '0.3.0' else pins$version[match(pkg, pins$package)]
    if (pkg != 'nanoarrow' && !identical(version, want))
      app_abort(paste('Unapproved package version:', pkg), 'environment')
  }
  path
}

svc_sources <- function() {
  files <- c(sort(list.files(svc_module, pattern = '\\.R$', full.names = TRUE)), app_module,
             file.path(svc_root, 'tests', 'service-contract', c('contract.json', 'dependencies.csv')))
  values <- as.list(unname(tools::sha256sum(files)))
  names(values) <- substring(files, nchar(svc_root) + 2L)
  if (anyNA(unlist(values))) app_abort('Cannot hash service source.', 'integrity')
  values
}

svc_setup <- function(environment_dir, source_library, model, model_alias, backend) {
  Sys.umask('0077')
  platform <- app_platform()
  source_library <- svc_library(source_library)
  if (!backend %in% c('cpu', 'metal') || (backend == 'metal' && Sys.info()[['sysname']] != 'Darwin'))
    app_abort('Choose cpu on Linux, or cpu/metal on macOS.')
  if (is.null(model) || is.null(model_alias)) app_abort('Supply an existing --model and its pinned --model-alias.')
  model <- normalizePath(model, mustWork = TRUE)
  app_no_symlink(model)
  registry <- utils::read.csv(file.path(source_library, 'relm', 'models.csv'), colClasses = 'character')
  row <- registry[registry$alias == model_alias, , drop = FALSE]
  if (nrow(row) != 1L || !model_alias %in% c('spark-x2.5-4b-q8_0', 'qwen2.5-0.5b-instruct-q8_0'))
    app_abort('Choose a model profile accepted by this service contract.')
  if (app_sha256(model) != row$sha256 || sprintf('%.0f', file.info(model)$size) != row$size_bytes)
    app_abort('Model bytes do not match the pinned registry.', 'integrity')
  parent <- dirname(path.expand(environment_dir))
  dir.create(parent, recursive = TRUE, showWarnings = FALSE, mode = '0700')
  target <- file.path(normalizePath(parent, mustWork = TRUE), basename(environment_dir))
  app_no_symlink(target)
  if (file.exists(target)) app_abort('Environment exists; choose a new directory.', 'environment')
  stage <- tempfile('.service-prepare-', tmpdir = dirname(target))
  if (!dir.create(stage, mode = '0700')) app_abort('Cannot stage service environment.', 'filesystem')
  on.exit(unlink(stage, recursive = TRUE), add = TRUE)
  library <- file.path(stage, 'library')
  dir.create(library, mode = '0700')
  packages <- c(svc_pins()$package, 'relm', 'nanoarrow')
  pinned <- setNames(vector('list', length(packages)), packages)
  for (pkg in packages) {
    from <- file.path(source_library, pkg)
    before <- app_package_fingerprint(from)
    if (!file.copy(from, library, recursive = TRUE, copy.mode = TRUE))
      app_abort(paste('Cannot snapshot package:', pkg), 'filesystem')
    if (!identical(before, app_package_fingerprint(file.path(library, pkg))))
      app_abort('Package changed during snapshot.', 'integrity')
    pinned[[pkg]] <- list(version = unname(read.dcf(file.path(from, 'DESCRIPTION'), 'Version')[[1L]]), sha256 = before)
  }
  input_dir <- file.path(svc_root, 'examples', 'funding-extraction')
  files <- c('prompt.txt', 'output.schema.json', 'documents.json')
  if (!all(file.copy(file.path(input_dir, files), stage))) app_abort('Cannot copy application fixtures.', 'filesystem')
  config <- app_read_json(file.path(input_dir, 'config.json'))
  config$backend <- backend
  contract <- svc_contract()
  config$context <- contract$limits$context_tokens
  config$max_tokens <- contract$limits$output_tokens
  app_write_atomic(config, file.path(stage, 'config.json'))
  files <- c(files, 'config.json')
  hashes <- as.list(unname(tools::sha256sum(file.path(stage, files))))
  names(hashes) <- files
  manifest <- list(service_environment_version = 1L, R = platform$R, platform = platform$platform,
                   packages = pinned, model = list(path = model, alias = model_alias,
                   sha256 = row$sha256, size_bytes = row$size_bytes),
                   backend = backend, files = hashes, service_sources = svc_sources())
  app_write_atomic(manifest, file.path(stage, 'environment.json'))
  if (!file.rename(stage, target)) app_abort('Cannot publish environment.', 'filesystem')
  invisible(manifest)
}

svc_environment <- function(path) {
  path <- normalizePath(path, mustWork = TRUE)
  app_no_symlink(path)
  library <- svc_library(file.path(path, 'library'))
  manifest <- app_read_json(file.path(path, 'environment.json'))
  app_object(manifest, c('service_environment_version', 'R', 'platform', 'packages', 'model',
                         'backend', 'files', 'service_sources'), 'service environment')
  platform <- app_platform()
  if (!identical(manifest$service_environment_version, 1L) || manifest$R != platform$R || manifest$platform != platform$platform)
    app_abort('Environment belongs to another R/platform.', 'environment')
  app_object(manifest$packages, c(svc_pins()$package, 'relm', 'nanoarrow'), 'package pins')
  for (pkg in names(manifest$packages)) {
    pin <- manifest$packages[[pkg]]
    app_object(pin, c('version', 'sha256'), 'package pin')
    where <- file.path(library, pkg)
    if (read.dcf(file.path(where, 'DESCRIPTION'), 'Version')[[1L]] != pin$version ||
        !identical(app_package_fingerprint(where), pin$sha256))
      app_abort(paste('Prepared package changed:', pkg), 'integrity')
  }
  if (!identical(app_canonical(manifest$service_sources), app_canonical(svc_sources())))
    app_abort('Service source/contract changed; prepare a new environment.', 'integrity')
  app_object(manifest$files, c('prompt.txt', 'output.schema.json', 'documents.json', 'config.json'), 'configuration files')
  for (name in names(manifest$files)) {
    app_no_symlink(file.path(path, name))
    if (!identical(app_sha256(file.path(path, name)), manifest$files[[name]]))
      app_abort('Prepared application configuration changed.', 'integrity')
  }
  app_object(manifest$model, c('path', 'alias', 'sha256', 'size_bytes'), 'model pin')
  model <- app_string(manifest$model$path, 'model path')
  app_no_symlink(model)
  if (!identical(app_sha256(model), manifest$model$sha256) ||
      sprintf('%.0f', file.info(model)$size) != manifest$model$size_bytes)
    app_abort('Prepared model changed.', 'integrity')
  config <- app_config(file.path(path, 'config.json'))
  contract <- svc_contract()
  if (!identical(config$backend, manifest$backend) || config$context != contract$limits$context_tokens ||
      config$max_tokens != contract$limits$output_tokens || !identical(config$temperature, '0') ||
      !identical(config$top_p, '0.95') || !isTRUE(config$chat)) app_abort('Service settings changed.', 'integrity')
  native <- list.files(file.path(library, 'relm', 'libs'), pattern = '\\.(so|dylib)$', full.names = TRUE)
  if (length(native) != 1L) app_abort('Expected one native relm library.', 'environment')
  identity <- list(environment_sha256 = app_sha256(file.path(path, 'environment.json')),
                   sources = manifest$service_sources, model_sha256 = manifest$model$sha256,
                   native_sha256 = app_sha256(native), backend = config$backend,
                   sampling = list(context = config$context, max_tokens = config$max_tokens,
                     temperature = config$temperature, top_p = config$top_p, chat = config$chat),
                   schema_sha256 = manifest$files[['output.schema.json']], prompt_sha256 = manifest$files[['prompt.txt']])
  list(path = path, library = library, manifest = manifest, model = model,
       config = config, identity = identity, contract = contract)
}
