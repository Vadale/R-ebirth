# One small, inspectable recipe; no service, retries or model-output repair.
# CI: Linux-release R-CMD-check runs `check` only. Actual generation is [MODEL].
args <- commandArgs(TRUE)
script <- sub("^--file=", "", grep("^--file=", commandArgs(), value = TRUE))
root <- dirname(normalizePath(script, mustWork = TRUE))
if (!requireNamespace("jsonlite", quietly = TRUE) ||
    as.character(packageVersion("jsonlite")) != "2.0.0")
  stop("Install application-only jsonlite 2.0.0 as described in README.md.")
read_json <- function(path) jsonlite::fromJSON(paste(readLines(path, warn = FALSE),
  collapse = "\n"), simplifyVector = FALSE)
write_json <- function(x, path) writeLines(jsonlite::toJSON(x, auto_unbox = TRUE,
  null = "null", na = "null", pretty = TRUE, digits = NA), path, useBytes = TRUE)
hash <- function(paths) unname(tools::sha256sum(paths))
read_table <- function(path) read.csv(path, stringsAsFactors = FALSE,
  colClasses = "character", na.strings = character(), check.names = FALSE)
notices <- read_table(file.path(root, "notices.csv"))
expected <- read_table(file.path(root, "expected.csv"))
settings <- read_json(file.path(root, "settings.json"))
schema <- paste(readLines(file.path(root, "schema.json")), collapse = "\n")
prompt <- paste(readLines(file.path(root, "prompt.txt")), collapse = "\n")
stopifnot(identical(names(notices), c("id", "programme", "text")),
  identical(names(expected), c("id", "amount_eur", "evidence_anchor", "case")),
  nrow(notices) == 6L, !anyDuplicated(notices$id),
  identical(notices$id, expected$id), all(nzchar(notices$text)),
  all(nzchar(notices$programme)), !anyNA(notices), !anyNA(expected))
for (i in seq_len(nrow(expected))) {
  if (nzchar(expected$amount_eur[i])) {
    stopifnot(grepl("^[0-9]+$", expected$amount_eur[i]),
      nzchar(expected$evidence_anchor[i]),
      grepl(expected$evidence_anchor[i], notices$text[i], fixed = TRUE))
  } else stopifnot(!nzchar(expected$evidence_anchor[i]))
}

# Literal parsing only. Invalid or partial records remain failures.
parse_record <- function(text) {
  x <- jsonlite::fromJSON(text, simplifyVector = FALSE)
  if (!is.list(x) || length(x) != 2L || anyDuplicated(names(x)) ||
      !setequal(names(x), c("amount_eur", "evidence"))) stop("Wrong record keys")
  amount <- x$amount_eur
  quote <- x$evidence
  if (!is.null(amount) && (!is.numeric(amount) || length(amount) != 1L ||
      is.na(amount) || amount != floor(amount) || amount < 0 ||
      amount > 2147483647)) stop("Invalid amount")
  if (!is.null(quote) && (!is.character(quote) || length(quote) != 1L ||
      is.na(quote) || nchar(quote) < 1L || nchar(quote) > 256L)) stop("Invalid evidence")
  list(amount = if (is.null(amount)) NA_real_ else amount,
    quote = if (is.null(quote)) NA_character_ else quote)
}
score <- function(results) {
  if (!identical(results$id, notices$id)) stop("Missing, extra or reordered results")
  rows <- lapply(seq_len(nrow(notices)), function(i) {
    x <- if (results$status[i] == "ok")
      tryCatch(parse_record(results$json[i]), error = function(e) NULL) else NULL
    valid <- !is.null(x)
    amount <- if (valid) x$amount else NA_real_
    quote <- if (valid) x$quote else NA_character_
    target <- if (nzchar(expected$amount_eur[i])) as.numeric(expected$amount_eur[i]) else NA_real_
    amount_ok <- valid && if (is.na(target)) is.na(amount) else
      !is.na(amount) && amount == target
    quote_ok <- valid && if (is.na(target)) is.na(quote) else
      !is.na(quote) && grepl(quote, notices$text[i], fixed = TRUE) &&
        grepl(expected$evidence_anchor[i], quote, fixed = TRUE)
    data.frame(id = notices$id[i], amount_eur = amount, expected_eur = target,
      evidence = quote, complete_record = valid, amount_correct = amount_ok,
      evidence_correct = quote_ok, passed = amount_ok && quote_ok,
      elapsed_seconds = as.numeric(results$elapsed_seconds[i]),
      # A matched toy label does not remove human review on a real document.
      human_review_required = TRUE)
  })
  do.call(rbind, rows)
}

