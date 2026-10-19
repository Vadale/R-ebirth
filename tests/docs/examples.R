# Focused WP16 documentation checks; reuses an installed relm, no native build.
# Rscript tests/docs/examples.R LIBRARY OUTPUT_DIR [MODEL SHA256 ENGINE_REVISION]
# CI runs the download-free path. A model argument explicitly enables new model
# examples, once per script; missing inputs never count as model acceptance.
args <- commandArgs(TRUE)
stopifnot(length(args) %in% c(2L, 5L))
.libPaths(c(normalizePath(args[1L], mustWork = TRUE), .libPaths()))
stopifnot(requireNamespace("relm", quietly = TRUE))
out <- args[2L]
if (dir.exists(out)) stop("Choose a new output directory; preserve earlier results.")
stopifnot(dir.create(out, recursive = TRUE))
files <- sort(list.files("rebirth/inst/examples/agents", "\\.R$", full.names = TRUE))
exports <- sort(getNamespaceExports("relm"))
stopifnot(identical(sort(sub("\\.R$", "", basename(files))), exports))
native <- c("llm", "llm_ablate", "llm_apply_direction", "llm_cancel", "llm_embed",
            "llm_generate", "llm_logits", "llm_steer", "llm_tokens", "llm_trace")
if (length(args) == 5L) files <- files[sub("\\.R$", "", basename(files)) %in% native]
only <- Sys.getenv("RELM_DOC_ONLY")
if (nzchar(only)) {
  selected <- strsplit(only, ",", fixed = TRUE)[[1L]]
  stopifnot(!anyDuplicated(selected), all(selected %in% sub("\\.R$", "", basename(files))))
  files <- files[sub("\\.R$", "", basename(files)) %in% selected]
}
rows <- list()
for (file in files) {
  name <- sub("\\.R$", "", basename(file))
  environment <- new.env(parent = globalenv())
  sys.source(file, environment)
  stopifnot(is.function(environment$run_example))
  mode <- if (name %in% native) "model_not_run" else if (name == "llm_download")
    "network_not_run" else "model_free_execution"
  if (length(args) == 2L && exists("usage_check", environment, inherits = FALSE)) {
    result <- environment$usage_check()
    saveRDS(result, file.path(out, paste0(name, "-usage.rds")))
  }
  if (mode == "model_free_execution") {
    result <- environment$run_example()
    saveRDS(result, file.path(out, paste0(name, ".rds")))
  } else if (name %in% native && length(args) == 5L) {
    inputs <- list(model_path = args[3L], expected_sha256 = args[4L])
    if (name == "llm_apply_direction") inputs$engine_revision <- args[5L]
    result <- do.call(environment$run_example, inputs)
    saveRDS(result, file.path(out, paste0(name, ".rds")))
    mode <- "model_execution"
  }
  rows[[name]] <- data.frame(export = name, execution = mode,
    usage_check_executed = length(args) == 2L && exists("usage_check", environment, inherits = FALSE))
  write.csv(do.call(rbind, rows), file.path(out, "results.csv"), row.names = FALSE)
  cat(name, mode, "\n")
}
writeLines(capture.output(sessionInfo()), file.path(out, "session.txt"))
dll <- getLoadedDLLs()[["relm"]][["path"]]
write.csv(data.frame(version = as.character(getNamespaceVersion("relm")),
                    dll_sha256 = unname(tools::sha256sum(dll))),
          file.path(out, "installed.csv"), row.names = FALSE)
