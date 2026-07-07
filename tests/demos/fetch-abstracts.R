# tests/demos/fetch-abstracts.R
#
# Fetch the REAL abstracts corpus for Demo B: ~5,000 recent abstracts across
# eight arXiv categories, written to a CSV in the same schema as the shipped
# synthetic sample (id, category, label, text).
#
# SOURCE + TERMS: abstracts are retrieved from the arXiv API
# (https://info.arxiv.org/help/api/index.html). The arXiv API is free and open;
# retrieved metadata is used here for LOCAL analysis only. arXiv abstracts remain
# under their authors' copyright and are NOT redistributed in this repository --
# this script pulls them onto the user's machine on demand. Please honour arXiv's
# API usage guidelines (this script paces requests at >= 3 s and pages in small
# chunks). arXiv is a trademark of Cornell University.
#
# Dependency-free: base R only (libcurl-backed url() + regex parsing), so it adds
# nothing to the package's dependency surface (D-020).
#
# Usage (from the repo root):
#   Rscript tests/demos/fetch-abstracts.R                 # -> tests/demos/abstracts-arxiv.csv
#   Rscript tests/demos/fetch-abstracts.R out.csv 800     # 800 per category

# arXiv category -> human-readable topic label. Eight well-separated fields.
.arxiv_categories <- c(
  "cs.LG"          = "Machine learning",
  "astro-ph.CO"    = "Cosmology",
  "q-bio.GN"       = "Genomics",
  "cond-mat.supr-con" = "Superconductivity",
  "cs.CR"          = "Cryptography and security",
  "math.NT"        = "Number theory",
  "physics.ao-ph"  = "Atmospheric and oceanic physics",
  "econ.EM"        = "Econometrics"
)

.xml_unescape <- function(x) {
  x <- gsub("&lt;", "<", x, fixed = TRUE)
  x <- gsub("&gt;", ">", x, fixed = TRUE)
  x <- gsub("&quot;", "\"", x, fixed = TRUE)
  x <- gsub("&#39;", "'", x, fixed = TRUE)
  x <- gsub("&apos;", "'", x, fixed = TRUE)
  gsub("&amp;", "&", x, fixed = TRUE) # ampersand last
}

.extract_first <- function(entry, tag) {
  m <- regmatches(entry, regexpr(sprintf("(?s)<%s>(.*?)</%s>", tag, tag), entry, perl = TRUE))
  if (!length(m)) return(NA_character_)
  inner <- sub(sprintf("(?s)^<%s>(.*)</%s>$", tag, tag), "\\1", m, perl = TRUE)
  inner <- gsub("\\s+", " ", inner) # collapse whitespace/newlines
  trimws(.xml_unescape(inner))
}

# One arXiv API page (Atom XML) -> character vector of abstracts.
.arxiv_page <- function(cat, start, chunk) {
  u <- sprintf(
    paste0(
      "https://export.arxiv.org/api/query?search_query=cat:%s",
      "&start=%d&max_results=%d&sortBy=submittedDate&sortOrder=descending"
    ),
    utils::URLencode(cat, reserved = TRUE), start, chunk
  )
  xml <- tryCatch(
    {
      con <- url(u, open = "r", encoding = "UTF-8")
      on.exit(close(con))
      paste(readLines(con, warn = FALSE), collapse = "\n")
    },
    error = function(e) {
      message("  request failed (", conditionMessage(e), ")")
      NA_character_
    }
  )
  if (is.na(xml)) return(character(0))
  entries <- strsplit(xml, "<entry>", fixed = TRUE)[[1L]]
  if (length(entries) <= 1L) return(character(0))
  abs <- vapply(entries[-1L], .extract_first, character(1), tag = "summary")
  abs <- abs[!is.na(abs) & nzchar(abs)]
  unname(abs)
}

fetch_arxiv_abstracts <- function(out = file.path("tests", "demos", "abstracts-arxiv.csv"),
                                  per_category = 625L, chunk = 100L, pause = 3.0) {
  rows <- list()
  n <- 0L
  for (cat in names(.arxiv_categories)) {
    label <- .arxiv_categories[[cat]]
    message(sprintf("fetching %s (%s) ...", cat, label))
    got <- character(0)
    start <- 0L
    while (length(got) < per_category) {
      page <- .arxiv_page(cat, start, min(chunk, per_category - length(got)))
      if (!length(page)) break # exhausted or network error
      got <- c(got, page)
      start <- start + chunk
      Sys.sleep(pause) # arXiv API etiquette
    }
    got <- unique(got)[seq_len(min(length(unique(got)), per_category))]
    if (length(got)) {
      rows[[length(rows) + 1L]] <- data.frame(
        category = cat, label = label, text = got, stringsAsFactors = FALSE
      )
      n <- n + length(got)
    }
    message(sprintf("  got %d abstracts", length(got)))
  }
  if (!length(rows)) {
    stop("no abstracts fetched (network unavailable?). The shipped synthetic ",
         "sample in rebirth/inst/extdata/ lets Demo B run offline.")
  }
  df <- do.call(rbind, rows)
  df <- data.frame(id = seq_len(nrow(df)), df, stringsAsFactors = FALSE)
  utils::write.csv(df, out, row.names = FALSE)
  message(sprintf("wrote %s: %d abstracts across %d categories (%.2f MB)",
                  out, nrow(df), length(unique(df$category)), file.info(out)$size / 1e6))
  invisible(df)
}

if (sys.nframe() == 0L) {
  args <- commandArgs(trailingOnly = TRUE)
  out <- if (length(args) >= 1L) args[[1L]] else file.path("tests", "demos", "abstracts-arxiv.csv")
  per <- if (length(args) >= 2L) as.integer(args[[2L]]) else 625L
  fetch_arxiv_abstracts(out = out, per_category = per)
}
