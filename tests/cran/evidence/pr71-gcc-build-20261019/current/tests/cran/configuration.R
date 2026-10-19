# Run from the repository root. Model-free configure/package source controls.
repo <- normalizePath(".", winslash = "/")
root <- tempfile("relm-cran-")
dir.create(root)
source("rebirth/tools/source-bundles.R")
dir.create(file.path(root, "src"))
# A structurally valid but incomplete archive must never publish a partial tree.
incomplete <- tempfile("incomplete-", tmpdir = root)
dir.create(incomplete)
dir.create(file.path(incomplete, "llama.cpp"))
writeLines("incomplete fixture", file.path(incomplete, "llama.cpp/README"))
old <- setwd(incomplete)
utils::tar(file.path(root, "src/llama-sources.tar.xz"), "llama.cpp/README",
           compression = "xz", tar = "internal")
setwd(old)
failure <- tryCatch(relm_unpack_engine(root), error = identity)
stopifnot(inherits(failure, "error"),
          grepl("Could not unpack", conditionMessage(failure)),
          !dir.exists(file.path(root, "src/llama.cpp")),
          !file.exists(file.path(root, "src/.relm-unpacked-engine")),
          length(list.files(file.path(root, "src"), pattern = "^\\.relm-engine-", all.files = TRUE)) == 0L)
stopifnot(file.copy("rebirth/src/llama-sources.tar.xz", file.path(root, "src"), overwrite = TRUE))
stopifnot(isTRUE(relm_unpack_engine(root)),
          file.exists(file.path(root, "src/.relm-unpacked-engine")),
          identical(relm_unpack_engine(root), FALSE))
original <- list.files("rebirth/src/llama.cpp", recursive = TRUE, all.files = TRUE,
                       no.. = TRUE, full.names = FALSE)
original <- original[!dir.exists(file.path("rebirth/src/llama.cpp", original))]
stopifnot(identical(unname(tools::md5sum(file.path("rebirth/src/llama.cpp", original))),
                    unname(tools::md5sum(file.path(root, "src/llama.cpp", original)))))
stopifnot(system2("sh", c("-c", shQuote(paste("cd", shQuote(root), "&& sh", shQuote(file.path(repo, "rebirth/cleanup")))))) == 0L,
          !dir.exists(file.path(root, "src/llama.cpp")))

configure_case <- function(vendor, not_cran, windows = FALSE, cmake = NULL) {
  directory <- tempfile("configure-", tmpdir = root)
  dir.create(directory)
  dir.create(file.path(directory, "src"))
  dir.create(file.path(directory, "src/rust"))
  dir.create(file.path(directory, "src/llama.cpp"))
  writeLines("# fixture", file.path(directory, "src/llama.cpp/CMakeLists.txt"))
  file.copy(file.path(repo, "rebirth/DESCRIPTION"), directory)
  file.copy(file.path(repo, "rebirth/tools"), directory, recursive = TRUE)
  for (file in c("Makevars.in", "Makevars.win.in"))
    file.copy(file.path(repo, "rebirth/src", file), file.path(directory, "src"))
  if (vendor) file.create(file.path(directory, "src/rust/vendor.tar.xz"))
  old <- setwd(directory)
  on.exit(setwd(old))
  env <- new.env(parent = globalenv())
  env$source <- function(file) sys.source(file, envir = env)
  env$Sys.setenv <- function(...) invisible(NULL)
  if (!is.null(cmake)) {
    env$Sys.which <- function(names) {
      if (identical(names, "cmake")) return(c(cmake = cmake))
      Sys.which(names)
    }
    env$system2 <- function(command, args = character(), ...) {
      if (identical(command, cmake) && identical(args, "--version"))
        return("cmake version 3.28.0")
      stop("Unexpected command in the CMake path fixture")
    }
  }
  env$Sys.getenv <- function(x, unset = "", ...) {
    values <- c(NOT_CRAN = not_cran, DEBUG = "", RELM_ENABLE_CUDA = "0", RELM_ENABLE_SELFTESTS = "0")
    if (length(x) == 1L && x %in% names(values)) return(unname(values[[x]]))
    Sys.getenv(x, unset, ...)
  }
  if (windows) {
    env$.Platform <- .Platform
    env$.Platform$OS.type <- "windows"
    env$.Platform$path.sep <- ";"
  }
  result <- tryCatch({sys.source("tools/config.R", envir = env); env}, error = identity)
  result
}
missing <- configure_case(FALSE, "false")
stopifnot(inherits(missing, "error"), grepl("Bundled Rust sources are missing", conditionMessage(missing)))
for (not_cran in c("", "false", "true")) {
  env <- configure_case(TRUE, not_cran)
  stopifnot(is.environment(env), identical(trimws(env$.cran_flags), "--locked -j 2 --offline"))
}
dev <- configure_case(FALSE, "true")
stopifnot(is.environment(dev), identical(trimws(dev$.cran_flags), "--locked -j 2"))
win <- configure_case(TRUE, "false", TRUE)
stopifnot(is.environment(win), grepl(";", win$new_path, fixed = TRUE),
          identical(win$mv_ofp, "src/Makevars.win"),
          any(win$new_txt == "CXX_STD = CXX17"))
unlink(root, recursive = TRUE)
cat(sprintf("CRAN_CONFIG_PASS cases=9 engine_files=%d native_builds=0 models=0\n", length(original)))
