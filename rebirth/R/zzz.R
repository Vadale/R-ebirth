# Package-level state and lifecycle (WP4 Step 5): the disk-spill session directory
# and its cleanup. Spill files live under a per-session directory below the user
# cache, are removed when the session ends, and any directory left by a crashed
# earlier session is swept on load.

# Per-session state, private to the package. `session_dir` is created lazily on
# the first spill; `counter` names successive spill files; `sentinel` carries the
# exit finalizer that removes the session directory.
.rebirth_state <- new.env(parent = emptyenv())

# The root under which every session's spill directory lives:
# <user cache>/rebirth/spill. `tools::R_user_dir()` is the base-R sanctioned
# per-user cache location (no extra dependency).
spill_root_dir <- function() {
  file.path(tools::R_user_dir("rebirth", "cache"), "spill")
}

# This session's spill directory path, unique per session (process id + a
# per-session token that does not perturb the user's RNG, so concurrent R sessions
# never share a directory). The path is only *computed* here; the engine creates
# the directory when it actually spills, so an in-memory trace (the common case,
# even at the default spill = TRUE) leaves no empty directory behind.
spill_session_dir <- function() {
  dir <- .rebirth_state$session_dir
  if (!is.null(dir)) {
    return(dir)
  }
  # basename(tempfile()) is unique within the session and uses tempfile's own
  # counter, so it does not touch (or reseed) the user's random-number state.
  token <- paste(Sys.getpid(), basename(tempfile("")), sep = "-")
  dir <- file.path(spill_root_dir(), token)
  .rebirth_state$session_dir <- dir
  dir
}

# The next spill file path (trace-<n>.arrow), bumping the per-session counter so
# successive traces never collide. Written under `spill_dir` when the caller
# supplies one, else this session's managed directory (which cleanup removes at
# exit; a user-supplied directory is left untouched). The engine creates the
# directory and the file when it actually spills.
next_spill_path <- function(spill_dir = NULL) {
  n <- .rebirth_state$counter
  n <- if (is.null(n)) 1L else n + 1L
  .rebirth_state$counter <- n
  fname <- sprintf("trace-%d.arrow", n)
  if (is.null(spill_dir)) {
    file.path(spill_session_dir(), fname)
  } else {
    file.path(spill_dir, fname)
  }
}

# Remove this session's spill directory (called by the exit finalizer). Best
# effort: never errors, so it is safe during R's shutdown.
cleanup_spill_session <- function() {
  dir <- .rebirth_state$session_dir
  if (!is.null(dir) && dir.exists(dir)) {
    unlink(dir, recursive = TRUE, force = TRUE)
  }
  invisible(NULL)
}

# Remove spill directories left by earlier sessions that ended more than
# `max_age_days` ago (a crashed session cannot run its exit finalizer). Best
# effort and silent: a locked or vanished directory is skipped.
sweep_old_spill_dirs <- function(max_age_days = 7) {
  root <- spill_root_dir()
  if (!dir.exists(root)) {
    return(invisible(NULL))
  }
  dirs <- list.dirs(root, full.names = TRUE, recursive = FALSE)
  keep <- .rebirth_state$session_dir
  cutoff <- Sys.time() - max_age_days * 24 * 60 * 60
  for (d in dirs) {
    if (!is.null(keep) && normalizePath(d, mustWork = FALSE) ==
      normalizePath(keep, mustWork = FALSE)) {
      next
    }
    mtime <- tryCatch(file.info(d)$mtime, error = function(e) NA)
    if (length(mtime) == 1L && !is.na(mtime) && mtime < cutoff) {
      unlink(d, recursive = TRUE, force = TRUE)
    }
  }
  invisible(NULL)
}

.onLoad <- function(libname, pkgname) {
  # Register the exit-time cleanup on a sentinel environment: reg.finalizer with
  # onexit = TRUE runs cleanup_spill_session() when R shuts down normally.
  sentinel <- new.env(parent = emptyenv())
  reg.finalizer(sentinel, function(e) cleanup_spill_session(), onexit = TRUE)
  .rebirth_state$sentinel <- sentinel
  # Sweep spill directories orphaned by earlier crashed sessions (never errors).
  tryCatch(sweep_old_spill_dirs(), error = function(e) NULL)
  invisible(NULL)
}
