# Build the complete site from a small staging copy, reusing an installed relm.
# Rscript tools/docs/build.R INSTALLED_LIBRARY NEW_OUTPUT_DIRECTORY
# No package compilation or model download. Documentation dependencies are
# maintainer tools, not relm runtime dependencies.
args <- commandArgs(TRUE)
stopifnot(length(args) == 2L)
.libPaths(c(normalizePath(args[1L], mustWork = TRUE), .libPaths()))
# Quarto starts another R process; .libPaths alone is process-local.
Sys.setenv(R_LIBS = paste(.libPaths(), collapse = .Platform$path.sep))
options(warn = 1)
stopifnot(requireNamespace("relm", quietly = TRUE),
          requireNamespace("pkgdown", quietly = TRUE),
          requireNamespace("quarto", quietly = TRUE))
root <- normalizePath(".", winslash = "/", mustWork = TRUE)
output <- args[2L]
if (file.exists(output)) stop("Choose a new site output directory.")
stopifnot(dir.create(output, recursive = TRUE))
output <- normalizePath(output, winslash = "/", mustWork = TRUE)
stage <- file.path(output, "source")
stopifnot(dir.create(stage))
for (name in c("DESCRIPTION", "NAMESPACE", "R", "man", "inst", "vignettes",
               "README.md", "NEWS.md", "LICENSE", "LICENSE.md", "_pkgdown.yml")) {
  stopifnot(file.copy(file.path("rebirth", name), stage, recursive = TRUE))
}
# The first site deployment happens only after this PR passes and merges. Keep
# its not-yet-live URL out of package metadata checked by CRAN; pkgdown's staging
# description alone needs the canonical site address for site metadata.
description <- read.dcf(file.path(stage, "DESCRIPTION"))
description[1L, "URL"] <- paste(description[1L, "URL"],
  "https://vadale.github.io/R-ebirth/", sep = ",\n    ")
write.dcf(description, file.path(stage, "DESCRIPTION"))
# Additional site-only articles. Their code is displayed, not silently executed.
# The dedicated examples runner separately records actual execution outcomes.
articles <- c("agents", "api-policy", "getting-started", "research-guide",
              "supported-workflow", "cran-submission")
dir.create(file.path(stage, "vignettes", "articles"))
github <- "https://github.com/Vadale/R-ebirth/blob/main/"
for (name in articles) {
  lines <- readLines(file.path("docs", paste0(name, ".md")), warn = FALSE)
  title <- sub("^# ", "", lines[1L])
  # Resolve every relative Markdown link in these repository docs against its
  # original directory before putting it in a different site directory.
  text <- paste(lines[-1L], collapse = "\n")
  matches <- gregexpr("\\]\\(([^)#]+)(#[^)]*)?\\)", text, perl = TRUE)
  links <- regmatches(text, matches)[[1L]]
  if (length(links)) {
    replacements <- vapply(links, function(link) {
      target <- substring(link, 3L, nchar(link) - 1L)
      if (grepl("^(https?://|mailto:|#)", target)) return(link)
      if (target == "../llms.txt") return("](../llms.txt)")
      if (target == "api-surface.csv") return("](../api-surface.csv)")
      if (sub("\\.md(#.*)?$", "", target) %in% articles)
        return(paste0("](", sub("\\.md", ".html", target), ")"))
      if (startsWith(target, "../")) target <- substring(target, 4L)
      else target <- paste0("docs/", target)
      paste0("](", github, target, ")")
    }, character(1))
    regmatches(text, matches) <- list(replacements)
  }
  writeLines(c("---", paste0("title: ", encodeString(title, quote = '"')),
    "---", "", text), file.path(stage, "vignettes", "articles", paste0(name, ".Rmd")))
}
config <- yaml::read_yaml(file.path(stage, "_pkgdown.yml"))
config$articles <- c(list(list(title = "Start and use relm", navbar = "Guides",
  contents = paste0("articles/", articles))), config$articles)
yaml::write_yaml(config, file.path(stage, "_pkgdown.yml"))
# The new model examples use explicit function arguments. Existing vignette
# model opt-ins stay unset in the documentation-only process.
model_env <- c("RELM_DEMO_MODEL", "RELM_TEST_MODEL_QWEN", "RELM_TEST_MODEL_VLM",
               "RELM_TEST_MMPROJ_VLM")
if (any(nzchar(Sys.getenv(model_env)))) stop("Unset model opt-ins before a site-only build.")
site <- file.path(output, "site")
pkgdown::build_site(stage, install = FALSE, new_process = FALSE, devel = FALSE,
  examples = TRUE, run_dont_run = FALSE, preview = FALSE, quiet = FALSE,
  override = list(destination = site))
# These six articles are generated from repository Markdown, not committed Rmd
# files. Point the displayed source link at the real file, keeping reference and
# original vignette source links unchanged.
for (name in articles) {
  path <- file.path(site, "articles", paste0(name, ".html"))
  html <- readLines(path, warn = FALSE)
  generated <- paste0("vignettes/articles/", name, ".Rmd")
  original <- paste0("docs/", name, ".md")
  source_url <- paste0(config$repo$url$source, generated)
  stopifnot(any(grepl(source_url, html, fixed = TRUE)))
  html <- gsub(source_url, paste0(github, original), html, fixed = TRUE)
  html <- gsub(paste0("<code>", generated, "</code>"),
               paste0("<code>", original, "</code>"), html, fixed = TRUE)
  writeLines(html, path, useBytes = TRUE)
}
stopifnot(file.copy("llms.txt", site, overwrite = TRUE),
          file.copy("docs/api-surface.csv", site),
          file.copy("rebirth/inst/examples/agents", site, recursive = TRUE))
reference <- c("# relm reference for agents", "",
  "Generated from the current Rd files; model-guarded examples are not execution receipts.",
  "", readLines("docs/agents.md"), "", readLines("docs/api-policy.md"))
for (file in sort(list.files("rebirth/man", "\\.Rd$", full.names = TRUE))) {
  reference <- c(reference, "", paste0("## ", basename(file)), "", "```text",
    capture.output(tools::Rd2txt(tools::parse_Rd(file), options = list(underline_titles = FALSE))), "```")
}
writeLines(reference, file.path(site, "llms-full.txt"), useBytes = TRUE)
writeLines(capture.output(sessionInfo()), file.path(output, "session.txt"))
cat("Site:", site, "\n")
