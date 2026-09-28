# D2 application helpers, not relm exports. Requires jsonlite 2.0.0 (D-031).
# Persistent data is literal JSON. Only setup may download or prepare packages.
app_module <- normalizePath(tail(Filter(Negate(is.null),
  lapply(sys.frames(), function(frame) frame$ofile)), 1L)[[1L]], mustWork = TRUE)

app_abort <- function(message, kind = "input") {
  stop(structure(list(message = message, call = NULL),
                 class = c(paste0("funding_error_", kind), "error", "condition")))
}

app_require_json <- function() {
  if (!requireNamespace("jsonlite", quietly = TRUE) ||
      as.character(utils::packageVersion("jsonlite")) != "2.0.0") {
    app_abort("Prepare jsonlite 2.0.0 before running this application.", "environment")
  }
}

app_string <- function(x, name, empty = FALSE, limit = 1048576L) {
  if (!is.character(x) || length(x) != 1L || is.na(x) ||
      (!empty && !nzchar(x)) || is.na(iconv(x, from = "UTF-8", to = "UTF-8")) ||
      nchar(x, type = "bytes") > limit) app_abort(paste("Invalid string:", name))
  enc2utf8(x)
}

app_integer <- function(x, name, low = 0L, high = .Machine$integer.max) {
  if (!is.numeric(x) || length(x) != 1L || !is.finite(x) ||
      x != trunc(x) || x < low || x > high) app_abort(paste("Invalid integer:", name))
  as.integer(x)
}

app_object <- function(x, keys, name) {
  if (!is.list(x) || is.null(names(x)) || anyDuplicated(names(x)) ||
      !setequal(names(x), keys)) app_abort(paste("Unknown, missing or duplicate keys in", name))
  invisible(x)
}

app_json_tree <- function(x, depth = 0L) {
  if (depth > 32L) app_abort("JSON nesting exceeds 32 levels.")
  if (is.null(x)) return(invisible(x))
  if (is.list(x)) {
    if (!is.null(names(x))) {
      if (anyDuplicated(names(x))) app_abort("Duplicate JSON object key.")
      for (key in names(x)) app_string(key, "JSON key", empty = TRUE)
    }
    for (value in x) app_json_tree(value, depth + 1L)
  } else if (is.character(x)) {
    app_string(x, "JSON string", empty = TRUE)
  } else if (is.logical(x)) {
    if (length(x) != 1L || is.na(x)) app_abort("Invalid JSON boolean.")
  } else {
    if (!is.numeric(x) || length(x) != 1L || !is.finite(x) ||
        x != trunc(x) || abs(x) > 9007199254740991)
      app_abort("JSON numbers must be exactly representable integers.")
  }
  invisible(x)
}

app_parse_json <- function(text) {
  app_require_json()
  app_string(text, "JSON text", limit = 8388608L)
  if (!isTRUE(jsonlite::validate(text))) app_abort("Malformed JSON.")
  # This profile uses lexical integers only. Discard quoted tokens first so
  # decimal/exponent spellings cannot round before identity checks see them.
  tokens <- regmatches(text, gregexpr('"(?:[^"\\\\]|\\\\.)*"|-?[0-9]+(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?',
                                     text, perl = TRUE))[[1L]]
  numbers <- tokens[!startsWith(tokens, '"')]
  if (any(grepl("[.eE]", numbers))) app_abort("JSON numbers must use integer notation; sampling decimals are strings.")
  # jsonlite 2.0.0 replaces lone UTF-16 surrogates and truncates escaped NUL.
  # Check only escape tokens before parsing; consume escaped backslashes so a
  # literal text fragment such as \\u0000 is not mistaken for a Unicode escape.
  positions <- gregexpr("\\\\(?:u[0-9A-Fa-f]{4}|.)", text, perl = TRUE)[[1L]]
  if (positions[[1L]] > 0L) {
    escapes <- regmatches(text, list(positions))[[1L]]
    codes <- vapply(escapes, function(x) if (startsWith(x, "\\u"))
      strtoi(substring(x, 3L), base = 16L) else -1L, integer(1))
    for (i in seq_along(codes)) {
      code <- codes[[i]]
      if (code == 0L) app_abort("Escaped NUL is not supported in R strings.")
      if (code >= 55296L && code <= 56319L &&
          (i == length(codes) || positions[[i + 1L]] != positions[[i]] + 6L ||
           codes[[i + 1L]] < 56320L || codes[[i + 1L]] > 57343L))
        app_abort("Unpaired high Unicode surrogate.")
      if (code >= 56320L && code <= 57343L &&
          (i == 1L || positions[[i - 1L]] + 6L != positions[[i]] ||
           codes[[i - 1L]] < 55296L || codes[[i - 1L]] > 56319L))
        app_abort("Unpaired low Unicode surrogate.")
    }
  }
  value <- tryCatch(jsonlite::fromJSON(txt = text, simplifyVector = FALSE),
                    error = function(e) app_abort("Cannot parse JSON."))
  app_json_tree(value)
  value
}

