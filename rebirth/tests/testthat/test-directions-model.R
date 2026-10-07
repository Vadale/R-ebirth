# Real captured F6d artifact from model-evaluation-20261007-175741. This is
# measured data, not an independent numerical golden; source/failed-run scope is
# retained in tests/directions/measurements. Ordinary CI does not download it.
test_that("[MODEL] checked direction preserves zero and original-handle seeded reset", {
  path <- Sys.getenv("RELM_TEST_MODEL_QWEN")
  skip_if(!nzchar(path) || !file.exists(path), "Set RELM_TEST_MODEL_QWEN to the cached Qwen file; no download.")
  sha <- unname(tools::sha256sum(path))
  skip_if(sha != "ca59ca7f13d0e15a8cfa77bd17e65d24f6844b554a7b6c12e07a5f89ff76844e",
    "This recorded artifact requires the exact Qwen2.5-0.5B-Instruct Q8_0 checkpoint.")
  artifact <- readRDS(test_path("fixtures", "direction-qwen.rds"))
  m <- llm(path, backend = "cpu", context_length = 512L)
  on.exit(close(m), add = TRUE)
  context <- list(sha256 = sha, architecture = m$architecture, quantization = m$quantization,
    hidden_size = as.integer(m$hidden_size), layers = as.integer(m$layers),
    engine_revision = "b10828-patched-D039-D040")
  prompt <- "Answer the question concisely in one short sentence.\nQuestion: What does the human heart pump?\nAnswer:"
  run <- function(handle) llm_generate(handle, prompt, chat = FALSE, max_tokens = 8L,
    temperature = 0, top_p = .95, seed = 101L)
  before <- run(m)
  zero <- llm_apply_direction(m, artifact, context, coef = 0)
  on.exit(close(zero), add = TRUE)
  expect_identical(run(zero), before)
  close(zero)
  changed <- llm_apply_direction(m, artifact, context, coef = 1)
  on.exit(close(changed), add = TRUE)
  actual <- run(changed); close(changed)
  raw <- llm_steer(m, 12L, artifact$value, coef = 1)
  on.exit(close(raw), add = TRUE)
  expect_identical(run(raw), actual)
  close(raw)
  expect_identical(run(m), before)
  expect_identical(m$interventions, list())
})
