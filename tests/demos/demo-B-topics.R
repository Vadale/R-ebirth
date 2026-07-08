# tests/demos/demo-B-topics.R
#
# Demo B -- "Topic modelling without Python" (SOLO-PHASE-PLAN.md Sec 8, WP7).
#
#   public abstracts -> llm_embed() -> uwot::umap() -> dbscan::hdbscan()
#     -> cluster naming via llm_generate() -> one labelled cluster map.
#
# A BERTopic-class pipeline, fully local, zero Python. Ships with a small
# synthetic sample (rebirth/inst/extdata/abstracts-sample.csv); use
# tests/demos/fetch-abstracts.R for the real ~5,000-abstract arXiv corpus.
#
# run_demo_B(extended = TRUE) (or REBIRTH_DEMO_EXTENDED=1) adds three BERTopic-report
# analyses (D-022), all base graphics via the shared demo-utils style: B1 topic-quality
# metrics (simplified silhouette + embedding cohesion + noise fraction), B2 distinctive
# terms per topic (log-odds z with an informative Dirichlet prior), and B3 inter-topic
# structure (centroid-cosine heatmap + hclust dendrogram). B4 -- the polished labelled
# map -- is the core, always-drawn figure.
#
# Dependencies: base R + rebirth + uwot + dbscan (Suggests, D-020), all guarded.
# Reproducibility: set.seed + n_sgd_threads = 1 for uwot; HDBSCAN is deterministic
# given its input; cluster labels use greedy (temperature = 0) generation.
# run_demo_B_reproducible() asserts fixed seeds => byte-identical clustering + stats.

.demo_dir <- function() {
  args <- commandArgs(FALSE)
  m <- grep("^--file=", args, value = TRUE)
  if (length(m)) return(dirname(sub("^--file=", "", m[[1L]])))
  for (i in rev(seq_len(sys.nframe()))) {
    of <- sys.frame(i)$ofile
    if (!is.null(of)) return(dirname(normalizePath(of)))
  }
  "tests/demos"
}

# ---- shared model-free helpers (palette, pch=21 points, halo text, colour-strip
# legend, the model|n|seed subtitle, and the Demo-B numeric helpers: silhouette,
# cohesion, cluster centroids, log-odds top terms) -----------------------------

local({
  p <- file.path(.demo_dir(), "demo-utils.R")
  if (!file.exists(p)) p <- "tests/demos/demo-utils.R"
  source(p)
})

# ---- data --------------------------------------------------------------------

demo_B_data <- function(path = NULL) {
  if (is.null(path) || !nzchar(path)) {
    path <- system.file("extdata", "abstracts-sample.csv", package = "rebirth")
    if (!nzchar(path)) {
      path <- file.path(.demo_dir(), "..", "..", "rebirth", "inst",
                        "extdata", "abstracts-sample.csv")
    }
  }
  if (!file.exists(path)) stop("abstracts CSV not found: ", path)
  utils::read.csv(path, stringsAsFactors = FALSE)
}

# ---- cluster naming ----------------------------------------------------------

# Representatives of one cluster: the medoid (point nearest the cluster centroid
# in the map, via .demo_B_medoid) and its nearest neighbours within the cluster.
.demo_B_reps <- function(coords, members, k = 4L) {
  medoid <- .demo_B_medoid(coords, members)
  d2m <- rowSums(sweep(coords[members, , drop = FALSE], 2, coords[medoid, ])^2)
  members[order(d2m)][seq_len(min(k, length(members)))]
}

.demo_B_clean_label <- function(s) {
  s <- trimws(s[[1L]])
  s <- sub("\n.*$", "", s) # first line only
  s <- gsub('^["\'`]+|["\'`.]+$', "", s) # strip wrapping quotes / trailing dot
  s <- sub("^(Topic label|Label|Topic)\\s*:?\\s*", "", s, ignore.case = TRUE)
  if (nchar(s) > 40L) s <- paste0(substr(s, 1L, 37L), "...")
  s
}

