# tests/demos/demo-A-anatomy-lab.R
#
# Demo A -- "The anatomy lab" (SOLO-PHASE-PLAN.md Sec 8, WP7).
#
#   fixed sentiment contrast set -> llm_trace() over all layers
#     -> prcomp() concept direction (deliberately classical)
#     -> per-layer cross-validated glmnet ridge-logistic probe (committed foldid)
#     -> the money plot: out-of-fold decodability (AUC + bootstrap CI) by layer
#     -> llm_steer() along the direction, verified on HELD-OUT prompts.
#
# The prompt sets below are FIXED and committed (no cherry-picking, WP7). This
# file defines functions and, when a GGUF model is available, auto-runs the demo
# (that is the nightly-CI / Mac acceptance path). With no model it defines the
# functions and skips, so a checker can source it harmlessly.
#
# Dependencies: base R + the rebirth package + glmnet (Suggests, D-020). glmnet
# use is guarded; AUC + CI come from tests/demos/demo-utils.R (no pROC).

# ---- locate + source the model-free helpers (demo_auc / demo_auc_ci) ---------

.demo_dir <- function() {
  args <- commandArgs(FALSE)
  m <- grep("^--file=", args, value = TRUE)
  if (length(m)) return(dirname(sub("^--file=", "", m[[1L]])))
  for (i in rev(seq_len(sys.nframe()))) {
    of <- sys.frame(i)$ofile
    if (!is.null(of)) return(dirname(normalizePath(of)))
  }
  "tests/demos" # fallback: invoked from the repo root
}

local({
  p <- file.path(.demo_dir(), "demo-utils.R")
  if (!file.exists(p)) p <- "tests/demos/demo-utils.R"
  source(p)
})

# ---- the committed contrast set (fixed; opposite sentiment) ------------------

.demo_A_train_pos <- c(
  "I absolutely loved this film; it was a masterpiece from start to finish.",
  "The service was outstanding and the staff made us feel truly welcome.",
  "What a wonderful day -- everything went perfectly and I feel great.",
  "This is the best meal I have had in years; simply delicious.",
  "She was thrilled with the results and could not stop smiling.",
  "The concert was electric and the crowd was overjoyed.",
  "I am so grateful for your help; you made my whole week.",
  "The new design is elegant, intuitive, and a real pleasure to use.",
  "Our vacation was relaxing, beautiful, and everything we hoped for.",
  "He gave a brilliant performance that left the audience delighted.",
  "The book was gripping and deeply moving; I recommend it warmly.",
  "Their kindness and generosity restored my faith in people.",
  "The project succeeded beyond our expectations and morale is high.",
  "This phone is fast, reliable, and worth every penny.",
  "A charming little cafe with friendly staff and superb coffee.",
  "The team celebrated a fantastic and well-deserved victory.",
  "I feel calm, happy, and optimistic about the future.",
  "The garden was gorgeous, full of color and sweet fragrance.",
  "Fantastic news -- the treatment worked and she is recovering well.",
  "Everything about the evening was joyful and unforgettable."
)

.demo_A_train_neg <- c(
  "I hated this film; it was a boring, pretentious waste of time.",
  "The service was appalling and the staff were rude and dismissive.",
  "What a miserable day -- everything went wrong and I feel awful.",
  "This is the worst meal I have had in years; utterly disgusting.",
  "She was devastated by the results and burst into tears.",
  "The concert was a shambles and the crowd was furious.",
  "I am so frustrated with your excuses; you ruined my whole week.",
  "The new design is clumsy, confusing, and a pain to use.",
  "Our vacation was stressful, ugly, and a complete disappointment.",
  "He gave a dreadful performance that left the audience cringing.",
  "The book was tedious and shallow; I regret buying it.",
  "Their cruelty and greed left me disgusted and angry.",
  "The project failed badly and morale has collapsed.",
  "This phone is slow, unreliable, and a total rip-off.",
  "A grim little cafe with surly staff and undrinkable coffee.",
  "The team suffered a humiliating and thoroughly deserved defeat.",
  "I feel anxious, gloomy, and hopeless about the future.",
  "The garden was a wreck, full of weeds and a foul smell.",
  "Terrible news -- the treatment failed and she is getting worse.",
  "Everything about the evening was dismal and forgettable."
)

