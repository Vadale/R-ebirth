# tests/demos/demo-utils.R
#
# Model-free helpers for the WP7 / WP7.5b demos. These are repo scripts, NOT part
# of the rebirth package. Per D-020 they replace a pROC dependency with a few
# lines of base R: AUC as the rank-based Mann-Whitney U statistic (exact, average
# ranks for ties) plus a stratified percentile-bootstrap CI. WP7.5b (D-022) adds
# the shared base-graphics visual style and a handful of self-tested numeric
# helpers (bootstrap mean CI, cosine matrix, truncated next-token KL, legend
# breaks) reused by the extended Demo A analyses.
#
# Demo A sources this file; vignette A inlines demo_auc() verbatim -- "AUC needs
# no dependency" is part of the demo's argument. The executable self-test at the
# foot of this file runs on source() and aborts loudly if any identity breaks,
# so the accepted script/vignette duplication is guarded (D-020, point 4).

# ---- AUC: rank-based Mann-Whitney U, exact, ties via average ranks -----------

# Core estimator on two score vectors. AUC = P(pos > neg) + 0.5 * P(pos == neg),
# which equals the normalized Mann-Whitney U. rank()'s default "average" method
# handles ties exactly (a tie contributes 0.5).
.demo_auc_pos_neg <- function(pos, neg) {
  n_pos <- length(pos)
  n_neg <- length(neg)
  r <- rank(c(pos, neg))
  (sum(r[seq_along(pos)]) - n_pos * (n_pos + 1) / 2) / (n_pos * n_neg)
}

# Resolve a binary label vector to a positive-class logical mask. logical labels
# are taken as-is (TRUE = positive); otherwise the two-level factor's second
# level is positive by default (the glmnet/pROC convention), or `positive` names
# it explicitly.
.demo_positive_mask <- function(labels, positive = NULL) {
  if (is.logical(labels)) {
    if (anyNA(labels)) stop("`labels` must not contain NA")
    return(labels)
  }
  f <- as.factor(labels)
  lv <- levels(f)
  if (length(lv) != 2L) {
    stop("AUC needs exactly two classes; found ", length(lv))
  }
  if (is.null(positive)) positive <- lv[2L]
  if (!positive %in% lv) {
    stop(
      "`positive` (", positive, ") is not one of the labels: ",
      paste(lv, collapse = ", ")
    )
  }
  f == positive
}

# demo_auc(scores, labels): AUC of a numeric score against a binary label.
demo_auc <- function(scores, labels, positive = NULL) {
  is_pos <- .demo_positive_mask(labels, positive)
  scores <- as.numeric(scores)
  if (length(scores) != length(is_pos)) {
    stop("`scores` and `labels` must have the same length")
  }
  if (anyNA(scores)) stop("`scores` must not contain NA")
  pos <- scores[is_pos]
  neg <- scores[!is_pos]
  if (length(pos) == 0L || length(neg) == 0L) {
    stop("AUC is undefined unless both classes are present")
  }
  .demo_auc_pos_neg(pos, neg)
}

# Evaluate `expr` under a fixed RNG seed without perturbing the caller's stream,
# so a fixed-seed CI is reproducible yet hermetic.
.demo_with_seed <- function(seed, expr) {
  if (exists(".Random.seed", envir = globalenv(), inherits = FALSE)) {
    saved <- get(".Random.seed", envir = globalenv(), inherits = FALSE)
    on.exit(assign(".Random.seed", saved, envir = globalenv()), add = TRUE)
  } else {
    on.exit(
      suppressWarnings(rm(".Random.seed", envir = globalenv())),
      add = TRUE
    )
  }
  set.seed(seed)
  expr # forced here, i.e. after set.seed()
}

# demo_auc_ci(): the point AUC plus a stratified percentile-bootstrap CI.
# Stratified = resample WITHIN each class (preserving the class sizes), so the
# interval reflects sampling variability at the observed prevalence. Fixed seed
# => identical output across runs (WP7 reproducibility).
demo_auc_ci <- function(scores, labels, positive = NULL,
                        level = 0.95, B = 2000L, seed = 1L) {
  is_pos <- .demo_positive_mask(labels, positive)
  scores <- as.numeric(scores)
  if (length(scores) != length(is_pos)) {
    stop("`scores` and `labels` must have the same length")
  }
  if (anyNA(scores)) stop("`scores` must not contain NA")
  pos <- scores[is_pos]
  neg <- scores[!is_pos]
  if (length(pos) == 0L || length(neg) == 0L) {
    stop("AUC is undefined unless both classes are present")
  }
  est <- .demo_auc_pos_neg(pos, neg)
  boot <- .demo_with_seed(seed, vapply(seq_len(B), function(i) {
    .demo_auc_pos_neg(
      sample(pos, replace = TRUE),
      sample(neg, replace = TRUE)
    )
  }, numeric(1)))
  a <- (1 - level) / 2
  ci <- stats::quantile(boot, c(a, 1 - a), names = FALSE, type = 7)
  c(auc = est, lower = ci[1L], upper = ci[2L])
}

