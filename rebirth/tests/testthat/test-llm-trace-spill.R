# WP4 Step 5: disk-spill round-trip for llm_trace(). These run in per-commit CI on
# the synthetic 2-layer llama model. Because that model is no_vocab (it has no
# tokenizer), llm_trace() -- which tokenizes text -- cannot run on it, so the tests
# drive the same spill path with RAW token ids via the internal
# rebirth_selftest_trace_tokens_spill() entry (fixed spec: all layers, all
# positions, all three components). The Rust side (tests/synthetic_spill.rs)
# separately proves the writer against the arrow reader; these tests prove the R
# nanoarrow reader, the lazy as.matrix() slice, the no-load print()/summary(), and
# the staleness fail-safe.

synthetic_model_path <- function() {
  p <- testthat::test_path("fixtures", "synthetic-llama-2l.gguf")
  skip_if_not(file.exists(p), "synthetic GGUF fixture is missing")
  p
}

# The synthetic golden's engine ids are INPUT_TOKENS = [1,7,13,22,5,31,44,2]; the
# selftest entry converts 1-based R ids to 0-based engine ids, so pass +1.
synthetic_tokens <- function() c(1, 7, 13, 22, 5, 31, 44, 2) + 1L

# Trace raw tokens through the real spill path (memory or disk per `budget`),
# wrapping the boundary payload with the same constructors llm_trace() uses, so the
# resulting object is byte-identical to a user's. `spill_dir` isolates the files.
selftest_trace_tokens <- function(m, tokens, spill, budget, spill_dir = NULL) {
  components <- c("residual", "attn_out", "mlp_out")
  # Mirror llm_trace()'s spec key + nonce trace id (M-2). The raw-token path has no
  # text prompts, so a fixed placeholder stands in for the prompts digest; it is
  # used consistently for both the footer and the object, so the two still agree.
  spec_key <- trace_spec_key(m, "tokens", NULL, "all", components)
  spill_path <- if (isTRUE(spill)) next_spill_path(spill_dir) else ""
  trace_id <- if (nzchar(spill_path)) next_trace_id() else ""
  payload <- relm_check(rebirth_selftest_trace_tokens_spill(
    m$ptr, as.integer(tokens), spill, as.double(budget),
    spill_path, m$path, trace_id, spec_key
  ))
  if (isTRUE(payload$spilled)) {
    new_spilled_trace(payload, m, "tokens", spec_key)
  } else {
    new_inmemory_trace(payload, m, "tokens")
  }
}

test_that("a spilled trace's slices equal the in-memory slices exactly", {
  # ACCEPTANCE (WP4 Step 5): an over-budget capture with spill = TRUE streams to an
  # Arrow-IPC file, and as.matrix() read back via nanoarrow equals the same capture
  # held in memory -- neuron for neuron. Defect this catches: any writer/reader
  # drift (float32 rounding, index off-by-one, batch mis-assembly, column swap).
  m <- llm(synthetic_model_path())
  dir <- tempfile("relm-spill-test-")
  dir.create(dir)
  on.exit({
    close(m)
    unlink(dir, recursive = TRUE, force = TRUE)
  }, add = TRUE)

  toks <- synthetic_tokens()
  ref <- selftest_trace_tokens(m, toks, spill = FALSE, budget = Inf)
  sp <- selftest_trace_tokens(m, toks, spill = TRUE, budget = 1024, spill_dir = dir)

  expect_false(isTRUE(attr(ref, "spilled")))
  expect_true(isTRUE(attr(sp, "spilled")))
  expect_true(file.exists(attr(sp, "spill_files")))

  # Every (layer, component) slice matches, exactly (F32 on disk widened to double).
  for (layer in 1:2) {
    for (comp in c("residual", "attn_out", "mlp_out")) {
      from_mem <- as.matrix(ref, layer = layer, component = comp)
      from_disk <- as.matrix(sp, layer = layer, component = comp)
      expect_identical(
        from_disk, from_mem,
        info = sprintf("layer %d component %s", layer, comp)
      )
    }
  }

  # The slice has the expected shape: 8 (prompt, position) rows x 32 neurons.
  x <- as.matrix(sp, layer = 1, component = "residual")
  expect_identical(dim(x), c(8L, 32L))
  expect_match(rownames(x)[1], "^[0-9]+\\.[0-9]+$")
})

