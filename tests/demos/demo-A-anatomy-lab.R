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

# Neutral held-out prompts for the steering check: sentiment should come from the
# intervention, not the prompt. Sixteen committed leads (was eight) -- the wider set
# tightens A3's per-coefficient bootstrap CIs at no extra committed-prompt risk.
.demo_A_neutral <- c(
  "Describe the meeting that happened this afternoon.",
  "Write a sentence about the food at the new restaurant.",
  "Tell me about your commute to work today.",
  "Summarize what the weather has been like this week.",
  "Describe the film you watched last night.",
  "Give your impression of the new office.",
  "Write a short note about how the project is going.",
  "Describe the neighbourhood where you live.",
  "Describe the book you are currently reading.",
  "Write a sentence about your morning routine.",
  "Tell me about the coffee shop near the station.",
  "Summarize how the training session went.",
  "Give your impression of the new phone.",
  "Describe the walk you took at lunchtime.",
  "Write a short note about the conference you attended.",
  "Tell me about the apartment you just moved into."
)

# ---- A1: a SECOND committed contrast set -- FORMALITY (register) --------------
#
# Formal vs casual register, deliberately ORTHOGONAL to sentiment and with no
# demographic sensitivity (D-022): the two lists are pairwise content-matched
# (item i says the same thing in each register), and each list carries the same
# balance of pleasant / unpleasant / procedural content, so the ONLY systematic
# axis separating the classes is register, not topic or sentiment. Fixed and
# committed (no cherry-picking, WP7). "formal" is the positive class.
.demo_A_formal <- c(
  "The committee has determined that the proposal warrants further consideration.",
  "I regret to inform you that the requested accommodation cannot be provided.",
  "It is with considerable pleasure that we announce the appointment of the new director.",
  "Please be advised that the premises will be inaccessible during scheduled maintenance.",
  "The findings suggest that additional research is required before any conclusion is drawn.",
  "We would be most grateful if you could confirm your attendance at your earliest convenience.",
  "The applicant failed to satisfy the criteria stipulated in the original agreement.",
  "Kindly ensure that all documentation is submitted prior to the stated deadline.",
  "The organisation sincerely regrets any inconvenience that may have arisen from this matter.",
  "Attendees are respectfully requested to silence their devices for the duration of the session.",
  "Upon reviewing the evidence, the board concluded that the objection was without merit.",
  "It would be advisable to reconsider the strategy in light of recent developments.",
  "The department wishes to express its appreciation for your continued support.",
  "Under no circumstances should the equipment be operated without appropriate authorisation.",
  "The revised figures indicate a substantial improvement over the preceding quarter.",
  "We are writing to notify you of a forthcoming change to the terms of service.",
  "The panel found the candidate's qualifications to be entirely satisfactory.",
  "Should you require any further assistance, please do not hesitate to contact our office.",
  "The measures adopted have proven insufficient to address the underlying difficulty.",
  "It is imperative that all personnel adhere strictly to the established safety protocols."
)

.demo_A_casual <- c(
  "The team reckons the idea's worth another look, so we'll dig into it.",
  "Sorry, but we just can't sort out that request right now.",
  "Really pumped to say we've got a new boss starting next week.",
  "Heads up, the place is gonna be shut while they fix things.",
  "Looks like we need to poke at this a bit more before we call it.",
  "Can you let me know if you're coming along? Whenever suits, no rush.",
  "Yeah, they didn't really hit what we'd agreed on, so it's a no.",
  "Make sure you send all the paperwork over before the cut-off, okay?",
  "Really sorry about the mix-up, that one's on us.",
  "Hey everyone, mind sticking your phones on silent while we chat?",
  "After a look through, they figured the complaint was kind of pointless.",
  "Honestly, we should rethink the plan now all this new stuff's come up.",
  "Just wanted to say a massive thanks for sticking with us.",
  "Don't touch the kit unless someone says it's fine, seriously.",
  "The new numbers look way better than last time round.",
  "Quick heads up: we're switching up the rules a bit soon.",
  "They loved the candidate, and the CV checked out fine.",
  "Need anything else? Just give us a shout whenever.",
  "What we tried didn't really fix the main problem, sadly.",
  "Everyone's got to stick to the safety rules, no exceptions."
)

# ---- A2: committed exemplar sentences for the token x layer heatmap -----------
#
# Short, clearly-valenced sentences (<= ~9 words each) so positions = "all" stays
# well within the D-017 materialized-bytes budget; 4 positive + 4 negative.
.demo_A_exemplars <- c(
  "The film was absolutely wonderful.",
  "This meal was disgusting and cold.",
  "I feel happy and hopeful today.",
  "The whole trip was a disaster.",
  "Their kindness truly made my day.",
  "The service here was painfully slow.",
  "What a delightful little surprise.",
  "That result left me deeply worried."
)
.demo_A_exemplar_pos <- c(TRUE, FALSE, TRUE, FALSE, TRUE, FALSE, TRUE, FALSE)

