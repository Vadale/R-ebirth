# Frozen F6e-v1 producer. One original CPU model, one derived owner at a time.
# This script never chooses metrics or coefficients itself: the independent
# verifier locks selection before the first final inference.
options(warn = 1, digits = 17)
f6e_csv <- function(x, path) write.table(x, path, sep = ',', quote = TRUE,
  row.names = FALSE, col.names = TRUE, na = '', fileEncoding = 'UTF-8', eol = '\n')
f6e_hash <- function(path) unname(tools::sha256sum(path))
f6e_json <- function(x, path) jsonlite::write_json(x, path, auto_unbox = TRUE,
  null = 'null', na = 'null', digits = NA, pretty = TRUE)
f6e_text <- function(x, path) writeBin(charToRaw(enc2utf8(as.character(x))), path)
f6e_descriptor <- function(path) list(file = path, sha256 = f6e_hash(path))
f6e_empty_events <- function() data.frame(event_id = integer(), event = character(),
  prompt_id = integer(), token_pos = integer(), token_id = integer(), text = character(),
  elapsed = double(), finish_reason = character(), validated = logical())
# Lossless typed data, independent of product canonical serialization. IEEE
# bytes keep all double bits, including signed zero, through the JSON transport.
f6e_node <- function(x, vector = FALSE) {
  if (is.null(x)) return(list('N', NULL))
  if (is.matrix(x)) return(list('M', list(nrow(x), ncol(x), as.list(rownames(x)),
    as.list(colnames(x)), lapply(as.vector(t(x)), function(v) paste(sprintf('%02x',
      as.integer(writeBin(v, raw(), size = 8L, endian = 'little'))), collapse = '')))))
  if (is.data.frame(x)) return(list('F', unname(lapply(names(x), function(k)
    list(k, f6e_node(x[[k]], TRUE))))))
  if (is.list(x)) return(list('R', unname(lapply(names(x), function(k)
    list(k, f6e_node(x[[k]], k %in% c('neuron', 'value')))))))
  tag <- switch(typeof(x), logical = 'L', integer = 'I', double = 'D', character = 'S',
    stop('Unsupported typed node'))
  values <- if (typeof(x) == 'double') lapply(x, function(v) paste(sprintf('%02x',
    as.integer(writeBin(v, raw(), size = 8L, endian = 'little'))), collapse = '')) else as.list(unname(x))
  scalar <- !vector && length(x) == 1L
  list(if (scalar) tag else tolower(tag), if (scalar) values[[1L]] else values)
}
f6e_setting <- function(setting, selected = NULL) {
  if (setting == 'baseline') return(list(operator = 'none', coefficient = 0, artifact = ''))
  if (setting == 'random_project_1') return(list(operator = 'project', coefficient = 1, artifact = 'random_mlp'))
  if (startsWith(setting, 'zero_')) { op <- sub('zero_', '', setting); coef <- 0
  } else if (startsWith(setting, 'selected_')) { op <- sub('selected_', '', setting); coef <- selected[[op]]
  } else { bits <- strsplit(setting, '_', fixed = TRUE)[[1L]]; op <- bits[[1L]]; coef <- as.double(bits[[2L]]) }
  stopifnot(op %in% c('add', 'project'), length(coef) == 1L, is.finite(coef))
  list(operator = op, coefficient = coef, artifact = if (op == 'add') 'residual' else 'mlp')
}
f6e_main <- function() {
  args <- commandArgs(TRUE); stopifnot(length(args) == 1L)
  out <- normalizePath(args[[1L]]); cfg <- jsonlite::read_json(file.path(out, 'config.json'))
  setwd(out)
  library(relm)
  stopifnot(normalizePath(find.package('relm')) == normalizePath(cfg$library),
    f6e_hash(getLoadedDLLs()[['relm']][['path']]) == cfg$dll_sha256,
    f6e_hash(cfg$model) == cfg$model_sha256)
  for (d in c('captures', 'artifacts', 'raw', 'states')) dir.create(d)
  schema <- jsonlite::read_json(cfg$schema, simplifyVector = TRUE)
  manifest <- jsonlite::read_json(cfg$manifest, simplifyVector = TRUE)
  prompts <- read.csv(cfg$prompts, stringsAsFactors = FALSE, check.names = FALSE,
    fileEncoding = 'UTF-8', na.strings = character())
  counts <- list(load = 0L, trace = 0L, derive = 0L, generate = 0L)
  increment <- function(k) { counts[[k]] <<- counts[[k]] + 1L; f6e_json(counts, 'attempt-counts.json') }
  stage <- function(name, details = list()) {
    f6e_json(c(list(status = 'running', stage = name, updated_unix = as.double(Sys.time()),
      counts_are = 'attempts'), details), cfg$status)
    cat('F6E_EVALUATION_STAGE ', name, '\n', sep = ''); flush.console()
  }
  helper <- function(stage) {
    rc <- system2(cfg$python, c(shQuote(cfg$collector), stage, shQuote(out)))
    if (rc != 0L) stop('Independent evidence stage failed: ', stage)
  }
  warnings <- list()
  condition_log <- function(w) {
    warnings[[length(warnings) + 1L]] <<- list(class = class(w), message = conditionMessage(w))
    f6e_json(warnings, 'warnings.json')
  }
  withCallingHandlers({
    # Initialization first: the product Once logger must not replace this adapter.
    relm:::rebirth_available_backends()
    shim <- dyn.load(cfg$logger)
    started <- .C('f6e_log_start', as.character(getLoadedDLLs()[['relm']][['path']]),
      file.path(out, 'native-placement.log'), status = integer(1), PACKAGE = shim[['name']])$status
    stopifnot(started == 0L)
    # Registered before model on.exit: native owners are closed before logger stop.
    on.exit({ result <- .C('f6e_log_stop', status = integer(1), PACKAGE = shim[['name']])$status
      if (result != 0L) warning('Placement logger teardown failed') }, add = TRUE, after = TRUE)
    stage('load_cpu'); increment('load')
    m <- llm(cfg$model, backend = 'cpu', context_length = 512L)
    on.exit(close(m), add = TRUE, after = FALSE)
    stopifnot(identical(m$backend, 'cpu'), m$hidden_size == 896, m$layers == 24)
    f6e_json(list(backend = m$backend, model_sha256 = f6e_hash(cfg$model),
      architecture = m$architecture, context_length = m$context_length,
      hidden_size = m$hidden_size, layers = m$layers), 'loaded-metadata.json')
    helper('cpu') # Actual native buffer/offload receipts, before any inference.
    record <- list(sha256 = cfg$model_sha256, architecture = m$architecture,
      quantization = m$quantization, hidden_size = as.integer(m$hidden_size),
      layers = as.integer(m$layers), engine_revision = 'b10828-patched-D039-D040')
    f6e_json(list(package_version = as.character(packageVersion('relm')),
      r_version = as.character(getRversion()), engine_revision = record$engine_revision), 'runtime.json')
    writeLines(capture.output(sessionInfo()), 'session-info.txt')
    RNGkind('Mersenne-Twister', 'Inversion', 'Rejection')
    set.seed(1046); signs <- sample(rep(c(-1L, 1L), each = 6L))
    set.seed(2046); bootstrap <- t(replicate(2000L, sample.int(8L, 8L, replace = TRUE)))
    colnames(bootstrap) <- paste0('draw', 1:8)
    f6e_csv(data.frame(replicate = 1:2000, bootstrap), 'bootstrap.csv')
    construction <- prompts[prompts$split == 'construction', ]
    ids <- construction$item_id[construction$role == 'target']
    f6e_csv(data.frame(item_id = ids, sign = signs), 'random-signs.csv')
    # Existing approved canonical matrix materialization bound plus the exact
    # installed trace expansion formula, evaluated before the four matrices.
    h <- as.integer(m$hidden_size); n <- 12L
    matrix_bound <- 8 * as.double(n) * h + 2^20 + 136 * n + 16 * h
    trace_bound <- 2 * h * 4 * relm:::TRACE_MATERIALIZED_EXPANSION
    stopifnot(4 * matrix_bound + trace_bound <= 64 * 1024^2)
    f6e_json(list(matrix_bound_each = matrix_bound, matrices = 4L,
      trace_bound = trace_bound, sum = 4 * matrix_bound + trace_bound,
      max_bytes = 64 * 1024^2, scope = 'four construction matrices plus one materialized trace'), 'capture-preflight.json')
    new_matrix <- function() matrix(0, n, h, dimnames = list(ids, as.character(seq_len(h))))
    matrices <- list(residual = list(target = new_matrix(), control = new_matrix()),
      mlp = list(target = new_matrix(), control = new_matrix()))
    positions <- integer(24L); construction_rows <- list()
    stage('construction')
    for (i in seq_len(nrow(construction))) {
      item <- construction[i, ]; increment('trace')
      tr <- llm_trace(m, item$prompt, layers = 12L, components = c('residual', 'mlp_out'),
        positions = 'last', spill = FALSE, max_bytes = trace_bound)
      stopifnot(nrow(tr) == 2L * h, length(unique(tr$token_pos)) == 1L)
      positions[[i]] <- unique(tr$token_pos)
      for (key in c('residual', 'mlp')) {
        component <- if (key == 'mlp') 'mlp_out' else 'residual'
        rows <- tr[tr$component == component, ]
        stopifnot(identical(rows$neuron, seq_len(h)), all(is.finite(rows$value)))
        matrices[[key]][[item$role]][match(item$item_id, ids), ] <- rows$value
      }
      file <- sprintf('captures/%02d.rds', i); saveRDS(tr, file)
      construction_rows[[i]] <- data.frame(item_id = item$item_id, role = item$role,
        prompt_sha256 = item$prompt_sha256, source_pos = positions[[i]],
        capture_file = file, capture_sha256 = f6e_hash(file))
      f6e_csv(do.call(rbind, construction_rows), 'construction.csv')
      rm(tr, rows); gc(FALSE)
    }
    pair <- data.frame(pair_id = ids, target_sha256 = construction$prompt_sha256[seq(1,24,2)],
      control_sha256 = construction$prompt_sha256[seq(2,24,2)],
      target_pos = positions[seq(1,24,2)], control_pos = positions[seq(2,24,2)])
    context <- function(component, pairs) list(model = record, capture = list(component = component,
      positions = 'last', input_format = 'raw_text', tokenizer = 'gguf_embedded', add_special = TRUE,
      parse_special = FALSE, template_sha256 = NULL, context_length = 512L, backend = 'cpu',
      relm_version = as.character(packageVersion('relm'))), pairs = pairs,
      splits = data.frame(prompt_sha256 = prompts$prompt_sha256, split = prompts$split), seed = NULL)
    artifacts <- list(); pair_rows <- list()
    for (key in c('residual', 'mlp', 'random_mlp')) {
      comp <- if (key == 'residual') 'residual' else 'mlp_out'
      input <- matrices[[if (key == 'random_mlp') 'mlp' else key]]; p <- pair
      if (key == 'random_mlp') for (i in which(signs == -1L)) {
        temp <- input$target[i, ]; input$target[i, ] <- input$control[i, ]; input$control[i, ] <- temp
        for (field in c('sha256', 'pos')) {
          a <- paste0('target_', field); b <- paste0('control_', field)
          temp <- p[i,a]; p[i,a] <- p[i,b]; p[i,b] <- temp
        }
      }
      ctx <- context(comp, p)
      d <- llm_direction(input$target, input$control, ctx, 12L,
        normalize_pairs = FALSE, orthogonalize = FALSE)
      file <- paste0('artifacts/', key, '.rds'); saveRDS(d, file)
      stopifnot(identical(d, readRDS(file)))
      artifacts[[key]] <- readRDS(file)
      saveRDS(list(target = input$target, control = input$control, context = ctx), paste0('artifacts/', key, '-inputs.rds'))
      f6e_json(list(schema = attr(d, 'direction')$schema, digests = attr(d, 'direction')$digests,
        target = f6e_node(input$target), control = f6e_node(input$control),
        pairs = f6e_node(ctx$pairs), splits = f6e_node(ctx$splits),
        values = f6e_node(list(neuron = d$neuron, value = d$value)),
        payload = f6e_node(relm:::direction_payload(d))), paste0('artifacts/', key, '-typed.json'))
      pair_rows[[key]] <- data.frame(artifact = key, item_id = p$pair_id,
        target_sha256 = p$target_sha256, control_sha256 = p$control_sha256,
        target_pos = p$target_pos, control_pos = p$control_pos)
    }
    f6e_csv(do.call(rbind, pair_rows), 'artifact-pairs.csv')
    helper('construction') # Independent arithmetic/encoding, before generation.
    rm(input, matrices, d, temp, ctx); gc(FALSE)
    runs <- list(selection = list(), evaluation = list(), view = list()); states_rows <- list()
    run_one <- function(item, setting, phase, ordinal, run_id, selected = NULL, lock_sha = '') {
      spec <- f6e_setting(setting, selected); events <- list(); states <- list()
      hnd <- m; derived <- FALSE
      on.exit(if (derived) close(hnd), add = TRUE)
      started <- as.double(Sys.time()); elapsed_start <- proc.time()[['elapsed']]
      stage(paste0(phase, '/', run_id), list(item_id = item$item_id, setting = setting))
      done <- FALSE; value <- NULL; err <- NULL; settlements <- 0L; timed_out <- FALSE
      collect_event <- function(e) { events[[length(events) + 1L]] <<- e; NULL }
      collect_state <- function(s) {
        states[[length(states) + 1L]] <<- s
        saveRDS(s, paste0('states/', run_id, '-', length(states), '.rds'))
        if (length(states) == 2L) llm_cancel(hnd)
        if (length(states) > 2L) stop('Unexpected third view state')
        NULL
      }
      tryCatch({
        if (spec$operator != 'none') {
          increment('derive')
          hnd <- llm_apply_direction(m, artifacts[[spec$artifact]], record,
            coef = spec$coefficient, operator = spec$operator, max_bytes = 64 * 1024^2)
          derived <- TRUE
        }
        call <- list(m = hnd, prompt = item$prompt, max_tokens = 256L, temperature = 0,
          top_p = .95, seed = 1046L, chat = FALSE, stop = NULL, images = NULL,
          schema = NULL, async = TRUE, on_token = collect_event)
        if (phase == 'view') call <- c(call, list(on_state = collect_state,
          layers = 12L, components = 'mlp_out', top = 3L, spill = FALSE))
        increment('generate')
        promise <- do.call(llm_generate, call)
        promises::then(promise, function(v) {value <<- v; done <<- TRUE; settlements <<- settlements + 1L; NULL},
          function(e) {err <<- e; done <<- TRUE; settlements <<- settlements + 1L; NULL})
        deadline <- proc.time()[['elapsed']] + 120
        while (!done && proc.time()[['elapsed']] < deadline) later::run_now(.05, loop = later::global_loop())
        if (!done) {
          timed_out <- TRUE; llm_cancel(hnd)
          deadline <- proc.time()[['elapsed']] + 30
          while (!done && proc.time()[['elapsed']] < deadline) later::run_now(.05, loop = later::global_loop())
        }
      }, error = function(e) { err <<- e; done <<- TRUE })
      elapsed <- proc.time()[['elapsed']] - elapsed_start; ended <- as.double(Sys.time())
      ev <- if (length(events)) do.call(rbind, events) else f6e_empty_events()
      ef <- paste0('raw/', run_id, '-events.csv'); f6e_csv(ev, ef)
      saveRDS(list(value = value, error = err, events = ev, settlements = settlements,
        timed_out = timed_out, done = done), paste0('raw/', run_id, '.rds'))
      if (!done) stop('Worker did not settle after watchdog cancellation; raw partial output retained')
      if (is.null(err) && (!identical(settlements, 1L) || timed_out)) stop('Invalid promise settlement')
      status <- if (timed_out) 'timed_out' else if (inherits(err, 'relm_error_cancelled')) 'cancelled' else if (!is.null(err)) 'error' else 'ok'
      tf <- th <- er <- eh <- seed <- ''
      if (status == 'ok') {
        stopifnot(is.character(value), length(value) == 1L, identical(attr(value, 'seed'), 1046))
        seed <- as.character(attr(value, 'seed')); tf <- paste0('raw/', run_id, '.txt')
        f6e_text(value, tf); th <- f6e_hash(tf)
      } else {
        er <- paste0('raw/', run_id, '-error.csv')
        reason <- if (!is.null(err$reason)) as.character(err$reason) else ''
        f6e_csv(data.frame(class = paste(class(err), collapse = ';'), reason = reason,
          message = conditionMessage(err)), er); eh <- f6e_hash(er)
      }
      row <- data.frame(ordinal = ordinal, run_id = run_id, phase = phase, item_id = item$item_id,
        setting = setting, operator = spec$operator, coefficient = spec$coefficient, artifact = spec$artifact,
        artifact_sha256 = if (nzchar(spec$artifact)) f6e_hash(paste0('artifacts/', spec$artifact, '.rds')) else '',
        prompt_sha256 = item$prompt_sha256, request_seed = 1046L, returned_seed = seed, chat = FALSE,
        temperature = 0, top_p = .95, max_tokens = 256L, stop_is_null = TRUE, images_is_null = TRUE,
        schema_is_null = TRUE, async = TRUE, on_state = phase == 'view', watchdog_seconds = 120L,
        status = status, started_unix = started, ended_unix = ended, elapsed_seconds = elapsed,
        text_file = tf, text_sha256 = th, events_file = ef, events_sha256 = f6e_hash(ef),
        error_file = er, error_sha256 = eh, selection_lock_sha256 = lock_sha)
      stopifnot(identical(names(row), schema$runs_columns))
      runs[[phase]][[length(runs[[phase]]) + 1L]] <<- row
      f6e_csv(do.call(rbind, runs[[phase]]), paste0(if (phase == 'view') 'views' else phase, '.csv'))
      if (phase == 'view') for (i in seq_along(states)) {
        s <- states[[i]]; st <- s$step; file <- paste0('states/', run_id, '-', i, '.rds')
        prefix <- if (i == 1L) '' else paste(ev$token_id[ev$event == 'token'][seq_len(i-1L)], collapse = ';')
        states_rows[[length(states_rows)+1L]] <<- data.frame(run_id = run_id, state_id = st$state_id,
          prompt_token_count = attr(s$trace, 'prompt_token_count'), source_pos = st$source_pos,
          source_token_id = st$token_id, generated_prefix_ids = prefix, state_file = file, state_sha256 = f6e_hash(file))
        f6e_csv(do.call(rbind, states_rows), 'view-states.csv')
      }
      cat('F6E_EVALUATION_RUN ', run_id, ' ', status, '\n', sep = ''); flush.console()
    }
    ordinal <- 0L
    for (i in which(prompts$split == 'selection')) for (setting in manifest$selection_settings) {
      ordinal <- ordinal + 1L; run_one(prompts[i, ], setting, 'selection', ordinal, sprintf('s%03d', ordinal))
    }
    helper('selection')
    lock <- jsonlite::read_json('selection-lock.json'); lock_sha <- f6e_hash('selection-lock.json')
    selected <- list(add = lock$selected_add, project = lock$selected_project)
    for (i in which(prompts$split == 'evaluation')) for (setting in manifest$final_settings) {
      ordinal <- ordinal + 1L; run_one(prompts[i, ], setting, 'evaluation', ordinal,
        sprintf('e%03d', ordinal - 72L), selected, lock_sha)
    }
    item <- prompts[prompts$item_id == 'f6e-c01' & prompts$role == 'target', ]
    for (setting in c('baseline', 'selected_project')) {
      ordinal <- ordinal + 1L; run_one(item, setting, 'view', ordinal, sprintf('v%03d', ordinal - 120L), selected, lock_sha)
    }
    close(m)
    stopifnot(counts$load == 1L, counts$trace == 24L, counts$generate <= 122L, ordinal == 122L)
    helper('complete')
    cat('F6E_EVALUATION_PRODUCER_COMPLETE calls=122 captures=24 models=1\n')
  }, warning = condition_log)
}
if (identical(Sys.getenv('F6E_RUN_EVALUATION'), '1')) f6e_main()
