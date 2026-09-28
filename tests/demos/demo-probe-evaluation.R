# WP11b: a fixed, synthetic paired-source demonstration, not a scientific
# generalization claim. The lexical control intentionally exposes the confound.
# Runs locally on the pinned Qwen0.5 and in nightly-demo-A; no model download here.
probe_example_data <- function() {
  topics <- c("film", "service", "meal", "concert", "book", "garden", "phone", "hotel",
              "lesson", "journey", "meeting", "design", "performance", "exhibition",
              "game", "story", "delivery", "coffee", "workshop", "lecture", "theatre",
              "museum", "breakfast", "presentation", "class", "trip", "festival",
              "painting", "interview", "report", "product", "restaurant", "course",
              "show", "visit", "party", "reception", "tour", "experience", "evening")
  group <- rep(sprintf("source-%02d", seq_along(topics)), each = 2L)
  label <- rep(0:1, length(topics))
  data.frame(group = group, label = label,
             prompt = sprintf("My experience with the %s was %s.", rep(topics, each = 2L),
                              ifelse(label == 1L, "excellent", "awful")),
             partition = rep(c(rep("development", 20), rep("test", 20)), each = 2L),
             stringsAsFactors = FALSE)
}

run_probe_evaluation <- function(model_path, output_dir, backend = "auto") {
  stopifnot(requireNamespace("relm", quietly = TRUE), requireNamespace("glmnet", quietly = TRUE))
  corpus <- probe_example_data()
  labels <- corpus$label
  groups <- corpus$group
  reserved <- unique(groups[corpus$partition == "test"])
  m <- relm::llm(model_path, context_length = 256, backend = backend)
  on.exit(close(m), add = TRUE)
  layers <- unique(pmax(1L, as.integer(m$layers * c(.25, .5, .75))))
  trace <- relm::llm_trace(m, corpus$prompt, layers = layers, positions = "last")
  fit <- relm::llm_probe(labels ~ relm::activations(layer = layers), trace,
                          groups = groups, test_groups = reserved, cv = 4, seed = 321)

  # The control uses the same development-fold/selection protocol on declared
  # ordinary features, through an internal acceptance-harness entry point.
  # These are not activations and are never presented as a relm_trace.
  features <- cbind(characters = nchar(corpus$prompt), excellent = as.numeric(grepl("excellent", corpus$prompt, fixed = TRUE)))
  baseline <- relm:::probe_fit_layers(function(layer) features, 1L, seq_len(nrow(corpus)),
    labels, groups, reserved, 4L, "auc", 321L, "simple_features")
  # Predeclared paired swap: alternate development groups are swapped, preserving
  # balance exactly. This is one negative control, not a permutation p-value.
  shuffled <- labels
  swap_groups <- unique(groups[corpus$partition == "development"])[seq(1L, 20L, by = 2L)]
  shuffled[groups %in% swap_groups] <- 1L - shuffled[groups %in% swap_groups]
  shuffled_fit <- relm::llm_probe(shuffled ~ relm::activations(layer = layers), trace,
                                 groups = groups, test_groups = reserved, cv = 4, seed = 321)
  stopifnot(identical(fit$audit$fold, baseline$audit$fold),
            identical(fit$audit$fold, shuffled_fit$audit$fold),
            all(baseline$metrics$test_score == 1),
            all(is.finite(predict(fit, trace))))
  metrics <- rbind(transform(fit$metrics, analysis = "activations"),
                   transform(baseline$metrics, analysis = "simple_features"),
                   transform(shuffled_fit$metrics, analysis = "paired_label_control"))
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(corpus, file.path(output_dir, "fixed-corpus.csv"), row.names = FALSE)
  utils::write.csv(metrics, file.path(output_dir, "metrics.csv"), row.names = FALSE)
  utils::write.csv(fit$audit, file.path(output_dir, "split-audit.csv"), row.names = FALSE)
  utils::write.csv(data.frame(prompt_id = seq_along(labels), original = labels, control = shuffled),
                   file.path(output_dir, "paired-control.csv"), row.names = FALSE)
  grDevices::pdf(file.path(output_dir, "decodability.pdf"), width = 7, height = 5)
  tryCatch(plot(fit), finally = grDevices::dev.off())
  writeLines(c("Synthetic paired-source example; no independent scientific performance claim.",
               "The simple lexical feature is intentionally sufficient for the labels.",
               "The paired-label control is a predeclared fixed swap, not a formal permutation test.",
               paste("Model:", basename(model_path)),
               paste("Requested backend:", backend),
               paste("Layers:", paste(layers, collapse = ", ")),
               paste("relm:", utils::packageVersion("relm")),
               capture.output(str(fit$solver)), capture.output(str(fit$protocol)),
               capture.output(sessionInfo())), file.path(output_dir, "provenance.txt"))
  print(metrics)
  invisible(list(fit = fit, baseline = baseline, control = shuffled_fit))
}
