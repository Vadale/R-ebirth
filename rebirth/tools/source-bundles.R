# Source archives keep portable package paths without changing vendor code.
# Used only by configure; Python/Git are maintainer tools, not dependencies.
relm_unpack_engine <- function(root = ".") {
  engine <- file.path(root, "src", "llama.cpp")
  archive <- file.path(root, "src", "llama-sources.tar.xz")
  if (dir.exists(engine)) {
    if (!file.exists(file.path(engine, "CMakeLists.txt"))) {
      stop("Existing llama.cpp source directory is incomplete.", call. = FALSE)
    }
    return(invisible(FALSE))
  }
  if (!file.exists(archive)) {
    stop("Bundled llama.cpp sources are missing; use a complete relm source package.", call. = FALSE)
  }
  members <- utils::untar(archive, list = TRUE)
  parts <- strsplit(members, "/", fixed = TRUE)
  safe <- length(members) > 0L && !anyDuplicated(members) &&
    all(startsWith(members, "llama.cpp/")) &&
    !any(grepl("\\\\|:", members)) &&
    !any(vapply(parts, function(x) any(x %in% c("", ".", "..")), logical(1L)))
  if (!safe) stop("Invalid bundled llama.cpp source paths.", call. = FALSE)
  # Publish only a complete extraction. Interrupted work never becomes engine.
  staging <- tempfile(".relm-engine-", tmpdir = file.path(root, "src"))
  if (!dir.create(staging)) stop("Could not create source staging directory.", call. = FALSE)
  on.exit(unlink(staging, recursive = TRUE), add = TRUE)
  status <- utils::untar(archive, exdir = staging)
  extracted <- file.path(staging, "llama.cpp")
  if (!identical(status, 0L) || !file.exists(file.path(extracted, "CMakeLists.txt"))) {
    stop("Could not unpack bundled llama.cpp sources.", call. = FALSE)
  }
  marker <- file.path(root, "src", ".relm-unpacked-engine")
  if (!file.create(marker)) stop("Could not mark extracted source ownership.", call. = FALSE)
  if (!file.rename(extracted, engine)) {
    unlink(marker)
    stop("Could not publish bundled llama.cpp sources.", call. = FALSE)
  }
  invisible(TRUE)
}