test_that("a materialized trace fits K x its f32-activation bytes (D-017 pins the factor)", {
  # ACCEPTANCE (D-017): the trace budget is measured on the peak resident cost of the
  # materialized data.frame the caller receives, estimated as
  # TRACE_MATERIALIZED_EXPANSION x the f32 activation bytes. This pins that factor
  # against a real boundary-produced trace: object.size(tr) must not exceed K x its
  # f32 bytes, or the budget/spill decision would under-count the object and let an
  # "in-budget" capture OOM the session (the H-1 failure class). Each long-format row
  # is exactly one f32 activation, so the f32 basis is nrow(tr) * 4 -- the same
  # quantity the engine's estimate_capture_bytes multiplies by K. Runs in CI on the
  # synthetic model via the raw-token in-memory path (2 layers x 3 components x 8
  # positions x 32 neurons = 1536 rows -- the FULL synthetic capture; ratio ~10.4x here,
  # under the pinned 11x. Smaller sub-600-row slices amortize R's fixed overhead worse
  # and exceed 11x (harmless: < ~22 KB, never near a budget), so keep these dims large.
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)

  tr <- selftest_trace_tokens(m, synthetic_tokens(), spill = FALSE, budget = Inf)
  expect_false(isTRUE(attr(tr, "spilled")))
  f32_bytes <- as.double(nrow(tr)) * 4
  expect_lte(as.double(object.size(tr)), TRACE_MATERIALIZED_EXPANSION * f32_bytes)
})

test_that("a no_vocab in-memory trace surfaces NA token pieces (matching the spill path)", {
  # REV-3: the synthetic model is no_vocab, so a captured row carries no token
  # piece. The in-memory boundary payload must surface `token` as NA_character_
  # (not ""), agreeing with the spill path -- which writes append_null (NA) -- and
  # the documented relm_trace schema. Defect this catches: trace_payload mapping
  # None to "" so the in-memory and spilled `token` columns silently disagree.
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)

  ref <- selftest_trace_tokens(m, synthetic_tokens(), spill = FALSE, budget = Inf)
  expect_false(isTRUE(attr(ref, "spilled")))
  expect_type(ref$token, "character")
  expect_true(all(is.na(ref$token)))
})

test_that("the trace payload carries the positions_recycled signal (Rust->R wiring)", {
  # REV-2: guards the field the API-GRAMMAR section 4 recycling warning reads. The
  # payload must carry a logical `positions_recycled` (FALSE for the fixed
  # all-positions selftest spec). A rename on either side of the boundary would
  # surface here as NULL, silently disabling the warning in llm_trace() (where
  # isTRUE(NULL) is FALSE). The warning firing on TRUE is covered by the [MODEL]
  # test in test-llm-trace.R and the Rust signal tests.
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)
  payload <- relm_check(rebirth_selftest_trace_tokens_spill(
    m$ptr, as.integer(synthetic_tokens()), FALSE, Inf, "", m$path, "", "spec"
  ))
  expect_type(payload$positions_recycled, "logical")
  expect_false(payload$positions_recycled)
})

test_that("print() and summary() on a spilled trace never read the file", {
  # ACCEPTANCE: print/summary report a spilled trace from its attributes alone.
  # Proof: delete the spill file, then print/summary still succeed (they would
  # error if they touched it), while as.matrix -- which must read -- fails cleanly.
  m <- llm(synthetic_model_path())
  dir <- tempfile("relm-spill-test-")
  dir.create(dir)
  on.exit({
    close(m)
    unlink(dir, recursive = TRUE, force = TRUE)
  }, add = TRUE)

  sp <- selftest_trace_tokens(m, synthetic_tokens(), spill = TRUE, budget = 1024, spill_dir = dir)
  file.remove(attr(sp, "spill_files"))

  # print reports dims from attributes (row count, layers, components, spill path).
  out <- capture.output(res <- print(sp))
  expect_identical(res, sp)
  expect_true(any(grepl("spilled:", out)))
  expect_true(any(grepl("residual", out)))
  # 2 layers x 3 components x 8 positions x 32 neurons = 1536 activation rows.
  expect_true(any(grepl("1536", out)))

  # summary reports per-group n from attributes; mean |value| is NA (needs a load).
  s <- summary(sp)
  expect_s3_class(s, "summary.relm_trace")
  expect_identical(nrow(s), 6L) # 2 layers x 3 components
  expect_true(all(s$n == 8 * 32)) # n_positions x n_embd per group
  expect_true(all(is.na(s$mean_abs)))

  # as.matrix must read, so with the file gone it fails with a classed error.
  expect_error(
    as.matrix(sp, layer = 1, component = "residual"),
    class = "relm_error_trace"
  )
})