app_read_text <- function(path, limit = 8388608L) {
  if (!file.exists(path) || dir.exists(path)) app_abort(paste("Missing file:", path))
  size <- file.info(path)$size
  if (is.na(size) || size > limit) app_abort(paste("File exceeds size limit:", path))
  raw <- readBin(path, "raw", n = size)
  if (any(raw == as.raw(0))) app_abort("NUL bytes are not allowed in text files.")
  text <- rawToChar(raw)
  app_string(text, "file contents", empty = TRUE, limit = limit)
}

app_read_json <- function(path) app_parse_json(app_read_text(path))

# S0 canonical representation: sorted UTF-8 keys, compact separators, integers,
# explicit JSON null. jsonlite handles string escaping; no custom JSON parser.
app_canonical <- function(x) {
  app_require_json()
  app_json_tree(x)
  encode <- function(value) {
    if (is.null(value)) return("null")
    if (is.list(value)) {
      if (is.null(names(value))) return(paste0("[", paste(vapply(value, encode, ""), collapse = ","), "]"))
      order <- order(enc2utf8(names(value)), method = "radix")
      parts <- vapply(order, function(i) paste0(encode(names(value)[[i]]), ":", encode(value[[i]])), "")
      return(paste0("{", paste(parts, collapse = ","), "}"))
    }
    if (is.character(value)) return(as.character(jsonlite::toJSON(enc2utf8(value), auto_unbox = TRUE)))
    if (is.logical(value)) return(if (value) "true" else "false")
    sprintf("%.0f", value)
  }
  enc2utf8(encode(x))
}

app_sha256 <- function(path) {
  hash <- unname(tools::sha256sum(path))
  if (length(hash) != 1L || is.na(hash) || !grepl("^[0-9a-f]{64}$", hash))
    app_abort(paste("Cannot hash file:", path), "integrity")
  hash
}

app_digest <- function(value) {
  path <- tempfile("funding-hash-")
  on.exit(unlink(path), add = TRUE)
  writeBin(charToRaw(app_canonical(value)), path)
  app_sha256(path)
}

app_nonce <- function() {
  con <- file("/dev/urandom", "rb", raw = TRUE)
  on.exit(close(con), add = TRUE)
  paste(sprintf("%02x", as.integer(readBin(con, "raw", 16L))), collapse = "")
}

app_no_symlink <- function(path) {
  link <- Sys.readlink(path)
  if (!is.na(link) && nzchar(link)) app_abort(paste("Refusing symbolic link:", path), "filesystem")
}

app_write_atomic <- function(value, path, replace = FALSE, before = NULL, after = NULL) {
  app_no_symlink(dirname(path)); app_no_symlink(path)
  if (!replace && file.exists(path)) app_abort(paste("Refusing to replace committed file:", path), "integrity")
  temporary <- file.path(dirname(path), paste0(".tmp-", app_nonce()))
  on.exit(unlink(temporary), add = TRUE)
  writeBin(charToRaw(app_canonical(value)), temporary)
  if (!is.null(before)) before()
  if (!file.rename(temporary, path)) app_abort(paste("Atomic publication failed:", path), "filesystem")
  if (!is.null(after)) after()
  invisible(path)
}

app_package_fingerprint <- function(path) {
  app_no_symlink(path)
  files <- sort(list.files(path, recursive = TRUE, all.files = TRUE,
                           no.. = TRUE, include.dirs = FALSE), method = "radix")
  if (!length(files)) app_abort(paste("Empty package:", path), "environment")
  for (file in list.files(path, recursive = TRUE, all.files = TRUE,
                          no.. = TRUE, include.dirs = TRUE, full.names = TRUE)) app_no_symlink(file)
  hashes <- as.list(unname(tools::sha256sum(file.path(path, files))))
  names(hashes) <- files
  if (anyNA(unlist(hashes))) app_abort("Package fingerprint failed.", "integrity")
  app_digest(hashes)
}

