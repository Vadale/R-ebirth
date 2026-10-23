# Note: Any variables prefixed with `.` are used for text
# replacement in the Makevars.in and Makevars.win.in

# check the packages MSRV first
source("tools/msrv.R")

# then check cmake is present and recent enough (builds the vendored llama.cpp)
source("tools/cmake.R")

# check DEBUG and NOT_CRAN environment variables
env_debug <- Sys.getenv("DEBUG")
env_not_cran <- Sys.getenv("NOT_CRAN")

# check if the vendored zip file exists
vendor_exists <- file.exists("src/rust/vendor.tar.xz")

is_not_cran <- identical(tolower(env_not_cran), "true")
is_debug <- env_debug != ""

if (is_debug) {
  # if we have DEBUG then we set not cran to true
  # CRAN is always release build
  is_not_cran <- TRUE
  message("Creating DEBUG build.")
}

if (!is_not_cran) {
  message("Building for CRAN.")
}

# Bound package compilation even when a developer has no vendor bundle.
.cran_flags <- paste("--locked -j 2", if (vendor_exists) "--offline" else "")
if (!is_not_cran && !vendor_exists) {
  stop("Bundled Rust sources are missing; use a complete relm source package. ",
       "Maintainers may set NOT_CRAN=true for an unbundled development checkout.", call. = FALSE)
}
source("tools/source-bundles.R")
relm_unpack_engine()

# Only explicit maintainer/CI builds expose native fixture entry points.
selftest <- Sys.getenv("RELM_ENABLE_SELFTESTS", "0")
if (!selftest %in% c("0", "1")) {
  stop("RELM_ENABLE_SELFTESTS must be 0 or 1", call. = FALSE)
}
.selftest_feature <- if (identical(selftest, "1")) "--features selftest" else ""
source("tools/cuda.R")
cuda <- relm_cuda_config()
.cuda_feature <- cuda$feature

# Ordinary R CPU/Metal binaries must not depend on the build machine's ISA.
# Keep the explicitly opted-in CUDA performance build at its accepted flags.
.native_build_env <- if (nzchar(.cuda_feature)) "RELM_R_PORTABLE=0" else paste(
  'RELM_R_PORTABLE=1 CC="$(CC)" CXX="$(CXX17)"',
  'CFLAGS="$(CPPFLAGS) $(CFLAGS) $(CPICFLAGS)"',
  'CXXFLAGS="$(CPPFLAGS) $(CXX17FLAGS) $(CXX17PICFLAGS) $(CXX17STD)"'
)
# Quote for the shell first, then escape dollars for the enclosing make recipe.
.native_build_env <- paste0("CMAKE=", gsub("$", "$$", shQuote(cmake_command, type = "sh"), fixed = TRUE),
                           " ", .native_build_env)

# when DEBUG env var is present we use `--debug` build
.profile <- ifelse(is_debug, "", "--release")
.clean_targets <- ifelse(is_debug, "", "$(TARGET_DIR)")

# We specify this target when building for webR
webr_target <- "wasm32-unknown-emscripten"

# here we check if the platform we are building for is webr
is_wasm <- identical(R.version$platform, webr_target)

# print to terminal to inform we are building for webr
if (is_wasm) {
  message("Building for WebR")
}

# we check if we are making a debug build or not
# if so, the LIBDIR environment variable becomes:
# LIBDIR = $(TARGET_DIR)/{wasm32-unknown-emscripten}/debug
# this will be used to fill out the LIBDIR env var for Makevars.in
target_libpath <- if (is_wasm) "wasm32-unknown-emscripten" else NULL
cfg <- if (is_debug) "debug" else "release"

# used to replace @LIBDIR@
.libdir <- paste(c(target_libpath, cfg), collapse = "/")

# use this to replace @TARGET@
# we specify the target _only_ on webR
# there may be use cases later where this can be adapted or expanded
.target <- ifelse(is_wasm, paste0("--target=", webr_target), "")

# add panic exports only for WASM builds
.panic_exports <- ifelse(
  is_wasm,
  "CARGO_PROFILE_DEV_PANIC=\"abort\" CARGO_PROFILE_RELEASE_PANIC=\"abort\" ",
  ""
)

# read in the Makevars.in file checking
is_windows <- .Platform[["OS.type"]] == "windows"
.rscript <- file.path(R.home("bin"), if (is_windows) "Rscript.exe" else "Rscript")
.rscript <- gsub("$", "$$", shQuote(.rscript, type = "sh"), fixed = TRUE)

