# WP5: llm_steer() / llm_ablate() -- the intervention R surface (D-016).
#
# What runs where:
#   * Argument/validation errors, the derived-handle contract, composition, the
#     close-source-first Arc lifetime, and the intervened-handle embed/trace guards
#     need no tokenizer, so they run in per-commit CI on the in-repo synthetic
#     model (a real llama handle) or a stubbed handle.
#   * The synthetic model is no_vocab, so it cannot llm_generate(). The
#     generation-level acceptances (a steer/ablate changes output, bit-for-bit
#     reversibility, and derivation-order-independence) are [MODEL]-gated on
#     RELM_TEST_MODEL_QWEN (the founder's hardware / nightly, plan section 10).
# The exact numerical effect + reversibility are proven independently in Rust
# (tests/synthetic_intervene.rs) against the numpy oracle, not here.

synthetic_model_path <- function() {
  p <- testthat::test_path("fixtures", "synthetic-llama-2l.gguf")
  skip_if_not(file.exists(p), "synthetic GGUF fixture is missing")
  p
}

qwen_model_path <- function() {
  p <- path.expand(Sys.getenv("RELM_TEST_MODEL_QWEN"))
  skip_if_not(
    nzchar(p) && file.exists(p),
    "RELM_TEST_MODEL_QWEN is not set to an existing GGUF file"
  )
  p
}

# --- argument validation (before the engine; runs in CI) --------------------

test_that("llm_steer() / llm_ablate() reject a non-llm handle", {
  expect_error(llm_steer(42, 2, 1), class = "relm_error_argument")
  expect_error(llm_ablate(42, 1, 1), class = "relm_error_argument")
})

# The R-side architecture hard-stop is gone (D-021): interventions are no longer
# gated by a fixed allow-list. The engine's runtime sentinel probe proves the
# mechanism takes effect on the specific model and raises relm_error_intervention
# if it would silently no-op. That rejection is exercised on real weights in the Rust
# integration test tests/synthetic_probe.rs (a steer at a layer the mechanism cannot
# reach is refused with the classed error); it cannot be tested here, since an
# unsupported-architecture model is never available in CI and a stub handle has no
# live engine to probe.

test_that("INTERVENTION_VALIDATED_ARCHS is documentation for the validated tier, not a gate", {
  # Retargeted from the old twin-pinned hard allow-list (D-021, hard rule 8f): the
  # constant now DOCUMENTS the behaviorally-validated tier (architectures with a
  # committed WP5 acceptance fixture beyond the runtime probe), consumed only by
  # ?llm_steer / the model matrix. It must gate nothing.
  expect_true(all(c("llama", "qwen2") %in% INTERVENTION_VALIDATED_ARCHS))
  # gemma3 was only source-verified, never behaviorally validated -> it is NOT in the
  # tier (honest); it still works at runtime whenever the probe passes.
  expect_false("gemma3" %in% INTERVENTION_VALIDATED_ARCHS)
  # The tier is doc-only: neither entry point consults it, and the old R-side arch
  # hard-stop call (check_intervention_arch) is gone -- the engine probe replaces it.
  for (fn in list(llm_steer, llm_ablate)) {
    src <- paste(deparse(body(fn)), collapse = "\n")
    expect_false(grepl("INTERVENTION_VALIDATED_ARCHS", src, fixed = TRUE))
    expect_false(grepl("check_intervention_arch", src, fixed = TRUE))
  }
})

