# Source this file, then call run_research_workflow(). No inference on source().
# Repository example only: no new relm export or dependency.
research_prompts <- function() data.frame(
  id = c("pair-a-target", "pair-a-control", "pair-b-target", "pair-b-control",
         "practice", "evaluation"),
  split = c(rep("construction", 4), "selection", "evaluation"),
  text = c(
    "Explain why a bicycle needs brakes in one short sentence.",
    "Explain why a bicycle needs brakes in a detailed paragraph.",
    "Explain what a kitchen thermometer measures in one short sentence.",
    "Explain what a kitchen thermometer measures in a detailed paragraph.",
    "What does a rain gauge measure? Answer in one short sentence.",
    "Why do people use a map when visiting an unfamiliar town? Answer in one short sentence."
  ), stringsAsFactors = FALSE)

research_preflight <- function(model_path, output_dir, engine_revision) {
  fail <- function(message) stop(message, call. = FALSE)
  text <- function(x) is.character(x) && length(x) == 1L && !is.na(x) && nzchar(x)
  if (!text(model_path) || !file.exists(model_path) || dir.exists(model_path))
    fail("Supply an existing cached GGUF file; this example never downloads a model.")
  if (!text(output_dir) || file.exists(output_dir) || dir.exists(output_dir))
    fail("Choose a new output directory; existing results are never overwritten.")
  if (!dir.exists(dirname(output_dir))) fail("Create the output parent directory first.")
  if (!text(engine_revision) || nchar(engine_revision, type = "bytes") > 128L)
    fail("Supply the engine revision recorded for your installed build (at most 128 bytes).")
  if (!requireNamespace("relm", quietly = TRUE)) fail("Install the Phase 6 relm build first.")
  needed <- c("llm_direction", "llm_apply_direction", "llm_compare", "llm_timeline")
  if (!all(needed %in% getNamespaceExports("relm")) ||
      !"operator" %in% names(formals(relm::llm_apply_direction)) ||
      !"on_state" %in% names(formals(relm::llm_generate)))
    fail("This installed relm lacks Phase 6 support. Upgrade and restart R.")
  for (pkg in c("later", "promises")) {
    if (!requireNamespace(pkg, quietly = TRUE)) fail(paste("Install optional package", pkg, "first."))
    minimum <- if (pkg == "later") "1.4.8" else "1.5.0"
    # Resolve the actual loaded namespace, not an earlier empty library directory.
    if (getNamespaceVersion(pkg) < package_version(minimum))
      fail(paste(pkg, "must be at least", minimum))
  }
  checksum <- unname(tools::sha256sum(model_path))
  pinned <- "ca59ca7f13d0e15a8cfa77bd17e65d24f6844b554a7b6c12e07a5f89ff76844e"
  if (!identical(checksum, pinned))
    fail("This bounded walkthrough requires the pinned qwen2.5-0.5b-instruct-q8_0 model.")
  list(model_path = normalizePath(model_path), model_sha256 = checksum,
       output_dir = file.path(normalizePath(dirname(output_dir)), basename(output_dir)),
       engine_revision = engine_revision)
}

research_generate <- function(model, prompt, settings) {
  first <- NULL; history <- NULL; ids <- integer(); done <- FALSE
  value <- NULL; failure <- NULL
  pending <- relm::llm_generate(model, prompt, chat = settings$chat,
    max_tokens = settings$max_tokens, temperature = settings$temperature,
    top_p = settings$top_p, seed = settings$seed, async = TRUE,
    layers = 12L, components = "mlp_out", top = 5L, spill = FALSE,
    on_state = function(state) {
      ids <<- c(ids, state$step$token_id)
      if (is.null(first)) first <<- state
      history <<- relm::llm_timeline(state, history, max_states = 32L)
      NULL
    })
  observer <- promises::then(pending,
    onFulfilled = function(x) { value <<- x; done <<- TRUE; NULL },
    onRejected = function(e) { failure <<- e; done <<- TRUE; NULL })
  deadline <- proc.time()[["elapsed"]] + 120
  while (!done && proc.time()[["elapsed"]] < deadline) later::run_now(0.05)
  if (!done) {
    relm::llm_cancel(model)
    deadline <- proc.time()[["elapsed"]] + 30
    while (!done && proc.time()[["elapsed"]] < deadline) later::run_now(0.05)
    stop("The walkthrough timed out; retained partial files are not completed results.")
  }
  if (!is.null(failure)) stop(failure)
  if (is.null(first)) stop("No live state was delivered; cannot produce the paired observation.")
  list(text = value, first = first, sampled_ids = ids, timeline = history)
}

