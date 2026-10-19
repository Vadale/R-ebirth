# Standalone relm example. Source this file into a fresh environment, then call
# run_example(). Sourcing performs no installation, download, model load or write.
# See docs/agents.md for prerequisites and the difference between usage checks
# (download-free CI) and successful model execution (explicit local input).
# Explicit opt-in: may download about 675 MB, or verify/reuse a cached file.
run_example <- function(cache_dir, allow_download = FALSE) {
  if (!isTRUE(allow_download))
    stop("Set allow_download = TRUE only after approving the network/cache write.")
  path <- relm::llm_download("qwen2.5-0.5b-instruct-q8_0", dir = cache_dir)
  list(path = path, sha256 = unname(tools::sha256sum(path)))
}

# Run by CI: an actual public-API refusal, not a successful model run.
usage_check <- function() {
  condition <- tryCatch(relm::llm_download("http://example.invalid/model.gguf"), error = identity)
  stopifnot(inherits(condition, "relm_error"))
  class(condition)[1L]
}