# ---- WP7.5b numeric helpers (shared by the extended Demo A analyses) ----------
#
# All model-free and self-tested at the foot of this file (D-022: every new
# numeric helper carries a hand-computed self-test).

# Unit-normalize a numeric vector; a zero vector is returned unchanged.
.demo_unit <- function(v) {
  s <- sqrt(sum(v^2))
  if (s == 0) v else v / s
}

# Sustained-onset layer (A1): the smallest `band` value from which every
# subsequent metric stays >= `thr`. This describes a rise-shape robustly even when
# the metric saturates at the ceiling (a lone early spike that later dips does NOT
# count as onset), which a bare which.max peak cannot. Returns NA_integer_ when the
# metric never stays above the threshold. `metric` and `band` are aligned and
# ordered by depth.
.demo_sustained_onset <- function(metric, band, thr) {
  metric <- as.numeric(metric)
  if (length(metric) != length(band)) {
    stop("`metric` and `band` must have the same length")
  }
  n <- length(metric)
  sustained <- rev(cumprod(rev(metric >= thr)) > 0) # TRUE where the tail stays >= thr
  i <- which(sustained)
  if (length(i) == 0L) NA_integer_ else as.integer(band[[i[[1L]]]])
}

# Bootstrap percentile CI of the mean (A3's dose-response aggregation). Resample
# the values with replacement B times; a fixed seed => byte-identical output
# across runs (the WP7 reproducibility rule), evaluated hermetically via
# .demo_with_seed so the caller's RNG stream is untouched.
.demo_boot_mean_ci <- function(x, level = 0.95, B = 2000L, seed = 1L) {
  x <- as.numeric(x)
  if (length(x) == 0L) stop("`x` must be non-empty")
  if (anyNA(x)) stop("`x` must not contain NA")
  n <- length(x)
  est <- mean(x)
  boot <- .demo_with_seed(seed, vapply(seq_len(B), function(i) {
    mean(x[sample.int(n, n, replace = TRUE)])
  }, numeric(1)))
  a <- (1 - level) / 2
  ci <- stats::quantile(boot, c(a, 1 - a), names = FALSE, type = 7)
  c(mean = est, lower = ci[1L], upper = ci[2L])
}

# Row-wise cosine-similarity matrix (A5). Rows of `M` are the vectors; the result
# is the symmetric k x k matrix of pairwise cosines, clamped to [-1, 1] to absorb
# floating-point drift so image()'s symmetric scale is exact. A zero row (no
# direction) is treated as orthogonal to all (its off-diagonal entries are 0).
.demo_cosine_matrix <- function(M) {
  M <- as.matrix(M)
  nrm <- sqrt(rowSums(M^2))
  nrm[nrm == 0] <- 1
  U <- M / nrm
  S <- tcrossprod(U)
  pmin(pmax(S, -1), 1)
}

# Truncated next-token KL over the union of two top-N token sets (A4). `base` and
# `int` are named probability vectors (names = token ids) as returned per prompt
# by llm_logits(). A token listed on only one side is floored at that side's
# smallest listed prob -- a token outside a top-N list has at most the tail prob --
# and each side is renormalized over the union, so both are valid distributions
# and KL(base || int) >= 0. When the two supports are identical and already sum to
# 1 this is the exact KL (pinned by the self-test).
.demo_next_token_kl <- function(base, int) {
  if (length(base) == 0L || length(int) == 0L) {
    stop("`base` and `int` must be non-empty named probability vectors")
  }
  ids <- union(names(base), names(int))
  fill <- function(p) {
    v <- as.numeric(p[ids]) # NA where an id is absent from this side's list
    v[is.na(v)] <- min(p) # floor at this side's top-N tail prob
    v / sum(v) # renormalize over the union
  }
  pb <- fill(base)
  pq <- fill(int)
  sum(pb * log(pb / pq))
}

# n + 1 evenly spaced breaks spanning `zlim`, matching an image()/colour-strip
# pairing where length(breaks) == length(col) + 1 (the colour-strip legend). A
# degenerate zlim (equal ends) is nudged so the breaks stay strictly increasing.
.demo_legend_breaks <- function(zlim, n) {
  zlim <- as.numeric(zlim)
  n <- as.integer(n)
  if (length(zlim) != 2L || anyNA(zlim) || any(!is.finite(zlim)) || n < 1L) {
    stop("`zlim` must be two finite numbers and `n` a positive integer")
  }
  if (zlim[2L] <= zlim[1L]) {
    pad <- if (zlim[2L] == 0) 1e-8 else abs(zlim[2L]) * 1e-8
    zlim <- c(zlim[1L] - pad, zlim[2L] + pad)
  }
  seq(zlim[1L], zlim[2L], length.out = n + 1L)
}