# Native link flags for the vendored llama.cpp/ggml/mtmd static archives
# (D-006, D-026). rebirth-llm/build.rs relocates the archives into $(LIBDIR);
# here we name them (in dependency order: mtmd references llama + ggml, so
# -lmtmd comes first; ggml-base is the leaf and comes last) plus the per-OS
# system libraries/frameworks the engine needs. Twin-pinned with `lib_stems`
# in rebirth-llm/build.rs — keep the two lists consistent. build.rs enables
# Metal only on macOS arm64, so the archive set and the frameworks are matched
# to that here.
sysname <- Sys.info()[["sysname"]]
arch <- R.version[["arch"]]
.windows_target <- ""
if (is_windows) {
  # Rtools uses GNU on x86 and LLVM/MinGW on ARM64. WIN is empty on current
  # ARM64 Rtools; derive Cargo's target from the R being installed into.
  .windows_target <- switch(arch,
    x86_64 = "x86_64-pc-windows-gnu",
    i386 = "i686-pc-windows-gnu", i686 = "i686-pc-windows-gnu",
    aarch64 = "aarch64-pc-windows-gnullvm", arm64 = "aarch64-pc-windows-gnullvm",
    stop("Unsupported Windows R architecture: ", arch, call. = FALSE))
  windows_cxx <- if (arch %in% c("aarch64", "arm64")) "-lc++" else "-lstdc++"
  # Windows CPU linking; actual build/check acceptance is the WP15 gate.
  .llama_libs <- paste(
    "-Wl,--start-group",
    "-lrelm-grammar -lmtmd -lvendor-hash -lllama -lggml -lggml-cpu -lggml-base",
    paste("-Wl,--end-group", windows_cxx)
  )
} else if (is_wasm) {
  # Rust's Emscripten static= links bundle all native archives into librelm.a.
  # Match --print=native-static-libs: only libc++ remains external to that bundle.
  .llama_libs <- "-lc++"
} else if (identical(sysname, "Darwin")) {
  is_arm <- arch %in% c("aarch64", "arm64")
  stems <- c("-lrelm-grammar", "-lmtmd", "-lvendor-hash", "-lllama", "-lggml", "-lggml-cpu")
  if (is_arm) stems <- c(stems, "-lggml-metal")
  stems <- c(stems, "-lggml-base")
  # ggml-cpu uses Accelerate on all Apple targets; the Metal backend adds
  # Metal/MetalKit/Foundation. Makevars selects the C++17 linker, which supplies
  # libc++ itself; adding it here would duplicate the driver's standard library.
  frameworks <- if (is_arm) {
    "-framework Metal -framework MetalKit -framework Foundation -framework Accelerate"
  } else {
    "-framework Accelerate"
  }
  .llama_libs <- paste(paste(stems, collapse = " "), frameworks)
} else {
  # Linux and other Unix: group the archives so any back-references
  # between them resolve regardless of order under GNU ld.
  .llama_libs <- paste(
    "-Wl,--start-group",
    "-lrelm-grammar -lmtmd -lvendor-hash -lllama -lggml -lggml-cpu -lggml-base",
    "-Wl,--end-group -lstdc++ -lm -ldl"
  )
  if (nzchar(.cuda_feature)) {
    .llama_libs <- sub("-lggml-base", "-lggml-cuda -lggml-base", .llama_libs, fixed = TRUE)
    .llama_libs <- paste(.llama_libs, cuda$libs)
  }
}

# if windows we replace in the Makevars.win.in
mv_fp <- ifelse(
  is_windows,
  "src/Makevars.win.in",
  "src/Makevars.in"
)

# set the output file
mv_ofp <- ifelse(
  is_windows,
  "src/Makevars.win",
  "src/Makevars"
)

# delete the existing Makevars{.win/.wasm}
if (file.exists(mv_ofp)) {
  message("Cleaning previous `", mv_ofp, "`.")
  invisible(file.remove(mv_ofp))
}

# read as a single string
mv_txt <- readLines(mv_fp)

# replace placeholder values
new_txt <- gsub("@CRAN_FLAGS@", .cran_flags, mv_txt) |>
  gsub("@PROFILE@", .profile, x = _) |>
  gsub("@SELFTEST_FEATURE@", .selftest_feature, x = _) |>
  gsub("@CUDA_FEATURE@", .cuda_feature, x = _) |>
  gsub("@NATIVE_BUILD_ENV@", .native_build_env, x = _, fixed = TRUE) |>
  gsub("@RSCRIPT@", .rscript, x = _, fixed = TRUE) |>
  gsub("@CLEAN_TARGET@", .clean_targets, x = _) |>
  gsub("@LIBDIR@", .libdir, x = _) |>
  gsub("@TARGET@", .target, x = _) |>
  gsub("@WINDOWS_TARGET@", .windows_target, x = _, fixed = TRUE) |>
  gsub("@LLAMA_LIBS@", .llama_libs, x = _) |>
  gsub("@PANIC_EXPORTS@", .panic_exports, x = _)

message("Writing `", mv_ofp, "`.")
con <- file(mv_ofp, open = "wb")
writeLines(new_txt, con, sep = "\n")
close(con)

message("`tools/config.R` has finished.")
