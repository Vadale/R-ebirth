# WP4: llm_trace() activation taps. Written golden-first / TDD: every test below
# targets the not-yet-implemented `llm_trace()` and the `rebirth_trace` S3
# methods, so they FAIL now and PASS once the coder implements the approved
# API-GRAMMAR section 4 surface. Each test names the defect it would catch.
#
# What runs where:
#   * Argument validation, predictive OOM, and the print/summary/as.matrix method
#     format tests need no engine (a stubbed or a valid open synthetic handle, or
#     a hand-built rebirth_trace), so they run in per-commit CI.
#   * Real activation values need a real tokenizer + model and are [MODEL]-gated on
#     REBIRTH_TEST_MODEL_QWEN (run on the founder's hardware / nightly).
# The synthetic model activations are checked exactly by the Rust de-risking gate
# (tests/synthetic_trace.rs) against the numpy oracle, not here.

synthetic_model_path <- function() {
  p <- testthat::test_path("fixtures", "synthetic-llama-2l.gguf")
  skip_if_not(file.exists(p), "synthetic GGUF fixture is missing")
  p
}

qwen_model_path <- function() {
  p <- path.expand(Sys.getenv("REBIRTH_TEST_MODEL_QWEN"))
  skip_if_not(
    nzchar(p) && file.exists(p),
    "REBIRTH_TEST_MODEL_QWEN is not set to an existing GGUF file"
  )
  p
}

# A hand-built `rebirth_trace` with the exact 7-column schema and attributes of
# API-GRAMMAR section 2, so the print/summary/as.matrix contracts can be tested
# with no engine. Small but non-degenerate: 1 prompt x 2 token positions x
# 2 layers x 2 components x 4 neurons = 32 rows. Each `value` encodes its own
# (prompt_id, token_pos, layer, component, neuron) coordinates as a distinctive
# 5-digit number, so (a) as.matrix slice selection + ordering is verifiable and
# (b) a print method that leaks the data is detectable (those numbers must not
# appear). The component axis order mirrors the WP4 golden (residual first here
# only to exercise a non-default first slot; order within a trace is free).
make_trace <- function() {
  prompts <- c("hello world") # one prompt
  positions <- 1:2 # two token positions
  layers <- 1:2
  components <- c("residual", "attn_out")
  n_neuron <- 4L

  grid <- expand.grid(
    neuron = seq_len(n_neuron),
    component = components,
    layer = layers,
    token_pos = positions,
    prompt_id = seq_along(prompts),
    stringsAsFactors = FALSE,
    KEEP.OUT.ATTRS = FALSE
  )
  comp_idx <- match(grid$component, components)
  value <- grid$prompt_id * 1e4 + grid$token_pos * 1e3 +
    grid$layer * 1e2 + comp_idx * 1e1 + grid$neuron

  df <- data.frame(
    prompt_id = as.integer(grid$prompt_id),
    token_pos = as.integer(grid$token_pos),
    token = sprintf("p%dt%d", grid$prompt_id, grid$token_pos),
    layer = as.integer(grid$layer),
    component = grid$component,
    neuron = as.integer(grid$neuron),
    value = as.numeric(value),
    stringsAsFactors = FALSE
  )
  structure(
    df,
    class = c("rebirth_trace", "data.frame"),
    model = "/models/synthetic-llama-2l.gguf",
    spilled = FALSE,
    spill_files = character(0),
    prompts = prompts
  )
}

# --- fixture well-formedness guard (no engine; runs in CI) ------------------

# Guards the in-code fixture itself: if a later edit to make_trace() drifts from
# the API-GRAMMAR section 2 schema, the method tests below would silently test
# the wrong shape. This catches that first.
test_that("the constructed rebirth_trace fixture matches the API-GRAMMAR schema", {
  x <- make_trace()
  expect_s3_class(x, "rebirth_trace")
  expect_s3_class(x, "data.frame")
  expect_identical(
    names(x),
    c("prompt_id", "token_pos", "token", "layer", "component", "neuron", "value")
  )
  expect_type(x$prompt_id, "integer")
  expect_type(x$token_pos, "integer")
  expect_type(x$token, "character")
  expect_type(x$layer, "integer")
  expect_type(x$component, "character")
  expect_type(x$neuron, "integer")
  expect_type(x$value, "double")
  expect_identical(nrow(x), 32L)
  expect_identical(attr(x, "spilled"), FALSE)
  expect_identical(attr(x, "prompts"), "hello world")
  expect_true(all(x$component %in% c("residual", "attn_out")))
})

