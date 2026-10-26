# Base-R orchestration regression; CI: R-CMD-check, Linux release only.
# Execute the actual helper and nightly acceptance block, replacing only the
# model and downstream analysis boundaries. No relm load, model, UMAP or build.
args <- commandArgs(trailingOnly = TRUE)
root <- if (length(args)) args[[1L]] else "."
demo <- parse(file.path(root, "tests/demos/demo-B-topics.R"))
helper <- Filter(function(x) is.call(x) && identical(x[[1L]], as.name("<-")) &&
                   identical(x[[2L]], as.name("run_demo_B_reproducible")), as.list(demo))
stopifnot(length(helper) == 1L)
workflow <- readLines(file.path(root, ".github/workflows/nightly-demo-B.yaml"))
start <- grep("^            ext_dir <-", workflow)
end <- which(seq_along(workflow) > start & grepl("^          '$", workflow))[1L]
stopifnot(length(start) == 1L, !is.na(end))
acceptance <- parse(text = sub("^            ", "", workflow[start:(end - 1L)]))
fixture <- data.frame(text = sprintf("synthetic abstract %04d", seq_len(1200L)),
                      category = rep(c("alpha", "beta"), 600L))
expected_emb <- cbind(seq_len(1200L), -seq_len(1200L))

exercise <- function(fault = NULL) {
  e <- new.env(parent = baseenv())
  e$mp <- "synthetic-model-boundary"
  e$calls <- list(); e$runs <- list(); e$opened <- 0L; e$closed <- 0L
  e$demo_B_data <- function() fixture
  e$close <- function(m) {
    stopifnot(identical(m, "fixture-handle"))
    e$closed <- e$closed + 1L
  }
  llm <- function(path) {
    stopifnot(identical(path, e$mp))
    e$opened <- e$opened + 1L
    "fixture-handle"
  }
  embed <- function(m, texts, pooling, normalize) {
    stopifnot(identical(m, "fixture-handle"), identical(pooling, "mean"),
              identical(normalize, TRUE))
    e$calls[[length(e$calls) + 1L]] <- texts
    if (identical(fault, "embedding error")) stop("fixture embedding error")
    rows <- match(texts, fixture$text)
    stopifnot(!anyNA(rows))
    out <- expected_emb[rows, , drop = FALSE]
    if (identical(fault, "embedding mismatch") && length(e$calls) == 2L) out[1L, 1L] <- -99L
    out
  }
  # Private evaluation environment only; unexpected namespace access is refused.
  e$`::` <- function(pkg, name) {
    stopifnot(identical(substitute(pkg), as.name("relm")))
    switch(as.character(substitute(name)), llm = llm, llm_embed = embed,
           stop("unexpected model API"))
  }
  e$run_demo_B <- function(model_path, abstracts = NULL, seed = 20240707L,
                          extended, emb = NULL, plot_file, plot_dir, verbose = TRUE) {
    df <- if (is.null(abstracts)) fixture else abstracts
    stopifnot(identical(model_path, e$mp), identical(df, fixture),
              identical(seed, 20240707L), isTRUE(extended))
    if (is.null(emb)) emb <- embed("fixture-handle", df$text, "mean", TRUE)
    stopifnot(identical(emb, expected_emb))
    index <- length(e$runs) + 1L
    files <- setNames(file.path(plot_dir, paste0("demoB-", c("B1", "B2", "B3"), ".png")),
                      c("B1", "B2", "B3"))
    for (f in c(plot_file, files)) writeLines("fixture figure boundary", f)
    result <- list(cluster = rep(1:2, 600L), labels = c("alpha", "beta"),
                   extended = list(B1 = list(mean_sil = 0.5, silhouette = c(0.5, 0.5),
                                             cohesion = c(0.9, 0.8)),
                                   B2 = list(top = c("alpha", "beta")),
                                   B3 = list(cos = diag(2)), files = files),
                   invocation = index)
    if (index == 2L) {
      if (identical(fault, "cluster")) result$cluster[1L] <- 0L
      if (identical(fault, "labels")) result$labels[1L] <- "changed"
      if (identical(fault, "silhouette")) result$extended$B1$silhouette[1L] <- 0.4
      if (identical(fault, "cohesion")) result$extended$B1$cohesion[1L] <- 0.7
      if (identical(fault, "top_terms")) result$extended$B2$top[1L] <- "changed"
      if (identical(fault, "cosine")) result$extended$B3$cos[1L, 2L] <- 0.1
    }
    if (identical(fault, "quality")) result$extended$B1$mean_sil <- NA_real_
    if (identical(fault, "figure")) unlink(plot_file)
    e$runs[[index]] <- list(result = result, plot_file = plot_file)
    result
  }
  eval(helper[[1L]], e)
  # Isolate output without changing the real workflow's temp-dir selection.
  out <- tempfile("demo-B-orchestration-")
  dir.create(out)
  previous <- Sys.getenv("RUNNER_TEMP", unset = NA_character_)
  Sys.setenv(RUNNER_TEMP = out)
  on.exit({
    if (is.na(previous)) Sys.unsetenv("RUNNER_TEMP") else Sys.setenv(RUNNER_TEMP = previous)
    unlink(out, recursive = TRUE)
  }, add = TRUE)
  error <- tryCatch({ eval(acceptance, e); NULL }, error = conditionMessage)
  list(error = error, env = e)
}

ok <- exercise()
stopifnot(is.null(ok$error))
e <- ok$env
stopifnot(length(e$calls) == 3L, length(e$runs) == 2L,
          identical(e$calls[[1L]], fixture$text[1:16]),
          identical(e$calls[[2L]], fixture$text[1:16]),
          identical(e$calls[[3L]], fixture$text),
          identical(e$res, e$runs[[1L]]$result), e$res$invocation == 1L,
          basename(e$runs[[1L]]$plot_file) == "demoB-B4-map.png",
          dirname(e$runs[[1L]]$plot_file) != dirname(e$runs[[2L]]$plot_file),
          e$opened == 1L, e$closed == 1L)

faults <- c("embedding mismatch", "embedding error", "cluster", "labels", "silhouette",
            "cohesion", "top_terms", "cosine", "quality", "figure")
for (fault in faults) {
  x <- exercise(fault)
  stopifnot(!is.null(x$error), x$env$opened == 1L, x$env$closed == 1L)
  if (fault %in% c("embedding mismatch", "embedding error")) {
    stopifnot(length(x$env$runs) == 0L, length(x$env$calls) <= 2L)
  }
  if (fault %in% c("cluster", "labels", "silhouette", "cohesion", "top_terms", "cosine")) {
    stopifnot(identical(x$error, paste0("Demo B is not reproducible; mismatched: ", fault)))
  }
  cat("refused:", fault, "--", x$error, "\n")
}
cat("Demo B orchestration: PASS (one corpus embedding, two sample calls, two analyses; 10 refusals)\n")
