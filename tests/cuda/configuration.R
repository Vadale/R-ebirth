# Build routing checks: no SDK needed for an ordinary CPU/Metal configuration.
source("rebirth/tools/cuda.R")
refused <- function(expr, pattern) {
  result <- tryCatch(force(expr), error = identity)
  stopifnot(inherits(result, "error"), grepl(pattern, conditionMessage(result), fixed = TRUE))
}
stopifnot(identical(relm_cuda_config("0", "/missing/sdk"), list(feature = "", libs = "")))
refused(relm_cuda_config("yes"), "must be 0 or 1")
refused(relm_cuda_config("1", system = "Darwin", arch = "arm64"), "requires Linux x86_64")
refused(relm_cuda_config("1", system = "Windows", arch = "x86_64"), "requires Linux x86_64")
refused(relm_cuda_config("1", system = "Linux", arch = "aarch64"), "requires Linux x86_64")
root <- tempfile("cuda toolkit ")
dir.create(root)
dir.create(file.path(root, "bin"))
refused(relm_cuda_config("1", root, "Linux", "x86_64"), "nvcc is missing")
file.create(file.path(root, "bin", "nvcc"))
refused(relm_cuda_config("1", root, "Linux", "x86_64"), "shared cudart and cublas")
dir.create(file.path(root, "lib"))
file.create(file.path(root, "lib", "libcudart.so"))
refused(relm_cuda_config("1", root, "Linux", "x86_64"), "shared cudart and cublas")
file.create(file.path(root, "lib", "libcublas.so"))
config <- relm_cuda_config("1", root, "Linux", "x86_64")
stopifnot(identical(config$feature, "--features cuda"),
          grepl("-lcudart -lcublas -lcuda", config$libs, fixed = TRUE),
          !grepl("stubs", config$libs, fixed = TRUE))
unlink(root, recursive = TRUE)
cat("CUDA_CONFIG_PASS cases=9\n")