app_platform <- function() {
  if (!(Sys.info()[["sysname"]] %in% c("Darwin", "Linux")))
    app_abort("This recipe is validated only on local macOS/Linux filesystems.", "environment")
  list(R = as.character(getRversion()), platform = R.version$platform)
}

app_setup <- function(environment_dir, model = NULL, model_alias = NULL,
                      model_sha256 = NULL, relm_library = NULL) {
  started <- proc.time()[["elapsed"]]
  platform <- app_platform()
  if (!is.null(relm_library)) .libPaths(c(normalizePath(relm_library, mustWork = TRUE), .libPaths()))
  app_require_json()
  if (!is.null(model_alias) && !is.null(model_sha256)) app_abort("Choose a model alias OR an expected SHA256.")
  if (is.null(model_alias) && is.null(model_sha256)) model_alias <- "spark-x2.5-4b-q8_0"
  packages <- c("relm", "nanoarrow", "jsonlite")
  sources <- setNames(lapply(packages, function(pkg) find.package(pkg, quiet = FALSE)), packages)
  versions <- lapply(sources, function(path) unname(read.dcf(file.path(path, "DESCRIPTION"), "Version")[[1L]]))
  if (versions$relm != "0.2.0.9000" || versions$jsonlite != "2.0.0")
    app_abort("This recipe requires relm 0.2.0.9000 and jsonlite 2.0.0; select the checked library.", "environment")
  if (!requireNamespace("relm", quietly = TRUE) || !"schema" %in% names(formals(relm::llm_generate)))
    app_abort("The selected relm build lacks constrained generation.", "environment")
  if (!is.null(model_alias)) {
    registry <- utils::read.csv(file.path(sources$relm, "models.csv"), colClasses = "character")
    row <- registry[registry$alias == model_alias, , drop = FALSE]
    if (nrow(row) != 1L) app_abort("Unknown pinned model alias.")
    model_sha256 <- row$sha256
  }
  if (!is.character(model_sha256) || length(model_sha256) != 1L ||
      !grepl("^[0-9a-f]{64}$", model_sha256)) app_abort("Supply a lowercase expected SHA256.")
  parent <- dirname(path.expand(environment_dir))
  if (!dir.exists(parent) && !dir.create(parent, recursive = TRUE)) app_abort("Cannot create environment parent.")
  target <- file.path(normalizePath(parent, mustWork = TRUE), basename(environment_dir))
  app_no_symlink(target)
  if (file.exists(target)) app_abort("Environment already exists; choose a new directory.", "environment")
  stage <- tempfile(".prepare-", tmpdir = dirname(target))
  if (!dir.create(stage, mode = "0700")) app_abort("Cannot stage environment.")
  on.exit(unlink(stage, recursive = TRUE), add = TRUE)
  library <- file.path(stage, "library")
  dir.create(library)
  pinned <- setNames(vector("list", length(packages)), packages)
  for (pkg in packages) {
    before <- app_package_fingerprint(sources[[pkg]])
    if (!file.copy(sources[[pkg]], library, recursive = TRUE, copy.mode = TRUE))
      app_abort(paste("Cannot snapshot package:", pkg), "environment")
    copied <- app_package_fingerprint(file.path(library, pkg))
    if (!identical(before, copied)) app_abort("Package changed during setup.", "integrity")
    pinned[[pkg]] <- list(version = versions[[pkg]], sha256 = copied)
  }
  if (is.null(model)) {
    if (is.null(model_alias)) app_abort("Custom models require a local --model file.")
    # Explicit setup is the sole network-capable path; use the checksummed registry.
    model <- relm::llm_download(model_alias, dir = file.path(dirname(target), "models"))
  }
  model <- normalizePath(model, mustWork = TRUE)
  if (!identical(app_sha256(model), model_sha256)) app_abort("Model SHA256 mismatch.", "integrity")
  if (!is.null(model_alias) && sprintf("%.0f", file.info(model)$size) != row$size_bytes)
    app_abort("Model size does not match registry.", "integrity")
  manifest <- list(format_version = 1L, R = platform$R, platform = platform$platform,
                   packages = pinned,
                   model = list(path = model, sha256 = model_sha256,
                                size_bytes = sprintf("%.0f", file.info(model)$size), alias = model_alias),
                   setup_elapsed_seconds = sprintf("%.6f", proc.time()[["elapsed"]] - started))
  app_write_atomic(manifest, file.path(stage, "environment.json"))
  if (!file.rename(stage, target)) app_abort("Could not publish prepared environment.", "filesystem")
  invisible(manifest)
}

