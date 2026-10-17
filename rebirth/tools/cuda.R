# Build configuration only; not installed as a public package API.
relm_cuda_config <- function(enabled = Sys.getenv("RELM_ENABLE_CUDA", "0"),
                             root = Sys.getenv("CUDA_PATH", "/usr/local/cuda"),
                             system = Sys.info()[["sysname"]],
                             arch = R.version[["arch"]]) {
  if (!enabled %in% c("0", "1")) {
    stop("RELM_ENABLE_CUDA must be 0 or 1", call. = FALSE)
  }
  if (identical(enabled, "0")) return(list(feature = "", libs = ""))
  if (!identical(system, "Linux") || !identical(arch, "x86_64")) {
    stop("RELM_ENABLE_CUDA=1 currently requires Linux x86_64", call. = FALSE)
  }
  root <- normalizePath(root, mustWork = TRUE)
  if (grepl("[\r\n$]", root)) stop("Unsupported character in CUDA_PATH", call. = FALSE)
  if (!file.exists(file.path(root, "bin", "nvcc"))) {
    stop("CUDA_PATH/bin/nvcc is missing", call. = FALSE)
  }
  dirs <- file.path(root, c("lib64", "lib", "targets/x86_64-linux/lib"))
  dirs <- dirs[file.exists(file.path(dirs, "libcudart.so")) &
    file.exists(file.path(dirs, "libcublas.so"))]
  if (!length(dirs)) {
    stop("CUDA_PATH must contain shared cudart and cublas libraries", call. = FALSE)
  }
  # R can then load the installed package without a shell LD_LIBRARY_PATH.
  # No toolkit stub-driver path is added: libcuda comes from the system driver.
  list(feature = "--features cuda", libs = paste(
    shQuote(paste0("-L", dirs[[1L]])),
    shQuote(paste0("-Wl,-rpath,", dirs[[1L]])), "-lcudart -lcublas -lcuda"
  ))
}
