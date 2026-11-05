# Actual downloader logic with only the curl process replaced; no network/install.
module <- new.env(parent = globalenv())
sys.source("tests/funding-service/download-source.R", envir = module)
module$Sys.which <- function(cmd) setNames("/fixture/curl", cmd)
payload <- charToRaw("fixed source bytes")
cases <- 0L
run_case <- function(responses, error = NULL, existing = FALSE) {
  directory <- tempfile("service-download-")
  dir.create(directory)
  on.exit(unlink(directory, recursive = TRUE), add = TRUE)
  destination <- file.path(directory, "source archive.tar.gz")
  if (existing) writeBin(charToRaw("original"), destination)
  calls <- character()
  module$system2 <- function(command, args, stdout, stderr, timeout) {
    # shQuote uses POSIX single quotes here; source paths contain a space.
    args <- substring(args, 2L, nchar(args) - 1L)
    option <- function(name) args[match(name, args) + 1L]
    stopifnot(command == "/fixture/curl", args[[1L]] == "--disable",
              option("--proto") == "=https", option("--proto-redir") == "=https",
              option("--retry") == "0", option("--max-redirs") == "3",
              option("--connect-timeout") == "10", option("--max-time") == "25",
              timeout == 30, !any(args %in% c("-k", "--insecure")),
              all(c("--fail", "--location") %in% args))
    target <- option("--output")
    stopifnot(!file.exists(target))
    calls <<- c(calls, tail(args, 1L))
    stopifnot(length(calls) <= 4L, length(responses) > 0L)
    answer <- responses[[1L]]
    responses <<- responses[-1L]
    writeBin(answer$body, target)
    writeLines(answer$http, stdout)
    writeLines("fixture transport diagnostic", stderr)
    answer$status
  }
  result <- tryCatch(module$service_download_source("stringi", "1.8.9", destination),
                     error = identity)
  if (is.null(error)) {
    if (inherits(result, "error")) stop(result)
    stopifnot(identical(readBin(destination, "raw", n = length(payload)), payload))
  } else {
    stopifnot(inherits(result, "error"), grepl(error, conditionMessage(result), fixed = TRUE))
    if (existing) stopifnot(identical(readBin(destination, "raw", n = 8L), charToRaw("original"))) else
      stopifnot(!file.exists(destination))
  }
  stopifnot(!any(file.exists(paste0(destination, c(".part", ".http", ".stderr")))))
  cases <<- cases + 1L
  calls
}
answer <- function(status, http, body = charToRaw("partial")) list(status = status, http = http, body = body)
ok <- answer(0L, "200", payload)
cloud <- "https://cloud.r-project.org/src/contrib/stringi_1.8.9.tar.gz"
cran <- "https://cran.r-project.org/src/contrib/stringi_1.8.9.tar.gz"
cloud_archive <- "https://cloud.r-project.org/src/contrib/Archive/stringi/stringi_1.8.9.tar.gz"
cran_archive <- "https://cran.r-project.org/src/contrib/Archive/stringi/stringi_1.8.9.tar.gz"
stopifnot(identical(run_case(list(ok)), cloud))
stopifnot(identical(run_case(list(answer(28L, "000"), ok)), c(cloud, cran)))
stopifnot(identical(run_case(list(answer(18L, "200"), ok)), c(cloud, cran)))
stopifnot(identical(run_case(list(answer(22L, "503"), ok)), c(cloud, cran)))
stopifnot(identical(run_case(list(answer(22L, "404"), ok)), c(cloud, cloud_archive)))
stopifnot(identical(run_case(list(answer(22L, "404"), answer(28L, "000"), ok)),
                    c(cloud, cloud_archive, cran)))
stopifnot(identical(run_case(c(rep(list(answer(22L, "404")), 3L), list(ok))),
                    c(cloud, cloud_archive, cran, cran_archive)))
stopifnot(length(run_case(rep(list(answer(22L, "404")), 4L), "both CRAN endpoints")) == 4L)
stopifnot(identical(run_case(list(answer(28L, "000"), answer(7L, "000")),
                            "both CRAN endpoints"), c(cloud, cran)))
stopifnot(identical(run_case(list(answer(124L, "000"), ok)), c(cloud, cran)))
for (response in list(answer(60L, "000"), answer(22L, "403"), answer(0L, "302"))) {
  stopifnot(identical(run_case(list(response), "Non-recoverable"), cloud))
}
stopifnot(identical(run_case(list(answer(0L, "200", raw())), "Empty pinned source"), cloud))
stopifnot(length(run_case(list(), "Refusing existing", existing = TRUE)) == 0L)
# Hosted macOS curl returned exit 56 with a confirmed HTTP 404. The HTTP
# result must select Archive on the same host, without accepting partial bytes.
stopifnot(identical(run_case(list(answer(56L, "404"), ok)), c(cloud, cloud_archive)))
stopifnot(identical(run_case(list(answer(28L, "000"), answer(56L, "404"), ok)),
                    c(cloud, cran, cran_archive)))
stopifnot(identical(run_case(list(answer(56L, "404"), answer(28L, "000"), ok)),
                    c(cloud, cloud_archive, cran)))
stopifnot(identical(run_case(rep(list(answer(56L, "404")), 4L), "both CRAN endpoints"),
                    c(cloud, cloud_archive, cran, cran_archive)))
# A receive failure alone is not an Archive signal or a complete download.
for (http in c("000", "200")) {
  stopifnot(identical(run_case(list(answer(56L, http), ok)), c(cloud, cran)))
}
# A transport code must not bypass a definite authorization/permanent HTTP
# refusal. Certificate/TLS failures remain fatal even alongside HTTP 404.
for (response in list(answer(60L, "404"), answer(35L, "404"),
                      answer(56L, "401"), answer(56L, "403"), answer(56L, "407"),
                      answer(28L, "404"), answer(56L, "410"))) {
  stopifnot(identical(run_case(list(response), "Non-recoverable"), cloud))
}
for (http in c("408", "429", "503")) {
  stopifnot(identical(run_case(list(answer(56L, http), ok)), c(cloud, cran)))
}
module$system2 <- function(...) stop("Unexpected network attempt")
for (input in list(c("../stringi", "1.8.9"), c("stringi", "1.8.9/other"),
                      c("https://example.org", "1.8.9"), c("stringi", NA_character_))) {
  error <- tryCatch(module$service_download_source(input[[1L]], input[[2L]], tempfile()),
                    error = identity)
  stopifnot(inherits(error, "error"), grepl("Invalid pinned package identity", conditionMessage(error), fixed = TRUE))
  cases <- cases + 1L
}
cat(sprintf("SERVICE_DOWNLOAD_OK cases=%d network=0 installs=0 models=0\n", cases))