# ---- WP7.5b Demo-B numeric helpers (topic-quality, terms, structure) ----------
#
# All model-free and self-tested at the foot of this file (D-022): every new numeric
# helper carries a hand-computed self-test. Used by the extended Demo B analyses
# (B1 topic-quality metrics, B2 top terms by log-odds, B3 inter-topic structure).

# Per-cluster centroids (the mean row) of a matrix, EXCLUDING the noise label 0.
# Rows are ordered by increasing cluster id and named by it -> a k x ncol(M) matrix.
# Shared by the embedding-cohesion metric (B1) and the inter-topic cosine/dendrogram
# (B3, via .demo_cosine_matrix on these centroids).
.demo_cluster_centroids <- function(M, cluster) {
  M <- as.matrix(M)
  if (nrow(M) != length(cluster)) stop("`M` rows must match `cluster` length")
  ids <- sort(setdiff(unique(cluster), 0L))
  cen <- matrix(NA_real_, nrow = length(ids), ncol = ncol(M),
                dimnames = list(as.character(ids), colnames(M)))
  for (i in seq_along(ids)) {
    cen[i, ] <- colMeans(M[cluster == ids[[i]], , drop = FALSE])
  }
  cen
}

# Simplified silhouette (Vendramin/Campello/Hruschka SSWC, centroid-based, O(n*k)) on
# the cluster COORDINATES: for each clustered point, a = Euclidean distance to its own
# cluster centroid, b = distance to the nearest OTHER cluster centroid, and
# s = (b - a) / max(a, b) in [-1, 1]. This is the dependency-free O(n*k) stand-in for
# the exact O(n^2) silhouette (the `cluster` package, D-022): it judges each point
# against compact cluster prototypes rather than all pairwise distances -- so an
# elongated cluster whose centroid sits off its own mass scores lower, which is an
# honest weakness signal, not a bug. Noise (label 0) is excluded from the centroids
# AND receives s = NA (it belongs to no cluster); < 2 clusters gives all-NA (undefined).
# Returns a per-point vector aligned to the input rows.
.demo_silhouette_simplified <- function(coords, cluster) {
  coords <- as.matrix(coords)
  if (nrow(coords) != length(cluster)) stop("`coords` rows must match `cluster` length")
  ids <- sort(setdiff(unique(cluster), 0L))
  sil <- rep(NA_real_, nrow(coords))
  if (length(ids) < 2L) return(sil)
  cen <- .demo_cluster_centroids(coords, cluster)
  d_cen <- vapply(seq_along(ids), function(i) {
    sqrt(rowSums(sweep(coords, 2, cen[i, ])^2))
  }, numeric(nrow(coords))) # n x k distances to every centroid
  for (i in seq_along(ids)) {
    members <- which(cluster == ids[[i]])
    a <- d_cen[members, i]
    b <- apply(d_cen[members, -i, drop = FALSE], 1L, min)
    denom <- pmax(a, b)
    sil[members] <- ifelse(denom == 0, 0, (b - a) / denom)
  }
  sil
}

# Embedding-space cohesion (B1): per cluster, the mean cosine similarity of its members
# to the cluster centroid. With members row-normalized this equals the resultant length
# ||mean of unit members|| (a directional-statistics identity), in [0, 1] -- 1 = one
# shared direction, 0 = uniformly spread. Reported ALONGSIDE the UMAP silhouette because
# UMAP distorts density and the honest cohesion lives in the original embedding space
# (D-022). Returns a named per-cluster vector.
.demo_embedding_cohesion <- function(emb, cluster) {
  emb <- as.matrix(emb)
  nrm <- sqrt(rowSums(emb^2))
  nrm[nrm == 0] <- 1
  cen <- .demo_cluster_centroids(emb / nrm, cluster) # unit rows -> centroid norm = mean cos
  stats::setNames(sqrt(rowSums(cen^2)), rownames(cen))
}

# A compact committed English stopword list: function words + academic-abstract
# boilerplate ("paper", "results", "method", "approach", "using", ...) that would
# otherwise top every topic. Deliberately small, fixed, and auditable so B2's
# tokenization is deterministic; it is NOT a linguistic authority. (The informative
# Dirichlet prior already discounts corpus-common words; this list only spares the
# reader the most obvious ones.)
.DEMO_STOPWORDS <- c(
  "the", "a", "an", "and", "or", "but", "if", "then", "else", "for", "of", "to",
  "in", "on", "at", "by", "with", "from", "as", "is", "are", "was", "were", "be",
  "been", "being", "this", "that", "these", "those", "it", "its", "we", "our", "us",
  "you", "your", "they", "their", "he", "she", "his", "her", "which", "who", "whom",
  "whose", "what", "when", "where", "how", "than", "so", "such", "can", "could",
  "may", "might", "will", "would", "shall", "should", "must", "do", "does", "did",
  "has", "have", "had", "not", "no", "nor", "also", "more", "most", "some", "any",
  "all", "each", "other", "into", "over", "under", "between", "within", "about",
  "based", "given", "here", "while", "toward", "towards", "further", "across", "both",
  "via", "one", "two", "three", "however", "study", "studies", "paper", "present",
  "results", "result", "method", "methods", "approach", "using", "use", "used",
  "show", "shows", "shown", "find", "finds", "found", "propose", "proposed", "new",
  "framework", "model", "models", "analysis", "work", "these", "we"
)