name_clusters <- function(m, texts, cluster, coords, k = 4L, verbose = TRUE) {
  ids <- sort(setdiff(unique(cluster), 0L))
  labels <- character(length(ids))
  for (j in seq_along(ids)) {
    reps <- .demo_B_reps(coords, which(cluster == ids[[j]]), k = k)
    prompt <- paste0(
      "You are labelling a cluster of research abstracts. Read the abstracts ",
      "below and reply with a SHORT topic label of 2 to 4 words, and nothing ",
      "else.\n\nAbstracts:\n",
      paste0("- ", texts[reps], collapse = "\n"),
      "\n\nTopic label:"
    )
    out <- rebirth::llm_generate(m, prompt, max_tokens = 12L, temperature = 0,
                                 seed = 1L, chat = TRUE)
    labels[[j]] <- .demo_B_clean_label(out)
    if (isTRUE(verbose)) message(sprintf("  cluster %d (n=%d): %s",
                                         ids[[j]], sum(cluster == ids[[j]]), labels[[j]]))
  }
  stats::setNames(labels, ids)
}

# ---- B4: the polished labelled cluster map (base graphics only) --------------
#
# The core, always-drawn map, upgraded onto the shared WP7.5b visual style (D-022):
# the qualitative "Dark 3" palette, pch = 21 fills with white strokes, halo topic
# labels at cluster medoids, optional convex-hull topic outlines, noise de-emphasized
# to faint grey, and the model | n | seed subtitle line.

# The medoid of a cluster in the map: its point nearest the cluster centroid.
.demo_B_medoid <- function(coords, members) {
  cen <- colMeans(coords[members, , drop = FALSE])
  members[which.min(rowSums(sweep(coords[members, , drop = FALSE], 2, cen)^2))]
}

demo_B_plot <- function(coords, cluster, labels = NULL, file = NULL,
                        model = NULL, seed = NULL, hulls = TRUE,
                        title = "Topic modelling without Python") {
  if (!is.null(file)) {
    grDevices::png(file, width = 1200, height = 950, res = 130)
    on.exit(grDevices::dev.off(), add = TRUE)
  }
  op <- graphics::par(no.readonly = TRUE)
  on.exit(graphics::par(op), add = TRUE)
  .demo_par(mar = c(4.3, 4.3, 3.2, 1.1))

  ids <- sort(setdiff(unique(cluster), 0L))
  k <- length(ids)
  pal <- .demo_pal_qual(k)
  is_noise <- cluster == 0L
  n_noise <- sum(is_noise)

  # pad the range so medoid labels near the edges are not clipped
  xr <- range(coords[, 1L])
  yr <- range(coords[, 2L])
  plot(coords, type = "n", xlab = "UMAP 1", ylab = "UMAP 2", main = title,
       xlim = xr + c(-1, 1) * 0.08 * diff(xr),
       ylim = yr + c(-1, 1) * 0.06 * diff(yr))

  # optional convex-hull outlines per topic (a faint fill + a coloured border), drawn
  # first so the points sit on top.
  if (isTRUE(hulls)) {
    for (j in seq_along(ids)) {
      members <- which(cluster == ids[[j]])
      if (length(members) >= 3L) {
        h <- grDevices::chull(coords[members, , drop = FALSE])
        graphics::polygon(coords[members[h], , drop = FALSE],
                          col = grDevices::adjustcolor(pal[[j]], 0.08),
                          border = grDevices::adjustcolor(pal[[j]], 0.5), lwd = 1)
      }
    }
  }

  # noise first (faint grey), then the coloured cluster points as pch = 21 with a
  # thin white stroke (the house point style) so clusters read cleanly over the hulls.
  if (n_noise) {
    graphics::points(coords[is_noise, , drop = FALSE], pch = 19, cex = 0.4,
                     col = grDevices::adjustcolor("grey70", 0.4))
  }
  bg <- rep(NA_character_, length(cluster))
  for (j in seq_along(ids)) bg[cluster == ids[[j]]] <- grDevices::adjustcolor(pal[[j]], 0.75)
  .demo_points(coords[!is_noise, 1L], coords[!is_noise, 2L],
               bg = bg[!is_noise], cex = 0.6, lwd = 0.4)

  .demo_subtitle(if (is.null(model)) "unknown" else model, length(cluster),
                 seed = seed,
                 extra = sprintf("%d topics | %d unclustered (grey)", k, n_noise))

  # topic names at cluster medoids: nudged just above the medoid and horizontally
  # justified by side of the plot, so an edge label stays inside the region (no
  # clipping) and sits clear of its own points.
  usr <- graphics::par("usr")
  yoff <- 0.018 * (usr[[4]] - usr[[3]])
  for (j in seq_along(ids)) {
    members <- which(cluster == ids[[j]])
    med <- .demo_B_medoid(coords, members)
    lab <- if (!is.null(labels)) labels[[as.character(ids[[j]])]] else paste("topic", ids[[j]])
    lx <- coords[med, 1L]
    frac <- (lx - usr[[1]]) / (usr[[2]] - usr[[1]])
    adjx <- if (frac < 0.28) 0 else if (frac > 0.72) 1 else 0.5
    .demo_halo_text(lx, coords[med, 2L] + yoff, lab, cex = 0.92, adj = c(adjx, 0.5))
  }
  invisible(NULL)
}