app_environment <- function(dir) {
  platform <- app_platform()
  dir <- normalizePath(dir, mustWork = TRUE)
  app_no_symlink(dir)
  library <- file.path(dir, "library")
  app_no_symlink(library)
  .libPaths(c(library, .libPaths()))
  for (pkg in c("relm", "nanoarrow", "jsonlite")) {
    if (pkg %in% loadedNamespaces() &&
        normalizePath(getNamespaceInfo(asNamespace(pkg), "path")) !=
        normalizePath(file.path(library, pkg), mustWork = TRUE))
      app_abort(paste("Use a fresh R session; an unprepared namespace is already loaded:", pkg), "environment")
  }
  manifest <- app_read_json(file.path(dir, "environment.json"))
  app_object(manifest, c("format_version", "R", "platform", "packages", "model", "setup_elapsed_seconds"), "environment")
  if (!identical(manifest$format_version, 1L) || manifest$R != platform$R || manifest$platform != platform$platform)
    app_abort("Prepared environment belongs to another R/platform; run setup in a new directory.", "environment")
  app_object(manifest$packages, c("relm", "nanoarrow", "jsonlite"), "package pins")
  for (pkg in names(manifest$packages)) {
    pin <- manifest$packages[[pkg]]
    app_object(pin, c("version", "sha256"), "package pin")
    path <- file.path(library, pkg)
    if (!identical(app_package_fingerprint(path), pin$sha256) ||
        unname(read.dcf(file.path(path, "DESCRIPTION"), "Version")[[1L]]) != pin$version)
      app_abort(paste("Prepared package changed:", pkg), "integrity")
  }
  if (manifest$packages$jsonlite$version != "2.0.0" || manifest$packages$relm$version != "0.2.0.9000")
    app_abort("Unsupported prepared package versions.", "environment")
  app_object(manifest$model, c("path", "sha256", "size_bytes", "alias"), "model pin")
  model <- app_string(manifest$model$path, "model path")
  if (!identical(app_sha256(model), manifest$model$sha256) ||
      sprintf("%.0f", file.info(model)$size) != manifest$model$size_bytes)
    app_abort("Prepared model changed; run setup in a new directory.", "integrity")
  list(path = dir, library = library, manifest = manifest, model = model)
}

app_config <- function(path) {
  path <- normalizePath(path, mustWork = TRUE)
  x <- app_read_json(path)
  app_object(x, c("format_version", "prompt", "schema", "documents", "backend", "context",
                  "max_tokens", "temperature", "top_p", "chat"), "configuration")
  if (!identical(x$format_version, 1L)) app_abort("Unsupported configuration format.")
  if (!is.character(x$backend) || length(x$backend) != 1L || !x$backend %in% c("cpu", "metal"))
    app_abort("Choose an explicit cpu or metal backend.")
  x$context <- app_integer(x$context, "context", 128L, 32768L)
  x$max_tokens <- app_integer(x$max_tokens, "max_tokens", 1L, x$context)
  for (key in c("temperature", "top_p")) {
    value <- app_string(x[[key]], key)
    if (!grepl("^(0|[1-9][0-9]*)(\\.[0-9]+)?$", value) ||
        !is.finite(as.numeric(value)) || as.numeric(value) > (if (key == "top_p") 1 else 2) ||
        (key == "top_p" && as.numeric(value) <= 0)) app_abort(paste("Invalid decimal string:", key))
  }
  if (!is.logical(x$chat) || length(x$chat) != 1L || is.na(x$chat)) app_abort("chat must be a boolean.")
  for (key in c("prompt", "schema", "documents")) {
    file <- app_string(x[[key]], key)
    if (!startsWith(file, "/")) file <- file.path(dirname(path), file)
    x[[key]] <- normalizePath(file, mustWork = TRUE)
  }
  x$prompt_text <- app_read_text(x$prompt, 1048576L)
  for (marker in c("{{target}}", "{{text}}", "{{schema}}")) {
    hits <- gregexpr(marker, x$prompt_text, fixed = TRUE)[[1L]]
    if (length(hits) != 1L || hits[[1L]] < 0L) app_abort(paste("Prompt must contain one", marker))
  }
  x$schema_text <- app_read_text(x$schema, 1048576L)
  app_read_json(x$schema) # Literal parsing/duplicate-key check before native use.
  x$inputs <- app_read_json(x$documents)
  if (!is.list(x$inputs) || !is.null(names(x$inputs)) || !length(x$inputs) || length(x$inputs) > 10000L)
    app_abort("documents must be a nonempty array with at most 10,000 entries.")
  for (doc in x$inputs) {
    app_object(doc, c("id", "target", "text", "seed"), "document")
    id <- app_string(doc$id, "document ID", limit = 64L)
    if (!grepl("^[A-Za-z0-9][A-Za-z0-9_-]*$", id)) app_abort("Document IDs must be safe ASCII filenames.")
    app_string(doc$target, "target", limit = 4096L)
    app_string(doc$text, "document text", limit = 1048576L)
    app_integer(doc$seed, "seed", 0L)
  }
  if (anyDuplicated(vapply(x$inputs, `[[`, "", "id"))) app_abort("Duplicate document ID.")
  x
}

