#!/usr/bin/env Rscript
# Execute trusted analysis code and retain compact evidence; not a sandbox.
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2L) stop(
  "Usage: run-analysis.R analysis.R new-output-dir [input-file ...]", call. = FALSE
)
analysis_path <- normalizePath(args[[1L]], mustWork = TRUE)
input_paths <- if (length(args) > 2L) {
  normalizePath(args[-c(1L, 2L)], mustWork = TRUE)
} else character()
if (any(dir.exists(c(analysis_path, input_paths)))) {
  stop("Analysis and inputs must be files.", call. = FALSE)
}
if (file.exists(args[[2L]]) || dir.exists(args[[2L]])) {
  stop("Output already exists; choose a new directory.", call. = FALSE)
}
if (!dir.create(args[[2L]], recursive = TRUE)) {
  stop("Could not create output directory.", call. = FALSE)
}
output_dir <- normalizePath(args[[2L]], mustWork = TRUE)
conditions <- data.frame(type = character(), class = character(),
                         message = character(), call = character())
started <- format(Sys.time(), tz = "UTC", usetz = TRUE)
write_status <- function(state) {
  receipt <- matrix(c(state, started, format(Sys.time(), tz = "UTC", usetz = TRUE)),
                    nrow = 1L, dimnames = list(NULL, c("State", "Started", "Updated")))
  temp <- file.path(output_dir, ".status.tmp")
  write.dcf(receipt, temp)
  if (!file.rename(temp, file.path(output_dir, "status.dcf"))) {
    stop("Could not publish status.", call. = FALSE)
  }
}
record_condition <- function(e, type) {
  conditions[nrow(conditions) + 1L, ] <<- list(
    type, paste(class(e), collapse = "/"), conditionMessage(e),
    paste(deparse(conditionCall(e)), collapse = " ")
  )
}
write_csv <- function(x, name) utils::write.csv(
  x, file.path(output_dir, name), row.names = FALSE, na = "NA", fileEncoding = "UTF-8"
)
require_columns <- function(x, columns, name) {
  if (!is.data.frame(x) || !all(columns %in% names(x))) {
    stop(name, " must be a data.frame containing: ", paste(columns, collapse = ", "),
         call. = FALSE)
  }
  if (any(vapply(x, is.list, logical(1)))) stop(name, " cannot contain list columns.")
}
write_status("running")
succeeded <- tryCatch(withCallingHandlers({
  declared <- c(analysis_path, input_paths)
  before <- unname(tools::md5sum(declared))
  if (anyNA(before)) stop("Could not fingerprint all declared files.")
  write_csv(data.frame(role = c("analysis", rep("input", length(input_paths))),
                       path = declared, md5_before = before, md5_after = NA_character_),
            "manifest.csv")
  if (!file.copy(analysis_path, file.path(output_dir, "analysis.R"))) {
    stop("Could not retain analysis code.")
  }
  env <- new.env(parent = globalenv())
  env$input_paths <- input_paths
  env$output_dir <- output_dir
  result <- source(analysis_path, local = env, echo = FALSE, chdir = FALSE,
                   encoding = "UTF-8")$value
  if (!is.list(result) || !is.character(result$summary) ||
      !length(result$summary) || anyNA(result$summary) ||
      !is.character(result$limitations) || anyNA(result$limitations)) {
    stop("Return summary and limitations as character vectors, plus estimates and diagnostics.")
  }
  required <- c("result_id", "term", "estimate", "conf_low", "conf_high",
                "conf_level", "scale", "units", "n", "method", "status")
  require_columns(result$estimates, required, "estimates")
  require_columns(result$diagnostics, c("check", "status", "detail"), "diagnostics")
  est <- result$estimates
  if (!nrow(est) || anyNA(est$result_id) || any(!nzchar(est$result_id)) ||
      anyDuplicated(est$result_id)) stop("Use nonempty unique result_id values.")
  for (column in c("estimate", "conf_low", "conf_high", "conf_level", "n")) {
    if (!is.numeric(est[[column]]) || any(is.infinite(est[[column]]))) {
      stop(column, " must contain finite numbers or NA.")
    }
  }
  if (any(!est$status %in% c("ok", "exploratory", "withheld")) ||
      any(!result$diagnostics$status %in% c("pass", "warn", "fail", "assumed", "not_assessed"))) {
    stop("Invalid result or diagnostic status.")
  }
  if (any(est$conf_low > est$conf_high, na.rm = TRUE) ||
      any(est$conf_level <= 0 | est$conf_level >= 1, na.rm = TRUE) ||
      any(est$n < 0 | est$n != floor(est$n), na.rm = TRUE)) {
    stop("Invalid interval bounds, interval level or observation count.")
  }
  if (any(is.na(est$conf_low) != is.na(est$conf_high)) ||
      any(!is.na(est$conf_low) & is.na(est$conf_level))) {
    stop("Intervals require both endpoints and a stated level.")
  }
  after <- unname(tools::md5sum(declared))
  write_csv(data.frame(role = c("analysis", rep("input", length(input_paths))),
                       path = declared, md5_before = before, md5_after = after),
            "manifest.csv")
  if (!identical(before, after)) stop("A declared input or the analysis code changed during execution.")
  write_csv(est, "estimates.csv")
  write_csv(result$diagnostics, "diagnostics.csv")
  writeLines(c("# Analysis result", "", result$summary, "", "## Limitations", "",
               if (length(result$limitations)) paste0("- ", result$limitations) else
                 "No additional limitations were supplied; inspect the design and diagnostics.",
               "", paste("Captured warnings:", sum(conditions$type == "warning")),
               "See estimates.csv, diagnostics.csv and conditions.csv for evidence."),
             file.path(output_dir, "summary.md"), useBytes = TRUE)
  TRUE
}, warning = function(w) {
  record_condition(w, "warning")
  invokeRestart("muffleWarning")
}), error = function(e) {
  record_condition(e, "error")
  FALSE
})
write_csv(conditions, "conditions.csv")
writeLines(capture.output(utils::sessionInfo()), file.path(output_dir, "session-info.txt"))
write_status(if (succeeded) "complete" else "failed")
cat(if (succeeded) "Analysis complete:" else "Analysis failed:", output_dir, "\n")
if (!succeeded) quit(save = "no", status = 1L)