# ==============================================================================
# The extended Demo B analyses (behind run_demo_B(extended = TRUE), D-022). Each
# returns a plain list and draws one base-graphics figure via the shared demo-utils
# style helpers. All statistics are deterministic given the (seeded) UMAP layout and
# the committed sample; fixed seeds => byte-identical numbers. Topic labels are the
# model's own suggestions (name_clusters), never ground truth.
# ==============================================================================

# Truncate a label for a plot axis / dendrogram leaf (ASCII-safe ellipsis).
.demo_B_short <- function(s, n = 16L) {
  s <- as.character(s)
  ifelse(nchar(s) > n, paste0(substr(s, 1L, n - 3L), "..."), s)
}

# Per-topic display labels aligned to a set of ids (falls back to "topic <id>").
.demo_B_labels <- function(labels, ids) {
  labs <- if (!is.null(labels)) labels[as.character(ids)] else rep(NA_character_, length(ids))
  ifelse(is.na(labs) | !nzchar(labs), paste("topic", ids), labs)
}

# ---- B1: topic-quality metrics -----------------------------------------------

# Per topic: the simplified silhouette on the UMAP coordinates (separation in the map
# the reader sees) AND the embedding-space cohesion (tightness in the ORIGINAL
# embedding space, where UMAP's density distortion cannot mislead), plus the noise
# fraction HDBSCAN leaves unclustered. Both metrics are reported because they answer
# different questions; weak clusters are shown, not hidden (D-022 honesty).
.demo_B1_run <- function(coords, cluster, emb, labels, model, say) {
  sil <- .demo_silhouette_simplified(coords, cluster)
  ids <- sort(setdiff(unique(cluster), 0L))
  sil_by <- vapply(ids, function(g) mean(sil[cluster == g]), numeric(1))
  coh_by <- .demo_embedding_cohesion(emb, cluster)[as.character(ids)]
  sizes <- vapply(ids, function(g) sum(cluster == g), integer(1))
  noise_frac <- mean(cluster == 0L)
  say(sprintf(
    "B1: mean silhouette %.3f (per-topic %.3f .. %.3f), mean cohesion %.3f, %.1f%% noise",
    mean(sil, na.rm = TRUE), min(sil_by), max(sil_by), mean(coh_by), 100 * noise_frac
  ))
  list(
    ids = ids, silhouette = sil_by, cohesion = as.numeric(coh_by), sizes = sizes,
    noise_frac = noise_frac, mean_sil = mean(sil, na.rm = TRUE),
    labels = labels, n = length(cluster), model = model
  )
}

