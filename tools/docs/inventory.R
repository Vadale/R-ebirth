# Source-only documentation inventory. Does not load relm or execute its code.
# Run from the repository root: Rscript tools/docs/inventory.R --check
args <- commandArgs(TRUE)
stopifnot(length(args) == 1L, args %in% c("--write", "--check"))
namespace <- readLines("rebirth/NAMESPACE")
exports <- sort(sub("^export\\((.*)\\)$", "\\1", grep("^export\\(", namespace, value = TRUE)))
methods <- sort(sub("^S3method\\(([^,]+),([^)]*)\\)$", "\\1.\\2",
                    grep("^S3method\\(", namespace, value = TRUE)))
definitions <- list()
for (file in sort(list.files("rebirth/R", "\\.R$", full.names = TRUE))) {
  for (node in parse(file)) {
    if (is.call(node) && identical(node[[1L]], as.name("<-")) &&
        is.symbol(node[[2L]]) && is.call(node[[3L]]) &&
        identical(node[[3L]][[1L]], as.name("function"))) {
      name <- as.character(node[[2L]])
      definitions[[name]] <- eval(node[[3L]], baseenv())
    }
  }
}
topics <- list()
for (file in sort(list.files("rebirth/man", "\\.Rd$", full.names = TRUE))) {
  rd <- tools::parse_Rd(file)
  for (node in rd) if (identical(attr(node, "Rd_tag"), "\\alias"))
    topics[[paste(unlist(node), collapse = "")]] <- basename(file)
}
signature <- function(name) {
  stopifnot(is.function(definitions[[name]]))
  f <- formals(definitions[[name]])
  arguments <- vapply(seq_along(f), function(i) {
    if (identical(f[[i]], quote(expr = ))) return(names(f)[i])
    paste0(names(f)[i], " = ", paste(deparse(f[[i]], width.cutoff = 500L), collapse = " "))
  }, character(1))
  paste0(name, "(", paste(arguments, collapse = ", "), ")")
}
all_names <- c(exports, methods)
stopifnot(!anyDuplicated(all_names), all(all_names %in% names(topics)))
surface <- data.frame(name = all_names,
  kind = c(rep("export", length(exports)), rep("S3 method", length(methods))),
  signature = vapply(all_names, signature, character(1)),
  topic = vapply(all_names, function(n) topics[[n]], character(1)), row.names = NULL)
output <- tempfile()
write.csv(surface, output, row.names = FALSE, na = "", fileEncoding = "UTF-8")
expected <- "docs/api-surface.csv"
if (args == "--write") {
  file.copy(output, expected, overwrite = TRUE)
} else {
  # Ignore only the host's text-file line endings; names/defaults/order remain exact.
  if (!identical(readLines(output, warn = FALSE), readLines(expected, warn = FALSE)))
    stop("Public API differs from docs/api-surface.csv. Review the API decision; do not blindly regenerate.")
}
unlink(output)
cat(length(exports), "exports and", length(methods), "S3 methods match the source inventory.\n")
