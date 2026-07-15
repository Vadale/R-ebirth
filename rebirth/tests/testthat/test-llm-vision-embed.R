# WP-V3 (D-026.5): llm_embed(images=) — the T2 multimodal-embedding surface.
# Split from test-llm-vision.R at the Phase 11 simplifier pass (file
# organization only; the tests are unchanged).
#
# Where each test runs (hard rule 8e):
#   * [CI]    — model-free, per-commit, in the R-CMD-check job on every
#               platform: the shared images pairing/marker/projector contract
#               on the in-repo synthetic model.
#   * [MODEL] — env-gated on RELM_TEST_MODEL_VLM + RELM_TEST_MMPROJ_VLM (or
#               the registry aliases resolved from the default llm_download()
#               cache); runs on the founder's Mac (Metal) and in the nightly
#               vision workflow, never per-commit.
#
# Shared helpers (synthetic_model_path, vision_fixture, vlm_model_path,
# vlm_mmproj_path) live in helper-llm.R.

# --- [CI] the machine gate that decides whether the T2 pin runs ---------------

# These run per-commit, model-free, and they are the reason the pin below is
# trustworthy: the pin itself only executes on one machine in the world, so the
# mechanism deciding that has to be checked somewhere that runs everywhere.
# Rule 8d: the key is derived from the machine, never asserted by an operator.

test_that("the machine fingerprint is derived, well-formed, and stable", {
  fp <- machine_fingerprint()
  expect_type(fp, "character")
  expect_length(fp, 1L)
  expect_match(fp, "^[^|]+ \\| [^|]+ \\| .+$")
  # Deriving it twice on one machine must agree, or every pin gated on it would
  # flap.
  expect_identical(fp, machine_fingerprint())
})

test_that("on macOS the fingerprint names the CPU, not just the platform", {
  # Scoped to Darwin deliberately. `unknown-cpu` is CORRECT gate behavior where
  # the CPU is unreadable -- it matches no committed sidecar, so the pin skips,
  # which is the safe answer. Asserting against it unconditionally would fail on
  # platforms this project ships to and where the derivation legitimately cannot
  # name a CPU. Here it IS load-bearing: macOS is where the pin actually runs,
  # and a PATH-stripped session (R.app, launchd) that lost `sysctl` would
  # silently stop running it. That must be loud.
  skip_if_not(identical(Sys.info()[["sysname"]], "Darwin"), "macOS-only assertion")
  expect_false(grepl("unknown-cpu", machine_fingerprint(), fixed = TRUE))
})

test_that("the committed T2 sidecar names a real machine and matches its golden", {
  # A corrupt, stale, or truncated sidecar must be caught HERE -- per-commit, on
  # every platform -- and not on the one machine that would have run the pin.
  skip_if_not(
    file.exists(vision_golden_path("embed-red-square-mean.csv")),
    "vision goldens not present (repo layout only)"
  )
  # This also exercises the digest check: golden_machine() errors on a stale
  # sidecar, so a bare call passing IS the assertion that the two are in sync.
  recorded <- golden_machine("embed-red-square-mean.csv")
  expect_false(is.na(recorded))
  expect_match(recorded, "^[^|]+ \\| [^|]+ \\| .+$")
  # The sidecar is comment-led; the parse must take the value, not a "#".
  expect_false(startsWith(recorded, "#"))
  # A COMMITTED fingerprint must name a CPU. `unknown-cpu` is tolerable as a
  # live answer (it just skips) but never as a recorded key: two unrelated
  # machines would both derive it, match each other, and run a pin recorded on
  # neither -- the one accidental-match hole in this gate.
  expect_false(grepl("unknown-cpu", recorded, fixed = TRUE))
})

# A golden + sidecar on disk for the pure verify_golden_sidecar() below. No
# mocking: `local_mocked_bindings()` cannot rebind a helper-file function
# (testthat searches the namespace, its parent and globalenv -- never the testing
# env where helper-*.R is sourced), so the mocked version of these tests ABORTED
# under R CMD check on both runners and passed locally only on a polluted
# globalenv. Paths are injected instead, which is why these now run everywhere.
# Files land in tempdir(), which R removes on exit.
sidecar_pair <- function(...) {
  golden <- tempfile(fileext = ".csv")
  side <- paste0(golden, ".machine")
  writeLines(c("1.0", "2.0"), golden)
  writeLines(c(...), side)
  list(golden = golden, sidecar = side)
}