.demo_B1_plot <- function(b1, file = NULL) {
  if (!is.null(file)) {
    grDevices::png(file, width = 1150, height = 900, res = 130)
    on.exit(grDevices::dev.off(), add = TRUE)
  }
  op <- graphics::par(no.readonly = TRUE)
  on.exit(graphics::par(op), add = TRUE)
  graphics::layout(matrix(c(1L, 2L), nrow = 2L), heights = c(5, 1.5))
  pal <- .demo_pal_qual(2)
  col_sil <- pal[[1]]
  col_coh <- pal[[2]]

  k <- length(b1$ids)
  labs <- .demo_B_short(.demo_B_labels(b1$labels, b1$ids), 20L)
  o <- order(b1$silhouette) # worst -> best, so weak clusters sit at the bottom
  xlo <- min(0, min(b1$silhouette, b1$cohesion))

  .demo_par(mar = c(4.2, 12, 3.2, 1.2))
  plot(NULL,
    xlim = c(xlo, 1), ylim = c(0.5, k + 0.5), yaxt = "n",
    xlab = "quality  (silhouette / cohesion, higher = better)", ylab = "",
    main = "Topic quality: separation and cohesion per topic"
  )
  graphics::abline(v = 0, col = "grey70")
  graphics::abline(v = b1$mean_sil, lty = 3, col = grDevices::adjustcolor(col_sil, 0.6))
  graphics::axis(2,
    at = seq_len(k), labels = sprintf("%s  (n=%d)", labs[o], b1$sizes[o]),
    las = 1, cex.axis = 0.72, tick = FALSE
  )
  for (i in seq_len(k)) {
    graphics::segments(xlo, i, max(b1$silhouette[o][i], b1$cohesion[o][i]), i, col = "grey90")
  }
  .demo_points(b1$silhouette[o], seq_len(k), bg = col_sil, cex = 1.2)
  .demo_points(b1$cohesion[o], seq_len(k), bg = col_coh, cex = 1.2)
  # bottom-left is the reliably-empty corner: cohesion pins the right edge (LLM
  # embeddings are anisotropic, so cohesion is uniformly high) and a well-separated
  # topic's silhouette sits far right too; the semi-opaque box keeps it readable if a
  # weak clustering pushes points leftward.
  graphics::legend("bottomleft",
    legend = c("silhouette (UMAP separation)", "cohesion (embedding tightness)"),
    col = c(col_sil, col_coh), pt.bg = c(col_sil, col_coh),
    pch = .DEMO_PCH, cex = 0.85,
    bg = grDevices::adjustcolor("white", 0.85), box.col = "grey85"
  )
  .demo_subtitle(b1$model, b1$n, extra = sprintf("mean silhouette %.2f (dotted)", b1$mean_sil))

  # the noise fraction HDBSCAN leaves unclustered
  nf <- b1$noise_frac
  .demo_par(mar = c(3.6, 12, 0.8, 1.2))
  plot(NULL, xlim = c(0, 1), ylim = c(0, 1), xaxt = "n", yaxt = "n", xlab = "", ylab = "", bty = "n")
  graphics::rect(0, 0.3, 1 - nf, 0.7, col = grDevices::adjustcolor(col_sil, 0.5), border = NA)
  graphics::rect(1 - nf, 0.3, 1, 0.7, col = grDevices::adjustcolor("grey70", 0.6), border = NA)
  graphics::rect(0, 0.3, 1, 0.7, col = NA, border = "grey50")
  graphics::axis(1, at = seq(0, 1, 0.25), labels = sprintf("%d%%", seq(0L, 100L, 25L)))
  graphics::text(0.5, 0.5, sprintf(
    "%.0f%% clustered    |    %.0f%% unclustered (noise)", 100 * (1 - nf), 100 * nf
  ), cex = 0.9, font = 2, col = "grey20")
  graphics::mtext("share of all abstracts", side = 1, line = 2.2, cex = 0.75, col = "grey35")
  invisible(b1)
}

# ---- B2: distinctive terms per topic (log-odds, informative Dirichlet prior) --

# Rank each topic's terms by Monroe-et-al. log-odds z-score against the rest of the
# corpus (via the self-tested demo-utils helpers), so the terms DISCRIMINATE the topic
# rather than echo corpus-wide common words. Tokenization + stopwords are committed and
# deterministic; the full top list is logged (no cherry-picking).
.demo_B2_run <- function(texts, cluster, labels, model, say, n_terms = 8L, min_count = 3L) {
  tokens_list <- lapply(texts, .demo_tokenize)
  counts <- .demo_term_counts(tokens_list, cluster, min_count = min_count)
  tt <- .demo_top_terms(counts, n = n_terms)
  ids <- as.integer(rownames(counts))
  labs <- .demo_B_labels(labels, ids)
  for (i in seq_along(ids)) {
    say(sprintf("B2 topic %d (%s): %s", ids[[i]], labs[[i]], paste(tt[[i]]$terms, collapse = ", ")))
  }
  list(
    top = tt, ids = ids, counts = counts, labels = labels,
    vocab_size = ncol(counts), n = length(texts), model = model
  )
}

