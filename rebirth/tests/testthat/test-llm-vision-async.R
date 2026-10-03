# Real VLM async parity; nightly vision executes this named gate.
# Ordinary model-free CI retains an explicit missing-model skip.

test_that("[MODEL] async vision matches the existing image generation path", {
  path <- path.expand(Sys.getenv("RELM_TEST_MODEL_VLM"))
  projector <- path.expand(Sys.getenv("RELM_TEST_MMPROJ_VLM"))
  skip_if_not(nzchar(path) && file.exists(path) && nzchar(projector) && file.exists(projector),
    "RELM_TEST_MODEL_VLM and RELM_TEST_MMPROJ_VLM are required")
  m <- llm(path, projector = projector)
  on.exit(close(m), add = TRUE)
  images <- vision_fixture("red-square.png")
  expected <- llm_generate(m, "What color is shown?", images = images,
    max_tokens = 8, temperature = 0, seed = 11)
  result <- async_test_observe(llm_generate(m, "What color is shown?", images = images,
    max_tokens = 8, temperature = 0, seed = 11, async = TRUE))
  async_test_wait(result, timeout = 120)
  expect_identical(result$value, expected)
})