test_that("llm_steer() validates layer / direction / coef / positions", {
  m <- stub_llm() # qwen2 (supported), layers = 24, hidden_size = 896

  # layer out of range
  expect_error(llm_steer(m, 0, rep(0, 896)), class = "relm_error_intervention")
  expect_error(llm_steer(m, 25, rep(0, 896)), class = "relm_error_intervention")
  expect_error(llm_steer(m, 2.5, rep(0, 896)), class = "relm_error_intervention")
  expect_error(llm_steer(m, c(2, 3), rep(0, 896)), class = "relm_error_intervention")

  # layer 1 steer is structurally unreachable (native cvec reserves engine index 0)
  cnd <- tryCatch(llm_steer(m, 1, rep(0, 896)), condition = function(c) c)
  expect_s3_class(cnd, "relm_error_intervention")
  expect_identical(cnd$argument, "layer")
  expect_match(conditionMessage(cnd), "layer 1", fixed = TRUE)
  expect_match(conditionMessage(cnd), "ablate layer 1", fixed = TRUE) # names the workaround

  # direction shape
  expect_error(llm_steer(m, 2, rep(0, 5)), class = "relm_error_intervention")
  expect_error(llm_steer(m, 2, c(rep(0, 895), NA)), class = "relm_error_intervention")
  expect_error(llm_steer(m, 2, c(rep(0, 895), Inf)), class = "relm_error_intervention")
  expect_error(llm_steer(m, 2, "x"), class = "relm_error_intervention")

  # coef shape
  expect_error(llm_steer(m, 2, rep(0, 896), coef = c(1, 2)), class = "relm_error_intervention")
  expect_error(llm_steer(m, 2, rep(0, 896), coef = NA), class = "relm_error_intervention")

  # positions: only "all" is supported in this release
  expect_error(llm_steer(m, 2, rep(0, 896), positions = 1:2), class = "relm_error_intervention")
  expect_error(
    llm_steer(m, 2, rep(0, 896), positions = "last"),
    class = "relm_error_intervention"
  )

  # the offending argument is named in a structured field
  cnd <- tryCatch(llm_steer(m, 2, rep(0, 5)), condition = function(c) c)
  expect_identical(cnd$argument, "direction")
})

test_that("llm_ablate() validates layer / neurons / value / component", {
  m <- stub_llm() # qwen2, layers = 24, hidden_size = 896

  expect_error(llm_ablate(m, 0, 1), class = "relm_error_intervention")
  expect_error(llm_ablate(m, 25, 1), class = "relm_error_intervention")

  # neurons shape / range
  expect_error(llm_ablate(m, 1, integer(0)), class = "relm_error_intervention")
  expect_error(llm_ablate(m, 1, c(0, 5)), class = "relm_error_intervention")
  expect_error(llm_ablate(m, 1, c(5, 999)), class = "relm_error_intervention")
  expect_error(llm_ablate(m, 1, 2.5), class = "relm_error_intervention")
  expect_error(llm_ablate(m, 1, c(3, NA)), class = "relm_error_intervention")

  # value shape
  expect_error(llm_ablate(m, 1, 3, value = c(0, 1)), class = "relm_error_intervention")
  expect_error(llm_ablate(m, 1, 3, value = Inf), class = "relm_error_intervention")

  # component: only "residual" is supported in this release
  expect_error(llm_ablate(m, 1, 3, component = "attn_out"), class = "relm_error_intervention")
  expect_error(llm_ablate(m, 1, 3, component = "mlp_out"), class = "relm_error_intervention")

  cnd <- tryCatch(llm_ablate(m, 1, c(5, 999)), condition = function(c) c)
  expect_identical(cnd$argument, "neurons")
})

test_that("interventions reject a closed handle", {
  m <- llm(synthetic_model_path())
  close(m)
  expect_error(llm_steer(m, 2, rep(0, 32)), class = "relm_error_closed")
  expect_error(llm_ablate(m, 1, 1), class = "relm_error_closed")
})

# --- derived-handle contract (synthetic model; runs in CI) ------------------

test_that("llm_steer() returns a new handle and never mutates the source", {
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)

  d <- llm_steer(m, layer = 2, direction = rep(0.1, m$hidden_size), coef = 2)
  on.exit(close(d), add = TRUE)

  expect_s3_class(d, "llm")
  # The source is untouched: no interventions, still open, distinct state env.
  expect_length(m$interventions, 0L)
  expect_false(isTRUE(m$state$closed))
  expect_false(identical(d$state, m$state))

  # The derived handle carries the structured steer entry.
  expect_length(d$interventions, 1L)
  iv <- d$interventions[[1]]
  expect_identical(iv$kind, "steer")
  expect_identical(iv$layer, 2L)
  expect_identical(iv$coef, 2)
  expect_identical(iv$positions, "all")
  expect_length(iv$direction, m$hidden_size)
})