.demo_A_holdout_pos <- c(
  "The morning sun and fresh air made me feel wonderful and alive.",
  "Our guests praised the dinner and the whole night was a delight.",
  "The update is smooth and fast; I am genuinely impressed.",
  "Volunteers worked cheerfully and the event was a resounding success.",
  "The puppy was adorable and filled the house with happy energy.",
  "Her speech was inspiring and the room erupted in warm applause.",
  "The results are excellent and the whole team is thrilled.",
  "A cozy, welcoming inn with delicious food and lovely views."
)

.demo_A_holdout_neg <- c(
  "The cold rain and traffic made me feel wretched and drained.",
  "Our guests complained about the dinner and the night was a disaster.",
  "The update is buggy and sluggish; I am genuinely disappointed.",
  "Volunteers argued bitterly and the event was a complete failure.",
  "The stray dog was filthy and filled the yard with a foul stench.",
  "Her speech was tedious and the room fell into an awkward silence.",
  "The results are terrible and the whole team is demoralized.",
  "A dingy, hostile motel with inedible food and grim views."
)

# ---- small internals ---------------------------------------------------------

# Feature matrix for one layer, with rows aligned to prompt order via the
# "<prompt_id>.<token_pos>" rownames (positions = "last" => one row per prompt).
.demo_A_layer_matrix <- function(tr, layer) {
  x <- as.matrix(tr, layer = layer, component = "residual")
  pid <- as.integer(sub("[.].*$", "", rownames(x)))
  x[order(pid), , drop = FALSE]
}

# Stratified committed foldid: assign folds within each class so every fold
# carries both classes (required for per-fold AUC prevalidation).
.demo_A_foldid <- function(y, nfolds = 10L, seed = 20240707L) {
  fid <- integer(length(y))
  old <- if (exists(".Random.seed", globalenv(), inherits = FALSE)) {
    get(".Random.seed", globalenv(), inherits = FALSE)
  }
  on.exit(if (!is.null(old)) assign(".Random.seed", old, globalenv()), add = TRUE)
  set.seed(seed)
  for (cls in unique(y)) {
    idx <- which(y == cls)
    k <- min(nfolds, length(idx))
    fid[idx] <- sample(rep(seq_len(k), length.out = length(idx)))
  }
  fid
}

# The unit "positive - negative" concept axis at one layer, via prcomp: take the
# principal component most aligned with the label and orient it toward positive
# sentiment. Deliberately classical (SOLO-PHASE-PLAN Sec 8).
.demo_A_direction <- function(x, y) {
  pc <- prcomp(x, center = TRUE, scale. = FALSE)
  k <- ncol(pc$x)
  align <- vapply(seq_len(k), function(j) abs(demo_auc(pc$x[, j], y) - 0.5), numeric(1))
  j <- which.max(align)
  dir <- pc$rotation[, j]
  if (demo_auc(pc$x[, j], y) < 0.5) dir <- -dir # orient toward positive
  dir / sqrt(sum(dir^2))
}

# ---- the money plot (base graphics only) -------------------------------------

