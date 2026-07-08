#' Download a pinned model, verified by checksum
#'
#' Fetches a GGUF model file over HTTPS into a local cache and returns its path.
#' `model` is either a pinned alias from the package's model registry (see the
#' Details section) or a full `https://` URL. The download is
#' **fail-closed**: for a registry alias the file's SHA256 must match the pinned
#' value or the file is deleted and `rebirth_error_download` is raised. Nothing
#' downloaded is ever executed — the file is only written to disk and checksummed.
#'
#' @details
#' **Registry aliases.** The package ships a small registry (`inst/models.csv`)
#' of license-clean, checksum-pinned models. The current aliases are:
#'
#' - `"qwen2.5-0.5b-instruct-q8_0"` — Qwen2.5 0.5B Instruct, Q8_0 (Apache-2.0);
#'   the small CI-integration model.
#' - `"qwen2.5-1.5b-instruct-q4_k_m"` — Qwen2.5 1.5B Instruct, Q4_K_M
#'   (Apache-2.0); the demo default.
#'
#' Passing an unknown alias raises `rebirth_error_download` and lists the known
#' aliases. Larger Qwen quantizations (7B) ship as split multi-part GGUFs and are
#' not in the single-file registry yet; Gemma models are gated by the Gemma Terms
#' of Use (they require accepting terms and an access token on Hugging Face), so
#' they are supplied by local path rather than downloaded here.
#'
#' **Full URLs.** A full `https://` URL is downloaded as given. Only HTTPS is
#' accepted (`http://`, `ftp://`, `file://`, ... are rejected). A bare URL has no
#' pinned checksum, so the file cannot be *verified*; it is downloaded and its
#' computed SHA256 is reported so you can pin it — the function never presents an
#' unverifiable file as if it had been verified.
#'
#' **Caching.** `dir = NULL` uses the per-user cache directory
#' `tools::R_user_dir("rebirth", "cache")`; the directory is created if missing.
#' The target file name is the URL's last path segment. If a registry model is
#' already present and its checksum matches, the download is skipped (idempotent,
#' offline-friendly); a present-but-mismatching file is treated as corrupt and
#' re-downloaded. Verification happens on a temporary file that is only moved into
#' place once it passes, so the final path never holds unverified bytes.
#'
#' This is one of only two functions in the package that write outside a session
#' temporary directory (the other is [llm_trace()] spill); see the package's
#' side-effect contract.
#'
#' @param model Single string: a registry alias (see Details) or a full
#'   `https://` URL to a GGUF file.
#' @param dir `NULL` (the user cache directory) or a single string naming the
#'   directory to download into (created recursively if missing).
#' @param quiet Single logical. `TRUE` suppresses the download progress bar and
#'   the informational messages. Default `FALSE`.
#' @return The local file path, returned **invisibly**. Errors:
#'   `rebirth_error_argument` (bad `model`/`dir`/`quiet` type),
#'   `rebirth_error_download` (non-HTTPS URL, unknown alias, network failure,
#'   checksum mismatch, or an unwritable directory).
#' @seealso [llm()]
#' @examples
#' # The default download directory (dir = NULL); no network access is performed:
#' tools::R_user_dir("rebirth", "cache")
#'
#' \dontrun{
#' # Fetch a pinned, checksum-verified model and load it:
#' path <- llm_download("qwen2.5-0.5b-instruct-q8_0")
#' m <- llm(path)
#' }
#' @export
llm_download <- function(model, dir = NULL, quiet = FALSE) {
  if (!is.character(model) || length(model) != 1L || is.na(model) || !nzchar(model)) {
    abort_argument(
      "model",
      "`model` must be a single non-empty string: a registry alias or an https:// URL."
    )
  }
  if (!is.logical(quiet) || length(quiet) != 1L || is.na(quiet)) {
    abort_argument("quiet", "`quiet` must be a single logical value (TRUE or FALSE).")
  }
  if (is.null(dir)) {
    dir <- tools::R_user_dir("rebirth", "cache")
  } else if (!is.character(dir) || length(dir) != 1L || is.na(dir) || !nzchar(dir)) {
    abort_argument(
      "dir",
      "`dir` must be NULL (the user cache directory) or a single non-empty directory path."
    )
  } else {
    dir <- path.expand(dir)
  }

  spec <- resolve_model(model)
  invisible(download_verify(spec$url, spec$sha256, dir, quiet))
}