test_that("llm_ablate() returns a new handle carrying the ablation spec", {
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)

  a <- llm_ablate(m, layer = 1, neurons = c(5, 3), value = -1)
  on.exit(close(a), add = TRUE)

  expect_s3_class(a, "llm")
  expect_length(m$interventions, 0L)
  expect_length(a$interventions, 1L)
  iv <- a$interventions[[1]]
  expect_identical(iv$kind, "ablate")
  expect_identical(iv$layer, 1L)
  expect_identical(iv$neurons, c(3L, 5L)) # sorted, unique
  expect_identical(iv$value, -1)
  expect_identical(iv$component, "residual")
})

test_that("summary() lists a derived handle's interventions; print() counts them", {
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)
  d <- m |>
    llm_steer(layer = 2, direction = rep(0.1, m$hidden_size)) |>
    llm_ablate(layer = 1, neurons = 3)
  on.exit(close(d), add = TRUE)

  print_out <- capture.output(print(d))
  expect_true(any(grepl("interventions:\\s+2 active", print_out)))

  sum_out <- capture.output(print(summary(d)))
  expect_true(any(grepl("steer  layer 2", sum_out, fixed = TRUE)))
  expect_true(any(grepl("ablate layer 1", sum_out, fixed = TRUE)))
})

# --- composition (synthetic model; runs in CI) ------------------------------

test_that("interventions compose and are derivation-order-independent (spec level)", {
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)
  dir <- rep(0.1, m$hidden_size)

  c1 <- m |> llm_steer(layer = 2, direction = dir) |> llm_ablate(layer = 1, neurons = 3)
  c2 <- m |> llm_ablate(layer = 1, neurons = 3) |> llm_steer(layer = 2, direction = dir)
  on.exit(close(c1), add = TRUE)
  on.exit(close(c2), add = TRUE)

  # Both accumulate the SAME set of interventions (a steer + an ablate), regardless
  # of derivation order (the graph applies ablation after steering either way).
  expect_length(c1$interventions, 2L)
  expect_length(c2$interventions, 2L)
  kinds1 <- vapply(c1$interventions, `[[`, character(1), "kind")
  kinds2 <- vapply(c2$interventions, `[[`, character(1), "kind")
  expect_setequal(kinds1, c("steer", "ablate"))
  expect_setequal(kinds2, c("steer", "ablate"))
})

test_that("stacking steers on one layer keeps both entries in the spec", {
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)
  d <- m |>
    llm_steer(layer = 2, direction = rep(0.1, m$hidden_size)) |>
    llm_steer(layer = 2, direction = rep(0.2, m$hidden_size))
  on.exit(close(d), add = TRUE)
  # Two steers are retained (the engine sums them per layer, D-016); deriving one
  # more from the stacked handle still works.
  expect_length(d$interventions, 2L)
  d2 <- llm_ablate(d, layer = 1, neurons = 1)
  on.exit(close(d2), add = TRUE)
  expect_length(d2$interventions, 3L)
})

# --- source lifetime: Arc<Model> keeps the weights alive (section 7.3) -------

test_that("a derived handle outlives the source it was derived from", {
  m <- llm(synthetic_model_path())
  d <- llm_steer(m, layer = 2, direction = rep(0.1, m$hidden_size))
  on.exit(close(d), add = TRUE)

  # Close the SOURCE first. The derived handle shares the underlying weights via a
  # cloned Arc<Model>, so it stays open AND can still derive further handles (which
  # needs the weights alive) -- a real native exercise, not just a flag check.
  close(m)
  expect_false(isTRUE(d$state$closed))
  d2 <- llm_ablate(d, layer = 1, neurons = 2)
  on.exit(close(d2), add = TRUE)
  expect_s3_class(d2, "llm")
  expect_length(d2$interventions, 2L)
})

test_that("closing a derived handle does not close its source", {
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)
  d <- llm_ablate(m, layer = 1, neurons = 1)
  close(d)
  expect_true(isTRUE(d$state$closed))
  expect_false(isTRUE(m$state$closed)) # independent state envs
  # The source is still usable after the derived handle is freed.
  d2 <- llm_steer(m, layer = 2, direction = rep(0.1, m$hidden_size))
  on.exit(close(d2), add = TRUE)
  expect_s3_class(d2, "llm")
})

# --- intervened-handle guards (embed / trace) -------------------------------

