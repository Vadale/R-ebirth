#!/usr/bin/env Rscript
# Internal worker for run-model.py. Base R + the installed relm package only.
# Each process loads one model, warms up once, then records three generations.
args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 7L) {
  stop("Use run-model.py: expected mode, model, backend, prompt, schema, output directory, R library.")
}
names(args) <- c("mode", "model", "backend", "prompt", "schema", "output", "library")
if (!args[["mode"]] %in% c("unconstrained", "structured")) stop("Invalid mode.")
if (!args[["backend"]] %in% c("metal", "cpu")) stop("Invalid backend.")
if (nzchar(args[["library"]])) .libPaths(c(args[["library"]], .libPaths()))
library(relm)
if (!"schema" %in% names(formals(llm_generate))) stop("Installed relm lacks schema support.")

read_utf8 <- function(path) {
  text <- rawToChar(readBin(path, "raw", n = file.info(path)$size))
  if (!validUTF8(text)) stop("Input is not UTF-8: ", path)
  Encoding(text) <- "UTF-8"
  text
}
clean_field <- function(x) gsub("[\t\r\n]", " ", as.character(x))
write_text <- function(text, path) writeBin(charToRaw(enc2utf8(text)), path)

prompt <- read_utf8(args[["prompt"]])
schema <- read_utf8(args[["schema"]])
m <- llm(args[["model"]], backend = args[["backend"]], context_length = 4096)
metadata <- list(
  package_version = as.character(packageVersion("relm")),
  package_path = find.package("relm"),
  native_library = getLoadedDLLs()[["relm"]][["path"]],
  r_version = R.version.string,
  r_platform = R.version$platform,
  backend = m$backend,
  context_length = m$context_length,
  token_count_source = "Internal generated_tokens payload captured by a base-R exit trace; public llm_generate() path measured"
)
write.table(data.frame(key = names(metadata), value = vapply(metadata, clean_field, "")),
  file.path(args[["output"]], "metadata.tsv"), sep = "\t", quote = FALSE,
  row.names = FALSE)
writeLines(capture.output(sessionInfo()), file.path(args[["output"]], "session-info.txt"))
records <- file.path(args[["output"]], "records.tsv")
writeLines("phase\tindex\tseed\tstatus\telapsed_seconds\toutput_tokens\tretokenized_count\terror_class\terror_message", records)

run_generations <- function() {
  counter <- new.env(parent = emptyenv())
  capture_count <- function(payload) counter$generated_tokens <- payload$generated_tokens
  wrapper <- if (args[["mode"]] == "structured") "rebirth_generate_structured" else "rebirth_generate"
  namespace <- asNamespace("relm")
  # Inject the closure itself: a package namespace cannot resolve this driver's
  # counter binding. The trace observes the return value without changing it.
  tracer <- substitute(CAPTURE(returnValue()), list(CAPTURE = capture_count))
  trace(wrapper, exit = tracer, where = namespace, print = FALSE)
  on.exit(untrace(wrapper, where = namespace), add = TRUE)

  for (i in 0:3) {
    counter$generated_tokens <- NULL
    seed <- c(1, 11, 29, 47)[i + 1L]
    phase <- if (i == 0L) "warmup" else "measured"
    started <- proc.time()[["elapsed"]]
    value <- tryCatch(llm_generate(m, prompt, max_tokens = 512, temperature = 0,
      top_p = 0.95, seed = seed, chat = TRUE,
      schema = if (args[["mode"]] == "structured") schema else NULL), error = identity)
    elapsed <- proc.time()[["elapsed"]] - started
    if (inherits(value, "error")) {
      row <- c(phase, i, seed, "failure", sprintf("%.9f", elapsed), "", "",
        class(value)[[1L]], clean_field(conditionMessage(value)))
      if (is.raw(value$partial_bytes)) {
        writeBin(value$partial_bytes, file.path(args[["output"]], sprintf("output-%d.partial.bin", i)))
      }
    } else {
      write_text(value[[1L]], file.path(args[["output"]], sprintf("output-%d.json", i)))
      count <- counter$generated_tokens
      if (!is.integer(count) || length(count) != 1L || is.na(count) || count <= 0L) {
        stop("Expected one positive native generated_tokens integer; install the current S1 build.")
      }
      # Additional diagnostic only; the latency denominator uses native count.
      # llm_tokens() already uses add_special = FALSE internally.
      retokenized <- length(llm_tokens(m, value[[1L]]))
      row <- c(phase, i, seed, "success", sprintf("%.9f", elapsed), count, retokenized, "", "")
    }
    cat(paste(row, collapse = "\t"), "\n", file = records, append = TRUE, sep = "")
  }
}
run_generations()
close(m)