# Tokenize free text into lowercase alphabetic tokens of >= min_chars letters, dropping
# stopwords. Pure regex (base R) -> a deterministic character vector; a character vector
# input is tokenized and concatenated (group-level counting). Intentionally simple (no
# stemming) so B2's top terms are literal corpus words a reader can check against the
# abstracts.
.demo_tokenize <- function(text, stopwords = .DEMO_STOPWORDS, min_chars = 3L) {
  x <- tolower(text)
  toks <- unlist(regmatches(x, gregexpr("[[:alpha:]]+", x)), use.names = FALSE)
  toks <- toks[nchar(toks) >= min_chars]
  toks[!toks %in% stopwords]
}

# Build a topics x vocabulary integer count matrix from per-document token vectors
# (`tokens_list`) and a per-document group id (`groups`; 0 = noise, dropped). Vocabulary
# = the tokens whose TOTAL corpus count is >= min_count (rare terms dropped to bound the
# vocab and the log-odds variance). Deterministic; rows named by cluster id, columns by
# term (sorted).
.demo_term_counts <- function(tokens_list, groups, min_count = 1L) {
  ids <- sort(setdiff(unique(groups), 0L))
  in_topic <- groups %in% ids
  tab <- table(unlist(tokens_list[in_topic], use.names = FALSE))
  vocab <- sort(names(tab)[tab >= min_count])
  counts <- matrix(0L, nrow = length(ids), ncol = length(vocab),
                   dimnames = list(as.character(ids), vocab))
  for (i in seq_along(ids)) {
    gt <- unlist(tokens_list[groups == ids[[i]]], use.names = FALSE)
    gt <- gt[gt %in% vocab]
    if (length(gt)) {
      ct <- table(gt)
      counts[i, names(ct)] <- as.integer(ct)
    }
  }
  counts
}

# Informative Dirichlet prior for the log-odds (Monroe et al.): alpha_w proportional to
# the word's overall corpus frequency, with total prior mass alpha_0 = V (the vocabulary
# size) -> on average one "virtual corpus-distributed token" per word. A light,
# scale-adaptive prior; the z-score normalization below makes the ranking robust to
# alpha_0 within reason. `counts` is the topics x vocab matrix.
.demo_informative_prior <- function(counts) {
  cw <- colSums(counts) # y_.w : corpus count per word
  total <- sum(cw)
  if (total == 0) return(rep(1, ncol(counts)))
  ncol(counts) * cw / total # alpha_0 = V, alpha_w proportional to corpus frequency
}

# Log-odds-ratio with a Dirichlet prior (Monroe, Colaresi & Quinn 2008, "Fightin'
# Words"): for each topic i (vs the REST of the corpus) and word w, the smoothed
# log-odds `delta` and its `z`-score. `counts` = topics x vocab; `prior` = alpha_w
# (length ncol(counts)). Ranking terms per topic by z surfaces the words that
# DISCRIMINATE the topic (over-represented AND reliably estimated), not merely the
# frequent ones -- which is exactly why raw frequency is not used (D-022). z = 0 means
# the word is no more likely in this topic than in the rest. Returns list(delta, z),
# both topics x vocab.
.demo_log_odds <- function(counts, prior = .demo_informative_prior(counts)) {
  counts <- as.matrix(counts)
  a0 <- sum(prior)
  ni <- rowSums(counts) # tokens per topic
  yw <- colSums(counts) # corpus count per word
  n_total <- sum(counts)
  alpha <- matrix(prior, nrow(counts), ncol(counts), byrow = TRUE) # alpha_w per cell
  y <- counts # y_iw : word w in topic i
  r <- sweep(-y, 2, yw, `+`) # r_iw = y_.w - y_iw : word w in the rest
  # odds of w within topic i vs within the rest (each smoothed by the prior):
  odds_topic <- (y + alpha) / ((ni + a0) - y - alpha)
  odds_rest <- (r + alpha) / ((n_total - ni + a0) - r - alpha)
  delta <- log(odds_topic) - log(odds_rest)
  z <- delta / sqrt(1 / (y + alpha) + 1 / (r + alpha))
  list(delta = delta, z = z)
}

# Top `n` terms per topic by log-odds z-score (B2). Returns a named list (one entry per
# topic) of list(terms, z), ordered most- to least-distinctive. Pure numeric on a counts
# matrix; the demo tokenizes abstracts into it.
.demo_top_terms <- function(counts, n = 6L, prior = .demo_informative_prior(counts)) {
  z <- .demo_log_odds(counts, prior)$z
  vocab <- colnames(counts)
  out <- lapply(seq_len(nrow(counts)), function(i) {
    o <- order(z[i, ], decreasing = TRUE)[seq_len(min(as.integer(n), ncol(counts)))]
    list(terms = vocab[o], z = unname(z[i, o]))
  })
  stats::setNames(out, rownames(counts))
}