test_that("a sidecar that does not match its golden is a loud error, not a skip", {
  # The failure this whole mechanism exists to prevent, in miniature: the golden
  # gets re-recorded on a new machine and the sidecar is left behind. Without the
  # digest that is a pin gated on a machine that no longer exists -- skipping
  # everywhere, silently, forever. Self-contained on tempfiles: no repo golden,
  # so it runs in the per-commit job its [CI] header claims.
  p <- sidecar_pair("machine: Fake | test | CPU", "golden-md5: not-the-right-digest")
  expect_error(verify_golden_sidecar(p$golden, p$sidecar), "STALE SIDECAR")
})

test_that("a matching digest returns the recorded machine", {
  # The positive control: same code path, correct digest. Without it, "errors on
  # mismatch" would also be satisfied by a function that always errors.
  golden <- tempfile(fileext = ".csv")
  writeLines(c("1.0", "2.0"), golden)
  side <- paste0(golden, ".machine")
  writeLines(
    c("machine: Fake | test | CPU", paste("golden-md5:", unname(tools::md5sum(golden)))),
    side
  )
  expect_identical(verify_golden_sidecar(golden, side), "Fake | test | CPU")
})

test_that("a sidecar with no digest is refused rather than trusted", {
  p <- sidecar_pair("machine: Fake | test | CPU")
  expect_error(verify_golden_sidecar(p$golden, p$sidecar), "no golden-md5")
})

test_that("an absent sidecar reports NA rather than crashing", {
  expect_true(is.na(verify_golden_sidecar(tempfile(), tempfile())))
  expect_true(is.na(golden_machine("no-such-golden-exists.csv")))
})

test_that("the CPU is parsed from both /proc/cpuinfo shapes", {
  # Rule 8e: CI is ubuntu-24.04 (x86_64) + macos-15, so the aarch64 branch runs
  # on no CI machine. Committed fixtures drive both branches per-commit on every
  # platform, off the hardware entirely.
  x86 <- cpu_from_cpuinfo(readLines(test_path("fixtures", "cpuinfo-x86_64.txt")))
  expect_identical(x86, "AMD EPYC 7763 64-Core Processor")

  # aarch64 has no "model name" -- returning "unknown-cpu" here (the first
  # version) meant two unrelated aarch64 machines matched each other and would
  # run a pin recorded on neither.
  arm <- cpu_from_cpuinfo(readLines(test_path("fixtures", "cpuinfo-aarch64.txt")))
  expect_identical(arm, "0x41/0xd0c/8")
  expect_false(grepl("unknown", arm, fixed = TRUE))
  expect_false(identical(arm, x86))

  # Nothing recognizable -> NA, which machine_fingerprint() turns into the
  # never-matches-a-sidecar fallback.
  expect_true(is.na(cpu_from_cpuinfo(c("processor\t: 0", "BogoMIPS\t: 50.00"))))
})

# --- [CI] llm_embed(images=) — the T2 surface (WP-V3) --------------------------

test_that("llm_embed() applies the shared images pairing contract", {
  # Same normalize_images/check_prompt_markers/check_images_usable helpers as
  # llm_generate (never forked); model-free, per-commit R-CMD-check job.
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)
  img <- vision_fixture("red-square.png")

  expect_error(llm_embed(m, "hi", images = 42), class = "relm_error_argument")
  expect_error(
    llm_embed(m, "hi", images = list(NA_character_)),
    class = "relm_error_argument"
  )
  expect_error(
    llm_embed(m, c("a", "b"), images = list(img)),
    class = "relm_error_argument"
  )
  # Bare vector recycling across inputs warns, then the no-projector check
  # fires on this text-only handle (vision domain) — same order as generate.
  expect_warning(
    expect_error(
      llm_embed(m, c("a", "b"), images = img),
      class = "relm_error_image"
    ),
    "recycled across all 2 prompts"
  )
  # The reserved marker in an image-bearing input: the condition names the
  # CALLER'S argument — `x` here, not llm_generate's `prompt` (reviewer
  # finding, WP-V3 round; the helper stays shared, only the name is passed).
  cnd <- tryCatch(
    llm_embed(m, "look <__media__> here", images = img),
    condition = function(c) c
  )
  expect_s3_class(cnd, "relm_error_argument")
  expect_identical(cnd$argument, "x")
  expect_match(conditionMessage(cnd), "`x[1]`", fixed = TRUE)
})

