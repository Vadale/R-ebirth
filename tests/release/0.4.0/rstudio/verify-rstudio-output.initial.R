# Read retained observations only; never source demos or load a model.
root <- "/private/tmp/relm-release-0.4.0"
status <- jsonlite::read_json(file.path(root, "rstudio-status.json"), simplifyVector = TRUE)
job <- readRDS(file.path(root, "rstudio-job-final.rds"))
launch <- readRDS(file.path(root, "rstudio-launch.rds"))
stopifnot(status$status == "passed", job$state == "succeeded",
          launch$job_id == "F3B7C316", !launch$importEnv, launch$exportEnv == "",
          status$package$version == "0.4.0",
          status$package$path == file.path(root, "packaging-r-path/library/relm"),
          identical(names(status$stages), c("readme-quickstart-and-schema", "demo-A", "demo-B-reproducibility")),
          all(vapply(status$stages, function(x) x$status == "passed", TRUE)))
observations <- readRDS(file.path(root, "readme-observations.rds"))
emb <- observations$embeddings
tr <- observations$trace
stopifnot(identical(dim(emb), c(3L, 896L)), all(is.finite(emb)),
          all(abs(rowSums(emb^2) - 1) < 1e-5),
          nrow(tr) == 896L, all(is.finite(tr$value)),
          identical(tr$neuron, seq_len(896L)), all(tr$layer == 12L),
          all(tr$component == "residual"), all(tr$token_pos == 5L))
async <- readRDS(file.path(root, "readme-async.rds"))
stopifnot(is.character(async), length(async) == 1L, nzchar(async), attr(async, "seed") == 17)
a <- readRDS(file.path(root, "demo-A.rds"))
stopifnot(identical(a$layers, 1:24), a$n == 40L,
          all(is.finite(c(a$auc, a$lower, a$upper))),
          a$best_auc == max(a$auc), a$best_layer == a$layers[which.max(a$auc)],
          a$best_auc == status$demo_A$best_auc, a$best_layer == status$demo_A$best_layer,
          a$best_auc >= 0.7, a$steer$shift_up > a$steer$shift_down,
          a$steer$shift_up == status$demo_A$shift_up,
          a$steer$shift_down == status$demo_A$shift_down,
          status$demo_B$seed == 20240707L, status$demo_B$corpus_size == 1200L)
warnings <- readRDS(file.path(root, "rstudio-warnings.rds"))
messages <- vapply(warnings, `[[`, "", "message")
stopifnot(length(warnings) == 30L, status$warning_count == 30L,
          all(vapply(warnings, `[[`, "", "stage") == "demo-A"))
counts <- table(messages)
stopifnot(length(counts) == 2L,
          sum(grepl("Too few (< 10) observations per fold", messages, fixed = TRUE)) == 24L,
          sum(messages == "zero-length arrow is of indeterminate angle and so skipped") == 6L)
result <- list(status = "passed", inference_calls = 0L, job_id = launch$job_id,
  elapsed_seconds = job$jobs$F3B7C316$elapsed,
  readme = list(embedding_shape = dim(emb), maximum_unit_norm_error = max(abs(rowSums(emb^2)-1)),
               trace_coordinates = nrow(tr), async_seed = attr(async, "seed")),
  demo_A = list(best_layer = a$best_layer, best_auc = a$best_auc,
                shift_up = a$steer$shift_up, shift_down = a$steer$shift_down),
  demo_B = list(corpus_size = 1200L, seed = 20240707L,
    evidence = "Retained actual RStudio PASS output and bound function assertions; result arrays were not persisted.",
    exact_scope = "First 16 abstracts embedded twice; all 1200 embedded once; seeded layout, labels, clustering and six statistics checks repeated using that one full embedding."),
  warning_counts = as.list(counts))
jsonlite::write_json(result, file.path(root, "rstudio-observation-owner.json"), auto_unbox = TRUE, pretty = TRUE)
cat("RSTUDIO_RETAINED_OBSERVATIONS_OK: 64 seconds, three stages, 30 disclosed warnings, zero model calls\n")