app_source <- function(doc) app_digest(list(target = doc$target, text = doc$text))

app_identity <- function(prepared, config) {
  native <- list.files(file.path(prepared$library, "relm", "libs"), pattern = "\\.(so|dylib)$", full.names = TRUE)
  if (length(native) != 1L) app_abort("Expected one installed native library.", "environment")
  list(format_version = 1L,
       build = list(relm = prepared$manifest$packages$relm$version, native = app_sha256(native),
                    R = prepared$manifest$R, platform = prepared$manifest$platform,
                    backend = config$backend, application_sha256 = app_sha256(app_module),
                    environment_sha256 = app_sha256(file.path(prepared$path, "environment.json"))),
       model_sha256 = prepared$manifest$model$sha256, projector_sha256 = NULL,
       schema_sha256 = app_sha256(config$schema), prompt_sha256 = app_sha256(config$prompt),
       sampling = list(temperature = config$temperature, top_p = config$top_p,
                       max_tokens = config$max_tokens, chat = config$chat, context_length = config$context),
       documents = lapply(config$inputs, function(doc) list(id = doc$id, source_sha256 = app_source(doc), seed = doc$seed)))
}

app_lock <- function(output_dir) {
  path <- file.path(output_dir, ".lock")
  app_no_symlink(path)
  if (!dir.create(path, mode = "0700", showWarnings = FALSE))
    app_abort("Run is locked. Stop/verify the owner before explicit lock recovery.", "locked")
  owner <- list(nonce = app_nonce(), hostname = unname(Sys.info()[["nodename"]]),
                pid = as.integer(Sys.getpid()), started_at = format(Sys.time(), tz = "UTC", usetz = TRUE))
  app_write_atomic(owner, file.path(path, "owner.json"))
  owner
}

app_unlock <- function(output_dir, owner) {
  path <- file.path(output_dir, ".lock")
  tryCatch({
    app_no_symlink(path)
    current <- app_read_json(file.path(path, "owner.json"))
    if (!identical(current$nonce, owner$nonce)) return(invisible(FALSE))
    entries <- list.files(path, all.files = TRUE, no.. = TRUE)
    if (!identical(entries, "owner.json")) return(invisible(FALSE))
    unlink(file.path(path, "owner.json"))
    unlink(path, recursive = TRUE)
    invisible(TRUE)
  }, error = function(e) invisible(FALSE))
}

app_recover_lock <- function(output_dir, nonce, confirm_owner_stopped = FALSE) {
  if (!isTRUE(confirm_owner_stopped)) app_abort("Explicit confirmation that all writers are stopped is required.", "locked")
  path <- file.path(normalizePath(output_dir, mustWork = TRUE), ".lock")
  app_no_symlink(path)
  if (!dir.exists(path)) app_abort("No lock to recover.", "locked")
  entries <- list.files(path, all.files = TRUE, no.. = TRUE)
  if (!"owner.json" %in% entries &&
      all(grepl("^\\.tmp-[0-9a-f]{32}$", entries))) {
    if (!identical(nonce, "empty")) app_abort("Empty lock requires the literal recovery nonce 'empty'.", "locked")
  } else {
    owner <- app_read_json(file.path(path, "owner.json"))
    app_object(owner, c("nonce", "hostname", "pid", "started_at"), "lock owner")
    app_integer(owner$pid, "owner PID", 1L)
    if (!identical(owner$nonce, nonce) || !identical(owner$hostname, unname(Sys.info()[["nodename"]])))
      app_abort("Lock nonce or host mismatch; refusing recovery.", "locked")
    if (isTRUE(tools::pskill(owner$pid, 0L))) app_abort("Lock owner PID is still alive; refusing recovery.", "locked")
  }
  # Operator must stop all writers/recoverers; this is not concurrent lock stealing.
  quarantine <- file.path(output_dir, paste0(".recovered-lock-", app_nonce()))
  if (!file.rename(path, quarantine)) app_abort("Could not quarantine abandoned lock.", "locked")
  invisible(quarantine)
}