test_that("a spill file whose footer disagrees with the object is rejected", {
  # ACCEPTANCE (ARCHITECTURE section 6): the staleness fail-safe. A reopened file
  # whose capture-spec footer differs from the object's attributes (a file
  # overwritten by a later trace, or from another session) must raise
  # relm_error_trace, never silently return the wrong data.
  m <- llm(synthetic_model_path())
  dir <- tempfile("relm-spill-test-")
  dir.create(dir)
  on.exit({
    close(m)
    unlink(dir, recursive = TRUE, force = TRUE)
  }, add = TRUE)

  sp <- selftest_trace_tokens(m, synthetic_tokens(), spill = TRUE, budget = 1024, spill_dir = dir)
  # A valid read first (the file and object agree).
  expect_silent(as.matrix(sp, layer = 1, component = "residual"))

  # Now make the object expect a different capture spec than the file's footer.
  stale <- sp
  attr(stale, "spill_spec") <- "model=OTHER|layers=all|positions=all|components=residual"
  expect_error(
    as.matrix(stale, layer = 1, component = "residual"),
    class = "relm_error_trace"
  )
})

test_that("the spec key varies with prompts and the trace id is a nonce (M-2)", {
  # ACCEPTANCE (M-2): the staleness fail-safe must not be defeatable by a same-filter
  # trace from a later session. Two defects enabled that: the trace id was the file
  # basename (trace-<n>.arrow, counter restarts each session -> collides in a reused
  # spill_dir), and the spec key omitted the prompts (identical filters -> identical
  # key regardless of the text traced). Both are closed here.
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)

  # Same filters, different prompts -> different spec keys.
  k1 <- trace_spec_key(m, c("alpha", "beta"), NULL, "all", "residual")
  k2 <- trace_spec_key(m, c("alpha", "GAMMA"), NULL, "all", "residual")
  expect_false(identical(k1, k2))
  # The digest is deterministic, so an object's stored spec always matches the footer
  # written from the same inputs at trace time.
  expect_identical(k1, trace_spec_key(m, c("alpha", "beta"), NULL, "all", "residual"))
  # The key now carries the model size and a prompts digest.
  expect_match(k1, "size=[0-9]")
  expect_match(k1, "prompts=[0-9a-f]")

  # The trace id is a fresh nonce per call (never the per-session-counter filename),
  # so two traces -- even to the same user spill_dir -- never share an id.
  expect_false(identical(next_trace_id(), next_trace_id()))
})

test_that("a spill file with a truncated/corrupt body fails as a classed condition", {
  # SEC-MEDIUM: a readable header/schema does NOT guarantee readable record-batch
  # bodies. A spill file whose batches are truncated must raise relm_error_trace
  # (with the re-run guidance), never a raw nanoarrow error. Defect this catches:
  # the batch-read loop in read_spill_slice() running unguarded.
  m <- llm(synthetic_model_path())
  dir <- tempfile("relm-spill-test-")
  dir.create(dir)
  on.exit({
    close(m)
    unlink(dir, recursive = TRUE, force = TRUE)
  }, add = TRUE)

  sp <- selftest_trace_tokens(m, synthetic_tokens(), spill = TRUE, budget = 1024, spill_dir = dir)
  path <- attr(sp, "spill_files")
  # A valid read first (file and object agree, body intact).
  expect_silent(as.matrix(sp, layer = 1, component = "residual"))

  # Truncate the body: keep the first 40% of the stream so the schema message (at
  # the head) survives but the record-batch data is cut off. The file is tens of KB
  # of batch data, so 40% lands well past the small schema and inside the first
  # batch's body.
  size <- file.info(path)$size
  expect_gt(size, 4000) # ample headroom: 40% >> the schema message
  bytes <- readBin(path, "raw", n = size)
  writeBin(head(bytes, ceiling(length(bytes) * 0.4)), path)

  # The schema/footer still verifies (so we are exercising the body-read branch,
  # not the header/staleness branch)...
  expect_silent(verify_spill_integrity(sp, path))
  # ...but pulling the truncated batches now surfaces a classed trace error.
  expect_error(
    as.matrix(sp, layer = 1, component = "residual"),
    class = "relm_error_trace"
  )
})