# --- argument validation (before the engine; runs in CI) --------------------

test_that("llm_trace() rejects a non-llm handle", {
  # Defect: forgetting the `m` type guard would send a bad object to the engine.
  expect_error(llm_trace(42, "hi"), class = "rebirth_error_argument")
  cnd <- tryCatch(llm_trace(42, "hi"), condition = function(c) c)
  expect_identical(cnd$argument, "m")
})

test_that("llm_trace() validates `prompts`", {
  # Defect: a non-character / empty / NA / empty-string prompt reaching the
  # tokenizer (mirrors the llm_embed() contract).
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)

  expect_error(llm_trace(m, 42), class = "rebirth_error_argument")
  expect_error(llm_trace(m, character(0)), class = "rebirth_error_argument")
  expect_error(llm_trace(m, NA_character_), class = "rebirth_error_argument")
  expect_error(llm_trace(m, c("a", NA)), class = "rebirth_error_argument")
  expect_error(llm_trace(m, c("a", "")), class = "rebirth_error_argument")

  # The offending argument is named in a structured field (API-GRAMMAR section 6).
  cnd <- tryCatch(llm_trace(m, 42), condition = function(c) c)
  expect_identical(cnd$argument, "prompts")
})

test_that("llm_trace() validates `layers` (type and 1-based range)", {
  # Defect: a non-integer, zero/negative (1-based), or out-of-range layer index
  # silently mis-selecting or reaching the engine. Range is validated in R
  # against m$layers (API-GRAMMAR section 1.3: index checks are R-side).
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)

  expect_error(llm_trace(m, "hi", layers = "one"), class = "rebirth_error_argument")
  expect_error(llm_trace(m, "hi", layers = 0L), class = "rebirth_error_argument")
  expect_error(llm_trace(m, "hi", layers = -1L), class = "rebirth_error_argument")
  expect_error(llm_trace(m, "hi", layers = 1.5), class = "rebirth_error_argument")
  # Out of range: the synthetic model has 2 layers, so 999 cannot be captured.
  expect_error(llm_trace(m, "hi", layers = 999L), class = "rebirth_error_argument")

  cnd <- tryCatch(
    llm_trace(m, "hi", layers = "one"),
    condition = function(c) c
  )
  expect_identical(cnd$argument, "layers")
})

test_that("llm_trace() validates `positions`", {
  # Defect: an unknown keyword or an invalid (zero/negative/non-integer/NA)
  # position surviving into capture assembly.
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)

  expect_error(llm_trace(m, "hi", positions = "middle"), class = "rebirth_error_argument")
  expect_error(llm_trace(m, "hi", positions = 0L), class = "rebirth_error_argument")
  expect_error(llm_trace(m, "hi", positions = -2L), class = "rebirth_error_argument")
  expect_error(llm_trace(m, "hi", positions = 1.5), class = "rebirth_error_argument")
  expect_error(llm_trace(m, "hi", positions = NA_integer_), class = "rebirth_error_argument")
  expect_error(llm_trace(m, "hi", positions = c(1L, NA_integer_)), class = "rebirth_error_argument")

  cnd <- tryCatch(
    llm_trace(m, "hi", positions = "middle"),
    condition = function(c) c
  )
  expect_identical(cnd$argument, "positions")
})

test_that("validate_positions() de-duplicates explicit positions (M-1)", {
  # Defect (M-1): a repeated position (e.g. positions = c(1, 2, 2)) would emit
  # duplicate capture rows that as.matrix() then mis-assembles into a wrong matrix
  # under correct labels. Explicit positions must collapse to a sorted unique
  # integer vector before capture; keyword positions pass through unchanged.
  expect_identical(validate_positions(c(1, 2, 2)), c(1L, 2L))
  expect_identical(validate_positions(c(2L, 1L, 2L, 1L)), c(1L, 2L))
  expect_identical(validate_positions(3L), 3L)
  expect_identical(validate_positions("last"), "last")
  expect_identical(validate_positions("all"), "all")
})

test_that("llm_trace() validates `components` (subset of the allowed set)", {
  # Defect: an unknown component name silently producing an empty capture rather
  # than a classed error naming the argument.
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)

  expect_error(llm_trace(m, "hi", components = "banana"), class = "rebirth_error_argument")
  expect_error(llm_trace(m, "hi", components = c("residual", "banana")), class = "rebirth_error_argument")
  expect_error(llm_trace(m, "hi", components = 1L), class = "rebirth_error_argument")
  expect_error(llm_trace(m, "hi", components = character(0)), class = "rebirth_error_argument")
  expect_error(llm_trace(m, "hi", components = NA_character_), class = "rebirth_error_argument")

  cnd <- tryCatch(
    llm_trace(m, "hi", components = "banana"),
    condition = function(c) c
  )
  expect_identical(cnd$argument, "components")
})