test_that("embedding / tracing an intervened handle is a classed error (stub)", {
  # The guard fires on any non-empty interventions list, before any tokenization,
  # so a stub with a placeholder entry exercises it with no model.
  s <- stub_llm(interventions = list(list(kind = "steer", layer = 2L)))
  expect_error(llm_embed(s, "hello"), class = "relm_error_embed")
  expect_error(llm_trace(s, "hello"), class = "relm_error_trace")
})

test_that("a real intervened handle blocks embed and trace", {
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)
  d <- llm_ablate(m, layer = 1, neurons = 1)
  on.exit(close(d), add = TRUE)
  # A fresh (un-intervened) synthetic handle raises relm_error_tokenize on embed;
  # the intervened handle raises the guard FIRST (relm_error_embed / _trace).
  expect_error(llm_embed(d, "hello"), class = "relm_error_embed")
  expect_error(llm_trace(d, "hello"), class = "relm_error_trace")
})

# --- [MODEL] generation-level acceptance (Qwen; founder hardware / nightly) --

test_that("steering measurably changes generated output", {
  m <- llm(qwen_model_path())
  on.exit(close(m), add = TRUE)
  prompt <- "In one sentence, describe the ocean."
  base <- llm_generate(m, prompt, max_tokens = 24, temperature = 0)

  # A strong steer at a mid layer perturbs the residual enough to change greedy
  # output. (The exact numerical effect is proven in synthetic_intervene.rs; this is
  # the coarse end-to-end check on a real tokenizer + model.)
  layer <- max(2L, as.integer(round(m$layers / 2)))
  s <- llm_steer(m, layer = layer, direction = rep(1, m$hidden_size), coef = 6)
  on.exit(close(s), add = TRUE)
  steered <- llm_generate(s, prompt, max_tokens = 24, temperature = 0)
  expect_false(identical(unname(base), unname(steered)))
})

test_that("ablation measurably changes generated output", {
  m <- llm(qwen_model_path())
  on.exit(close(m), add = TRUE)
  prompt <- "In one sentence, describe the ocean."
  base <- llm_generate(m, prompt, max_tokens = 24, temperature = 0)

  # Ablating the entire residual of the last block to zero is a large, guaranteed
  # perturbation of the next-token distribution.
  a <- llm_ablate(m, layer = m$layers, neurons = seq_len(m$hidden_size), value = 0)
  on.exit(close(a), add = TRUE)
  ablated <- llm_generate(a, prompt, max_tokens = 24, temperature = 0)
  expect_false(identical(unname(base), unname(ablated)))
})

test_that("the original handle reproduces its output bit-for-bit after derivation", {
  m <- llm(qwen_model_path())
  on.exit(close(m), add = TRUE)
  prompt <- "In one sentence, describe the ocean."
  base <- llm_logits(m, prompt) # deterministic; Metal greedy text is not bit-reproducible

  # Deriving steered / ablated handles must not touch the source context.
  s <- llm_steer(m, layer = 4, direction = rep(1, m$hidden_size), coef = 3)
  a <- llm_ablate(s, layer = 6, neurons = c(1, 2, 3), value = 0)
  on.exit(close(s), add = TRUE)
  on.exit(close(a), add = TRUE)

  after <- llm_logits(m, prompt)
  expect_identical(base, after) # source next-token distribution unchanged (WP5)
})

test_that("generation is derivation-order-independent (steer/ablate commute)", {
  m <- llm(qwen_model_path())
  on.exit(close(m), add = TRUE)
  prompt <- "In one sentence, describe the ocean."
  dir <- rep(1, m$hidden_size)

  c1 <- m |>
    llm_steer(layer = 5, direction = dir, coef = 3) |>
    llm_ablate(layer = 5, neurons = c(10, 20, 30), value = 0)
  c2 <- m |>
    llm_ablate(layer = 5, neurons = c(10, 20, 30), value = 0) |>
    llm_steer(layer = 5, direction = dir, coef = 3)
  on.exit(close(c1), add = TRUE)
  on.exit(close(c2), add = TRUE)

  # Same interventions, opposite derivation order -> identical next-token
  # distribution (a steer never moves an ablated neuron; ablation runs after the
  # steer, D-016). Asserted via the deterministic, intervention-aware llm_logits,
  # not greedy text (see the reversibility test above for why).
  expect_identical(
    llm_logits(c1, prompt),
    llm_logits(c2, prompt)
  )
})