app_validate_output <- function(x, text) {
  fields <- c("amount_usd", "amount_qualifier", "duration_years", "conditional_on_funds")
  app_object(x, c(fields, "evidence"), "extracted output")
  app_object(x$evidence, fields, "evidence")
  if (!is.null(x$amount_usd)) app_integer(x$amount_usd, "amount_usd")
  if (!is.null(x$duration_years)) app_integer(x$duration_years, "duration_years", 1L, 30L)
  qualifier <- app_string(x$amount_qualifier, "amount_qualifier")
  if (!qualifier %in% c("stated", "approximate", "at_most", "less_than", "at_least", "more_than", "not_stated"))
    app_abort("Invalid amount qualifier.")
  if (!is.null(x$conditional_on_funds) && (!is.logical(x$conditional_on_funds) ||
      length(x$conditional_on_funds) != 1L || is.na(x$conditional_on_funds))) app_abort("Invalid conditional_on_funds.")
  if (is.null(x$amount_usd) != (qualifier == "not_stated")) app_abort("Amount/qualifier missingness mismatch.")
  for (field in fields) {
    missing <- is.null(x[[field]]) || identical(x[[field]], "not_stated")
    evidence <- x$evidence[[field]]
    if (is.null(evidence) != missing) app_abort("Value/evidence missingness mismatch.")
    if (!is.null(evidence)) {
      app_string(evidence, "evidence")
      if (nchar(evidence, type = "chars") > 512L || !grepl(evidence, text, fixed = TRUE))
        app_abort("Evidence must be an exact source quote of at most 512 characters.")
    }
  }
  invisible(x)
}

app_check_result <- function(record, doc, identity) {
  keys <- c("id", "run_identity", "source_sha256", "seed", "state", "status", "output",
            "output_sha256", "raw_output", "error", "elapsed_seconds", "record_sha256")
  app_object(record, keys, "committed result")
  core <- record[setdiff(names(record), "record_sha256")]
  if (!identical(record$record_sha256, app_digest(core)) || !identical(record$id, doc$id) ||
      !identical(record$run_identity, identity) || !identical(record$source_sha256, app_source(doc)) ||
      !identical(record$seed, doc$seed) || !identical(record$state, "committed") ||
      !is.character(record$status) || length(record$status) != 1L ||
      !record$status %in% c("success", "invalid", "error"))
    app_abort("Corrupt or stale committed result; refusing reuse.", "integrity")
  if (record$status == "success") {
    app_validate_output(record$output, doc$text)
    if (!is.null(record$error) || !identical(record$output_sha256, app_digest(record$output)) ||
        !identical(app_canonical(app_parse_json(record$raw_output)), app_canonical(record$output)))
      app_abort("Committed output digest/raw output mismatch.", "integrity")
  } else {
    if (!is.null(record$output) || !is.null(record$output_sha256)) app_abort("Failure contains accepted output.", "integrity")
    app_object(record$error, c("class", "message"), "failure detail")
    app_string(record$error$class, "error class"); app_string(record$error$message, "error message")
    if (record$status == "invalid") app_string(record$raw_output, "invalid output", empty = TRUE)
    if (record$status == "error" && !is.null(record$raw_output)) app_abort("Generation error contains output.", "integrity")
  }
  app_string(record$elapsed_seconds, "elapsed seconds")
  invisible(record)
}

app_engine <- function(prepared, config) {
  .libPaths(c(prepared$library, .libPaths()))
  if (!requireNamespace("relm", quietly = TRUE) ||
      normalizePath(getNamespaceInfo(asNamespace("relm"), "path")) !=
      normalizePath(file.path(prepared$library, "relm")))
    app_abort("Use a fresh R session with the prepared relm library.", "environment")
  model <- relm::llm(prepared$model, context_length = config$context, backend = config$backend)
  list(generate = function(prompt, seed) {
    relm::llm_generate(model, prompt, max_tokens = config$max_tokens,
                       temperature = as.numeric(config$temperature), top_p = as.numeric(config$top_p),
                       seed = seed, chat = config$chat, schema = config$schema_text)[[1L]]
  }, close = function() close(model))
}