demo_A_plot <- function(res, file = NULL) {
  if (!is.null(file)) {
    grDevices::png(file, width = 1100, height = 750, res = 130)
    on.exit(grDevices::dev.off(), add = TRUE)
  }
  op <- graphics::par(no.readonly = TRUE)
  on.exit(graphics::par(op), add = TRUE)
  graphics::par(mar = c(4.6, 4.6, 3.4, 1.2), mgp = c(2.7, 0.7, 0), las = 1)

  L <- res$layers
  ylo <- min(0.45, min(res$lower) - 0.02)
  plot(L, res$auc,
    type = "n", ylim = c(ylo, 1.0), xlim = range(L),
    xlab = "Transformer layer", ylab = "Probe AUC (out-of-fold)",
    main = "The anatomy lab: where sentiment becomes linearly readable"
  )
  graphics::grid(nx = NA, ny = NULL, col = "grey92", lty = 1)
  graphics::abline(h = 0.5, lty = 2, col = "grey45") # chance
  graphics::text(min(L), 0.5, "chance", pos = 3, offset = 0.2, col = "grey45", cex = 0.8)
  graphics::arrows(L, res$lower, L, res$upper,
    angle = 90, code = 3, length = 0.03, col = "grey30"
  )
  graphics::lines(L, res$auc, col = "#3B6EA5", lwd = 1.5)
  graphics::points(L, res$auc, pch = 21, bg = "#3B6EA5", col = "white", cex = 1.3)

  b <- res$best_layer
  by <- res$auc[match(b, L)]
  graphics::abline(v = b, lty = 3, col = grDevices::adjustcolor("#D1495B", 0.4))
  graphics::points(b, by, pch = 21, bg = "#D1495B", col = "white", cex = 1.7)
  graphics::text(max(L), ylo + 0.04,
    labels = sprintf("best: layer %d\nAUC %.2f", b, res$best_auc),
    adj = c(1, 0), font = 2, col = "#D1495B", cex = 0.95
  )
  graphics::mtext(
    sprintf("model: %s  |  contrast n = %d  |  95%% bootstrap CI", basename(res$model), res$n),
    side = 3, line = 0.3, cex = 0.8, col = "grey35"
  )
  invisible(res)
}

# ---- the demo ----------------------------------------------------------------

run_demo_A <- function(model_path = .demo_A_model_path(),
                       layers = NULL, plot_file = NULL,
                       steer_scale = 4, verbose = TRUE) {
  if (!requireNamespace("glmnet", quietly = TRUE)) {
    stop("Demo A needs the 'glmnet' package (Suggests). install.packages('glmnet').")
  }
  stopifnot(nzchar(model_path), file.exists(model_path))

  say <- function(...) if (isTRUE(verbose)) message(...)
  m <- rebirth::llm(model_path)
  on.exit(close(m), add = TRUE)
  say(sprintf("Demo A: %s, %d layers x %d dim", basename(model_path), m$layers, m$hidden_size))

  train <- c(.demo_A_train_pos, .demo_A_train_neg)
  y <- c(rep(TRUE, length(.demo_A_train_pos)), rep(FALSE, length(.demo_A_train_neg)))
  yf <- factor(ifelse(y, "pos", "neg"), levels = c("neg", "pos"))

  # (1) One forward pass, last token of each prompt, all layers.
  say("tracing the contrast set ...")
  tr <- rebirth::llm_trace(m, train, layers = layers, positions = "last",
                           components = "residual")
  band <- sort(unique(tr$layer))

  # (2)+(3) prcomp direction (illustrative) and the per-layer OOF probe.
  foldid <- .demo_A_foldid(y)
  auc <- lower <- upper <- numeric(length(band))
  for (i in seq_along(band)) {
    x <- .demo_A_layer_matrix(tr, band[[i]])
    cvfit <- glmnet::cv.glmnet(
      x, yf,
      family = "binomial", alpha = 0, # ridge: hidden_size >> n (p >> n)
      foldid = foldid, type.measure = "auc", keep = TRUE
    )
    # Honest out-of-fold scores at lambda.min (prevalidated with the SAME folds).
    oof <- cvfit$fit.preval[, match(cvfit$lambda.min, cvfit$lambda)]
    ci <- demo_auc_ci(oof, y, seed = 1L)
    auc[[i]] <- ci[["auc"]]
    lower[[i]] <- ci[["lower"]]
    upper[[i]] <- ci[["upper"]]
  }
  best_i <- which.max(auc)
  best_layer <- band[[best_i]]
  say(sprintf("peak decodability: layer %d, AUC %.3f", best_layer, auc[[best_i]]))

  res <- list(
    layers = band, auc = auc, lower = lower, upper = upper,
    best_layer = best_layer, best_auc = auc[[best_i]],
    n = length(train), model = model_path
  )

  # (4) the money plot.
  demo_A_plot(res, file = plot_file)

  # (5) steer along the concept direction; verify on HELD-OUT prompts.
  res$steer <- .demo_A_steer_check(m, tr, band, best_layer, y, steer_scale, say)

  class(res) <- c("demo_A_result", "list")
  res
}