# ---- A4: committed short, PEAKED, opinion-eliciting completion prompts --------
#
# A4 measures how much an ablation moves the next-token distribution. The prompt's
# next token must be sharply predictable (peaked) or an ablation's signal drowns in
# the model's own uncertainty -- the WP5 KL fixture chose "short factual/relational
# completions" for exactly this reason (intervene_kl.rs). These are the sentiment-
# demo analogue: each next token is a valenced adjective, so the effect is
# measurable AND concept-relevant. Fixed and committed.
.demo_A_eliciting <- c(
  "The movie was",
  "The food tasted",
  "My overall experience was",
  "Honestly, the service felt",
  "In the end, the result was",
  "The hotel room was",
  "Their customer support was",
  "The new update is"
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

# The committed steering layer: a mid-depth layer (~65% of depth), NOT the peak-
# decodability `best_layer`. Decodability (where a concept is READABLE) and
# steerability (where injecting the direction CHANGES behaviour) are different
# properties -- exactly the "reading is not causing" lesson. On a capable model
# decodability saturates from very early layers, so `best_layer` can land at the
# first ceiling-hit (e.g. layer 5/42 on Gemma 4 E4B), where steering does NOT
# causally control the output; a mid-depth layer does (verified by a per-layer
# dose-response sweep: gemma4 L27, Qwen2.5-0.5B L16 -- both ~0.65 depth). Committed
# and arch-agnostic; clamped to a steerable layer (>= 2, layer 1 is not steerable).
.DEMO_A_STEER_FRAC <- 0.65
.demo_A_steer_layer <- function(band) {
  target <- round(.DEMO_A_STEER_FRAC * max(band))
  cand <- band[band >= 2L]
  if (length(cand) == 0L) cand <- band # degenerate tiny model
  as.integer(cand[which.min(abs(cand - target))])
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
  .demo_par()

  pal <- .demo_pal_qual(2)
  series <- pal[[1]]
  highlight <- pal[[2]]

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
  graphics::lines(L, res$auc, col = series, lwd = 1.5)
  .demo_points(L, res$auc, bg = series, cex = 1.3)

  b <- res$best_layer
  by <- res$auc[match(b, L)]
  graphics::abline(v = b, lty = 3, col = grDevices::adjustcolor(highlight, 0.4))
  .demo_points(b, by, bg = highlight, cex = 1.7)
  graphics::text(max(L), ylo + 0.04,
    labels = sprintf("best: layer %d\nAUC %.2f", b, res$best_auc),
    adj = c(1, 0), font = 2, col = highlight, cex = 0.95
  )
  .demo_subtitle(res$model, res$n, extra = "95% bootstrap CI")
  invisible(res)
}

# ---- per-layer probe: OOF AUC + CI + the probe direction ---------------------

# One cross-validated ridge-logistic probe per layer (the money-plot engine),
# returning both the out-of-fold AUC + bootstrap CI and the probe DIRECTION
# (the lambda.min coefficient vector, unit-normalized and oriented toward the
# positive class). `rows` optionally restricts the layer matrix to a subset of
# prompts (A1 traces two concepts in one pass and probes each on its own rows).
# The AUC/CI path is identical to the original inline loop, so the core money
# plot is byte-for-byte unchanged; `dirs` is the only addition.
.demo_A_probe_by_layer <- function(tr, band, y, foldid, rows = NULL) {
  yf <- factor(ifelse(y, "pos", "neg"), levels = c("neg", "pos"))
  auc <- lower <- upper <- numeric(length(band))
  dirs <- vector("list", length(band))
  for (i in seq_along(band)) {
    x <- .demo_A_layer_matrix(tr, band[[i]])
    if (!is.null(rows)) x <- x[rows, , drop = FALSE]
    cvfit <- glmnet::cv.glmnet(
      x, yf,
      family = "binomial", alpha = 0, # ridge: hidden_size >> n (p >> n)
      foldid = foldid, type.measure = "auc", keep = TRUE
    )
    oof <- cvfit$fit.preval[, match(cvfit$lambda.min, cvfit$lambda)]
    ci <- demo_auc_ci(oof, y, seed = 1L)
    auc[[i]] <- ci[["auc"]]
    lower[[i]] <- ci[["lower"]]
    upper[[i]] <- ci[["upper"]]
    beta <- as.numeric(stats::coef(cvfit, s = "lambda.min"))[-1L] # drop intercept
    d <- .demo_unit(beta)
    if (demo_auc(as.numeric(x %*% d), y) < 0.5) d <- -d # orient toward positive
    dirs[[i]] <- d
  }
  best_i <- which.max(auc)
  list(
    auc = auc, lower = lower, upper = upper, dirs = dirs,
    best_i = best_i, best_layer = band[[best_i]], best_auc = auc[[best_i]]
  )
}

# ==============================================================================
# The five extended analyses (behind run_demo_A(extended = TRUE)). Each returns a
# plain list of numeric results and draws one base-graphics figure via the shared
# demo-utils style helpers. All prompt/exemplar/coefficient/neuron grids are fixed
# and committed (no cherry-picking, WP7); fixed seeds => byte-identical numbers.
# ==============================================================================

# ---- A1: multi-concept decodability overlay ----------------------------------

# The two concepts' AUC curves both saturate at the ceiling on a capable model, so
# "peak layer" is a weak descriptor. The honest, robust contrast is the RISE-SHAPE:
# the first layer from which decodability stays >= this threshold (sustained onset).
.DEMO_A1_ONSET_THR <- 0.9

# Trace sentiment AND formality in a SINGLE forward pass, then probe each concept
# per layer. The story is the rise-shape difference: register (formality) is a
# surface feature readable from the very first layer, while sentiment is noisy early
# and only stabilizes with depth.
.demo_A1_run <- function(m, say) {
  sent <- c(.demo_A_train_pos, .demo_A_train_neg)
  form <- c(.demo_A_formal, .demo_A_casual)
  y_sent <- c(rep(TRUE, length(.demo_A_train_pos)), rep(FALSE, length(.demo_A_train_neg)))
  y_form <- c(rep(TRUE, length(.demo_A_formal)), rep(FALSE, length(.demo_A_casual)))
  say("A1: tracing sentiment + formality in one pass ...")
  tr <- rebirth::llm_trace(m, c(sent, form),
    layers = NULL, positions = "last", components = "residual"
  )
  band <- sort(unique(tr$layer))
  idx_sent <- seq_along(sent)
  idx_form <- length(sent) + seq_along(form)
  ps <- .demo_A_probe_by_layer(tr, band, y_sent, .demo_A_foldid(y_sent), rows = idx_sent)
  pf <- .demo_A_probe_by_layer(tr, band, y_form, .demo_A_foldid(y_form), rows = idx_form)
  onset_sent <- .demo_sustained_onset(ps$auc, band, .DEMO_A1_ONSET_THR)
  onset_form <- .demo_sustained_onset(pf$auc, band, .DEMO_A1_ONSET_THR)
  say(sprintf(
    "A1: sustained AUC >= %.2f from L%s (sentiment) vs L%s (formality); early-layer AUC %.3f vs %.3f",
    .DEMO_A1_ONSET_THR, onset_sent, onset_form, ps$auc[[1L]], pf$auc[[1L]]
  ))
  list(
    band = band, sentiment = ps, formality = pf,
    onset_sent = onset_sent, onset_form = onset_form, thr = .DEMO_A1_ONSET_THR,
    n = length(sent) + length(form), model = m$path
  )
}

.demo_A1_plot <- function(a1, file = NULL) {
  if (!is.null(file)) {
    grDevices::png(file, width = 1100, height = 750, res = 130)
    on.exit(grDevices::dev.off(), add = TRUE)
  }
  op <- graphics::par(no.readonly = TRUE)
  on.exit(graphics::par(op), add = TRUE)
  .demo_par()
  pal <- .demo_pal_qual(2)
  col_sent <- pal[[1]]
  col_form <- pal[[2]]
  L <- a1$band
  ylo <- min(0.45, min(a1$sentiment$lower, a1$formality$lower) - 0.02)
  plot(L, a1$sentiment$auc,
    type = "n", ylim = c(ylo, 1.0), xlim = range(L),
    xlab = "Transformer layer", ylab = "Probe AUC (out-of-fold)",
    main = "Formality reads from layer 1; sentiment emerges with depth"
  )
  graphics::grid(nx = NA, ny = NULL, col = "grey92", lty = 1)
  graphics::abline(h = 0.5, lty = 2, col = "grey45")
  graphics::text(min(L), 0.5, "chance", pos = 3, offset = 0.2, col = "grey45", cex = 0.8)
  # Mark where sentiment's decodability first stabilizes (its sustained onset): the
  # depth the register signal never needed. Formality's onset is layer 1, so its
  # marker would sit on the axis -- the legend states it instead.
  fmt_onset <- function(o) if (is.na(o)) "not sustained" else sprintf("L%d", o)
  if (!is.na(a1$onset_sent) && a1$onset_sent > min(L)) {
    graphics::abline(v = a1$onset_sent, lty = 3, col = grDevices::adjustcolor(col_sent, 0.55))
    graphics::text(a1$onset_sent, ylo + 0.02,
      labels = sprintf("sentiment stabilizes\n(AUC >= %.2f from %s)", a1$thr, fmt_onset(a1$onset_sent)),
      pos = 4, offset = 0.3, col = col_sent, cex = 0.8, font = 2)
  }
  draw_series <- function(p, col) {
    graphics::arrows(L, p$lower, L, p$upper, angle = 90, code = 3, length = 0.03,
      col = grDevices::adjustcolor(col, 0.5))
    graphics::lines(L, p$auc, col = col, lwd = 1.5)
    .demo_points(L, p$auc, bg = col, cex = 1.2)
  }
  draw_series(a1$sentiment, col_sent)
  draw_series(a1$formality, col_form)
  graphics::legend("bottomright",
    legend = c(
      sprintf("sentiment: noisy early, readable from %s", fmt_onset(a1$onset_sent)),
      sprintf("formality: readable from %s (surface register)", fmt_onset(a1$onset_form))
    ),
    col = c(col_sent, col_form), pt.bg = c(col_sent, col_form),
    pch = .DEMO_PCH, lwd = 1.5, bty = "n", cex = 0.9
  )
  .demo_subtitle(a1$model, a1$n,
    extra = sprintf("one trace | onset = sustained AUC >= %.2f | 95%% CI", a1$thr))
  invisible(a1)
}

# ---- A2: token x layer concept heatmap ---------------------------------------

# Choose the layer band so the positions = "all" capture stays comfortably in
# memory (D-017: budget on the MATERIALIZED bytes, K = 11 -- the twin-pinned
# TRACE_MATERIALIZED_EXPANSION in trace.rs). The estimate is printed; a big model
# is banded down to keep the trace in memory (A2 needs the in-memory token column).
.demo_A2_layers <- function(m, n_tokens_total, say, mem_target = 0.8e9) {
  k_expand <- 11 # D-017 materialized-bytes expansion factor (trace.rs)
  per_layer <- as.double(n_tokens_total) * m$hidden_size * 4 * k_expand
  est_all <- per_layer * m$layers
  say(sprintf(
    "A2: positions='all', %d tokens x %d layers ~= %.0f MB materialized (D-017)",
    n_tokens_total, m$layers, est_all / 1e6
  ))
  if (est_all <= mem_target) {
    return(seq_len(m$layers))
  }
  n_fit <- max(4L, as.integer(floor(mem_target / per_layer)))
  band <- unique(round(seq(1, m$layers, length.out = min(n_fit, m$layers))))
  say(sprintf("A2: banding to %d layers (~%.0f MB) to stay in memory", length(band),
    length(band) * per_layer / 1e6))
  as.integer(band)
}

# Clean token pieces for axis labels: drop the leading word-boundary space, show a
# visible marker for a blank piece.
.demo_A2_clean_tokens <- function(t) {
  t <- gsub("^[[:space:]▁Ġ]+", "", t) # SentencePiece / GPT2 space markers
  t[!nzchar(t)] <- "_"
  t
}

.demo_A2_run <- function(m, best_dir, say, mem_target = 0.8e9) {
  ex <- .demo_A_exemplars
  counts <- lengths(rebirth::llm_tokens(m, ex))
  n_tok <- sum(counts)
  band <- .demo_A2_layers(m, n_tok, say, mem_target)
  tr <- rebirth::llm_trace(m, ex, layers = band, positions = "all", components = "residual")
  if (isTRUE(attr(tr, "spilled"))) {
    stop("A2 trace spilled unexpectedly; lower the exemplar count or the layer band.")
  }
  # One row per (prompt_id, token_pos), ordered exactly as as.matrix() returns them.
  key <- tr[tr$layer == band[[1L]] & tr$component == "residual" & tr$neuron == 1L,
    c("prompt_id", "token_pos", "token")]
  key <- key[order(key$prompt_id, key$token_pos), , drop = FALSE]
  # Projection onto the best-layer probe direction for every (token, layer).
  proj <- vapply(band, function(L) {
    as.numeric(as.matrix(tr, layer = L, component = "residual") %*% best_dir)
  }, numeric(nrow(key)))
  # Drop each sentence's FIRST token: position 1 is an attention sink whose residual
  # has an anomalous, sentiment-agnostic magnitude that otherwise dominates the
  # per-layer scale and flattens every content token. Then z-standardize the
  # remaining content tokens WITHIN each layer, so per-token contrast is comparable
  # at every depth (later layers project onto the best-layer direction meaningfully;
  # early layers carry little of it, which the heatmap shows honestly).
  keep <- key$token_pos > 1L
  proj <- proj[keep, , drop = FALSE]
  key <- key[keep, , drop = FALSE]
  z <- apply(proj, 2L, function(p) (p - mean(p)) / stats::sd(p))
  say(sprintf("A2: heatmap over %d content tokens x %d layers", nrow(key), length(band)))
  list(
    z = z, tokens = key$token, pid = key$prompt_id, band = band,
    exemplar_pos = .demo_A_exemplar_pos, model = m$path
  )
}

.demo_A2_plot <- function(a2, file = NULL) {
  if (!is.null(file)) {
    grDevices::png(file, width = 1300, height = 780, res = 130)
    on.exit(grDevices::dev.off(), add = TRUE)
  }
  op <- graphics::par(no.readonly = TRUE)
  on.exit(graphics::par(op), add = TRUE)
  n_col <- 32L
  # Cap the symmetric scale at a robust quantile so a lone extreme content token does
  # not wash out the rest (the display clips; the underlying z is unchanged).
  zcap <- min(max(stats::quantile(abs(a2$z), 0.98, names = FALSE), 1), 3)
  zc <- pmax(pmin(a2$z, zcap), -zcap)
  breaks <- .demo_legend_breaks(c(-zcap, zcap), n_col)
  pal <- .demo_pal_seq(n_col, rev = FALSE) # dark = strong positive-sentiment signal
  graphics::layout(matrix(c(1L, 2L), nrow = 1L), widths = c(6, 1))

  .demo_par(mar = c(7.6, 4.4, 3.4, 0.6))
  n_tok <- nrow(a2$z)
  graphics::image(
    x = seq_len(n_tok), y = a2$band, z = zc, col = pal, breaks = breaks,
    axes = FALSE, xlab = "", ylab = "Transformer layer",
    main = "Token x layer: where the sentiment signal lives"
  )
  graphics::axis(2, at = pretty(a2$band))
  graphics::axis(1,
    at = seq_len(n_tok), labels = .demo_A2_clean_tokens(a2$tokens),
    las = 2, cex.axis = 0.5, tick = FALSE, mgp = c(3, 0.4, 0)
  )
  graphics::box(col = "grey60")
  # exemplar separators + a coloured index label per exemplar (pos / neg), placed
  # above the plot; the subtitle moves to the bottom so nothing collides.
  bnd <- which(diff(a2$pid) != 0L) + 0.5
  graphics::abline(v = bnd, col = "white", lwd = 1.6)
  pal2 <- .demo_pal_qual(2)
  centers <- tapply(seq_len(n_tok), a2$pid, mean)
  ex_ids <- as.integer(names(centers))
  for (j in seq_along(centers)) {
    ex <- ex_ids[[j]]
    graphics::mtext(sprintf("%d%s", ex, if (a2$exemplar_pos[[ex]]) "+" else "-"),
      side = 3, at = centers[[j]], line = 0.25, cex = 0.7, font = 2,
      col = if (a2$exemplar_pos[[ex]]) pal2[[1]] else pal2[[2]]
    )
  }
  graphics::mtext(
    .demo_subtitle_text(a2$model, length(a2$exemplar_pos), extra = "content tokens | z per layer"),
    side = 1, line = 6.4, cex = 0.75, col = "grey35"
  )

  .demo_color_strip_legend(breaks, pal, title = "z")
  invisible(a2)
}

# ---- A3: steering dose-response curve ----------------------------------------

# Sweep the steering coefficient over a symmetric committed grid (multiples of the
# positive-negative gap) at the committed mid-depth steer layer (.demo_A_steer_layer,
# NOT best_layer -- see there); generate from the held-out neutral leads and score
# each continuation through the CLEAN handle (D-016). The grid is dense near zero
# (for a clean local slope) and reaches a committed tail so the saturation/
# degradation of over-steering is ALWAYS shown (honesty guard) -- but the dense
# default region stays in the coherent regime, so the positive side rises to a
# saturation tail rather than sitting in the degenerate zone.
.demo_A3_run <- function(m, tr, band, y, say,
                         mults = c(-2.5, -1.5, -1, -0.5, -0.25, 0,
                                   0.25, 0.5, 1, 1.5, 2.5)) {
  steer_layer <- .demo_A_steer_layer(band)
  x <- .demo_A_layer_matrix(tr, steer_layer)
  dir <- .demo_A_direction(x, y)
  proj <- as.numeric(x %*% dir)
  gap <- mean(proj[y]) - mean(proj[!y])
  leads <- .demo_A_neutral
  sentiment <- function(txt) {
    # Extreme steering can degenerate a continuation to empty; llm_trace rejects
    # "" so score such a case at a neutral placeholder rather than crash the sweep.
    txt[!nzchar(trimws(txt))] <- "."
    trg <- rebirth::llm_trace(m, txt, layers = steer_layer, positions = "last",
      components = "residual")
    as.numeric(.demo_A_layer_matrix(trg, steer_layer) %*% dir)
  }
  g_base <- rebirth::llm_generate(m, leads, max_tokens = 32L, temperature = 0,
    seed = 1L, chat = TRUE)
  s_base <- sentiment(g_base)

  n <- length(mults)
  means <- lower <- upper <- numeric(n)
  per_lead <- matrix(NA_real_, nrow = length(leads), ncol = n)
  samples <- vector("list", n)
  for (j in seq_len(n)) {
    if (mults[[j]] == 0) {
      shift <- rep(0, length(leads))
      samples[[j]] <- g_base
    } else {
      ms <- rebirth::llm_steer(m, layer = steer_layer, direction = dir, coef = mults[[j]] * gap)
      g <- tryCatch(
        rebirth::llm_generate(ms, leads, max_tokens = 32L, temperature = 0,
          seed = 1L, chat = TRUE),
        finally = close(ms)
      )
      shift <- sentiment(g) - s_base
      samples[[j]] <- g
    }
    per_lead[, j] <- shift
    ci <- .demo_boot_mean_ci(shift, seed = 1L)
    means[[j]] <- ci[["mean"]]
    lower[[j]] <- ci[["lower"]]
    upper[[j]] <- ci[["upper"]]
  }
  cen <- which(abs(mults) <= 1 + 1e-9) # local slope near zero
  slope <- unname(stats::coef(stats::lm(means[cen] ~ mults[cen]))[[2L]])
  say(sprintf(
    "A3: dose-response @ L%d, gap %.3f, local slope %.3f/gap, mean-shift range [%.3f, %.3f]",
    steer_layer, gap, slope, min(means), max(means)
  ))
  list(
    mults = mults, means = means, lower = lower, upper = upper, per_lead = per_lead,
    slope = slope, steer_layer = steer_layer, gap = gap, samples = samples,
    n = length(leads), model = m$path
  )
}

.demo_A3_plot <- function(a3, file = NULL) {
  if (!is.null(file)) {
    grDevices::png(file, width = 1050, height = 900, res = 130)
    on.exit(grDevices::dev.off(), add = TRUE)
  }
  op <- graphics::par(no.readonly = TRUE)
  on.exit(graphics::par(op), add = TRUE)
  graphics::layout(matrix(c(1L, 2L), nrow = 2L), heights = c(3, 2))
  pal <- .demo_pal_qual(2)

  .demo_par(mar = c(2.4, 4.6, 3.4, 1.2))
  yr <- range(a3$lower, a3$upper)
  plot(a3$mults, a3$means,
    type = "n", ylim = yr, xlab = "", ylab = "Mean sentiment shift",
    main = "Steering is a dial: dose-response (full swept range)"
  )
  graphics::abline(h = 0, col = "grey60")
  graphics::abline(v = 0, col = "grey85", lty = 3)
  graphics::arrows(a3$mults, a3$lower, a3$mults, a3$upper, angle = 90, code = 3,
    length = 0.03, col = "grey30")
  graphics::lines(a3$mults, a3$means, col = pal[[1]], lwd = 1.6)
  .demo_points(a3$mults, a3$means, bg = pal[[1]], cex = 1.3)
  graphics::mtext(sprintf("local slope near 0: %.3f per gap-unit", a3$slope),
    side = 3, line = -1.2, adj = 0.02, cex = 0.8, col = "grey30")
  .demo_subtitle(a3$model, a3$n, seed = 1,
    extra = sprintf("steer L%d | greedy", a3$steer_layer))

  .demo_par(mar = c(4.4, 4.6, 0.6, 1.2))
  graphics::matplot(a3$mults, t(a3$per_lead),
    type = "l", lty = 1, lwd = 1, col = grDevices::adjustcolor(pal[[2]], 0.55),
    xlab = "steering coefficient (multiples of the positive-negative gap)",
    ylab = "Per-lead shift"
  )
  graphics::abline(h = 0, col = "grey60")
  graphics::abline(v = 0, col = "grey85", lty = 3)
  invisible(a3)
}

# ---- A4: targeted-vs-matched-random ablation effect curve --------------------

# Split an llm_logits() frame into one named probability vector per prompt (names
# = token ids), the input the truncated-KL helper consumes.
.demo_A_split_logits <- function(lg) {
  lapply(sort(unique(lg$prompt_id)), function(pid) {
    sub <- lg[lg$prompt_id == pid, , drop = FALSE]
    stats::setNames(sub$prob, as.character(sub$token_id))
  })
}

# Ablate top-k residual units vs a matched random-k at the best layer, measuring
# the mean next-token KL from base over the committed eliciting prompts. The MONEY
# figure (.demo_A4_plot) claims exactly one thing -- ablation is UNIT-SPECIFIC:
#   IMPACT   -- the top-k units by residual MAGNITUDE (RMS across the contrast set):
#               the outlier / "massive-activation" dimensions that carry most of the
#               residual norm and are load-bearing for next-token prediction on ANY
#               prompt, for any concept. Ablating them dwarfs a matched-random set.
#               This is the faithful promotion of the WP5 honesty fixture
#               (calibrate_kl in intervene_kl.rs), whose targeted neurons were ranked
#               by MEASURED ablation-KL, not probe coefficients -- the RMS ranking is
#               its zero-cost, trace-derived proxy for that same impact family.
#   RANDOM   -- averaged over `n_random` size-matched draws so one unlucky draw
#               (hitting a rogue unit, common at large k) does not dominate it (the
#               WP5 fixture averages 3 seeds).
# A third ranking is also RECORDED but is NOT in the money figure (D-022 impl. note):
#   CONCEPT  -- the top-k units by |probe coefficient|: where sentiment is most
#               linearly READABLE. On real models this set is nearly disjoint from
#               the impact set and is no more disruptive than matched random --
#               decodability is not the causal locus. That decodability != causality
#               story (with its A3 reconciliation and the magnitude caveat that makes
#               "below random" unclaimable) lives in the anatomy-lab vignette; here
#               the series is kept in the returned data and drawn only by the
#               supplementary .demo_A4_plot_decodability().
# The matched-random control hugs zero. Verified on Qwen2.5-0.5B: impact/random ~
# 70-2000x across all k, random < 0.07, concept ~ random -- re-checked on the demo
# model on the founder's Mac + nightly.
.demo_A4_run <- function(m, tr, best_layer, best_dir, say,
                         ks = c(1L, 2L, 4L, 8L, 16L, 32L, 64L),
                         top = 256L, seed = 20240707L, n_random = 5L) {
  prompts <- .demo_A_eliciting # peaked next token => a measurable, controlled effect
  hidden <- m$hidden_size
  act_rms <- sqrt(colMeans(.demo_A_layer_matrix(tr, best_layer)^2))
  ord_impact <- order(act_rms, decreasing = TRUE)
  ord_concept <- order(abs(best_dir), decreasing = TRUE)

  base_by <- .demo_A_split_logits(rebirth::llm_logits(m, prompts, top = top))
  base_top1 <- vapply(base_by, function(v) names(v)[which.max(v)], character(1))
  effect <- function(neurons) {
    ma <- rebirth::llm_ablate(m, layer = best_layer, neurons = neurons)
    lg <- tryCatch(rebirth::llm_logits(ma, prompts, top = top), finally = close(ma))
    by <- .demo_A_split_logits(lg)
    kl <- vapply(seq_along(prompts),
      function(p) .demo_next_token_kl(base_by[[p]], by[[p]]), numeric(1))
    t1 <- vapply(by, function(v) names(v)[which.max(v)], character(1))
    list(kl = kl, changed = mean(t1 != base_top1))
  }

  mk <- function() list(mean = numeric(length(ks)), lower = numeric(length(ks)),
    upper = numeric(length(ks)), changed = numeric(length(ks)))
  det_fill <- function(dst, e, i) {
    ci <- .demo_boot_mean_ci(e$kl, seed = 1L)
    dst$mean[[i]] <- ci[["mean"]]
    dst$lower[[i]] <- ci[["lower"]]
    dst$upper[[i]] <- ci[["upper"]]
    dst$changed[[i]] <- e$changed
    dst
  }
  impact <- concept <- rnd <- mk()
  last_impact <- last_random <- NULL
  for (i in seq_along(ks)) {
    k <- ks[[i]]
    ei <- effect(ord_impact[seq_len(k)])
    ec <- effect(ord_concept[seq_len(k)])
    er <- lapply(seq_len(n_random), function(s) {
      effect(.demo_with_seed(seed + 1000L * s + k, sample.int(hidden, k)))
    })
    impact <- det_fill(impact, ei, i)
    concept <- det_fill(concept, ec, i)
    er_kl <- vapply(er, `[[`, numeric(length(prompts)), "kl") # [n_prompts x n_random]
    ci <- .demo_boot_mean_ci(as.numeric(er_kl), seed = 1L) # pooled across seeds
    rnd$mean[[i]] <- ci[["mean"]]
    rnd$lower[[i]] <- ci[["lower"]]
    rnd$upper[[i]] <- ci[["upper"]]
    rnd$changed[[i]] <- mean(vapply(er, `[[`, numeric(1), "changed"))
    last_impact <- ei$kl
    last_random <- rowMeans(er_kl) # per-prompt, seed-averaged (paired with impact)
  }
  # The acceptance honesty check: the impact-targeted set dominates matched-random.
  p_val <- suppressWarnings(stats::wilcox.test(last_impact, last_random,
    paired = TRUE, alternative = "greater")$p.value)
  out <- list(ks = ks, layer = best_layer, impact = impact, concept = concept,
    random = rnd, p_value = p_val, n = length(prompts), model = m$path)
  out$acceptance <- list(
    nightly = .demo_A4_accept(out, "nightly"),
    model = .demo_A4_accept(out, "model")
  )
  k8 <- match(8L, ks)
  say(sprintf(
    "A4: @L%d unit-specificity impact/random = %.0fx @k=8 (impact %.3f vs random %.3f); concept-readout %.3f ~ random (no more disruptive); impact>random p=%.3g",
    best_layer, out$acceptance$nightly$ratio_k8, impact$mean[[k8]], rnd$mean[[k8]],
    concept$mean[[k8]], p_val
  ))
  say(sprintf(
    "A4 acceptance: nightly(0.5B) %s | model(E4B) %s [random_max %.3f, k=8 ratio %.0fx, p %.3g]",
    if (out$acceptance$nightly$pass) "PASS" else "FAIL",
    if (out$acceptance$model$pass) "PASS" else "FAIL",
    out$acceptance$nightly$random_max, out$acceptance$nightly$ratio_k8, p_val
  ))
  out
}

# Executable A4 acceptance thresholds (D-022 implementation note). Two tiers:
#   "nightly" (Qwen2.5-0.5B Q8_0, the nightly-demo-A gate): the matched-random
#             pooled mean KL <= 0.10 nats at EVERY k; the impact set >= 10x random at
#             k = 8; the paired one-sided Wilcoxon p <= 0.01 at max k (its floor at
#             n = 8 prompts is 1/2^8 = 0.0039, so this needs every prompt to shift
#             more under impact than random).
#   "model"  (Gemma 4 E4B on the founder's Mac, the [MODEL] showcase): impact >= 5x
#             random at k = 8 (the smaller/quantized showcase clears a lower bar).
# The concept-readout series is RECORDED, never gated: it is an empirical finding
# that may legitimately differ across models, and gating would freeze it into CI.
# Returns per-check flags + the measured values; `$pass` is their conjunction.
.demo_A4_accept <- function(a4, tier = c("nightly", "model")) {
  tier <- match.arg(tier)
  k8 <- match(8L, a4$ks)
  if (is.na(k8)) stop("A4 acceptance requires k = 8 in the sweep")
  ratio_k8 <- a4$impact$mean[[k8]] / max(a4$random$mean[[k8]], .Machine$double.eps)
  random_max <- max(a4$random$mean)
  checks <- list(impact_ratio = ratio_k8 >= if (tier == "nightly") 10 else 5)
  if (tier == "nightly") {
    checks$random_hugs_zero <- random_max <= 0.10
    checks$wilcoxon <- isTRUE(a4$p_value <= 0.01)
  }
  list(tier = tier, pass = all(unlist(checks)), checks = checks,
    ratio_k8 = ratio_k8, random_max = random_max, p_value = a4$p_value)
}

# Shared A4 log-y KL panel drawer. `series` is a list of list(data, col, cex),
# drawn back-to-front; the last entry sits on top. Draws the axes, the CI bands, the
# lines+points, then a legend from `legend`/`legcol`, and the model|n subtitle. Both
# the two-series money figure and the three-series supplementary figure use it, so
# they share one axis/floor/scale convention exactly.
.demo_A4_kl_panel <- function(a4, series, main, legend, legcol, sub_extra) {
  xx <- log2(a4$ks)
  .demo_par(mar = c(2.4, 4.6, 3.4, 1.2))
  # log-y: the effect spans orders of magnitude (impact ~ 1, random/concept ~ 1e-3);
  # a floor keeps a near-zero value plottable without claiming an exact 0.
  floor_kl <- 1e-4
  pos <- function(v) pmax(v, floor_kl)
  ymax <- max(vapply(series, function(s) max(s[[1]]$upper, na.rm = TRUE), numeric(1)))
  plot(xx, pos(a4$impact$mean), type = "n", log = "y", yaxt = "n", xaxt = "n",
    ylim = c(floor_kl, ymax * 1.4), xlab = "", ylab = "Mean next-token KL (log)",
    main = main)
  aty <- 10^(seq(floor(log10(floor_kl)), ceiling(log10(ymax))))
  graphics::axis(2, at = aty, labels = formatC(aty, format = "g"))
  graphics::abline(h = aty, col = "grey93", lty = 1)
  for (s in series) {
    graphics::arrows(xx, pos(s[[1]]$lower), xx, pos(s[[1]]$upper), angle = 90,
      code = 3, length = 0.03, col = grDevices::adjustcolor(s[[2]], 0.5))
  }
  for (s in series) {
    graphics::lines(xx, pos(s[[1]]$mean), col = s[[2]], lwd = 1.6)
    .demo_points(xx, pos(s[[1]]$mean), bg = s[[2]], cex = s[[3]])
  }
  graphics::legend("topleft", legend = legend, col = legcol, pt.bg = legcol,
    pch = .DEMO_PCH, lwd = 1.6, bty = "n", cex = 0.85)
  .demo_subtitle(a4$model, a4$n, extra = sub_extra)
}

# Shared A4 "top-1 token changed" bottom panel. `series` = list(data, col).
.demo_A4_changed_panel <- function(a4, series) {
  xx <- log2(a4$ks)
  .demo_par(mar = c(4.4, 4.6, 0.6, 1.2))
  plot(xx, a4$impact$changed, type = "n", ylim = c(0, 1), xaxt = "n",
    xlab = "neurons ablated (k)", ylab = "Top-1 token changed")
  for (s in series) {
    graphics::lines(xx, s[[1]]$changed, col = s[[2]], lwd = 1.4)
    .demo_points(xx, s[[1]]$changed, bg = s[[2]], cex = 1.0)
  }
  graphics::axis(1, at = xx, labels = a4$ks)
}

# The A4 money figure: TWO series only -- top-RMS "load-bearing" units vs matched
# random. It claims exactly unit-specificity (D-022 impl. note): which units you
# remove is everything. The concept-readout series is deliberately absent here (it
# is recorded and lives in the supplementary decodability figure + the vignette).
.demo_A4_plot <- function(a4, file = NULL) {
  if (!is.null(file)) {
    grDevices::png(file, width = 1050, height = 950, res = 130)
    on.exit(grDevices::dev.off(), add = TRUE)
  }
  op <- graphics::par(no.readonly = TRUE)
  on.exit(graphics::par(op), add = TRUE)
  graphics::layout(matrix(c(1L, 2L), nrow = 2L), heights = c(3, 2))
  pal <- .demo_pal_qual(2)
  col_impact <- pal[[1]]
  col_random <- "grey45"
  ki <- match(if (8L %in% a4$ks) 8L else max(a4$ks), a4$ks)
  ratio8 <- a4$impact$mean[[ki]] / max(a4$random$mean[[ki]], .Machine$double.eps)

  .demo_A4_kl_panel(a4,
    series = list(list(a4$random, col_random, 1.3), list(a4$impact, col_impact, 1.3)),
    main = "Ablation is unit-specific: load-bearing units vs matched random",
    legend = c("load-bearing units (top-k by residual RMS)",
      "matched random-k (control, averaged)"),
    legcol = c(col_impact, col_random),
    sub_extra = sprintf("ablate L%d | impact %.0fx random @k=%d | p=%.2g",
      a4$layer, ratio8, a4$ks[[ki]], a4$p_value))

  .demo_A4_changed_panel(a4,
    list(list(a4$random, col_random), list(a4$impact, col_impact)))
  invisible(a4)
}

# The supplementary THREE-series figure (impact + random + concept-readout) for the
# anatomy-lab vignette's "Reading is not causing" subsection. Adding the concept-
# readout ranking (top-k by |probe coef|) exposes the decodability != causality gap:
# the units where sentiment is most READABLE are no more disruptive than matched
# random. "No more disruptive than random" is the only honest claim -- the count-
# matched randoms carry a larger typical magnitude, so a "below random" reading is a
# magnitude confound (the vignette spells this out), not a finding.
.demo_A4_plot_decodability <- function(a4, file = NULL) {
  if (!is.null(file)) {
    grDevices::png(file, width = 1050, height = 950, res = 130)
    on.exit(grDevices::dev.off(), add = TRUE)
  }
  op <- graphics::par(no.readonly = TRUE)
  on.exit(graphics::par(op), add = TRUE)
  graphics::layout(matrix(c(1L, 2L), nrow = 2L), heights = c(3, 2))
  pal <- .demo_pal_qual(3)
  col_impact <- pal[[1]]
  col_concept <- pal[[3]]
  col_random <- "grey45"

  .demo_A4_kl_panel(a4,
    series = list(list(a4$random, col_random, 1.3), list(a4$concept, col_concept, 1.0),
      list(a4$impact, col_impact, 1.3)),
    main = "Reading is not causing: readable units are not the causal locus",
    legend = c("load-bearing units (top-k by residual RMS)",
      "matched random-k (control, averaged)",
      "concept-readout units (top-k by |probe coef|)"),
    legcol = c(col_impact, col_random, col_concept),
    sub_extra = sprintf("ablate L%d | concept-readout ~ matched random", a4$layer))

  .demo_A4_changed_panel(a4,
    list(list(a4$concept, col_concept), list(a4$random, col_random),
      list(a4$impact, col_impact)))
  invisible(a4)
}

# ---- A5: concept-direction geometry across layers ----------------------------

# Layer x layer cosine similarity of the per-layer probe directions: does one axis
# persist through depth, or does the representation reorganize? Plus the adjacent-
# layer alignment trace.
.demo_A5_run <- function(dirs, band, model, say) {
  cmat <- .demo_cosine_matrix(do.call(rbind, dirs))
  adj <- vapply(seq_len(nrow(cmat) - 1L), function(i) cmat[i, i + 1L], numeric(1))
  say(sprintf("A5: mean adjacent-layer alignment %.3f (range %.3f .. %.3f)",
    mean(adj), min(adj), max(adj)))
  list(cos = cmat, band = band, adjacent = adj, model = model)
}

.demo_A5_plot <- function(a5, file = NULL) {
  if (!is.null(file)) {
    grDevices::png(file, width = 1150, height = 1000, res = 130)
    on.exit(grDevices::dev.off(), add = TRUE)
  }
  op <- graphics::par(no.readonly = TRUE)
  on.exit(graphics::par(op), add = TRUE)
  n_col <- 32L
  breaks <- .demo_legend_breaks(c(-1, 1), n_col) # symmetric diverging scale
  pal <- .demo_pal_div(n_col)
  # Draw order = image (top-left), adjacent-cos trace (bottom-left), legend (right,
  # full height) LAST -- the colour-strip legend saves/restores par(), so it must be
  # the final panel or it disrupts the ones after it.
  graphics::layout(matrix(c(1L, 3L, 2L, 3L), nrow = 2L, byrow = TRUE),
    widths = c(6, 1), heights = c(4, 1.5))

  .demo_par(mar = c(4.4, 4.4, 3.4, 0.6))
  L <- a5$band
  graphics::image(x = L, y = L, z = a5$cos, col = pal, breaks = breaks, zlim = c(-1, 1),
    xlab = "Transformer layer", ylab = "Transformer layer",
    main = "Concept-direction geometry: layer x layer cosine")
  graphics::box(col = "grey60")
  # Left-anchor the subtitle (adj = 0): a long model name would otherwise reach the
  # right edge and collide with the "cos" colour-key title above the legend strip.
  .demo_subtitle(a5$model, length(L), extra = "per-layer probe directions", adj = 0)

  .demo_par(mar = c(4.2, 4.4, 1.2, 0.6))
  pal2 <- .demo_pal_qual(1)
  xa <- L[-length(L)]
  plot(xa, a5$adjacent, type = "n", ylim = c(min(0, min(a5$adjacent)), 1),
    xlab = "Transformer layer", ylab = "Adjacent cos",
    main = "Adjacent-layer alignment")
  graphics::abline(h = 0, col = "grey75", lty = 3)
  graphics::lines(xa, a5$adjacent, col = pal2[[1]], lwd = 1.5)
  .demo_points(xa, a5$adjacent, bg = pal2[[1]], cex = 1.0)

  .demo_color_strip_legend(breaks, pal, title = "cos")
  invisible(a5)
}

# ---- extended orchestrator ---------------------------------------------------

# Run A1-A5 and (when plot_dir is set) write the five PNGs. Reuses the core trace
# `tr`, layer band, and per-layer probe (its directions) wherever possible so the
# extra work stays within the +10 min budget (D-022).
.demo_A_extended <- function(m, tr, band, probe, y, plot_dir, say) {
  fp <- function(name) if (is.null(plot_dir)) NULL else file.path(plot_dir, name)
  best_dir <- probe$dirs[[probe$best_i]]

  a1 <- .demo_A1_run(m, say)
  .demo_A1_plot(a1, file = fp("demoA-A1-multiconcept.png"))

  a2 <- .demo_A2_run(m, best_dir, say)
  .demo_A2_plot(a2, file = fp("demoA-A2-token-layer.png"))

  a3 <- .demo_A3_run(m, tr, band, y, say)
  .demo_A3_plot(a3, file = fp("demoA-A3-dose-response.png"))

  a4 <- .demo_A4_run(m, tr, probe$best_layer, best_dir, say)
  .demo_A4_plot(a4, file = fp("demoA-A4-ablation.png")) # money: 2 series (unit-specificity)
  # Supplementary 3-series figure feeding the vignette's "Reading is not causing"
  # subsection (impact + random + concept-readout; decodability != causality).
  .demo_A4_plot_decodability(a4, file = fp("demoA-A4-decodability.png"))

  a5 <- .demo_A5_run(probe$dirs, band, m$path, say)
  .demo_A5_plot(a5, file = fp("demoA-A5-geometry.png"))

  list(
    A1 = a1, A2 = a2, A3 = a3, A4 = a4, A5 = a5,
    files = c(
      A1 = fp("demoA-A1-multiconcept.png"), A2 = fp("demoA-A2-token-layer.png"),
      A3 = fp("demoA-A3-dose-response.png"), A4 = fp("demoA-A4-ablation.png"),
      A4_decodability = fp("demoA-A4-decodability.png"),
      A5 = fp("demoA-A5-geometry.png")
    )
  )
}

# ---- the demo ----------------------------------------------------------------

run_demo_A <- function(model_path = .demo_model_path(),
                       layers = NULL, plot_file = NULL,
                       steer_scale = 2, extended = FALSE, plot_dir = NULL,
                       verbose = TRUE) {
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

  # (1) One forward pass, last token of each prompt, all layers.
  say("tracing the contrast set ...")
  tr <- rebirth::llm_trace(m, train, layers = layers, positions = "last",
                           components = "residual")
  band <- sort(unique(tr$layer))

  # (2)+(3) the per-layer OOF probe: AUC + bootstrap CI + the probe direction.
  probe <- .demo_A_probe_by_layer(tr, band, y, .demo_A_foldid(y))
  best_layer <- probe$best_layer
  say(sprintf("peak decodability: layer %d, AUC %.3f", best_layer, probe$best_auc))

  res <- list(
    layers = band, auc = probe$auc, lower = probe$lower, upper = probe$upper,
    best_layer = best_layer, best_auc = probe$best_auc,
    n = length(train), model = model_path
  )

  # (4) the money plot.
  demo_A_plot(res, file = plot_file)

  # (5) steer along the concept direction; verify on HELD-OUT prompts.
  res$steer <- .demo_A_steer_check(m, tr, band, y, steer_scale, say)

  # (6) the extended analyses (A1-A5), behind extended = TRUE (D-022). They write
  # their PNGs into plot_dir (defaulting to plot_file's directory, else the cwd).
  if (isTRUE(extended)) {
    if (is.null(plot_dir)) {
      plot_dir <- if (!is.null(plot_file)) dirname(plot_file) else "."
    }
    say("running the extended analyses A1-A5 ...")
    res$extended <- .demo_A_extended(m, tr, band, probe, y, plot_dir, say)
    res$plot_dir <- plot_dir
  }

  class(res) <- c("demo_A_result", "list")
  res
}

# Verify steering BEHAVIOURALLY on held-out prompts. Interventions apply to
# generation (not to llm_trace, which rejects an intervened handle by grammar),
# so we: generate continuations from neutral leads under +/- steering, then score
# each continuation's sentiment by tracing it through the CLEAN model and
# projecting onto the probe's sentiment axis. Positive steering should yield
# more-positive output than negative steering.
.demo_A_steer_check <- function(m, tr, band, y, steer_scale, say) {
  steer_layer <- .demo_A_steer_layer(band) # mid-depth steerable layer (see there)
  x <- .demo_A_layer_matrix(tr, steer_layer)
  dir <- .demo_A_direction(x, y) # sentiment axis at this layer
  proj <- as.numeric(x %*% dir)
  gap <- mean(proj[y]) - mean(proj[!y]) # positive-negative gap on the axis
  coef <- steer_scale * gap

  m_pos <- rebirth::llm_steer(m, layer = steer_layer, direction = dir, coef = coef)
  m_neg <- rebirth::llm_steer(m, layer = steer_layer, direction = dir, coef = -coef)
  on.exit({
    close(m_pos)
    close(m_neg)
  }, add = TRUE)

  leads <- .demo_A_neutral
  generate <- function(model) {
    rebirth::llm_generate(model, leads, max_tokens = 32L, temperature = 0,
                          seed = 1L, chat = TRUE)
  }
  # Score generated text by tracing it through the CLEAN handle (m) -- never an
  # intervened one -- and projecting the last token onto the sentiment axis.
  sentiment <- function(txt) {
    trg <- rebirth::llm_trace(m, txt, layers = steer_layer, positions = "last",
                              components = "residual")
    as.numeric(.demo_A_layer_matrix(trg, steer_layer) %*% dir)
  }
  g_base <- generate(m)
  g_pos <- generate(m_pos)
  g_neg <- generate(m_neg)
  s_base <- sentiment(g_base)
  s_pos <- sentiment(g_pos)
  s_neg <- sentiment(g_neg)

  # One-sided paired Wilcoxon: does +coef push the OUTPUT more positive, and
  # -coef more negative, than baseline?
  p_up <- suppressWarnings(wilcox.test(s_pos, s_base, paired = TRUE, alternative = "greater")$p.value)
  p_down <- suppressWarnings(wilcox.test(s_neg, s_base, paired = TRUE, alternative = "less")$p.value)
  say(sprintf(
    "steer @ L%d (coef %.2f): output sentiment +%.3f (p=%.3g) / %.3f (p=%.3g)",
    steer_layer, coef, mean(s_pos - s_base), p_up, mean(s_neg - s_base), p_down
  ))

  list(
    steer_layer = steer_layer, coef = coef,
    shift_up = mean(s_pos - s_base), shift_down = mean(s_neg - s_base),
    p_up = p_up, p_down = p_down,
    generations = list(base = g_base, pos = g_pos, neg = g_neg)
  )
}

# ---- auto-run when a model is available --------------------------------------

if (!nzchar(Sys.getenv("REBIRTH_DEMO_NO_AUTORUN"))) {
  .mp <- .demo_model_path()
  if (nzchar(.mp) && file.exists(.mp)) {
    demoA <- run_demo_A(.mp, extended = nzchar(Sys.getenv("REBIRTH_DEMO_EXTENDED")))
  } else {
    message(
      "Demo A: no GGUF model found (set REBIRTH_DEMO_MODEL or ",
      "REBIRTH_TEST_MODEL_QWEN). Functions defined; skipping the end-to-end run."
    )
  }
}