.demo_B2_plot <- function(b2, file = NULL) {
  if (!is.null(file)) {
    grDevices::png(file, width = 1250, height = 900, res = 130)
    on.exit(grDevices::dev.off(), add = TRUE)
  }
  op <- graphics::par(no.readonly = TRUE)
  on.exit(graphics::par(op), add = TRUE)
  k <- length(b2$ids)
  nc <- if (k <= 4L) 2L else 3L
  nr <- ceiling(k / nc)
  pal <- .demo_pal_qual(k)
  labs <- .demo_B_short(.demo_B_labels(b2$labels, b2$ids), 22L)
  graphics::par(
    mfrow = c(nr, nc), mar = c(2.6, 6.6, 2.2, 0.8), mgp = .DEMO_MGP,
    oma = c(3, 0, 3.2, 0), las = 1L
  )
  for (i in seq_len(k)) {
    tt <- b2$top[[i]]
    graphics::barplot(rev(tt$z),
      horiz = TRUE, names.arg = rev(tt$terms), col = pal[[i]], border = NA,
      cex.names = 0.72, cex.axis = 0.7, main = labs[[i]], cex.main = 0.92
    )
  }
  graphics::mtext("Distinctive terms per topic (log-odds z, informative Dirichlet prior)",
    side = 3, outer = TRUE, line = 0.9, font = 2, cex = 0.98
  )
  graphics::mtext(.demo_subtitle_text(b2$model, b2$n,
    extra = sprintf("%d-word vocab | top %d by log-odds z", b2$vocab_size, length(b2$top[[1]]$terms))
  ), side = 1, outer = TRUE, line = 1.1, cex = 0.72, col = "grey35")
  invisible(b2)
}

# The B2 top terms as a printable data.frame (one row per topic, terms comma-joined) --
# the "tabulate" half of B2 for the vignette / console.
demo_B_terms_table <- function(b2) {
  ids <- b2$ids
  data.frame(
    topic = ids,
    label = .demo_B_labels(b2$labels, ids),
    top_terms = vapply(b2$top, function(t) paste(t$terms, collapse = ", "), character(1)),
    stringsAsFactors = FALSE
  )
}

# ---- B3: inter-topic structure (centroid cosine heatmap + dendrogram) --------

# Topic-centroid cosine-similarity matrix in the ORIGINAL embedding space, rendered as
# a diverging heatmap (reusing the A5 palette + colour-strip legend) and as an
# average-linkage dendrogram on 1 - cosine. Together they show which topics are near
# duplicates vs genuinely distinct -- the standard BERTopic-report content, zero Python.
.demo_B3_run <- function(emb, cluster, labels, model, say) {
  cen <- .demo_cluster_centroids(emb, cluster)
  cos <- .demo_cosine_matrix(cen)
  ids <- as.integer(rownames(cen))
  labs <- .demo_B_labels(labels, ids)
  hc <- stats::hclust(stats::as.dist(1 - cos), method = "average")
  od <- cos[upper.tri(cos)] # off-diagonal cosines
  say(sprintf("B3: %d topics, off-diagonal centroid cosine %.3f .. %.3f (mean %.3f)",
    length(ids), min(od), max(od), mean(od)))
  list(cos = cos, hc = hc, ids = ids, labels = labs, n = length(cluster), model = model)
}