# ---- WP7.5b shared visual style (one coherent look across all demo figures) ---
#
# The house palette (hcl.colors: qualitative "Dark 3", sequential "YlOrBr",
# diverging "Blue-Red 3"), point discipline (pch = 21 fills with white strokes),
# a consistent par() block, the halo-text label helper, a colour-strip legend
# (a base-R stand-in for fields::image.plot, D-020: no dependency for one legend),
# and the model | n | seed subtitle line.

.DEMO_PCH <- 21L
.DEMO_MGP <- c(2.7, 0.7, 0)
.DEMO_PT_STROKE <- "white"

# Apply the house par() block (the caller saves/restores par itself).
.demo_par <- function(mar = c(4.6, 4.6, 3.4, 1.2), ...) {
  graphics::par(mar = mar, mgp = .DEMO_MGP, las = 1L, ...)
}

.demo_pal_qual <- function(k) grDevices::hcl.colors(max(as.integer(k), 1L), "Dark 3")
# Sequential YlOrBr. rev = TRUE (dark -> light for low -> high) is the D-022
# default; A2 passes rev = FALSE so a strong positive-sentiment cell reads dark.
.demo_pal_seq <- function(n, rev = TRUE) grDevices::hcl.colors(as.integer(n), "YlOrBr", rev = rev)
.demo_pal_div <- function(n) grDevices::hcl.colors(as.integer(n), "Blue-Red 3")

# Points in the house style: a filled pch = 21 marker with a white stroke.
.demo_points <- function(x, y, bg, cex = 1.3, ...) {
  graphics::points(x, y, pch = .DEMO_PCH, bg = bg, col = .DEMO_PT_STROKE, cex = cex, ...)
}

# The "model | n | seed | ..." subtitle string (pure; drawn by .demo_subtitle()).
# A very long basename (e.g. an Ollama sha256-<64hex> blob path, which the founder
# uses during development) is truncated so it does not overflow the plot margin.
.demo_subtitle_text <- function(model, n, seed = NULL, extra = NULL) {
  bn <- basename(model)
  if (nchar(bn) > 44L) bn <- paste0(substr(bn, 1L, 41L), "...")
  parts <- c(sprintf("model: %s", bn), sprintf("n = %d", as.integer(n)))
  if (!is.null(seed)) parts <- c(parts, sprintf("seed = %d", as.integer(seed)))
  if (!is.null(extra)) parts <- c(parts, extra)
  paste(parts, collapse = "  |  ")
}

# `adj` defaults to NA (mtext's own default => centered over the panel, the look
# every figure uses). A panel with a full-height legend on its right (A5) passes
# adj = 0 so a long model name left-anchors and never collides with the legend
# title.
.demo_subtitle <- function(model, n, seed = NULL, extra = NULL, line = 0.3,
                           cex = 0.8, adj = NA) {
  graphics::mtext(
    .demo_subtitle_text(model, n, seed, extra),
    side = 3, line = line, cex = cex, col = "grey35", adj = adj
  )
}

# Text with a white halo, so labels stay readable over coloured points/cells.
# (The shared copy: both Demo A and Demo B now use it -- demo-B's local copy was
# folded onto this file in WP7.5b part-2.)
.demo_halo_text <- function(x, y, labels, col = "black", cex = 1, font = 2,
                            adj = c(0.5, 0.5), ...) {
  off <- 0.006 * diff(graphics::par("usr")[1:2])
  for (dx in c(-1, 1)) {
    for (dy in c(-1, 1)) {
      graphics::text(x + dx * off, y + dy * off, labels,
        col = "white", cex = cex, font = font, adj = adj, ...
      )
    }
  }
  graphics::text(x, y, labels, col = col, cex = cex, font = font, adj = adj, ...)
}

# A vertical colour-strip legend drawn into the CURRENT (narrow) panel: the caller
# reserves a slim column via layout(). `breaks`/`col` are exactly the pair the
# matching image() used (length(breaks) == length(col) + 1). ~15 base-R lines in
# place of a fields/plotrix dependency (D-020).
.demo_color_strip_legend <- function(breaks, col, title = NULL, n_lab = 5L) {
  op <- graphics::par(no.readonly = TRUE)
  on.exit(graphics::par(op), add = TRUE)
  graphics::par(mar = c(4.6, 0.4, 3.4, 3.2), mgp = .DEMO_MGP, las = 1L)
  graphics::plot.new()
  graphics::plot.window(xlim = c(0, 1), ylim = range(breaks), xaxs = "i", yaxs = "i")
  for (i in seq_along(col)) {
    graphics::rect(0, breaks[i], 1, breaks[i + 1L], col = col[i], border = NA)
  }
  graphics::rect(0, breaks[1L], 1, breaks[length(breaks)], col = NA, border = "grey40")
  at <- pretty(range(breaks), n = n_lab)
  at <- at[at >= min(breaks) & at <= max(breaks)]
  graphics::axis(4, at = at)
  if (!is.null(title)) {
    graphics::mtext(title, side = 3, line = 0.5, cex = 0.8, col = "grey25")
  }
  invisible(NULL)
}

