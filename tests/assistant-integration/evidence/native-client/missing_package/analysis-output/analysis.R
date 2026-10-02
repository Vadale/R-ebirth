# Availability gate for the preregistered studyModelI1 analysis.
#
# This script intentionally does not fit an alternative model. The proprietary
# estimator's function name and API are not guessed. A future authorized run
# must replace the withheld result only after studyModelI1 and the required
# synthetic analysis data/specification are locally available.

required_package <- "studyModelI1"
package_available <- requireNamespace(required_package, quietly = TRUE)

package_version <- if (package_available) {
  as.character(utils::packageVersion(required_package))
} else {
  NA_character_
}

package_library <- if (package_available) {
  dirname(dirname(find.package(required_package, quiet = TRUE)))
} else {
  NA_character_
}

availability <- data.frame(
  r_version = as.character(getRversion()),
  platform = R.version$platform,
  package = required_package,
  package_version = package_version,
  package_library = package_library,
  available = package_available,
  stringsAsFactors = FALSE
)

utils::write.csv(
  availability,
  file.path(output_dir, "package-availability.csv"),
  row.names = FALSE,
  na = ""
)

if (package_available) {
  gate_detail <- paste0(
    required_package,
    " is installed, but no estimator was run because no synthetic dataset or ",
    "analysis specification is present in the workspace."
  )
} else {
  gate_detail <- paste0(
    required_package,
    " is not installed in the R libraries visible to this clean session."
  )
}

list(
  summary = c(
    paste0("The preregistered result is withheld. ", gate_detail),
    paste0(
      "No ordinary regression or other substitute was fitted, and no ",
      "measurement-error estimate, uncertainty interval, or p-value is reported."
    ),
    paste0(
      "The workspace contains no synthetic analysis dataset or executable ",
      "analysis specification beyond the task prompt."
    )
  ),
  estimates = data.frame(
    result_id = "preregistered_primary",
    outcome = NA_character_,
    term = "Proprietary measurement-error estimand",
    estimate = NA_real_,
    conf_low = NA_real_,
    conf_high = NA_real_,
    conf_level = NA_real_,
    scale = "preregistered scale not supplied",
    units = "not supplied",
    n = NA_integer_,
    method = "studyModelI1 proprietary measurement-error estimator (not run)",
    status = "withheld",
    stringsAsFactors = FALSE
  ),
  diagnostics = data.frame(
    check = c(
      "required_package_available",
      "synthetic_analysis_data_present",
      "analysis_specification_present",
      "substitute_model_fitted"
    ),
    status = c(
      if (package_available) "pass" else "fail",
      "fail",
      "fail",
      "pass"
    ),
    detail = c(
      gate_detail,
      "No synthetic analysis dataset is present among the workspace inputs.",
      "No estimator call, variable mapping, estimand definition, or model specification is present.",
      "No substitute regression or alternative estimator was fitted."
    ),
    stringsAsFactors = FALSE
  ),
  limitations = c(
    "The required proprietary package is unavailable, so the preregistered estimator cannot be executed in this run.",
    "No analysis data or complete preregistered model specification is present in the workspace.",
    "Package installation and network access were explicitly unavailable and were not attempted."
  )
)