test_that("llm_trace() validates `spill` and `spill_dir`", {
  # Defect: a non-logical spill flag or a bad spill_dir type reaching the spill
  # planner (mirrors the llm_embed() `normalize` contract for spill).
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)

  expect_error(llm_trace(m, "hi", spill = "yes"), class = "rebirth_error_argument")
  expect_error(llm_trace(m, "hi", spill = NA), class = "rebirth_error_argument")
  expect_error(llm_trace(m, "hi", spill = c(TRUE, FALSE)), class = "rebirth_error_argument")
  expect_error(llm_trace(m, "hi", spill_dir = 42), class = "rebirth_error_argument")
  expect_error(llm_trace(m, "hi", spill_dir = c("a", "b")), class = "rebirth_error_argument")

  cnd_spill <- tryCatch(
    llm_trace(m, "hi", spill = "yes"),
    condition = function(c) c
  )
  expect_identical(cnd_spill$argument, "spill")
  cnd_dir <- tryCatch(
    llm_trace(m, "hi", spill_dir = 42),
    condition = function(c) c
  )
  expect_identical(cnd_dir$argument, "spill_dir")
})

test_that("llm_trace() rejects a closed handle", {
  # Defect: using a freed native handle after close().
  m <- llm(synthetic_model_path())
  close(m)
  expect_error(llm_trace(m, "hi"), class = "rebirth_error_closed")
})

# --- predictive OOM (no model; runs in CI) ----------------------------------

test_that("llm_trace(spill = FALSE) over budget raises rebirth_error_oom before allocation", {
  # ACCEPTANCE (API-GRAMMAR section 4): an over-budget request with spill = FALSE
  # must raise rebirth_error_oom carrying a numeric `estimate_bytes` field,
  # BEFORE any allocation or tokenization -- so it is provable with a stub handle
  # (no native model) and positions = "last" (a length-independent 1-per-prompt
  # estimate). Defect this catches: an OOM that only triggers after the engine
  # has already tried to allocate the full capture (the 16 GB rule's whole point).
  m <- stub_llm() # layers = 24, hidden_size = 896; no native pointer used
  old <- options(rebirth.trace_budget = 1024) # 1 KB budget
  on.exit(options(old), add = TRUE)

  cnd <- tryCatch(
    llm_trace(
      m, "hello",
      positions = "last",
      components = c("residual", "attn_out", "mlp_out"),
      spill = FALSE
    ),
    condition = function(c) c
  )
  expect_s3_class(cnd, "rebirth_error_oom")
  expect_true(is.numeric(cnd$estimate_bytes))
  expect_length(cnd$estimate_bytes, 1L)
  expect_gt(cnd$estimate_bytes, 1024)
})

# --- rebirth_trace S3 methods (constructed object; runs in CI) --------------

test_that("print.rebirth_trace shows dims + capture spec and never dumps the data", {
  # ACCEPTANCE (API-GRAMMAR section 2): print is a one-screen digest (dimensions +
  # capture spec), never the rows. Defect this catches: falling through to
  # print.data.frame, which would dump every activation (and blow the console /
  # leak values) instead of summarizing.
  x <- make_trace()
  out <- capture.output(res <- print(x))
  expect_identical(res, x) # returns its argument invisibly

  # Compact: far fewer lines than the 32 data rows (a row dump would exceed them).
  expect_lt(length(out), nrow(x))

  # Capture spec is shown: the captured components are named.
  expect_true(any(grepl("residual", out)))
  expect_true(any(grepl("attn_out", out)))

  # The data itself is NOT printed: no per-row value, no token piece appears.
  # The needles are computed from `x` so they are exactly the strings a
  # data-dumping fallthrough (print.data.frame) would leak.
  expect_false(any(grepl(as.character(min(x$value)), out, fixed = TRUE)))
  expect_false(any(grepl(as.character(max(x$value)), out, fixed = TRUE)))
  expect_false(any(grepl(x$token[[1]], out, fixed = TRUE)))
})

