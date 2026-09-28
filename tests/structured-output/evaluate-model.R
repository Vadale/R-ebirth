#!/usr/bin/env Rscript
# D1 worker: label-free inputs, one loaded model, no JSON parsing dependency.
main <- function() {
  args <- commandArgs(trailingOnly = TRUE)
  if (length(args) != 11L) stop("Use evaluate-model.py to supply the 11 worker arguments.")
  names(args) <- c("mode", "model", "backend", "inputs", "schema", "output", "library",
    "max_tokens", "context_length", "temperature", "top_p")
  if (!args[["mode"]] %in% c("structured", "unconstrained")) stop("Invalid mode.")
  if (nzchar(args[["library"]])) .libPaths(c(args[["library"]], .libPaths()))
  library(relm)
  read_utf8 <- function(path) {
    value <- rawToChar(readBin(path, "raw", n = file.info(path)$size))
    if (!validUTF8(value)) stop("Input is not UTF-8: ", path)
    Encoding(value) <- "UTF-8"
    value
  }
  clean <- function(x) gsub("[\t\r\n]", " ", as.character(x))
  inputs <- read.delim(args[["inputs"]], quote = "", comment.char = "",
    na.strings = character(), colClasses = c("integer", "character", "integer", "character"))
  schema <- read_utf8(args[["schema"]])
  m <- llm(args[["model"]], backend = args[["backend"]],
    context_length = as.integer(args[["context_length"]]))
  on.exit(close(m), add = TRUE)
  metadata <- list(package_version = as.character(packageVersion("relm")),
    package_path = find.package("relm"), native_library = getLoadedDLLs()[["relm"]][["path"]],
    native_library_sha256 = unname(tools::sha256sum(getLoadedDLLs()[["relm"]][["path"]])),
    r_version = R.version.string, r_platform = R.version$platform,
    backend = m$backend, context_length = m$context_length)
  write.table(data.frame(key = names(metadata), value = vapply(metadata, clean, "")),
    file.path(args[["output"]], "metadata.tsv"), sep = "\t", quote = FALSE, row.names = FALSE)
  writeLines(capture.output(sessionInfo()), file.path(args[["output"]], "session-info.txt"))
  records <- file.path(args[["output"]], "records.tsv")
  writeLines("index\tid\tseed\tstatus\telapsed_seconds\terror_class\terror_message", records)
  for (i in seq_len(nrow(inputs))) {
    row <- inputs[i, ]
    prompt <- read_utf8(row$prompt_file)
    started <- proc.time()[["elapsed"]]
    value <- tryCatch(llm_generate(m, prompt, max_tokens = as.integer(args[["max_tokens"]]),
      temperature = as.double(args[["temperature"]]), top_p = as.double(args[["top_p"]]),
      seed = row$seed, chat = TRUE,
      schema = if (args[["mode"]] == "structured") schema else NULL), error = identity)
    elapsed <- proc.time()[["elapsed"]] - started
    prefix <- file.path(args[["output"]], sprintf("output-%d", row$index))
    if (inherits(value, "error")) {
      record <- c(row$index, row$id, row$seed, "failure", sprintf("%.9f", elapsed),
        class(value)[[1L]], clean(conditionMessage(value)))
      if (is.raw(value$partial_bytes)) {
        writeBin(head(value$partial_bytes, 65536L), paste0(prefix, ".partial.bin"))
      }
    } else {
      writeBin(charToRaw(enc2utf8(value[[1L]])), paste0(prefix, ".json"))
      record <- c(row$index, row$id, row$seed, "success", sprintf("%.9f", elapsed), "", "")
    }
    cat(paste(record, collapse = "\t"), "\n", file = records, append = TRUE, sep = "")
  }
}
main()