test_that("a spill file with a tampered column type is rejected (schema check)", {
  # SEC-LOW: matching integrity metadata (format/trace_id/spec) is not enough -- if
  # a column's TYPE was altered on disk, the read would coerce to NA/garbage. So
  # verify_spill_integrity() also checks the on-disk schema. Defect this catches:
  # trusting the metadata strings without confirming the columns still decode.

  # spill_schema_ok() accepts the exact on-disk encoding (uint32 indices, float32
  # value, utf8 strings). These schemas need no array, so no `arrow` package.
  real_shape <- nanoarrow::na_struct(list(
    prompt_id = nanoarrow::na_uint32(), token_pos = nanoarrow::na_uint32(),
    token = nanoarrow::na_string(), layer = nanoarrow::na_uint32(),
    component = nanoarrow::na_string(), neuron = nanoarrow::na_uint32(),
    value = nanoarrow::na_float()
  ))
  expect_true(spill_schema_ok(real_shape))
  # A tampered `value` (string, not float) is rejected; so is a missing/renamed col.
  tampered_schema <- nanoarrow::na_struct(list(
    prompt_id = nanoarrow::na_uint32(), token_pos = nanoarrow::na_uint32(),
    token = nanoarrow::na_string(), layer = nanoarrow::na_uint32(),
    component = nanoarrow::na_string(), neuron = nanoarrow::na_uint32(),
    value = nanoarrow::na_string()
  ))
  expect_false(spill_schema_ok(tampered_schema))
  expect_false(spill_schema_ok(NULL))

  # End to end: a genuine Arrow-IPC file whose metadata still matches the object but
  # whose `value` column is utf8 (index columns int32 so nanoarrow needs no `arrow`).
  dir <- tempfile("relm-spill-test-")
  dir.create(dir)
  on.exit(unlink(dir, recursive = TRUE, force = TRUE), add = TRUE)
  path <- file.path(dir, "tampered.arrow")

  spec_key <- "model=/m.gguf|layers=all|positions=all|components=residual"
  file_schema <- nanoarrow::nanoarrow_schema_modify(
    nanoarrow::na_struct(list(
      prompt_id = nanoarrow::na_int32(), token_pos = nanoarrow::na_int32(),
      token = nanoarrow::na_string(), layer = nanoarrow::na_int32(),
      component = nanoarrow::na_string(), neuron = nanoarrow::na_int32(),
      value = nanoarrow::na_string()
    )),
    list(metadata = list(
      "relm.spill_format" = "1", "relm.trace_id" = "t",
      "relm.model" = "/m.gguf", "relm.spec" = spec_key
    ))
  )
  df <- data.frame(
    prompt_id = 0L, token_pos = 0L, token = "x", layer = 0L,
    component = "residual", neuron = 0L, value = "NOT_A_NUMBER",
    stringsAsFactors = FALSE
  )
  nanoarrow::write_nanoarrow(nanoarrow::as_nanoarrow_array(df, schema = file_schema), path)

  # The object's integrity strings MATCH the file's metadata, so the schema type
  # check -- not the format / trace-id / spec check -- is what must fire.
  x <- structure(
    data.frame(
      prompt_id = integer(0), token_pos = integer(0), token = character(0),
      layer = integer(0), component = character(0), neuron = integer(0),
      value = double(0), stringsAsFactors = FALSE
    ),
    class = c("relm_trace", "data.frame"),
    spilled = TRUE, spill_files = path,
    spill_trace_id = "t", spill_spec = spec_key
  )
  expect_error(verify_spill_integrity(x, path), class = "relm_error_trace")
  expect_error(
    as.matrix(x, layer = 1, component = "residual"),
    class = "relm_error_trace"
  )
})