# ---- Executable self-test ----------------------------------------------------

demo_utils_selftest <- function(verbose = TRUE) {
  ok <- function(cond, msg) {
    if (!isTRUE(cond)) stop("demo-utils self-test FAILED: ", msg, call. = FALSE)
  }

  # 1. Perfect separation -> 1; perfect anti-separation -> 0.
  y3 <- c(TRUE, TRUE, TRUE, FALSE, FALSE, FALSE)
  ok(
    isTRUE(all.equal(demo_auc(c(3, 4, 5, 0, 1, 2), y3), 1)),
    "perfect separation should give AUC = 1"
  )
  ok(
    isTRUE(all.equal(demo_auc(c(0, 1, 2, 3, 4, 5), y3), 0)),
    "perfect anti-separation should give AUC = 0"
  )

  # 2. Label-flip symmetry: AUC(flipped positive) == 1 - AUC.
  s <- c(0.2, 0.9, 0.1, 0.6, 0.75, 0.4)
  y <- c(TRUE, TRUE, FALSE, FALSE, TRUE, FALSE)
  a <- demo_auc(s, y)
  ok(
    isTRUE(all.equal(demo_auc(s, !y), 1 - a)),
    "flipping the positive class should give 1 - AUC"
  )

  # 3. Monotone-transform invariance (AUC depends only on ranks).
  ok(
    isTRUE(all.equal(a, demo_auc(exp(3 * s) + 5, y))),
    "a strictly increasing transform must not change AUC"
  )
  ok(
    isTRUE(all.equal(a, demo_auc(-1 / (s + 2), y))),
    "a second strictly increasing transform must not change AUC"
  )

  # 4. Hand-computed tie case. pos = {1, 2}, neg = {1, 3}; the four pos-neg
  #    pairs score (1,1)=0.5, (1,3)=0, (2,1)=1, (2,3)=0 -> 1.5 / 4 = 0.375.
  ok(
    isTRUE(all.equal(
      demo_auc(c(1, 2, 1, 3), c(TRUE, TRUE, FALSE, FALSE)), 0.375
    )),
    "hand-computed tie case should give AUC = 0.375"
  )

  # 5. Bootstrap CI: reproducible for a fixed seed, brackets the estimate,
  #    stays within [0, 1].
  ci1 <- demo_auc_ci(s, y, B = 500L, seed = 42L)
  ci2 <- demo_auc_ci(s, y, B = 500L, seed = 42L)
  ok(isTRUE(all.equal(ci1, ci2)), "the CI must be reproducible for a fixed seed")
  ok(
    ci1[["lower"]] <= ci1[["auc"]] && ci1[["auc"]] <= ci1[["upper"]],
    "the CI must bracket the point estimate"
  )
  ok(
    ci1[["lower"]] >= 0 && ci1[["upper"]] <= 1,
    "the CI must lie within [0, 1]"
  )

  # ---- WP7.5b helpers (D-022) ----

  # 6. Bootstrap mean CI (A3 dose-response): reproducible, brackets the mean,
  #    and degenerate on a constant vector (every resample is the same value).
  m1 <- .demo_boot_mean_ci(c(1, 2, 3, 4, 5), B = 500L, seed = 7L)
  m2 <- .demo_boot_mean_ci(c(1, 2, 3, 4, 5), B = 500L, seed = 7L)
  ok(isTRUE(all.equal(m1, m2)), "the mean CI must be reproducible for a fixed seed")
  ok(
    m1[["lower"]] <= m1[["mean"]] && m1[["mean"]] <= m1[["upper"]],
    "the mean CI must bracket the mean"
  )
  mc <- .demo_boot_mean_ci(rep(5, 8L), B = 200L, seed = 1L)
  ok(
    isTRUE(all.equal(unname(mc), c(5, 5, 5))),
    "a constant vector's mean CI collapses to the value"
  )

  # 7. Cosine matrix (A5): equal -> 1, orthogonal -> 0, opposite -> -1.
  cm <- .demo_cosine_matrix(rbind(c(1, 0), c(0, 1), c(-1, 0)))
  ok(
    isTRUE(all.equal(cm, matrix(c(1, 0, -1, 0, 1, 0, -1, 0, 1), 3L, 3L))),
    "the cosine matrix must give 1 / 0 / -1 for equal / orthogonal / opposite rows"
  )

  # 8. Truncated next-token KL (A4): exact on a shared full support, 0 against
  #    itself, finite+positive when the supports differ (floor + union path).
  b <- c("1" = 0.7, "2" = 0.2, "3" = 0.1)
  q <- c("1" = 0.5, "2" = 0.3, "3" = 0.2)
  ok(
    isTRUE(all.equal(
      .demo_next_token_kl(b, q),
      0.7 * log(0.7 / 0.5) + 0.2 * log(0.2 / 0.3) + 0.1 * log(0.1 / 0.2)
    )),
    "top-N KL on a shared full-support pair equals the exact KL"
  )
  ok(
    isTRUE(all.equal(.demo_next_token_kl(b, b), 0)),
    "KL of a distribution against itself is 0"
  )
  kl_diff <- .demo_next_token_kl(c("1" = 0.6, "2" = 0.4), c("1" = 0.5, "3" = 0.5))
  ok(
    is.finite(kl_diff) && kl_diff > 0,
    "top-N KL with differing supports is finite and positive"
  )

  # 9. Legend breaks (colour-strip): n + 1 evenly spaced values over zlim.
  ok(
    isTRUE(all.equal(.demo_legend_breaks(c(0, 1), 4L), c(0, 0.25, 0.5, 0.75, 1))),
    "legend breaks must be n + 1 evenly spaced values over zlim"
  )

  # 10. Unit-normalization: (3, 4) -> (0.6, 0.8); a zero vector is unchanged.
  ok(
    isTRUE(all.equal(.demo_unit(c(3, 4)), c(0.6, 0.8))),
    "unit() must normalize to length 1"
  )
  ok(
    isTRUE(all.equal(.demo_unit(c(0, 0)), c(0, 0))),
    "unit() must leave a zero vector unchanged"
  )

  # 11. Subtitle line: basename + n, with seed appended only when supplied.
  ok(
    identical(
      .demo_subtitle_text("/a/b/model.gguf", 40, 7),
      "model: model.gguf  |  n = 40  |  seed = 7"
    ),
    "the subtitle text must read 'model | n | seed'"
  )
  ok(
    identical(.demo_subtitle_text("x.gguf", 5), "model: x.gguf  |  n = 5"),
    "the subtitle omits the seed when none is given"
  )
  long_bn <- paste0("sha256-", paste(rep("a", 64L), collapse = ""))
  ok(
    identical(
      .demo_subtitle_text(long_bn, 8),
      paste0("model: ", substr(long_bn, 1L, 41L), "...  |  n = 8")
    ),
    "a very long model basename is truncated in the subtitle"
  )

  # 12. Sustained onset (A1 rise-shape): the first layer from which the metric
  #     stays >= thr; an early spike that later dips does NOT count; never-sustained
  #     gives NA.
  ok(
    identical(.demo_sustained_onset(c(0.6, 0.95, 0.8, 0.99, 1.0), 1:5, 0.9), 4L),
    "sustained onset ignores an early spike that dips back below thr"
  )
  ok(
    identical(.demo_sustained_onset(c(1, 1, 1), 1:3, 0.9), 1L),
    "a metric at the ceiling everywhere has onset at the first layer"
  )
  ok(
    identical(.demo_sustained_onset(c(0.5, 0.6), 1:2, 0.9), NA_integer_),
    "a metric that never stays above thr has no onset (NA)"
  )

  # ---- WP7.5b Demo-B helpers (D-022) ----

  # A hand fixture: two well-separated 1-D clusters on the x-axis + one noise point.
  #   cluster 1 = {(0,0), (2,0)} -> centroid (1,0);  cluster 2 = {(10,0), (12,0)} ->
  #   centroid (11,0);  (6,0) is noise (label 0).
  sil_coords <- rbind(c(0, 0), c(2, 0), c(6, 0), c(10, 0), c(12, 0))
  sil_clus <- c(1L, 1L, 0L, 2L, 2L)

  # 13. Cluster centroids: mean row per cluster, noise excluded.
  ok(
    isTRUE(all.equal(unname(.demo_cluster_centroids(sil_coords, sil_clus)),
                     rbind(c(1, 0), c(11, 0)))),
    "cluster centroids must be the per-cluster mean row, excluding noise"
  )

  # 14. Centroid cosine (B3): the cosine matrix of orthogonal cluster centroids is I.
  cc_emb <- rbind(c(1, 0), c(1, 0), c(0, 1), c(0, 1))
  ok(
    isTRUE(all.equal(unname(.demo_cosine_matrix(.demo_cluster_centroids(cc_emb, c(1, 1, 2, 2)))),
                     diag(2))),
    "orthogonal cluster centroids give an identity cosine matrix"
  )

  # 15. Simplified silhouette, hand-computed. (0,0): a=1, b=11 -> 10/11; (2,0): a=1,
  #     b=9 -> 8/9; symmetric for cluster 2. Noise gets NA.
  sil <- .demo_silhouette_simplified(sil_coords, sil_clus)
  ok(
    isTRUE(all.equal(sil[c(1, 2, 4, 5)], c(10 / 11, 8 / 9, 8 / 9, 10 / 11))),
    "simplified silhouette must match the hand-computed values"
  )
  ok(is.na(sil[[3]]), "a noise point has silhouette NA")

  # 16. Silhouette is undefined (all NA) with fewer than two clusters.
  ok(
    all(is.na(.demo_silhouette_simplified(rbind(c(0, 0), c(1, 0)), c(1L, 1L)))),
    "silhouette with a single cluster is all NA"
  )

  # 17. Embedding cohesion = ||mean of unit members||: orthogonal pair -> sqrt(1/2),
  #     identical -> 1, opposite -> 0.
  coh <- .demo_embedding_cohesion(
    rbind(c(1, 0), c(0, 1), c(1, 0), c(1, 0), c(1, 0), c(-1, 0)),
    c(1L, 1L, 2L, 2L, 3L, 3L)
  )
  ok(
    isTRUE(all.equal(unname(coh), c(sqrt(0.5), 1, 0))),
    "embedding cohesion must equal the resultant length of unit members"
  )

  # 18. Tokenizer: lowercase alphabetic tokens >= min_chars, stopwords dropped.
  ok(
    identical(
      .demo_tokenize("The Deep neural-network learns fast; a cat sat.",
                     stopwords = c("the", "a", "sat"), min_chars = 3L),
      c("deep", "neural", "network", "learns", "fast", "cat")
    ),
    "the tokenizer must lowercase, split on non-letters, and drop short/stopwords"
  )
  ok(
    length(.demo_tokenize("We study the model using this method")) == 0L,
    "the default stopword list removes abstract boilerplate"
  )

  # 19. Term counts: topics x vocab integer matrix, noise document excluded.
  tc <- .demo_term_counts(
    list(c("alpha", "alpha", "shared"), c("beta", "shared"), c("gamma")),
    c(1L, 2L, 0L)
  )
  ok(
    isTRUE(all.equal(tc, matrix(c(2L, 0L, 0L, 1L, 1L, 1L), 2L, 3L,
      dimnames = list(c("1", "2"), c("alpha", "beta", "shared"))
    ))),
    "term counts must tabulate topics x vocab and drop noise"
  )

  # 20. Informative prior: alpha_w proportional to corpus frequency, alpha_0 = V.
  lo_counts <- rbind(c(8, 1, 1), c(1, 1, 8)) # corpus counts 9, 2, 9; total 20; V = 3
  ok(
    isTRUE(all.equal(.demo_informative_prior(lo_counts), c(1.35, 0.3, 1.35))),
    "the informative prior must be V * corpus_freq"
  )

  # 21. Log-odds (Monroe et al.), hand-computed with a uniform prior alpha = 1.
  #     Topic 1, word 1: odds_topic = 9/4, odds_rest = 2/11 -> delta = log(99/8);
  #     var = 1/9 + 1/2 = 11/18 -> z = log(99/8)/sqrt(11/18).
  lo <- .demo_log_odds(lo_counts, prior = rep(1, 3))
  ok(
    isTRUE(all.equal(lo$delta[1, 1], log(99 / 8))),
    "the smoothed log-odds must match the hand-computed value"
  )
  ok(
    isTRUE(all.equal(lo$z[1, 1], log(99 / 8) / sqrt(11 / 18))),
    "the log-odds z-score must match the hand-computed value"
  )
  ok(
    isTRUE(all.equal(lo$z[1, 2], 0)),
    "a word split evenly across topics has log-odds z = 0"
  )
  ok(
    isTRUE(all.equal(lo$z[2, 3], lo$z[1, 1])) &&
      isTRUE(all.equal(lo$z[1, 3], -lo$z[1, 1])),
    "log-odds z is mirror-symmetric across the two topics and signs its direction"
  )

  # 22. Top terms on a symmetric two-topic corpus (equal totals). Topic 1 over-uses
  #     "focus", under-uses "anti", and shares "spread"/"filler" evenly: the ranking is
  #     focus (z > 0) > spread/filler (z = 0) > anti (z < 0).
  tt <- .demo_top_terms(
    matrix(c(10, 0, 0, 10, 5, 5, 5, 5), 2L, 4L,
      dimnames = list(NULL, c("focus", "anti", "spread", "filler"))
    ),
    n = 4L, prior = rep(1, 4)
  )
  ok(
    identical(tt[[1]]$terms[[1]], "focus"),
    "the term concentrated in a topic ranks first"
  )
  ok(
    identical(tt[[1]]$terms[[4]], "anti") && isTRUE(all.equal(tt[[1]]$z[[2]], 0)),
    "an under-represented term ranks last; an evenly-split term has z = 0"
  )

  if (isTRUE(verbose)) message("demo-utils self-test: OK (41 checks)")
  invisible(TRUE)
}

# Run on source() so a broken helper fails loudly and immediately. Set
# REBIRTH_DEMO_SKIP_SELFTEST=1 to skip (e.g. when only re-defining the funcs).
if (!nzchar(Sys.getenv("REBIRTH_DEMO_SKIP_SELFTEST"))) {
  demo_utils_selftest()
}