run_research_workflow <- function(model_path, output_dir, engine_revision,
                                  backend = c("cpu", "metal", "cuda")) {
  backend <- match.arg(backend)
  cfg <- research_preflight(model_path, output_dir, engine_revision)
  if (!dir.create(cfg$output_dir)) stop("Could not create the new output directory.")
  path <- function(name) file.path(cfg$output_dir, name)
  save <- function(x, name) saveRDS(x, path(name), version = 3)
  csv <- function(x, name) write.csv(x, path(name), row.names = FALSE, fileEncoding = "UTF-8")
  hash_text <- function(x) {
    p <- tempfile(); on.exit(unlink(p), add = TRUE)
    writeBin(charToRaw(enc2utf8(x)), p); unname(tools::sha256sum(p))
  }
  figure <- function(name, draw) {
    grDevices::png(path(name), width = 1200, height = 840, res = 120)
    on.exit(grDevices::dev.off(), add = TRUE); draw()
  }
  writeLines("INCOMPLETE: inspect the log and partial files before taking further action.", path("STATUS.txt"))
  writeLines(capture.output(sessionInfo()), path("session-info.txt"))
  prompts <- research_prompts()
  prompts$sha256 <- vapply(prompts$text, hash_text, character(1))
  stopifnot(!anyDuplicated(prompts$sha256))
  csv(prompts, "prompts.csv")
  settings <- list(seed = 1707L, chat = FALSE, temperature = 0, top_p = 0.95,
    max_tokens = 32L, stop = NULL, context_length = 512L, backend = backend,
    relm_version = as.character(getNamespaceVersion("relm")), engine_revision = engine_revision)
  save(settings, "settings.rds")
  # The coefficient is fixed before any generation: this exercise does not tune it.
  conditions <- data.frame(condition = c("original", "zero", "addition", "projection"),
    operator = c("none", "project", "add", "project"), coefficient = c(0, 0, 1, 1))
  csv(conditions, "conditions.csv")
  m <- relm::llm(cfg$model_path, backend = backend, context_length = 512L)
  on.exit(close(m), add = TRUE)
  stopifnot(m$architecture == "qwen2", m$hidden_size == 896L, m$layers == 24L, m$backend == backend)
  record <- list(sha256 = cfg$model_sha256, architecture = m$architecture,
    quantization = m$quantization, hidden_size = as.integer(m$hidden_size),
    layers = as.integer(m$layers), engine_revision = engine_revision)
  save(list(model = record, model_path = cfg$model_path,
    installed_library = normalizePath(find.package("relm")),
    engine_revision_source = "caller-supplied build record; not inferred from model weights"), "provenance.rds")
  dll <- getLoadedDLLs()[["relm"]][["path"]]
  csv(data.frame(path = dll, sha256 = unname(tools::sha256sum(dll))), "installed-dll.csv")
  captures <- lapply(seq_len(4L), function(i) {
    relm::llm_trace(m, prompts$text[[i]], layers = 12L, positions = "last",
      components = c("residual", "mlp_out"), spill = FALSE)
  })
  # Four last-position traces are bounded here by the pinned 896-wide model.
  for (tr in captures) stopifnot(nrow(tr) == 1792L, length(unique(tr$token_pos)) == 1L)
  save(captures, "construction.rds")
  pairs <- data.frame(pair_id = c("pair-a", "pair-b"),
    target_sha256 = prompts$sha256[c(1, 3)], control_sha256 = prompts$sha256[c(2, 4)],
    target_pos = vapply(captures[c(1, 3)], function(x) unique(x$token_pos), integer(1)),
    control_pos = vapply(captures[c(2, 4)], function(x) unique(x$token_pos), integer(1)))
  directions <- lapply(c("residual", "mlp_out"), function(component) {
    rows <- lapply(captures, function(tr) {
      x <- tr[tr$component == component, ]; stopifnot(identical(x$neuron, seq_len(896L)))
      x$value
    })
    target <- do.call(rbind, rows[c(1, 3)]); control <- do.call(rbind, rows[c(2, 4)])
    dimnames(target) <- dimnames(control) <- list(pairs$pair_id, as.character(seq_len(896L)))
    context <- list(model = record, capture = list(component = component, positions = "last",
      input_format = "raw_text", tokenizer = "gguf_embedded", add_special = TRUE,
      parse_special = FALSE, template_sha256 = NULL, context_length = 512L, backend = backend,
      relm_version = settings$relm_version), pairs = pairs,
      splits = data.frame(prompt_sha256 = prompts$sha256, split = prompts$split), seed = NULL)
    relm::llm_direction(target, control, context, layer = 12L)
  })
  names(directions) <- c("residual", "mlp_out")
  save(directions, "directions.rds")
  stopifnot(identical(directions, readRDS(path("directions.rds"))))
  results <- list(); metrics <- list()
  for (i in 5:6) {
    for (j in seq_len(nrow(conditions))) {
      condition <- conditions[j, ]; key <- paste(prompts$id[[i]], condition$condition, sep = "-")
      run <- (function() {
        handle <- m
        if (condition$operator != "none") {
          component <- if (condition$operator == "add") "residual" else "mlp_out"
          handle <- relm::llm_apply_direction(m, directions[[component]], record,
            coef = condition$coefficient, operator = condition$operator)
          on.exit(close(handle), add = TRUE)
        }
        if (i == 5L && condition$condition == "projection")
          figure("configured-model.png", function() plot(handle, layers = c(1L, 12L, 24L)))
        research_generate(handle, prompts$text[[i]], settings)
      })()
      save(run, paste0(key, ".rds")); results[[key]] <- run
      metrics[[key]] <- data.frame(prompt_id = prompts$id[[i]], condition = condition$condition,
        characters = nchar(run$text[[1L]], type = "chars"), sampled_states = length(run$sampled_ids),
        reached_token_cap = length(run$sampled_ids) == settings$max_tokens,
        text = unname(run$text[[1L]]))
      csv(do.call(rbind, metrics), "outputs.csv")
    }
    baseline <- results[[paste(prompts$id[[i]], "original", sep = "-")]]
    zero <- results[[paste(prompts$id[[i]], "zero", sep = "-")]]
    stopifnot(identical(baseline$text, zero$text), identical(baseline$sampled_ids, zero$sampled_ids))
    intervention <- results[[paste(prompts$id[[i]], "projection", sep = "-")]]
    observation <- function(x) list(model_sha256 = cfg$model_sha256,
      settings = settings, generated_tokens = x$sampled_ids[1L])
    compared <- relm::llm_compare(baseline$first, intervention$first,
      list(reference = observation(baseline), intervention = observation(intervention)),
      layer = 12L, component = "mlp_out")
    save(compared, paste0(prompts$id[[i]], "-comparison.rds"))
    csv(as.data.frame(compared), paste0(prompts$id[[i]], "-comparison.csv"))
    figure(paste0(prompts$id[[i]], "-comparison.png"), function()
      plot(compared, main = "First-state observation: fixed MLP projection versus original"))
  }
  writeLines(c("Inspect every answer for correctness, relevance and completeness.",
    "Length and token-cap indicators do not measure answer quality.",
    "Two construction pairs and two prompts are a usability exercise, not an efficacy study.",
    "The practice prompt is labelled selection for split provenance; no coefficient was selected.",
    "Static projection and residual addition differ in site and direction as well as operator.",
    "Sampled-state counts are not necessarily committed output-token counts.",
    "RDS files are trusted local artifacts; CSV drops attributes. Keep both.",
    paste(backend, "was requested and recorded from handle metadata; this script does not audit native device logs.")),
    path("INTERPRETATION.txt"))
  close(m)
  files <- list.files(cfg$output_dir, full.names = TRUE)
  files <- files[basename(files) != "STATUS.txt"]
  csv(data.frame(file = basename(files), sha256 = unname(tools::sha256sum(files))), "files.csv")
  writeLines("COMPLETE: walkthrough execution only; external validation and efficacy are separate.", path("STATUS.txt"))
  invisible(cfg$output_dir)
}