check <- function() {
  # Independent synthetic scorer controls, not model measurements.
  good <- vapply(seq_len(nrow(expected)), function(i) {
    x <- if (nzchar(expected$amount_eur[i])) list(
      amount_eur = as.numeric(expected$amount_eur[i]),
      evidence = expected$evidence_anchor[i]) else
        list(amount_eur = NULL, evidence = NULL)
    as.character(jsonlite::toJSON(x, auto_unbox = TRUE, null = "null"))
  }, character(1))
  fixture <- data.frame(id = notices$id, status = "ok", json = good, elapsed_seconds = 0)
  stopifnot(all(score(fixture)$passed))
  negatives <- c('{"amount_eur":1,"evidence":"total budget of EUR 250000"}',
    '{"amount_eur":250000,"evidence":"made up"}',
    '{"amount_eur":250000,"evidence":null}',
    '{"amount_eur":true,"evidence":"x"}',
    '{"amount_eur":250000,"evidence":"x","extra":0}',
    '{"amount_eur":250000,"amount_eur":1,"evidence":"x"}',
    '{"amount_eur":250000', '[]')
  for (bad in negatives) {
    changed <- fixture; changed$json[1L] <- bad
    stopifnot(!score(changed)$passed[1L])
  }
  changed <- fixture; changed$status[1L] <- "error"
  stopifnot(!score(changed)$passed[1L])
  changed <- fixture; changed$json[2L] <- '{"amount_eur":40000,"evidence":"grants of up to EUR 40000 per project"}'
  stopifnot(!score(changed)$passed[2L])
  refused <- tryCatch({score(fixture[-1L, ]); FALSE}, error = function(e) TRUE)
  stopifnot(refused)
  recorded <- file.path(root, "recorded", "results.csv")
  if (file.exists(recorded)) {
    actual <- score(read_table(recorded))
    saved <- read.csv(file.path(root, "recorded", "review.csv"), stringsAsFactors = FALSE)
    stopifnot(isTRUE(all.equal(actual, saved, check.attributes = FALSE)))
  }
  cat("Six positive scorer cases; ten bad-record cases and missing-row refusal; recorded review matches when present. No model loaded.\n")
}

