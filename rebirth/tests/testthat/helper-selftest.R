# Native fixtures are compiled only by an explicit RELM_ENABLE_SELFTESTS=1 build.
# Inspect registration, not R wrappers: a production wrapper may still exist
# without its deliberately omitted native entry point.
relm_selftest_names <- c(
  "rebirth_async_test_handle", "rebirth_async_test_config", "rebirth_async_test_stats",
  "rebirth_selftest_projection_ledger", "rebirth_selftest_projection_budget_error",
  "rebirth_selftest_projection_transfer", "rebirth_selftest_projection_constructor",
  "rebirth_selftest_projection_combined_logits", "rebirth_selftest_new_handle",
  "rebirth_selftest_validate_image", "rebirth_selftest_panic",
  "rebirth_selftest_trace_tokens_spill"
)

relm_selftest_registered <- function() {
  routines <- names(getDLLRegisteredRoutines("relm")[[".Call"]])
  sub("^wrap__", "", routines[grepl("^wrap__rebirth_(selftest_|async_test_)", routines)])
}

require_relm_selftest <- function(routines = relm_selftest_names) {
  missing <- setdiff(routines, relm_selftest_registered())
  if (!length(missing)) return(invisible(NULL))
  message <- paste("Native selftest entries are unavailable:", paste(missing, collapse = ", "))
  if (identical(Sys.getenv("RELM_ENABLE_SELFTESTS"), "1")) {
    stop(paste("Required selftest build is incomplete.", message), call. = FALSE)
  }
  testthat::skip(paste("Production build omits native fixtures.", message))
}

# Public async/model tests still run on production builds. Missing optional
# counters must not replace their real timeout failure with a symbol error.
async_test_native_stats <- function() {
  if ("rebirth_async_test_stats" %in% relm_selftest_registered()) {
    return(relm:::rebirth_async_test_stats())
  }
  if (identical(Sys.getenv("RELM_ENABLE_SELFTESTS"), "1")) {
    require_relm_selftest("rebirth_async_test_stats")
  }
  list(available = FALSE, reason = "Native counters are omitted from production builds.")
}