app_prompt <- function(config, doc) {
  # Split the template first: source text containing placeholders is never expanded.
  markers <- "\\{\\{(target|text|schema)\\}\\}"
  positions <- gregexpr(markers, config$prompt_text, perl = TRUE)[[1L]]
  lengths <- attr(positions, "match.length")
  values <- list("{{target}}" = doc$target, "{{text}}" = doc$text, "{{schema}}" = config$schema_text)
  out <- ""; start <- 1L
  for (i in seq_along(positions)) {
    pos <- positions[[i]]; end <- pos + lengths[[i]] - 1L
    key <- substr(config$prompt_text, pos, end)
    out <- paste0(out, if (pos > start) substr(config$prompt_text, start, pos - 1L) else "", values[[key]])
    start <- end + 1L
  }
  paste0(out, substr(config$prompt_text, start, nchar(config$prompt_text)))
}

app_event <- function(output_dir, event, id, status = NULL, error_class = NULL) {
  value <- list(time = format(Sys.time(), tz = "UTC", usetz = TRUE), event = event,
                id = id, status = status, error_class = error_class)
  path <- file.path(output_dir, "events.jsonl")
  app_no_symlink(path)
  # Leading newline isolates a previous partial write. Events are diagnostic only.
  cat(paste0("\n", app_canonical(value), "\n"), file = path, append = TRUE)
}

app_table <- function(records) {
  fields <- c("amount_usd", "amount_qualifier", "duration_years", "conditional_on_funds")
  rows <- lapply(records, function(record) {
    value <- record$output
    row <- list(id = record$id, status = record$status)
    for (field in fields) row[[field]] <- if (is.null(value[[field]])) NA else value[[field]]
    for (field in fields) row[[paste0("evidence_", field)]] <- if (is.null(value$evidence[[field]])) NA_character_ else value$evidence[[field]]
    row$error_class <- if (is.null(record$error)) NA_character_ else record$error$class
    row$error_message <- if (is.null(record$error)) NA_character_ else record$error$message
    as.data.frame(row, stringsAsFactors = FALSE)
  })
  do.call(rbind, rows)
}

