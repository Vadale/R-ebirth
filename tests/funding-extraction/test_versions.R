# Version-boundary controls only; no package installation or model activity.
source("examples/funding-service/common.R")
for (version in c("0.3.0", "0.4.0", "0.5.0")) stopifnot(app_relm_version_supported(version))
for (version in list("0.2.0", "0.3.1", "0.6.0", "0.4.0.9000", "", NA_character_,
                    NULL, character(), c("0.3.0", "0.4.0"), 0.4))
  stopifnot(!app_relm_version_supported(version))
scratch <- tempfile("version-metadata-")
dir.create(scratch)
original_libs <- .libPaths()
pins <- svc_pins()
write_version <- function(package, version) {
  dir.create(file.path(scratch, package), showWarnings = FALSE)
  writeLines(c(paste("Package:", package), paste("Version:", version)),
             file.path(scratch, package, "DESCRIPTION"))
}
for (i in seq_len(nrow(pins))) write_version(pins$package[[i]], pins$version[[i]])
write_version("nanoarrow", "metadata-fixture")
tryCatch({
  for (version in c("0.3.0", "0.4.0", "0.5.0")) {
    write_version("relm", version)
    stopifnot(identical(svc_library(scratch), normalizePath(scratch)))
  }
  for (version in c("0.2.0", "0.6.0")) {
    write_version("relm", version)
    error <- tryCatch(svc_library(scratch), error = identity)
    stopifnot(inherits(error, "funding_error_environment"))
  }
  write_version("relm", "0.4.0")
  write_version("jsonlite", "0.0.0")
  error <- tryCatch(svc_library(scratch), error = identity)
  stopifnot(inherits(error, "funding_error_environment"))
}, finally = {
  .libPaths(original_libs)
  unlink(scratch, recursive = TRUE)
})
cat("APPLICATION_VERSION_OK predicate_cases=13 service_cases=6 models=0\n")