test_that("summary.rebirth_trace digests per (layer, component): n and mean|value|", {
  # ACCEPTANCE (API-GRAMMAR section 2): summary reports, per (layer, component),
  # the count n and the mean |value|. Defect this catches: falling through to
  # summary.data.frame (per-column Min/Median/Max), which neither groups by
  # (layer, component) nor reports mean absolute activation.
  x <- make_trace()
  s <- summary(x)
  out <- capture.output(print(s))

  # Discriminator vs summary.data.frame (which hides character-column *values*):
  # a grouped digest names each captured component.
  expect_true(any(grepl("residual", out)))
  expect_true(any(grepl("attn_out", out)))
  # The mean |value| statistic is reported (API-GRAMMAR wording).
  expect_true(any(grepl("mean", out, ignore.case = TRUE)))

  # Independent reference: 2 layers x 2 components = 4 groups, each with
  # prompts * positions * neurons = 1 * 2 * 4 = 8 observations.
  ref_n <- aggregate(list(n = x$value), x[c("layer", "component")], length)
  expect_identical(nrow(ref_n), 4L)
  expect_true(all(ref_n$n == 8L))

  # If the digest is exposed as a per-group table, verify n and mean|value|
  # numerically against the independent aggregate (order-insensitive).
  if (is.data.frame(s)) {
    expect_identical(nrow(s), 4L)
    ref_m <- aggregate(list(m = abs(x$value)), x[c("layer", "component")], mean)
    num <- Filter(is.numeric, s)
    has_means <- vapply(
      num, function(col) isTRUE(all.equal(sort(col), sort(ref_m$m))), logical(1)
    )
    has_n <- vapply(
      num, function(col) isTRUE(all.equal(sort(col), rep(8, 4))), logical(1)
    )
    expect_true(any(has_means))
    expect_true(any(has_n))
  }
})

test_that("as.matrix.rebirth_trace extracts one (layer, component) slice as a matrix", {
  # ACCEPTANCE (API-GRAMMAR section 4): as.matrix(x, layer, component) returns one
  # slice -- one row per (prompt_id, token_pos), one column per neuron, rownames
  # "<prompt_id>.<token_pos>". Defect this catches: falling through to
  # as.matrix.data.frame (which ignores layer/component and coerces the whole
  # 32x7 frame), or selecting the wrong slice / scrambling row or neuron order.
  x <- make_trace()

  # Helper: the expected slice, computed INDEPENDENTLY from x's own rows (not the
  # encoding formula), so it also catches a wrong-value extraction.
  expected_slice <- function(layer, component) {
    sub <- x[x$layer == layer & x$component == component, ]
    sub <- sub[order(sub$prompt_id, sub$token_pos, sub$neuron), ]
    pts <- unique(sub[c("prompt_id", "token_pos")])
    pts <- pts[order(pts$prompt_id, pts$token_pos), ]
    m <- matrix(sub$value, nrow = nrow(pts), byrow = TRUE)
    rownames(m) <- sprintf("%d.%d", pts$prompt_id, pts$token_pos)
    m
  }

  r1 <- as.matrix(x, layer = 1L, component = "residual")
  expect_true(is.matrix(r1))
  expect_identical(dim(r1), c(2L, 4L)) # 2 (prompt,pos) rows x 4 neurons
  expect_identical(rownames(r1), c("1.1", "1.2"))
  expect_equal(unname(r1), unname(expected_slice(1L, "residual")))

  # A different slice must differ and match its own independent expectation,
  # proving the (layer, component) selection is real (not a fixed slice).
  a2 <- as.matrix(x, layer = 2L, component = "attn_out")
  expect_identical(rownames(a2), c("1.1", "1.2"))
  expect_equal(unname(a2), unname(expected_slice(2L, "attn_out")))
  expect_false(isTRUE(all.equal(unname(r1), unname(a2))))

  # `component` defaults to "residual" (API-GRAMMAR section 4).
  expect_equal(
    unname(as.matrix(x, layer = 1L)),
    unname(expected_slice(1L, "residual"))
  )

  # Slicing an uncaptured layer, or omitting the required `layer`, is an error
  # (never a silent empty / whole-frame coercion).
  expect_error(as.matrix(x, layer = 99L))
  expect_error(as.matrix(x))
})