.demo_B3_plot <- function(b3, file = NULL) {
  if (!is.null(file)) {
    grDevices::png(file, width = 1150, height = 1050, res = 130)
    on.exit(grDevices::dev.off(), add = TRUE)
  }
  op <- graphics::par(no.readonly = TRUE)
  on.exit(graphics::par(op), add = TRUE)
  n_col <- 32L
  # Data-driven colour scale over the OFF-DIAGONAL cosines. Decoder-LLM embeddings are
  # anisotropic -- every topic-pair centroid cosine sits high (~0.9 on Qwen) -- so a
  # fixed [-1, 1] scale would wash the whole matrix to one colour. Scaling to the actual
  # off-diagonal range (with the trivial self-similarity diagonal omitted) shows the
  # RELATIVE near/far structure honestly; the legend prints the true cosine values. A
  # SEQUENTIAL palette (darker = more similar) is honest for these all-positive cosines --
  # a diverging scale would falsely read a low-but-still-high similarity as "dissimilar".
  z <- b3$cos
  diag(z) <- NA_real_
  breaks <- .demo_legend_breaks(range(b3$cos[upper.tri(b3$cos)]), n_col)
  pal <- .demo_pal_seq(n_col, rev = TRUE) # rev=TRUE: high value -> dark, i.e. more similar = darker
  labs <- .demo_B_short(b3$labels, 15L)
  # Draw order = heatmap (1), dendrogram (2), colour-strip legend (3) LAST -- the
  # legend saves/restores par(), so it must be the final panel (as in A5).
  graphics::layout(matrix(c(1L, 3L, 2L, 3L), nrow = 2L, byrow = TRUE),
    widths = c(6, 1), heights = c(5, 4))
  k <- nrow(b3$cos)

  .demo_par(mar = c(8.4, 8.4, 3.4, 0.6))
  graphics::image(
    x = seq_len(k), y = seq_len(k), z = z, col = pal, breaks = breaks,
    axes = FALSE, xlab = "", ylab = "", main = "Inter-topic similarity (centroid cosine)"
  )
  graphics::axis(1, at = seq_len(k), labels = labs, las = 2L, cex.axis = 0.62, tick = FALSE)
  graphics::axis(2, at = seq_len(k), labels = labs, las = 1L, cex.axis = 0.62, tick = FALSE)
  graphics::box(col = "grey60")
  .demo_subtitle(b3$model, b3$n, extra = "diagonal omitted", adj = 0)

  .demo_par(mar = c(7.6, 4.4, 1.6, 0.6))
  b3$hc$labels <- labs
  plot(b3$hc, main = "Topic dendrogram (1 - cosine)", xlab = "", sub = "", ylab = "height", cex = 0.7)

  .demo_color_strip_legend(breaks, pal, title = "cos")
  invisible(b3)
}

# ---- extended orchestrator ---------------------------------------------------

# Run B1-B3 and (when plot_dir is set) write the three PNGs. B4 (the polished map) is
# the core, always-drawn figure in run_demo_B; B1-B3 are the extended additions.
.demo_B_extended <- function(coords, cluster, emb, texts, labels, model, seed, plot_dir, say) {
  fp <- function(name) if (is.null(plot_dir)) NULL else file.path(plot_dir, name)
  ids <- sort(setdiff(unique(cluster), 0L))
  if (length(ids) < 2L) {
    say("extended Demo B needs >= 2 topics; skipping B1-B3 (only ", length(ids), " found).")
    return(list(B1 = NULL, B2 = NULL, B3 = NULL, files = character(0)))
  }
  b1 <- .demo_B1_run(coords, cluster, emb, labels, model, say)
  .demo_B1_plot(b1, file = fp("demoB-B1-quality.png"))

  b2 <- .demo_B2_run(texts, cluster, labels, model, say)
  .demo_B2_plot(b2, file = fp("demoB-B2-terms.png"))

  b3 <- .demo_B3_run(emb, cluster, labels, model, say)
  .demo_B3_plot(b3, file = fp("demoB-B3-structure.png"))

  list(
    B1 = b1, B2 = b2, B3 = b3,
    files = c(
      B1 = fp("demoB-B1-quality.png"), B2 = fp("demoB-B2-terms.png"),
      B3 = fp("demoB-B3-structure.png")
    )
  )
}

# ---- the demo ----------------------------------------------------------------