# The model registry (inst/models.csv): alias -> url, sha256, size_bytes,
# license, notes. Read fresh on each resolve (a tiny file); all columns are kept
# as character so a >2 GB size never coerces to NA and a hash is never re-typed.
model_registry <- function() {
  path <- system.file("models.csv", package = "rebirth")
  if (!nzchar(path) || !file.exists(path)) {
    abort_download(
      "The model registry (models.csv) is missing from the installed package."
    )
  }
  utils::read.csv(path, stringsAsFactors = FALSE, colClasses = "character")
}

# Resolve `model` to a download spec: list(url, sha256, source, size_bytes).
# An alias resolves from the registry (sha256 known); a full URL is passed
# through (sha256 = NA, unverifiable) but must be HTTPS. A string carrying any
# URL scheme is treated as a URL; anything else is looked up as an alias.
resolve_model <- function(model, call = sys.call(-1L)) {
  has_scheme <- grepl("^[a-zA-Z][a-zA-Z0-9+.-]*://", model)
  if (has_scheme) {
    if (!grepl("^https://", model, ignore.case = TRUE)) {
      abort_download(
        sprintf(
          paste0(
            "Only HTTPS downloads are allowed; '%s' does not start with 'https://'. ",
            "Supply an https:// URL or a registry alias."
          ),
          model
        ),
        fields = list(argument = "model", url = model),
        call = call
      )
    }
    return(list(
      url = model, sha256 = NA_character_, source = "url", size_bytes = NA_character_
    ))
  }

  reg <- model_registry()
  row <- reg[reg$alias == model, , drop = FALSE]
  if (nrow(row) == 0L) {
    abort_download(
      sprintf(
        "Unknown model alias '%s'. Known aliases: %s. (Or pass a full https:// URL.)",
        model, paste(reg$alias, collapse = ", ")
      ),
      fields = list(argument = "model", known_aliases = reg$alias),
      call = call
    )
  }
  url <- row$url[[1L]]
  if (!grepl("^https://", url, ignore.case = TRUE)) {
    # Defensive: the shipped registry is HTTPS-only, but never trust a
    # non-HTTPS URL even if one slipped into the file.
    abort_download(
      sprintf("Registry entry '%s' has a non-HTTPS URL; refusing to download.", model),
      fields = list(argument = "model", url = url),
      call = call
    )
  }
  list(
    url = url,
    sha256 = tolower(row$sha256[[1L]]),
    source = "alias",
    size_bytes = row$size_bytes[[1L]]
  )
}

# The last path segment of a URL, with any query string / fragment stripped;
# used as the on-disk file name.
basename_from_url <- function(url) {
  basename(sub("[?#].*$", "", url))
}