run <- function(output, model_dir) {
  if (!requireNamespace("relm", quietly = TRUE) || packageVersion("relm") < "0.6.1")
    stop("Install relm >= 0.6.1 first.")
  if (file.exists(output)) stop("Choose a NEW output directory; existing results are preserved.")
  model_path <- file.path(model_dir, settings$model_file)
  if (!file.exists(model_path)) stop("Model missing. Run the explicit download step first.")
  start <- proc.time()[["elapsed"]]
  if (file.info(model_path)$size != settings$model_bytes ||
      hash(model_path) != settings$model_sha256) stop("Model identity mismatch")
  verify_seconds <- proc.time()[["elapsed"]] - start
  stopifnot(dir.create(output, recursive = TRUE))
  inputs <- c("notices.csv", "expected.csv", "prompt.txt", "schema.json", "settings.json", "run.R")
  stopifnot(all(file.copy(file.path(root, inputs), output)))
  write.csv(data.frame(file = inputs, sha256 = hash(file.path(root, inputs))),
    file.path(output, "inputs.csv"), row.names = FALSE)
  info <- packageDescription("relm")
  dll <- getLoadedDLLs()[["relm"]][["path"]]
  write_json(list(relm = as.character(packageVersion("relm")),
    source = info$RemoteSha, dll_sha256 = hash(dll), R = as.character(getRversion()),
    platform = R.version$platform, jsonlite = as.character(packageVersion("jsonlite")),
    settings = settings, started_utc = format(Sys.time(), tz = "UTC", usetz = TRUE)),
    file.path(output, "provenance.json"))
  load_start <- proc.time()[["elapsed"]]
  m <- relm::llm(model_path, backend = settings$backend,
    context_length = settings$context_length, threads = settings$threads)
  on.exit(close(m), add = TRUE)
  load_seconds <- proc.time()[["elapsed"]] - load_start
  results <- list()
  for (i in seq_len(nrow(notices))) {
    question <- paste(prompt, "Requested programme:", notices$programme[i],
      "Notice:", notices$text[i], sep = "\n")
    before <- proc.time()[["elapsed"]]
    answer <- tryCatch(relm::llm_generate(m, question, schema = schema,
      chat = settings$chat, max_tokens = settings$max_tokens,
      temperature = settings$temperature, top_p = settings$top_p, seed = settings$seed),
      error = identity)
    elapsed <- proc.time()[["elapsed"]] - before
    failed <- inherits(answer, "error")
    results[[i]] <- data.frame(id = notices$id[i], status = if (failed) "error" else "ok",
      json = if (failed) "" else unname(answer[[1L]]), elapsed_seconds = elapsed,
      error_class = if (failed) paste(class(answer), collapse = ";") else "",
      error_message = if (failed) conditionMessage(answer) else "",
      partial_output = if (failed && is.raw(answer$partial_bytes))
        rawToChar(answer$partial_bytes) else "", stringsAsFactors = FALSE)
    # Persist each attempt. Interruptions leave inspectable but incomplete rows.
    write.csv(do.call(rbind, results), file.path(output, "results.csv"), row.names = FALSE, na = "")
    cat(notices$id[i], if (failed) "error" else "complete", sprintf("%.3f s\n", elapsed))
  }
  results <- do.call(rbind, results)
  review <- score(results)
  write.csv(review, file.path(output, "review.csv"), row.names = FALSE, na = "NA")
  rss <- NA_real_
  if (file.exists("/proc/self/status")) {
    line <- grep("^VmHWM:", readLines("/proc/self/status"), value = TRUE)
    if (length(line) == 1L) rss <- as.numeric(gsub("[^0-9]", "", line)) * 1024
  }
  write_json(list(model_verify_seconds = verify_seconds, model_load_seconds = load_seconds,
    generation_seconds = sum(results$elapsed_seconds),
    run_elapsed_seconds = proc.time()[["elapsed"]] - start,
    process_peak_rss_bytes = rss, model_bytes = file.info(model_path)$size,
    complete_records = sum(review$complete_record), correct_amounts = sum(review$amount_correct),
    matching_amount_and_evidence = sum(review$passed), cases = nrow(notices),
    scope = "One CPU process; no warm-up or retry. Download/install excluded. RSS from Linux VmHWM; unavailable on other systems. Electricity and human review time unmeasured."),
    file.path(output, "metrics.json"))
  print(review[c("id", "amount_eur", "expected_eur", "passed")], row.names = FALSE)
}

if (length(args) == 1L && args[1L] == "check") {
  check()
} else if (length(args) == 2L && args[1L] == "score") {
  print(score(read_table(file.path(args[2L], "results.csv"))), row.names = FALSE)
} else if (length(args) == 2L && args[1L] == "download") {
  if (!requireNamespace("relm", quietly = TRUE)) stop("Install relm first.")
  options(timeout = max(600, getOption("timeout")))
  path <- relm::llm_download(settings$model_alias, dir = args[2L])
  if (hash(path) != settings$model_sha256) stop("Downloaded model differs from this recipe")
  cat("Verified model ready. Run inference separately.\n")
} else if (length(args) == 3L && args[1L] == "run") {
  run(args[2L], args[3L])
} else stop("Usage: run.R check | score OUTPUT | download MODEL_DIR | run NEW_OUTPUT MODEL_DIR")