test_that("llm_embed() images on a projector-less handle raise relm_error_image", {
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)
  cnd <- tryCatch(
    llm_embed(m, "what is this?", images = vision_fixture("red-square.png")),
    condition = function(c) c
  )
  expect_s3_class(cnd, "relm_error_image")
  expect_match(conditionMessage(cnd), "without a projector")
})

test_that("llm_embed() empty-string rules: text-only rejected, image-bearing allowed", {
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)
  img <- vision_fixture("red-square.png")
  # Text-only empty string: rejected exactly as before (pre-WP-V3 contract).
  expect_error(llm_embed(m, ""), class = "relm_error_argument")
  expect_error(
    llm_embed(m, c("ok", ""), images = list(img, character(0))),
    class = "relm_error_argument"
  )
  # An empty string WITH an image passes the argument check and proceeds to
  # the vision checks (this handle has no projector -> relm_error_image),
  # proving x = "" is embeddable when paired with an image.
  expect_error(
    llm_embed(m, "", images = img),
    class = "relm_error_image"
  )
})

test_that("llm_embed() text path is untouched by the images plumbing", {
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)
  # images = NULL and all-empty sets route through the unchanged text
  # transport: this tokenizer-less model fails with relm_error_tokenize
  # exactly like the pre-WP-V3 call (never an image/projector error).
  expect_error(llm_embed(m, "hello"), class = "relm_error_tokenize")
  expect_error(llm_embed(m, "hello", images = NULL), class = "relm_error_tokenize")
  expect_error(
    llm_embed(m, "hello", images = list(character(0))),
    class = "relm_error_tokenize"
  )
})

# --- [MODEL] llm_embed(images=) on the pinned VLM ------------------------------

test_that("[MODEL] multimodal embeddings: row contract, x = '', determinism", {
  m <- llm(vlm_model_path(), projector = vlm_mmproj_path())
  on.exit(close(m), add = TRUE)
  img <- vision_fixture("red-square.png")

  # One row per (text, image) input, hidden_size columns, rownames preserved.
  e <- llm_embed(m, c(q = "What color is the square?"), images = img)
  expect_true(is.matrix(e))
  expect_identical(dim(e), c(1L, m$hidden_size))
  expect_identical(rownames(e), "q")
  expect_true(all(is.finite(e)))
  # Normalized rows are unit vectors.
  expect_equal(sqrt(sum(e^2)), 1, tolerance = 1e-4)

  # The plan-§5 acceptance shape: x = "" with an image embeds the image alone.
  e0 <- llm_embed(m, "", images = vision_fixture("cat.png"))
  expect_identical(dim(e0), c(1L, m$hidden_size))
  expect_true(all(is.finite(e0)))

  # Mixed batch: a text-only input and an image-bearing input in one call.
  e2 <- llm_embed(m, c("plain text", "with image"), images = list(character(0), img))
  expect_identical(dim(e2), c(2L, m$hidden_size))
  # The text-only row is byte-identical to a plain llm_embed of the same text.
  expect_identical(e2[1, ], llm_embed(m, "plain text")[1, ])

  # The image conditions the embedding: same text, with vs without the image.
  t_only <- llm_embed(m, "What color is the square?")
  expect_lt(sum(e[1, ] * t_only[1, ]), 0.999)
})

test_that("[MODEL] the cat image embeds closer to 'a cat' than to 'a car'", {
  # The committed, non-cherry-picked similarity fixture (plan §5 WP-V3): the
  # deterministic cartoon cat drawn by tests/vision/make-fixtures.R, measured
  # on its FIRST run against the pinned Qwen2-VL-2B (CPU): cos(image, "a cat")
  # = 0.3368, cos(image, "a dog") = 0.3128, cos(image, "a car") = 0.2895 —
  # margin cat-over-car 0.0473. The gate asserts the ranking with a 0.01
  # floor (backend-robust), far below the observed margin.
  m <- llm(vlm_model_path(), projector = vlm_mmproj_path())
  on.exit(close(m), add = TRUE)
  e_img <- llm_embed(m, "", images = vision_fixture("cat.png"))
  e_txt <- llm_embed(m, c(cat = "a cat", car = "a car"))
  cs <- as.numeric(e_img %*% t(e_txt))
  names(cs) <- rownames(e_txt)
  expect_gt(cs[["cat"]], cs[["car"]] + 0.01)
})