test_that("as.matrix.rebirth_trace fails loud on a mis-shaped (duplicated) slice (M-1)", {
  # Defect (M-1): duplicate (prompt_id, token_pos, neuron) rows in a slice would make
  # matrix(byrow = TRUE) silently recycle/interleave values under correct row and
  # column labels -- a wrong matrix, no error. The structural invariant
  # nrow(sub) == n_points * n_neuron must instead raise a classed rebirth_error_trace,
  # catching any duplication source (a future one, or a defeated upstream dedupe).
  x <- make_trace()
  base <- as.data.frame(x)
  # Duplicate the layer-1/residual slice's rows: same coordinates, so the unique
  # (prompt, pos) points and neuron count are unchanged but nrow doubles.
  slice <- base[base$layer == 1L & base$component == "residual", ]
  dup <- structure(
    rbind(base, slice),
    class = c("rebirth_trace", "data.frame"),
    model = attr(x, "model"),
    spilled = FALSE,
    spill_files = character(0),
    prompts = attr(x, "prompts")
  )
  expect_error(
    as.matrix(dup, layer = 1L, component = "residual"),
    class = "rebirth_error_trace"
  )
  # The guard is slice-local: an untouched (layer, component) slice still works.
  clean <- as.matrix(dup, layer = 2L, component = "attn_out")
  expect_true(is.matrix(clean))
  expect_identical(dim(clean), c(2L, 4L))
})

# --- [MODEL] real-model trace (Qwen: tokenizer + hidden_size = 896) ----------

test_that("llm_trace() on a real model returns the rebirth_trace schema and slices [MODEL]", {
  # ACCEPTANCE: a real forward-pass trace yields the exact 7-column schema with
  # the requested layers/components, and as.matrix() returns a hidden_size-wide
  # slice. Skipped in CI; run on the founder's hardware with REBIRTH_TEST_MODEL_QWEN.
  m <- llm(qwen_model_path())
  on.exit(close(m), add = TRUE)

  tr <- llm_trace(
    m, c(a = "The cat sat on the mat.", b = "Quarks feel the strong force."),
    layers = 1:2, positions = "last",
    components = c("residual", "mlp_out"), spill = FALSE
  )

  expect_s3_class(tr, "rebirth_trace")
  expect_identical(
    names(tr),
    c("prompt_id", "token_pos", "token", "layer", "component", "neuron", "value")
  )
  expect_type(tr$prompt_id, "integer")
  expect_type(tr$value, "double")
  expect_setequal(unique(tr$component), c("residual", "mlp_out"))
  expect_setequal(unique(tr$layer), 1:2)
  expect_setequal(unique(tr$prompt_id), 1:2) # one per input prompt
  expect_true(all(tr$neuron >= 1L & tr$neuron <= m$hidden_size))

  mat <- as.matrix(tr, layer = 1L, component = "residual")
  expect_true(is.matrix(mat))
  expect_identical(ncol(mat), m$hidden_size)
  expect_match(rownames(mat)[1], "^[0-9]+\\.[0-9]+$")
})

test_that("llm_trace() attn_out on a qwen2 model is a classed, honest error [MODEL]", {
  # D-014: attn_out is the post-projection attention output, which qwen2 does not
  # name (it exposes only the pre-projection kqv_out, a different quantity, not even
  # hidden_size wide on gemma3). The engine raises rebirth_error_trace naming the
  # available components, never silently substituting the pre-Wo tensor.
  m <- llm(qwen_model_path())
  on.exit(close(m), add = TRUE)
  expect_error(
    llm_trace(m, "hello", components = "attn_out"),
    class = "rebirth_error_trace"
  )
})

test_that("llm_trace() warns when explicit positions are recycled across differing lengths [MODEL]", {
  # ACCEPTANCE (API-GRAMMAR section 4): an explicit `positions` vector is recycled
  # per prompt, "with a warning if lengths differ". A position valid for a long
  # prompt but out of range for a short one is dropped for the short one, which must
  # warn (once). Keyword positions ("last"/"all") never warn. Skipped in CI (needs a
  # tokenizer + model); runs on the founder's hardware with REBIRTH_TEST_MODEL_QWEN.
  m <- llm(qwen_model_path())
  on.exit(close(m), add = TRUE)

  short_long <- c("Hi.", "A considerably longer sentence, with several tokens to trace.")

  # Position 9 is out of range for the short prompt -> recycled/dropped -> warn.
  expect_warning(
    llm_trace(m, short_long, layers = 1L, positions = c(1L, 9L), components = "residual"),
    regexp = "recycled"
  )
  # Keyword positions never warn, even across differing-length prompts.
  expect_no_warning(
    llm_trace(m, short_long, layers = 1L, positions = "last", components = "residual")
  )
  # An explicit position in range for every prompt does not warn.
  expect_no_warning(
    llm_trace(m, short_long, layers = 1L, positions = 1L, components = "residual")
  )
})
