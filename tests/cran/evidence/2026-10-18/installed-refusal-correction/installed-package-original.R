# Packaging acceptance only: one tiny CPU load/generation, no research replay.
args <- commandArgs(TRUE)
stopifnot(length(args) == 3L)
library(relm)
stopifnot(normalizePath(find.package("relm")) == normalizePath(args[[1L]]),
          identical(as.character(packageVersion("relm")), "0.4.0"))
ns <- asNamespace("relm")
source_env <- new.env(parent = ns)
for (p in sort(list.files(file.path(args[[2L]], "R"), full.names = TRUE)))
  sys.source(p, source_env)
functions <- Filter(function(n) is.function(source_env[[n]]), ls(source_env, all.names = TRUE))
for (n in functions) stopifnot(exists(n, ns, inherits = FALSE),
  identical(body(source_env[[n]]), body(ns[[n]])),
  identical(formals(source_env[[n]]), formals(ns[[n]])))
usage <- capture.output(codetools::checkUsagePackage("relm"), type = "output")
stopifnot(length(usage) == 0L)
registered <- names(getDLLRegisteredRoutines("relm")$.Call)
stopifnot(!any(grepl("selftest", registered, fixed = TRUE)),
          identical(relm:::rebirth_available_backends(), "cpu"))
profile <- relm:::rebirth_projection_allocation_profile()
stopifnot(length(profile) == 27L, all(is.finite(unlist(profile))),
          profile$ffi_fixed_bytes == profile$ffi_response_bytes + profile$ffi_registry_bytes + 160)
model <- llm(file.path(args[[2L]], "tests/testthat/fixtures/synthetic-llama-2l.gguf"),
             backend = "cpu", context_length = 64L)
result <- tryCatch(llm_generate(model, "Hello", max_tokens = 4L, temperature = 0,
                               seed = 9001L, chat = FALSE),
                   finally = close(model))
stopifnot(is.character(result), length(result) == 1L, !is.na(result))
saveRDS(list(functions = functions, registered = registered, profile = profile,
             result = result, model_closed = TRUE, load_attempts = 1L,
             generation_attempts = 1L, session = sessionInfo()), args[[3L]])
cat(sprintf("CRAN_INSTALLED_PASS functions=%d profile=27 fixtures=0 loads=1 generations=1\n",
            length(functions)))