run_demo_B <- function(model_path = .demo_model_path(),
                       abstracts = NULL, n_max = NULL,
                       n_neighbors = 15L, min_dist = 0.1, min_pts = 15L,
                       seed = 20240707L, plot_file = NULL, extended = FALSE,
                       plot_dir = NULL, hulls = TRUE, emb = NULL, verbose = TRUE) {
  for (pkg in c("uwot", "dbscan")) {
    if (!requireNamespace(pkg, quietly = TRUE)) {
      stop(sprintf("Demo B needs the '%s' package (Suggests). install.packages('%s').", pkg, pkg))
    }
  }
  stopifnot(nzchar(model_path), file.exists(model_path))
  say <- function(...) if (isTRUE(verbose)) message(...)

  df <- if (is.null(abstracts)) demo_B_data() else abstracts
  if (!is.null(n_max) && n_max < nrow(df)) df <- df[seq_len(n_max), , drop = FALSE]
  say(sprintf("Demo B: %d abstracts", nrow(df)))

  m <- rebirth::llm(model_path)
  on.exit(close(m), add = TRUE)

  # (1) embed. llm_embed returns an L2-normalized matrix by default. A precomputed emb
  # (same row order as df) can be passed to skip this step -- used by the reproducibility
  # check, which reuses the first run's embeddings to test the seeded layout + stats.
  if (is.null(emb)) {
    say("embedding ...")
    emb <- rebirth::llm_embed(m, df$text, pooling = "mean", normalize = TRUE)
  } else {
    stopifnot(nrow(emb) == nrow(df))
    say("using precomputed embeddings ...")
  }

  # (2) UMAP. set.seed + n_sgd_threads = 1 => reproducible layout.
  say("UMAP ...")
  set.seed(seed)
  coords <- uwot::umap(emb, n_neighbors = n_neighbors, min_dist = min_dist,
                       n_components = 2L, metric = "cosine", n_sgd_threads = 1L)

  # (3) HDBSCAN (deterministic given the layout). 0 = noise.
  say("HDBSCAN ...")
  cluster <- dbscan::hdbscan(coords, minPts = min_pts)$cluster

  # (4) name clusters with the model itself.
  say("naming clusters ...")
  labels <- name_clusters(m, df$text, cluster, coords, verbose = verbose)

  # (5) B4: the polished labelled map (the core, always-drawn figure).
  demo_B_plot(coords, cluster, labels, file = plot_file, model = model_path,
              seed = seed, hulls = hulls)

  res <- list(
    coords = coords, cluster = cluster, labels = labels, emb = emb,
    n = nrow(df), k = length(labels), n_noise = sum(cluster == 0L),
    category = df$category, model = model_path, seed = seed
  )

  # (6) the extended analyses (B1-B3), behind extended = TRUE (D-022). They write
  # their PNGs into plot_dir (defaulting to plot_file's directory, else the cwd).
  if (isTRUE(extended)) {
    if (is.null(plot_dir)) {
      plot_dir <- if (!is.null(plot_file)) dirname(plot_file) else "."
    }
    say("running the extended analyses B1-B3 ...")
    res$extended <- .demo_B_extended(coords, cluster, emb, df$text, labels,
                                     model_path, seed, plot_dir, say)
    res$plot_dir <- plot_dir
  }

  class(res) <- c("demo_B_result", "list")
  res
}

# Reproducibility check (D-022 acceptance): fixed seeds => byte-identical clustering
# and topic statistics. Confirms the embedding is deterministic across identical calls,
# then runs the seeded layout + HDBSCAN + the B1-B3 statistics TWICE on ONE embedding
# and asserts they match exactly. Figures go to temp files (no stray device). Returns
# TRUE or stops loudly.
run_demo_B_reproducible <- function(model_path = .demo_model_path(),
                                    abstracts = NULL, seed = 20240707L, verbose = TRUE) {
  say <- function(...) if (isTRUE(verbose)) message(...)
  df <- if (is.null(abstracts)) demo_B_data() else abstracts

  m <- rebirth::llm(model_path)
  # embedding determinism: a small subset embedded twice must be bit-identical.
  sub <- df$text[seq_len(min(16L, nrow(df)))]
  e1 <- rebirth::llm_embed(m, sub, pooling = "mean", normalize = TRUE)
  e2 <- rebirth::llm_embed(m, sub, pooling = "mean", normalize = TRUE)
  if (!identical(e1, e2)) {
    close(m)
    stop("embedding is not reproducible across identical calls")
  }
  emb <- rebirth::llm_embed(m, df$text, pooling = "mean", normalize = TRUE)
  close(m) # run_demo_B opens its own handle for naming; reuse `emb` for the rest

  d1 <- file.path(tempdir(), "demoB-repro-1")
  d2 <- file.path(tempdir(), "demoB-repro-2")
  dir.create(d1, showWarnings = FALSE)
  dir.create(d2, showWarnings = FALSE)
  run1 <- function(pd) {
    run_demo_B(model_path, abstracts = df, seed = seed, extended = TRUE, emb = emb,
               plot_file = file.path(pd, "map.png"), plot_dir = pd, verbose = FALSE)
  }
  r1 <- run1(d1)
  r2 <- run1(d2)

  checks <- c(
    cluster = identical(r1$cluster, r2$cluster),
    labels = identical(r1$labels, r2$labels),
    silhouette = identical(r1$extended$B1$silhouette, r2$extended$B1$silhouette),
    cohesion = identical(r1$extended$B1$cohesion, r2$extended$B1$cohesion),
    top_terms = identical(r1$extended$B2$top, r2$extended$B2$top),
    cosine = identical(r1$extended$B3$cos, r2$extended$B3$cos)
  )
  if (!all(checks)) {
    stop("Demo B is not reproducible; mismatched: ",
         paste(names(checks)[!checks], collapse = ", "))
  }
  say(sprintf("Demo B reproducibility: PASS (%d clusters, %.1f%% noise, all stats identical)",
    length(r1$labels), 100 * mean(r1$cluster == 0L)))
  invisible(TRUE)
}

