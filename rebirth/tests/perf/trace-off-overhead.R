# WP4 acceptance (REV-1 / docs/wp4-trace-plan.md section 7.4): tap-off generation
# overhead < 2%.
#
# WHY THIS IS ~0, NOT A FOUGHT-FOR BUDGET (the structural guarantee). The activation
# tap is installed ONLY on a dedicated, transient trace context: engine.rs
# `create_trace_context()` sets `cb_eval`/`cb_eval_user_data`, and that context is
# dropped at the end of each `llm_trace()` call. The GENERATION context, created once
# in engine.rs `load()`, never sets `cb_eval` (it takes `llama_context_default_params`
# and only overrides `n_ctx`), so the ggml scheduler takes its no-callback fast path
# for every generated token. Running traces in a session therefore cannot slow
# generation -- the two paths use separate contexts.
#
# THE ABI PIN THIS RESTS ON. The guarantee would break only if a vendor-bump silently
# shifted the context-params layout so the null we write elsewhere landed on
# `cb_eval` (turning generation into a tapped pass). rebirth-llm's ffi.rs test
# `context_params_embedding_fields_have_the_expected_abi` pins exactly that: it asserts
# `size_of::<llama_context_params>() == 160` AND that `cb_eval`/`cb_eval_user_data`
# default to null. So a layout drift fails `cargo test` before it could reach here.
#
# WHAT THIS SCRIPT DOES. It DEMONSTRATES the guarantee empirically: it times
# `llm_generate()` alone (baseline) vs `llm_generate()` in a session that is also
# running activation traces (each timed generation is preceded by an `llm_trace()`),
# and asserts the median difference is < 2%. Because the generation context is pristine
# in both, the measured overhead is measurement noise around zero.
#
# HOW TO RUN. This file lives under tests/perf/ (a subdirectory that neither testthat
# nor R CMD check sources), so it never runs in the normal suite; it needs a real
# tokenizer + model, so it is gated on RELM_TEST_MODEL_QWEN. From the package root:
#
#   RELM_TEST_MODEL_QWEN=/path/to/qwen2.5-0.5b-instruct-q8_0.gguf \
#     Rscript -e 'devtools::load_all(quiet = TRUE); \
#                 testthat::test_file("tests/perf/trace-off-overhead.R")'
#
# (For an installed package, replace the load_all() with library(relm).)

test_that("tap-off generation overhead is < 2% (generation never installs cb_eval)", {
  model_path <- path.expand(Sys.getenv("RELM_TEST_MODEL_QWEN"))
  skip_if_not(
    nzchar(model_path) && file.exists(model_path),
    "RELM_TEST_MODEL_QWEN is not set to an existing GGUF file"
  )

  m <- llm(model_path)
  on.exit(close(m), add = TRUE)

  prompt <- "Explain in one sentence why the sky appears blue."
  # A fixed seed + fixed max_tokens keeps the generation work constant across reps,
  # so the timing compares like with like.
  generate_once <- function() {
    invisible(llm_generate(m, prompt, max_tokens = 32L, seed = 1L))
  }
  elapsed_generate <- function() {
    unname(system.time(generate_once())[["elapsed"]])
  }

  # Warm up: the first call pays one-time context/graph warmup, not measured.
  generate_once()

  reps <- 11L
  # Baseline: generation alone.
  baseline <- replicate(reps, elapsed_generate())
  # Trace-active: run an activation trace (which installs cb_eval on its own transient
  # context, then drops it) immediately before each timed generation, so tracing is
  # part of the session's work. Only the generation is timed; it uses the pristine
  # generation context, so its cost must be unchanged.
  trace_active <- replicate(reps, {
    invisible(llm_trace(m, prompt, layers = 1:4, components = "residual"))
    elapsed_generate()
  })

  baseline_med <- stats::median(baseline)
  active_med <- stats::median(trace_active)
  overhead <- (active_med - baseline_med) / baseline_med

  cat(sprintf(
    paste0(
      "tap-off generation overhead: baseline median %.4fs (min %.4fs), ",
      "trace-active median %.4fs (min %.4fs) -> overhead %.2f%%\n"
    ),
    baseline_med, min(baseline), active_med, min(trace_active), 100 * overhead
  ))

  # The generation context never has cb_eval, so true overhead is zero; the assertion
  # allows only measurement noise. A real regression (a callback leaking onto the
  # generation path) would be far larger than 2%.
  expect_lt(overhead, 0.02)
})
