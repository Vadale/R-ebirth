# Cargo and rustc can be packaged separately. Check each declared floor before
# extracting/building sources; never install or update either tool automatically.
desc <- read.dcf("DESCRIPTION")
if (!"SystemRequirements" %in% colnames(desc)) {
  stop("Declare Cargo and rustc minimum versions in DESCRIPTION SystemRequirements.")
}
# DCF continuation lines are whitespace, including in R CMD build's DESCRIPTION.
sysreqs <- gsub("[[:space:]]+", " ", desc[, "SystemRequirements"])
requirements <- strsplit(sysreqs, ",", fixed = TRUE)[[1L]]
minimum <- function(tool) {
  entry <- trimws(requirements[grepl(paste0("^", tool, "\\b"),
                                    trimws(requirements), ignore.case = TRUE)])
  if (length(entry) != 1L || !grepl(">= [0-9]+\\.[0-9]+\\.[0-9]+$", entry)) {
    stop("Declare an explicit ", tool, " minimum (>= major.minor.patch) in SystemRequirements.")
  }
  sub(".*>= ", "", entry)
}
floors <- c(rustc = minimum("rustc"), cargo = minimum("Cargo"))

# Keep system tools first, then the user's standard rustup installation.
Sys.setenv(PATH = paste(Sys.getenv("PATH"), file.path(path.expand("~"), ".cargo", "bin"),
                       sep = .Platform$path.sep))
for (tool in names(floors)) {
  label <- if (tool == "rustc") "Rust" else "Cargo"
  help <- paste0("Install ", tool, " >= ", floors[[tool]],
                 " using your OS package manager or https://rustup.rs/; ",
                 "then put it on PATH (or in ~/.cargo/bin).")
  output <- tryCatch(system(paste(tool, "--version"), intern = TRUE),
                     error = function(e) stop(tool, " could not run. ", help, call. = FALSE))
  status <- attr(output, "status")
  pattern <- paste0("^", tool, " ([0-9]+\\.[0-9]+\\.[0-9]+)([-+ ].*)?$")
  if ((!is.null(status) && status != 0L) || length(output) != 1L ||
      is.na(output) || !grepl(pattern, output)) {
    stop("Cannot determine ", tool, " version from a successful --version command. ",
         help, call. = FALSE)
  }
  current <- sub(pattern, "\\1", output)
  message("Using ", output)
  if (utils::compareVersion(current, floors[[tool]]) < 0L) {
    stop("Minimum supported ", label, " version is ", floors[[tool]],
         ". Installed ", label, " version is ", current, ". ", help, call. = FALSE)
  }
}