# Download `url` into `dir` and, when `expected` is a known SHA256, verify it
# fail-closed. Returns the destination path.
#
# Fail-closed discipline: the fetch lands in a temporary ".part" file on the same
# filesystem; it is checksummed there and only renamed into place once it passes,
# so the destination path never contains unverified or partial bytes, and a
# mismatch deletes the temporary file before the error is raised. A verified
# cached file is returned without re-downloading (idempotent); a corrupt cached
# file is removed and re-fetched. With `expected = NA` (a bare URL) there is
# nothing to verify against: the computed hash is reported, never asserted.
download_verify <- function(url, expected, dir, quiet, call = sys.call(-1L)) {
  if (!dir.exists(dir)) {
    dir.create(dir, recursive = TRUE, showWarnings = FALSE)
    if (!dir.exists(dir)) {
      abort_download(
        sprintf(
          "Could not create the download directory '%s'. Check permissions or choose another `dir`.",
          dir
        ),
        fields = list(dir = dir), call = call
      )
    }
  }

  fname <- basename_from_url(url)
  # Reject a name that would not stay inside `dir` (empty, or a path-traversal
  # token). basename() already strips directory components, so this only guards
  # the degenerate ".."/"."/"/" results of a URL ending in a separator.
  if (!nzchar(fname) || fname %in% c(".", "..", "/")) {
    abort_download(
      sprintf("Could not determine a file name from the URL '%s'.", url),
      fields = list(url = url), call = call
    )
  }
  dest <- file.path(dir, fname)

  if (!is.na(expected)) {
    if (file.exists(dest)) {
      if (identical(tolower(unname(tools::sha256sum(dest))), expected)) {
        if (!quiet) {
          message(sprintf("Using cached '%s' at '%s' (SHA256 verified).", fname, dir))
        }
        return(dest)
      }
      # Present but wrong: a corrupt cache. Remove it now so a later failed
      # re-download cannot leave a corrupt file masquerading as the model.
      if (!quiet) {
        message(sprintf("Cached '%s' failed its checksum; re-downloading.", fname))
      }
      unlink(dest, force = TRUE)
    }
  } else if (file.exists(dest)) {
    # Bare URL with a file already present: nothing to verify against, so report
    # its hash and reuse it rather than re-downloading.
    actual <- tolower(unname(tools::sha256sum(dest)))
    if (!quiet) {
      message(sprintf(
        "Using existing '%s' at '%s'.\n  SHA256: %s (no registry checksum to verify against).",
        fname, dir, actual
      ))
    }
    return(dest)
  }

  tmp <- tempfile(pattern = "rebirth-dl-", tmpdir = dir, fileext = ".part")
  on.exit(unlink(tmp, force = TRUE), add = TRUE)
  fetch_url(url, tmp, quiet)

  if (!file.exists(tmp)) {
    abort_download(
      sprintf("Download of '%s' produced no file.", url),
      fields = list(url = url), call = call
    )
  }
  actual <- tolower(unname(tools::sha256sum(tmp)))
  if (is.na(actual)) {
    unlink(tmp, force = TRUE)
    abort_download(
      sprintf("Could not read back the downloaded file for '%s' to checksum it.", url),
      fields = list(url = url), call = call
    )
  }

  if (!is.na(expected)) {
    if (!identical(actual, expected)) {
      unlink(tmp, force = TRUE) # FAIL-CLOSED: delete before raising.
      abort_download(
        sprintf(
          paste0(
            "SHA256 mismatch for '%s'.\n  expected: %s\n  actual:   %s\n",
            "The file was NOT kept. This can mean a corrupted or tampered ",
            "download; try again, and report it if it persists."
          ),
          url, expected, actual
        ),
        fields = list(expected = expected, actual = actual, url = url),
        call = call
      )
    }
  }

  if (!move_into_place(tmp, dest)) {
    unlink(tmp, force = TRUE)
    abort_download(
      sprintf("Could not move the downloaded file into place at '%s'.", dest),
      fields = list(dest = dest), call = call
    )
  }

  if (!quiet) {
    if (!is.na(expected)) {
      message(sprintf("Saved verified '%s' to '%s'.", fname, dest))
    } else {
      message(sprintf(
        "Saved '%s' to '%s'.\n  SHA256: %s (unverified: no registry checksum for a bare URL; pin this value to verify future downloads).",
        fname, dest, actual
      ))
    }
  }
  dest
}

# Move a verified temp file to its destination. file.rename is atomic within one
# filesystem (tmp and dest share `dir`); fall back to copy+remove if it fails
# (e.g. a dir mounted such that rename is refused).
move_into_place <- function(tmp, dest) {
  if (suppressWarnings(file.rename(tmp, dest))) {
    return(TRUE)
  }
  if (file.copy(tmp, dest, overwrite = TRUE)) {
    unlink(tmp, force = TRUE)
    return(TRUE)
  }
  FALSE
}

# The single network call: fetch `url` to `dest` over HTTPS via base R's libcurl
# method. Isolated so tests mock exactly this and drive every surrounding path
# offline. download.file() raises on an HTTP/connection error and leaves no file;
# any residue is removed and the failure re-raised as a classed condition.
fetch_url <- function(url, dest, quiet) {
  status <- tryCatch(
    utils::download.file(
      url, destfile = dest, method = "libcurl", mode = "wb", quiet = quiet
    ),
    error = function(e) {
      if (file.exists(dest)) unlink(dest, force = TRUE)
      abort_download(
        sprintf(
          "Download failed for '%s': %s\n  Check your network connection and the URL.",
          url, conditionMessage(e)
        ),
        fields = list(url = url)
      )
    }
  )
  if (!identical(as.integer(status), 0L)) {
    if (file.exists(dest)) unlink(dest, force = TRUE)
    abort_download(
      sprintf("Download of '%s' failed with status %s.", url, as.character(status)),
      fields = list(url = url)
    )
  }
  invisible(dest)
}