# Steer at the peak layer, read the effect DOWNSTREAM (a later layer) on held-out
# prompts: a genuine propagated effect, not the tautology of reading the injected
# vector back at the layer where it was added.
.demo_A_steer_check <- function(m, tr, band, best_layer, y, steer_scale, say) {
  steer_layer <- max(best_layer, 2L) # layer 1 is not steerable (grammar)
  read_layer <- max(band[band >= min(steer_layer + 4L, max(band))])

  x_steer <- .demo_A_layer_matrix(tr, steer_layer)
  dir <- .demo_A_direction(x_steer, y)
  proj <- as.numeric(x_steer %*% dir)
  gap <- mean(proj[y]) - mean(proj[!y]) # positive-negative gap on this axis
  coef <- steer_scale * gap
  read_dir <- .demo_A_direction(.demo_A_layer_matrix(tr, read_layer), y)

  m_pos <- rebirth::llm_steer(m, layer = steer_layer, direction = dir, coef = coef)
  m_neg <- rebirth::llm_steer(m, layer = steer_layer, direction = dir, coef = -coef)
  on.exit({ close(m_pos); close(m_neg) }, add = TRUE)

  held <- c(.demo_A_holdout_pos, .demo_A_holdout_neg)
  readout <- function(model) {
    h <- rebirth::llm_trace(model, held, layers = read_layer, positions = "last",
                            components = "residual")
    as.numeric(.demo_A_layer_matrix(h, read_layer) %*% read_dir)
  }
  base <- readout(m)
  up <- readout(m_pos)
  down <- readout(m_neg)

  # One-sided paired Wilcoxon: does +coef raise, and -coef lower, the downstream
  # sentiment read-out relative to baseline on the held-out prompts?
  p_up <- suppressWarnings(wilcox.test(up, base, paired = TRUE, alternative = "greater")$p.value)
  p_down <- suppressWarnings(wilcox.test(down, base, paired = TRUE, alternative = "less")$p.value)
  say(sprintf(
    "steer @ L%d, read @ L%d: mean shift +%.3f (p=%.3g) / %.3f (p=%.3g)",
    steer_layer, read_layer, mean(up - base), p_up, mean(down - base), p_down
  ))

  # Qualitative before/after generation on one neutral prompt.
  neutral <- "In one sentence, describe the town where you grew up."
  gen <- tryCatch(
    list(
      base = rebirth::llm_generate(m, neutral, max_tokens = 40L, seed = 1L),
      pos = rebirth::llm_generate(m_pos, neutral, max_tokens = 40L, seed = 1L),
      neg = rebirth::llm_generate(m_neg, neutral, max_tokens = 40L, seed = 1L)
    ),
    error = function(e) NULL
  )

  list(
    steer_layer = steer_layer, read_layer = read_layer, coef = coef,
    shift_up = mean(up - base), shift_down = mean(down - base),
    p_up = p_up, p_down = p_down, generations = gen
  )
}

.demo_A_model_path <- function() {
  p <- Sys.getenv("REBIRTH_DEMO_MODEL", "")
  if (!nzchar(p)) p <- Sys.getenv("REBIRTH_TEST_MODEL_QWEN", "")
  p
}

# ---- auto-run when a model is available --------------------------------------

if (!nzchar(Sys.getenv("REBIRTH_DEMO_NO_AUTORUN"))) {
  .mp <- .demo_A_model_path()
  if (nzchar(.mp) && file.exists(.mp)) {
    demoA <- run_demo_A(.mp)
  } else {
    message(
      "Demo A: no GGUF model found (set REBIRTH_DEMO_MODEL or ",
      "REBIRTH_TEST_MODEL_QWEN). Functions defined; skipping the end-to-end run."
    )
  }
}
