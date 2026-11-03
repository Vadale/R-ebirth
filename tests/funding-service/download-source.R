# Source preparation for CI/application setup only; never part of relm's runtime.
# Preserve exact version pins and R's installation/MD5 checks. The SHA printed
# below records fetched bytes; it is not an independently pinned hash oracle.
service_download_source <- function(package, version, destination) {
  scalar <- function(x) is.character(x) && length(x) == 1L && !is.na(x)
  if (!scalar(package) || !grepl("^[A-Za-z][A-Za-z0-9.]*$", package) ||
      !scalar(version) || !grepl("^[0-9]+([.-][0-9]+)*$", version))
    stop("Invalid pinned package identity.")
  is_link <- function(path) {
    link <- Sys.readlink(path)
    !is.na(link) & nzchar(link)
  }
  if (!scalar(destination) || !nzchar(destination) || file.exists(destination) ||
      dir.exists(destination) || is_link(destination))
    stop("Refusing existing or invalid download destination.")
  curl <- unname(Sys.which("curl"))
  if (!nzchar(curl)) stop("curl is required for bounded source preparation.")
  partial <- paste0(destination, ".part")
  http_file <- paste0(destination, ".http")
  error_file <- paste0(destination, ".stderr")
  scratch <- c(partial, http_file, error_file)
  if (any(file.exists(scratch) | dir.exists(scratch)) ||
      any(is_link(scratch)))
    stop("Refusing existing download scratch files.")
  on.exit(unlink(scratch), add = TRUE)
  filename <- paste0(package, "_", version, ".tar.gz")
  # At most four curl invocations (up to three HTTPS redirects each): current + Archive on each host, Archive only on 404.
  # 10s connect, 25s transfer, 30s process; no retries. Worst process budget 120s
  # does not exceed the former two 60s download.file attempts.
  for (host in c("https://cloud.r-project.org", "https://cran.r-project.org")) {
    urls <- paste0(host, c("/src/contrib/", paste0("/src/contrib/Archive/", package, "/")),
                   filename)
    for (url in urls) {
      unlink(scratch)
      arguments <- c("--disable", "--fail", "--show-error", "--silent",
                     "--location", "--max-redirs", "3", "--proto", "=https",
                     "--proto-redir", "=https", "--connect-timeout", "10",
                     "--max-time", "25", "--retry", "0", "--output", partial,
                     "--write-out", "%{http_code}", url)
      started <- proc.time()[["elapsed"]]
      status <- system2(curl, shQuote(arguments), stdout = http_file,
                        stderr = error_file, timeout = 30)
      http <- if (file.exists(http_file)) paste(readLines(http_file, warn = FALSE), collapse = "") else ""
      diagnostic <- if (file.exists(error_file)) paste(readLines(error_file, warn = FALSE), collapse = "\n") else ""
      message(sprintf("PIN_DOWNLOAD package=%s version=%s url=%s exit=%d http=%s seconds=%.3f",
                      package, version, url, status, http, proc.time()[["elapsed"]] - started))
      if (nzchar(diagnostic)) message(diagnostic)
      if (status == 0L && identical(http, "200")) {
        if (!file.exists(partial) || is.na(file.info(partial)$size) || file.info(partial)$size <= 0)
          stop("Empty pinned source response: ", package)
        digest <- unname(tools::sha256sum(partial))
        if (is.na(digest) || !grepl("^[0-9a-f]{64}$", digest))
          stop("Cannot record source digest: ", package)
        if (!file.rename(partial, destination)) stop("Cannot retain pinned source: ", package)
        message("PIN_DOWNLOAD_COMPLETE package=", package, " sha256=", digest)
        return(invisible(destination))
      }
      if (status == 22L && identical(http, "404")) next
      transient <- status %in% c(5L, 6L, 7L, 18L, 28L, 52L, 55L, 56L, 124L) ||
        (status == 22L && (http %in% c("408", "429") || grepl("^5[0-9]{2}$", http)))
      if (transient) break
      stop("Non-recoverable pinned source failure: ", package, " (exit=", status, ", HTTP=", http, ").")
    }
  }
  stop("Pinned source unavailable from both CRAN endpoints: ", package)
}
