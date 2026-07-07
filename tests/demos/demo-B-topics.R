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
# Dependencies: base R + rebirth + uwot + dbscan (Suggests, D-020), all guarded.
# Reproducibility: set.seed + n_sgd_threads = 1 for uwot; HDBSCAN is deterministic
# given its input; cluster labels use greedy (temperature = 0) generation.

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
# in the map) and its nearest neighbours within the cluster.
.demo_B_reps <- function(coords, members, k = 4L) {
  sub <- coords[members, , drop = FALSE]
  cen <- colMeans(sub)
  d2c <- rowSums(sweep(sub, 2, cen)^2)
  medoid <- members[which.min(d2c)]
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

# ---- the labelled cluster map (base graphics only) ---------------------------

# Text with a white halo, so labels stay readable over coloured points.
.demo_halo_text <- function(x, y, labels, col = "black", cex = 1, font = 2,
                            adj = c(0.5, 0.5), ...) {
  off <- 0.006 * diff(par("usr")[1:2])
  for (dx in c(-1, 1)) {
    for (dy in c(-1, 1)) {
      graphics::text(x + dx * off, y + dy * off, labels, col = "white",
                     cex = cex, font = font, adj = adj, ...)
    }
  }
  graphics::text(x, y, labels, col = col, cex = cex, font = font, adj = adj, ...)
}

demo_B_plot <- function(coords, cluster, labels = NULL, file = NULL,
                        title = "Topic modelling without Python") {
  if (!is.null(file)) {
    grDevices::png(file, width = 1200, height = 950, res = 130)
    on.exit(grDevices::dev.off(), add = TRUE)
  }
  op <- graphics::par(no.readonly = TRUE)
  on.exit(graphics::par(op), add = TRUE)
  graphics::par(mar = c(4.3, 4.3, 3.2, 1.1), mgp = c(2.6, 0.7, 0), las = 1)

  ids <- sort(setdiff(unique(cluster), 0L))
  k <- length(ids)
  pal <- if (k > 0L) grDevices::adjustcolor(grDevices::hcl.colors(k, "Dark 3"), 0.6)
  col <- rep(grDevices::adjustcolor("grey70", 0.45), length(cluster)) # noise = grey
  for (j in seq_along(ids)) col[cluster == ids[[j]]] <- pal[[j]]

  # pad the range so medoid labels near the edges are not clipped
  xr <- range(coords[, 1L])
  yr <- range(coords[, 2L])
  plot(coords, col = col, pch = 19, cex = 0.55, xlab = "UMAP 1", ylab = "UMAP 2",
       main = title,
       xlim = xr + c(-1, 1) * 0.08 * diff(xr),
       ylim = yr + c(-1, 1) * 0.06 * diff(yr))
  n_noise <- sum(cluster == 0L)
  graphics::mtext(
    sprintf("%d abstracts  |  %d topics discovered  |  %d unclustered (grey)",
            length(cluster), k, n_noise),
    side = 3, line = 0.3, cex = 0.82, col = "grey35"
  )

  # topic names at cluster medoids: nudged just above the medoid and horizontally
  # justified by side of the plot, so an edge label stays inside the region (no
  # clipping) and sits clear of its own points.
  usr <- graphics::par("usr")
  yoff <- 0.018 * (usr[[4]] - usr[[3]])
  for (j in seq_along(ids)) {
    members <- which(cluster == ids[[j]])
    cen <- colMeans(coords[members, , drop = FALSE])
    med <- members[which.min(rowSums(sweep(coords[members, , drop = FALSE], 2, cen)^2))]
    lab <- if (!is.null(labels)) labels[[as.character(ids[[j]])]] else paste("topic", ids[[j]])
    lx <- coords[med, 1L]
    frac <- (lx - usr[[1]]) / (usr[[2]] - usr[[1]])
    adjx <- if (frac < 0.28) 0 else if (frac > 0.72) 1 else 0.5
    .demo_halo_text(lx, coords[med, 2L] + yoff, lab, cex = 0.92, adj = c(adjx, 0.5))
  }
  invisible(NULL)
}

# ---- the demo ----------------------------------------------------------------

run_demo_B <- function(model_path = .demo_B_model_path(),
                       abstracts = NULL, n_max = NULL,
                       n_neighbors = 15L, min_dist = 0.1, min_pts = 15L,
                       seed = 20240707L, plot_file = NULL, verbose = TRUE) {
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

  # (1) embed. llm_embed returns an L2-normalized matrix by default.
  say("embedding ...")
  emb <- rebirth::llm_embed(m, df$text, pooling = "mean", normalize = TRUE)

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

  # (5) the labelled map.
  demo_B_plot(coords, cluster, labels, file = plot_file)

  res <- list(
    coords = coords, cluster = cluster, labels = labels,
    n = nrow(df), k = length(labels), n_noise = sum(cluster == 0L),
    category = df$category, model = model_path
  )
  class(res) <- c("demo_B_result", "list")
  res
}

.demo_B_model_path <- function() {
  p <- Sys.getenv("REBIRTH_DEMO_MODEL", "")
  if (!nzchar(p)) p <- Sys.getenv("REBIRTH_TEST_MODEL_QWEN", "")
  p
}

# ---- auto-run when a model is available --------------------------------------

if (!nzchar(Sys.getenv("REBIRTH_DEMO_NO_AUTORUN"))) {
  .mp <- .demo_B_model_path()
  if (nzchar(.mp) && file.exists(.mp)) {
    demoB <- run_demo_B(.mp)
  } else {
    message(
      "Demo B: no GGUF model found (set REBIRTH_DEMO_MODEL or ",
      "REBIRTH_TEST_MODEL_QWEN). Functions defined; skipping the end-to-end run."
    )
  }
}