app_run <- function(config_path, environment_dir, output_dir, engine_factory = app_engine,
                    checkpoint = function(stage, id) invisible(NULL)) {
  started <- proc.time()[["elapsed"]]
  prepared <- app_environment(environment_dir)
  config <- app_config(config_path)
  run_config <- app_identity(prepared, config)
  identity <- app_digest(run_config)
  output_dir <- path.expand(output_dir)
  app_no_symlink(output_dir)
  if (!dir.exists(output_dir) && !dir.create(output_dir, recursive = TRUE, mode = "0700"))
    app_abort("Cannot create output directory.", "filesystem")
  output_dir <- normalizePath(output_dir, mustWork = TRUE)
  owner <- app_lock(output_dir)
  on.exit(app_unlock(output_dir, owner), add = TRUE)
  manifest_path <- file.path(output_dir, "manifest.json")
  records_dir <- file.path(output_dir, "records")
  app_no_symlink(manifest_path); app_no_symlink(records_dir)
  manifest <- list(config = run_config, run_identity = identity)
  if (file.exists(manifest_path)) {
    existing <- app_read_json(manifest_path)
    if (!identical(app_canonical(existing), app_canonical(manifest)))
      app_abort("Run configuration or inputs changed; choose a new output directory.", "stale")
  } else {
    entries <- list.files(output_dir, all.files = TRUE, no.. = TRUE)
    allowed <- entries == ".lock" | grepl("^\\.tmp-[0-9a-f]{32}$|^\\.recovered-lock-[0-9a-f]{32}$", entries)
    if (any(!allowed)) app_abort("Nonempty output directory has no manifest.", "integrity")
    app_write_atomic(manifest, manifest_path)
  }
  if (!dir.exists(records_dir) && !dir.create(records_dir)) app_abort("Cannot create records directory.", "filesystem")
  expected <- paste0(vapply(config$inputs, `[[`, "", "id"), ".json")
  entries <- list.files(records_dir, all.files = TRUE, no.. = TRUE)
  if (any(!entries %in% expected & !grepl("^\\.tmp-[0-9a-f]{32}$", entries)))
    app_abort("Unknown file in records directory.", "integrity")
  records <- vector("list", length(config$inputs))
  # Check every committed file before loading a model or adding a result.
  for (i in seq_along(records)) {
    path <- file.path(records_dir, expected[[i]])
    app_no_symlink(path)
    if (file.exists(path)) {
      records[[i]] <- app_read_json(path)
      app_check_result(records[[i]], config$inputs[[i]], identity)
    }
  }
  pending <- which(vapply(records, is.null, logical(1)))
  first_result <- NULL
  if (length(pending)) {
    engine <- engine_factory(prepared, config)
    on.exit(engine$close(), add = TRUE)
    for (i in pending) {
      doc <- config$inputs[[i]]
      app_event(output_dir, "started", doc$id)
      before <- proc.time()[["elapsed"]]
      raw <- NULL; output <- NULL; detail <- NULL; status <- "success"
      generated <- tryCatch(engine$generate(app_prompt(config, doc), doc$seed), error = function(e) e)
      if (inherits(generated, "error")) {
        status <- "error"; detail <- list(class = class(generated)[[1L]], message = conditionMessage(generated))
      } else {
        raw <- app_string(generated, "generated output", empty = TRUE, limit = 8388608L)
        parsed <- tryCatch({ value <- app_parse_json(raw); app_validate_output(value, doc$text); value }, error = function(e) e)
        if (inherits(parsed, "error")) {
          status <- "invalid"; detail <- list(class = class(parsed)[[1L]], message = conditionMessage(parsed))
        } else output <- parsed
      }
      record <- list(id = doc$id, run_identity = identity, source_sha256 = app_source(doc), seed = doc$seed,
                     state = "committed", status = status, output = output,
                     output_sha256 = if (is.null(output)) NULL else app_digest(output), raw_output = raw,
                     error = detail, elapsed_seconds = sprintf("%.6f", proc.time()[["elapsed"]] - before))
      record$record_sha256 <- app_digest(record)
      app_check_result(record, doc, identity)
      app_write_atomic(record, file.path(records_dir, expected[[i]]),
                       before = function() checkpoint("before_record_rename", doc$id),
                       after = function() checkpoint("after_record_rename", doc$id))
      records[[i]] <- record
      if (is.null(first_result)) first_result <- sprintf("%.6f", proc.time()[["elapsed"]] - started)
      app_event(output_dir, "committed", doc$id, status, if (is.null(detail)) NULL else detail$class)
    }
  }
  result <- app_table(records)
  csv <- file.path(output_dir, "results.csv")
  app_no_symlink(csv)
  temporary <- file.path(output_dir, paste0(".tmp-", app_nonce()))
  on.exit(unlink(temporary), add = TRUE)
  utils::write.csv(result, temporary, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  if (!file.rename(temporary, csv)) app_abort("Cannot publish derived CSV.", "filesystem")
  summary <- list(run_identity = identity, documents = length(records), processed = length(pending),
                  reused = length(records) - length(pending),
                  success = sum(result$status == "success"), invalid = sum(result$status == "invalid"),
                  errors = sum(result$status == "error"),
                  first_result_seconds = first_result,
                  elapsed_seconds = sprintf("%.6f", proc.time()[["elapsed"]] - started))
  app_write_atomic(summary, file.path(output_dir, "summary.json"), replace = TRUE)
  attr(result, "run_summary") <- summary
  result
}

app_options <- function(args, values, flags = character()) {
  result <- list()
  while (length(args)) {
    key <- sub("^--", "", args[[1L]])
    if (!startsWith(args[[1L]], "--") || !key %in% c(values, flags) || key %in% names(result))
      app_abort(paste("Unknown or repeated option:", args[[1L]]))
    args <- args[-1L]
    if (key %in% flags) result[[key]] <- TRUE else {
      if (!length(args) || startsWith(args[[1L]], "--")) app_abort(paste("Missing value for", key))
      result[[key]] <- args[[1L]]; args <- args[-1L]
    }
  }
  result
}

app_cli <- function(code) {
  tryCatch(force(code), error = function(e) {
    cat(sprintf("Error [%s]: %s\n", class(e)[[1L]], conditionMessage(e)), file = stderr())
    quit(save = "no", status = 1L)
  })
}