# Model-free smoke test of the B1-B4 FIGURE code (no model, no uwot/dbscan): synthesize
# coordinates, cluster labels, an embedding, and texts, then render every analysis to a
# headless PDF device and assert it is written. Guards the base-graphics code paths per
# commit (the numeric helpers have their own hand-tests in demo_utils_selftest; the
# nightly exercises the same figures on a real model). Returns TRUE or stops loudly.
demo_B_plot_selftest <- function(verbose = FALSE) {
  set.seed(1L)
  k <- 5L
  per <- 30L
  centers <- cbind(cos(2 * pi * seq_len(k) / k), sin(2 * pi * seq_len(k) / k)) * 6
  coords <- do.call(rbind, lapply(seq_len(k), function(g) {
    sweep(matrix(rnorm(per * 2L, sd = 0.5), per, 2L), 2L, centers[g, ], `+`)
  }))
  coords <- rbind(coords, matrix(rnorm(20L, sd = 6), 10L, 2L)) # 10 noise points
  cluster <- c(rep(seq_len(k), each = per), rep(0L, 10L))
  dd <- 16L
  dirs <- matrix(rnorm(k * dd), k, dd)
  dirs <- dirs / sqrt(rowSums(dirs^2))
  emb <- rbind(
    dirs[rep(seq_len(k), each = per), ] + matrix(rnorm(k * per * dd, sd = 0.3), k * per, dd),
    matrix(rnorm(10L * dd), 10L, dd)
  )
  emb <- emb / sqrt(rowSums(emb^2))
  words <- c("alpha", "beta", "gamma", "delta", "epsilon")
  texts <- c(
    unlist(lapply(seq_len(k), function(g) rep(paste(words[[g]], "shared common term"), per))),
    rep("noise text", 10L)
  )
  labels <- stats::setNames(paste("topic", seq_len(k)), seq_len(k))
  say <- function(...) if (isTRUE(verbose)) message(...)

  f <- file.path(tempdir(), "demoB-plot-selftest.pdf")
  grDevices::pdf(f) # headless-robust device (no cairo/X11 needed)
  tryCatch(
    {
      demo_B_plot(coords, cluster, labels, model = "synthetic.gguf", seed = 1L)
      .demo_B1_plot(.demo_B1_run(coords, cluster, emb, labels, "synthetic.gguf", say))
      .demo_B2_plot(.demo_B2_run(texts, cluster, labels, "synthetic.gguf", say))
      .demo_B3_plot(.demo_B3_run(emb, cluster, labels, "synthetic.gguf", say))
    },
    finally = grDevices::dev.off()
  )
  if (!file.exists(f) || file.info(f)$size == 0) {
    stop("demo_B_plot_selftest: a figure failed to render", call. = FALSE)
  }
  if (isTRUE(verbose)) message("demo-B plot self-test: OK (B1-B4 rendered)")
  invisible(TRUE)
}

# ---- auto-run when a model is available --------------------------------------

if (!nzchar(Sys.getenv("REBIRTH_DEMO_NO_AUTORUN"))) {
  .mp <- .demo_model_path()
  if (nzchar(.mp) && file.exists(.mp)) {
    demoB <- run_demo_B(.mp, extended = nzchar(Sys.getenv("REBIRTH_DEMO_EXTENDED")))
  } else {
    message(
      "Demo B: no GGUF model found (set REBIRTH_DEMO_MODEL or ",
      "REBIRTH_TEST_MODEL_QWEN). Functions defined; skipping the end-to-end run."
    )
  }
}
