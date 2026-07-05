# Check that `cmake` (>= 3.28) is available: it drives the vendored llama.cpp
# static build via rebirth-llm/build.rs (DECISIONS.md D-006). Mirrors the
# cargo/rustc check in tools/msrv.R. Binary users on r-universe never hit this.

# The minimum cmake version (kept in sync with DESCRIPTION SystemRequirements).
cmake_min_version <- "3.28"

no_cmake_msg <- c(
  "----------------------- [CMAKE NOT FOUND]--------------------------",
  "The 'cmake' command was not found on the PATH. It is required to",
  paste0("build the vendored 'llama.cpp' engine (cmake >= ", cmake_min_version, ")."),
  "Please install CMake from: https://cmake.org/download/",
  "",
  "Alternatively, install it from your OS package manager:",
  " - Debian/Ubuntu: apt-get install cmake",
  " - Fedora/CentOS: dnf install cmake",
  " - macOS: brew install cmake",
  "-------------------------------------------------------------------"
)

# extract a semantic version (e.g. from "cmake version 3.28.3")
extract_semver <- function(ver) {
  if (grepl("\\d+\\.\\d+(\\.\\d+)?", ver)) {
    sub(".*?(\\d+\\.\\d+(\\.\\d+)?).*", "\\1", ver)
  } else {
    NA_character_
  }
}

cmake_version_raw <- tryCatch(
  system("cmake --version", intern = TRUE),
  error = function(e) stop(paste(no_cmake_msg, collapse = "\n")),
  warning = function(e) stop(paste(no_cmake_msg, collapse = "\n"))
)

current_cmake_version <- extract_semver(cmake_version_raw[[1]])

if (!is.na(current_cmake_version) &&
  utils::compareVersion(current_cmake_version, cmake_min_version) < 0) {
  fmt <- paste0(
    "\n------------------ [UNSUPPORTED CMAKE VERSION]------------------\n",
    "- Minimum supported CMake version is %s.\n",
    "- Installed CMake version is %s.\n",
    "- Please upgrade CMake: https://cmake.org/download/\n",
    "---------------------------------------------------------------"
  )
  stop(sprintf(fmt, cmake_min_version, current_cmake_version))
}

message(sprintf("Using cmake %s", current_cmake_version))