test_that("[MODEL] the pooled multimodal embedding matches the committed pin", {
  # The T2 regression pin (tests/llm-golden/vision/README.md — a
  # same-implementation determinism pin, NOT an independent oracle; the
  # cross-build encoder ATOL leg is the independent one, in the cargo
  # vlm_golden suite).
  #
  # This vector is specific to the MACHINE that recorded it (the founder's M4),
  # not to its OS/arch — D-026 fourth addendum. The first real nightly measured
  # max |d| = 6.05e-3 against it on a *non-M4 arm64 runner*, 600x the tolerance,
  # while the same run's byte-exact text golden passed: identical semantics,
  # different floats. The old `Darwin && arm64` gate was therefore never the
  # right one — it named a platform where the recording machine was meant.
  # The mechanism is below the arch: ggml keeps GGML_ACCELERATE on for the macOS
  # CPU backend and dispatches on runtime CPU features, and the M4 has SME/SME2
  # where earlier Apple Silicon does not. Two arm64 machines, different
  # instructions.
  #
  # Unlike the encoder leg, this pin cannot be rebuilt on another machine: no
  # upstream reference exists for a pooled multimodal embedding at b9726 (second
  # addendum), so there is nothing to regenerate from. It stays an exact pin on
  # its recording machine. The nightly's T2 coverage is instead the cat-vs-car
  # SEMANTIC gate above, which holds on any machine and needs no tolerance.
  #
  # The gate is DERIVED from this machine (hard rule 8d), not asserted by an
  # operator: the previous `RELM_VISION_RECORDING_MACHINE=1` was an echoed
  # assertion, and it had rule 8d's predicted failure mode — the pin ran nowhere,
  # because nobody remembers an env var. It now runs here with no ceremony.
  golden <- vision_golden_path("embed-red-square-mean.csv")
  skip_if_not(file.exists(golden), "embedding pin not present (repo layout only)")
  skip_if_not_recording_machine("embed-red-square-mean.csv")
  m <- llm(vlm_model_path(), projector = vlm_mmproj_path(), backend = "cpu")
  on.exit(close(m), add = TRUE)
  e <- llm_embed(m, "What color is the square?",
    images = vision_fixture("red-square.png"),
    pooling = "mean", normalize = TRUE
  )
  ref <- as.numeric(readLines(golden))
  expect_identical(length(ref), ncol(e))
  expect_lt(max(abs(e[1, ] - ref)), 1e-5)
})

test_that("[MODEL] multimodal embed over the context window is a classed error", {
  # The rule-8a artifact for this path: the combined text+image token count is
  # checked pre-flight against context_length (every text chunk then fits one
  # batch by construction, n_batch = n_ubatch = n_ctx in the D-011 context) —
  # the over-limit case must be the classed reject, never an engine abort.
  m <- llm(vlm_model_path(), projector = vlm_mmproj_path(), context_length = 256)
  on.exit(close(m), add = TRUE)
  long_text <- paste(rep("far too many words for this tiny window", 100), collapse = " ")
  expect_error(
    llm_embed(m, long_text, images = vision_fixture("red-square.png")),
    class = "relm_error_embed"
  )
})

test_that("[MODEL] a multimodal prompt with a text portion over n_batch decodes (rule 8a)", {
  # Hard rule 8a for the new decode path: the default n_batch is 2048, so a
  # ~2300-token text portion plus the image chunk MUST be split internally by
  # mtmd_helper_eval_chunks — a single oversized llama_decode would abort the
  # process (GGML_ASSERT(n_tokens_all <= n_batch)). Reaching any result at all
  # proves the chunking; the assertion checks it generated text.
  m <- llm(vlm_model_path(), projector = vlm_mmproj_path(), context_length = 4096)
  on.exit(close(m), add = TRUE)
  long_text <- paste(rep("count the words in this sentence and", 330), collapse = " ")
  answer <- llm_generate(
    m, paste(long_text, "then say what color the square is."),
    images = vision_fixture("red-square.png"),
    max_tokens = 4, temperature = 0
  )
  expect_type(answer, "character")
  expect_length(answer, 1L)
})

test_that("[MODEL] combined text+image tokens over the window raise context overflow", {
  m <- llm(vlm_model_path(), projector = vlm_mmproj_path(), context_length = 512)
  on.exit(close(m), add = TRUE)
  long_text <- paste(rep("far too many words for this tiny window", 200), collapse = " ")
  cnd <- tryCatch(
    llm_generate(
      m, long_text,
      images = vision_fixture("red-square.png"),
      max_tokens = 4, temperature = 0
    ),
    condition = function(c) c
  )
  expect_s3_class(cnd, "relm_error_context_overflow")
  # The grammar: the message states by how much.
  expect_match(conditionMessage(cnd), "too many")
})
