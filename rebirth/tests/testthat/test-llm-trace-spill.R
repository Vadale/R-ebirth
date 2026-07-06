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
  spec_key <- trace_spec_key(m, NULL, "all", components)
  spill_path <- if (isTRUE(spill)) next_spill_path(spill_dir) else ""
  trace_id <- if (nzchar(spill_path)) basename(spill_path) else ""
  payload <- rebirth_check(rebirth_selftest_trace_tokens_spill(
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
  dir <- tempfile("rebirth-spill-test-")
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

test_that("a no_vocab in-memory trace surfaces NA token pieces (matching the spill path)", {
  # REV-3: the synthetic model is no_vocab, so a captured row carries no token
  # piece. The in-memory boundary payload must surface `token` as NA_character_
  # (not ""), agreeing with the spill path -- which writes append_null (NA) -- and
  # the documented rebirth_trace schema. Defect this catches: trace_payload mapping
  # None to "" so the in-memory and spilled `token` columns silently disagree.
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)

  ref <- selftest_trace_tokens(m, synthetic_tokens(), spill = FALSE, budget = Inf)
  expect_false(isTRUE(attr(ref, "spilled")))
  expect_type(ref$token, "character")
  expect_true(all(is.na(ref$token)))
})

test_that("print() and summary() on a spilled trace never read the file", {
  # ACCEPTANCE: print/summary report a spilled trace from its attributes alone.
  # Proof: delete the spill file, then print/summary still succeed (they would
  # error if they touched it), while as.matrix -- which must read -- fails cleanly.
  m <- llm(synthetic_model_path())
  dir <- tempfile("rebirth-spill-test-")
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
  expect_s3_class(s, "summary.rebirth_trace")
  expect_identical(nrow(s), 6L) # 2 layers x 3 components
  expect_true(all(s$n == 8 * 32)) # n_positions x n_embd per group
  expect_true(all(is.na(s$mean_abs)))

  # as.matrix must read, so with the file gone it fails with a classed error.
  expect_error(
    as.matrix(sp, layer = 1, component = "residual"),
    class = "rebirth_error_trace"
  )
})

test_that("a spill file whose footer disagrees with the object is rejected", {
  # ACCEPTANCE (ARCHITECTURE section 6): the staleness fail-safe. A reopened file
  # whose capture-spec footer differs from the object's attributes (a file
  # overwritten by a later trace, or from another session) must raise
  # rebirth_error_trace, never silently return the wrong data.
  m <- llm(synthetic_model_path())
  dir <- tempfile("rebirth-spill-test-")
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
    class = "rebirth_error_trace"
  )
})

test_that("a spill file with a truncated/corrupt body fails as a classed condition", {
  # SEC-MEDIUM: a readable header/schema does NOT guarantee readable record-batch
  # bodies. A spill file whose batches are truncated must raise rebirth_error_trace
  # (with the re-run guidance), never a raw nanoarrow error. Defect this catches:
  # the batch-read loop in read_spill_slice() running unguarded.
  m <- llm(synthetic_model_path())
  dir <- tempfile("rebirth-spill-test-")
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
    class = "rebirth_error_trace"
  )
})
