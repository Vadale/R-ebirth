# WP-V2 (D-026): llm(projector=) + llm_generate(images=) — T1 vision.
#
# Where each test runs (hard rule 8e):
#   * [CI]    — model-free, per-commit, in the R-CMD-check job on every
#               platform: the image pre-decode gate through the real classed
#               plumbing (rebirth_selftest_validate_image, no model, no
#               decode), the `images` pairing/recycling contract on the
#               in-repo synthetic model, and print/handle-slot logic.
#   * [MODEL] — env-gated on RELM_TEST_MODEL_VLM + RELM_TEST_MMPROJ_VLM
#               (dev pin: Qwen2-VL-2B-Instruct Q4_K_M + mmproj-f16 from
#               ggml-org/Qwen2-VL-2B-Instruct-GGUF, Apache-2.0); runs on the
#               founder's Mac (Metal) and in the future nightly VLM job
#               (WP-V4), never per-commit.
#
# SHA256 of the dev artifacts as observed on download (2026-07-14, from
# https://huggingface.co/ggml-org/Qwen2-VL-2B-Instruct-GGUF, branch main;
# recorded per the WP-V2 brief — the fail-closed registry pin is WP-V4):
#   Qwen2-VL-2B-Instruct-Q4_K_M.gguf
#     5745685d2e607a82a0696c1118e56a2a1ae0901da450fd9cd4f161c6b62867d7
#   mmproj-Qwen2-VL-2B-Instruct-f16.gguf
#     ecb20cabcdd8dbc277de06bd6eb980aeb2adfaaba9f199a434e328d205675d03

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

vision_fixture <- function(name) {
  p <- testthat::test_path("fixtures", "vision", name)
  skip_if_not(file.exists(p), sprintf("vision fixture '%s' is missing", name))
  p
}

# --- [CI] the pre-decode gate: allow-list --------------------------------------

test_that("the image gate accepts exactly JPEG, PNG, and BMP", {
  for (case in list(
    c("red-square.png", "png"),
    c("red-square.jpg", "jpeg"),
    c("red-square.bmp", "bmp")
  )) {
    payload <- relm:::rebirth_selftest_validate_image(
      vision_fixture(case[[1]]), 64 * 1024^2
    )
    expect_true(isTRUE(payload$ok), info = case[[1]])
    expect_identical(payload$format, case[[2]])
  }
})

test_that("the image gate rejects audio magics, GIF, and garbage at the magic stage", {
  # The audio-gate mutation proof (audit req 4): every magic miniaudio's loose
  # sniff would route to the audio decoder — RIFF/WAVE, MP3 frame sync, the
  # loosest 0xFF/0xE0 MPEG sync, ID3, fLaC — plus a REAL GIF (dropped from the
  # allow-list) and plain garbage must all raise the classed image error whose
  # message names the MAGIC stage and the three allowed formats: proof the
  # rejection happens on the allow-list, before the header probe or any decode.
  for (name in c(
    "wav-magic.bin", "mp3-sync.bin", "mpeg-loose-sync.bin",
    "id3-magic.bin", "flac-magic.bin", "gif-1x1.gif", "garbage.bin"
  )) {
    path <- vision_fixture(name)
    cnd <- tryCatch(
      relm_check(relm:::rebirth_selftest_validate_image(path, 64 * 1024^2)),
      condition = function(c) c
    )
    expect_s3_class(cnd, "relm_error_image")
    expect_match(
      conditionMessage(cnd), "magic bytes match none of the allowed formats",
      info = name
    )
    expect_match(conditionMessage(cnd), "JPEG, PNG, BMP", info = name)
    expect_identical(cnd$path, path)
  }
})

test_that("the image gate rejects a truncated file of each allowed format", {
  for (name in c("truncated.png", "truncated.jpg", "truncated.bmp")) {
    cnd <- tryCatch(
      relm_check(relm:::rebirth_selftest_validate_image(
        vision_fixture(name), 64 * 1024^2
      )),
      condition = function(c) c
    )
    expect_s3_class(cnd, "relm_error_image")
    expect_match(
      conditionMessage(cnd), "header could not be parsed",
      info = name
    )
  }
})

test_that("the image gate rejects over-cap dimensions before any decode", {
  # overdims.png CLAIMS 100000 x 4 in a valid header: over the per-dimension
  # cap. overpixels.png claims 16000 x 16000 (256 Mpx, ~768 MB decoded):
  # each side within the dimension cap, so it is provably the PIXEL cap that
  # rejects. Neither is ever decoded.
  cnd <- tryCatch(
    relm_check(relm:::rebirth_selftest_validate_image(
      vision_fixture("overdims.png"), 64 * 1024^2
    )),
    condition = function(c) c
  )
  expect_s3_class(cnd, "relm_error_image")
  expect_match(conditionMessage(cnd), "maximum supported dimension")

  cnd <- tryCatch(
    relm_check(relm:::rebirth_selftest_validate_image(
      vision_fixture("overpixels.png"), 64 * 1024^2
    )),
    condition = function(c) c
  )
  expect_s3_class(cnd, "relm_error_image")
  expect_match(conditionMessage(cnd), "pixel cap")
})

test_that("the image gate enforces the byte cap and names the override", {
  cnd <- tryCatch(
    relm_check(relm:::rebirth_selftest_validate_image(
      vision_fixture("red-square.png"), 100
    )),
    condition = function(c) c
  )
  expect_s3_class(cnd, "relm_error_image")
  expect_match(conditionMessage(cnd), "byte cap")
  expect_match(conditionMessage(cnd), "relm.image_max_bytes", fixed = TRUE)
})

test_that("the image gate accepts the degenerate-but-legal dimension fixtures", {
  # 1x1 and the two 16384-long thin strips are WITHIN the caps: the gate must
  # pass them (the model-side behavior — classed error or success, never an
  # abort — is the [MODEL] test below, audit req 4).
  for (name in c("tiny-1x1.png", "thin-16384x1.png", "tall-1x16384.png")) {
    payload <- relm:::rebirth_selftest_validate_image(
      vision_fixture(name), 64 * 1024^2
    )
    expect_true(isTRUE(payload$ok), info = name)
  }
})

test_that("a missing image file is a classed image error with the path field", {
  cnd <- tryCatch(
    relm_check(relm:::rebirth_selftest_validate_image(
      "/nonexistent/nope.png", 64 * 1024^2
    )),
    condition = function(c) c
  )
  expect_s3_class(cnd, "relm_error_image")
  expect_identical(cnd$path, "/nonexistent/nope.png")
})

# --- [CI] the images argument contract (synthetic model, no projector) --------

test_that("llm_generate() validates the images argument type and pairing", {
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)
  img <- vision_fixture("red-square.png")

  # Wrong type.
  expect_error(llm_generate(m, "hi", images = 42), class = "relm_error_argument")
  # NA in a bare vector / a list element.
  expect_error(
    llm_generate(m, "hi", images = NA_character_),
    class = "relm_error_argument"
  )
  expect_error(
    llm_generate(m, "hi", images = list(NA_character_)),
    class = "relm_error_argument"
  )
  # A non-character list element.
  expect_error(
    llm_generate(m, "hi", images = list(1L)),
    class = "relm_error_argument"
  )
  # A list of the wrong length is NOT recycled (only the bare-vector form is).
  expect_error(
    llm_generate(m, c("a", "b"), images = list(img)),
    class = "relm_error_argument"
  )
  expect_error(
    llm_generate(m, "a", images = list(img, img)),
    class = "relm_error_argument"
  )
  # The offending argument is named in the structured field.
  cnd <- tryCatch(
    llm_generate(m, c("a", "b"), images = list(img)),
    condition = function(c) c
  )
  expect_identical(cnd$argument, "images")
})

test_that("a bare images vector recycles across prompts with a warning", {
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)
  img <- vision_fixture("red-square.png")
  # The recycling warning fires during normalization; the call then fails on
  # the no-projector check (this synthetic handle is text-only) — proving the
  # order: pairing first (argument domain), vision capability second (image
  # domain).
  expect_warning(
    expect_error(
      llm_generate(m, c("a", "b"), images = img),
      class = "relm_error_image"
    ),
    "recycled across all 2 prompts"
  )
})

test_that("images on a handle loaded without a projector raise relm_error_image", {
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)
  cnd <- tryCatch(
    llm_generate(m, "what is this?", images = vision_fixture("red-square.png")),
    condition = function(c) c
  )
  expect_s3_class(cnd, "relm_error_image")
  expect_match(conditionMessage(cnd), "without a projector")
  expect_match(conditionMessage(cnd), "projector = ", fixed = TRUE)
})

test_that("an image-bearing prompt containing the media marker is rejected pre-boundary", {
  # Reviewer finding (WP-V2 fix round): a literal "<__media__>" in a prompt
  # that carries images would corrupt the marker/bitmap pairing inside
  # mtmd_tokenize and used to surface as a misleading relm_error_internal.
  # The R layer now rejects it BEFORE the boundary as relm_error_argument
  # naming `prompt` — model-free, per-commit CI (the synthetic handle never
  # reaches the vision checks because the marker gate fires first).
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)
  img <- vision_fixture("red-square.png")
  cnd <- tryCatch(
    llm_generate(m, "look: <__media__> what is it?", images = img),
    condition = function(c) c
  )
  expect_s3_class(cnd, "relm_error_argument")
  expect_identical(cnd$argument, "prompt")
  expect_match(conditionMessage(cnd), "<__media__>", fixed = TRUE)
  expect_match(conditionMessage(cnd), "reserved")

  # Scoped to image-bearing prompts only: with NO images the same text is
  # ordinary content and takes the text path unchanged (this tokenizer-less
  # model then fails with relm_error_tokenize, exactly like any text call).
  expect_error(
    llm_generate(m, "look: <__media__> what is it?", chat = FALSE, max_tokens = 4),
    class = "relm_error_tokenize"
  )
  # And a marker in a prompt whose OWN image set is empty is allowed too.
  expect_error(
    llm_generate(m, "plain <__media__> text",
      chat = FALSE, max_tokens = 4,
      images = list(character(0))
    ),
    class = "relm_error_tokenize"
  )
})

test_that("the R media-marker literal twin-pins the engine's marker", {
  # Hard rule 8f: the marker literal exists in R (images.R) and in the engine.
  # The chain: this test pins the R constant to "<__media__>"; the ffi.rs ABI
  # test (per-commit cargo test) pins mtmd_default_marker() to the SAME
  # literal. A vendor-bump that changes the engine marker fails the Rust leg
  # loudly, prompting both to move together. [CI] per-commit, model-free.
  expect_identical(relm:::relm_media_marker, "<__media__>")
})

test_that("character(0) image sets mean no images and need no projector", {
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)
  # All-empty image sets are a text-only call: it must proceed past the vision
  # checks and fail exactly like the text path does on this tokenizer-less
  # model (relm_error_tokenize), NOT with an image error.
  expect_error(
    llm_generate(m, "hello", max_tokens = 4, chat = FALSE, images = list(character(0))),
    class = "relm_error_tokenize"
  )
})

test_that("images = NULL leaves the text path byte-identical (same classed error)", {
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)
  expect_error(
    llm_generate(m, "hello", max_tokens = 4, chat = FALSE, images = NULL),
    class = "relm_error_tokenize"
  )
})

test_that("a broken relm.image_max_bytes option is a classed argument error", {
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)
  old <- options(relm.image_max_bytes = -1)
  on.exit(options(old), add = TRUE)
  # The option is consulted only when images are present; with a broken value
  # the call is rejected before any native work.
  expect_error(
    llm_generate(m, "hi", images = vision_fixture("red-square.png")),
    class = "relm_error_argument"
  )
})

# --- [CI] projector argument validation + handle slots -------------------------

test_that("llm() validates the projector argument", {
  # Wrong type: an argument error.
  expect_error(
    llm(synthetic_model_path(), projector = 42),
    class = "relm_error_argument"
  )
  expect_error(
    llm(synthetic_model_path(), projector = c("a", "b")),
    class = "relm_error_argument"
  )
  expect_error(
    llm(synthetic_model_path(), projector = ""),
    class = "relm_error_argument"
  )
  # A path that does not exist: the vision-domain classed error, with the path.
  cnd <- tryCatch(
    llm(synthetic_model_path(), projector = "/nonexistent/mmproj.gguf"),
    condition = function(c) c
  )
  expect_s3_class(cnd, "relm_error_image")
  expect_identical(cnd$path, "/nonexistent/mmproj.gguf")
})

test_that("a non-mmproj file as projector is a classed image error, not a crash", {
  # The synthetic text GGUF is a valid model but NOT an mmproj: the engine's
  # projector load must reject it as relm_error_image (clip refuses the file),
  # never abort the session. Runs per-commit: both files are in-repo.
  cnd <- tryCatch(
    llm(synthetic_model_path(), projector = synthetic_model_path()),
    condition = function(c) c
  )
  expect_s3_class(cnd, "relm_error_image")
  expect_match(conditionMessage(cnd), "projector")
})

test_that("a text-only handle has NULL projector and vision FALSE", {
  m <- llm(synthetic_model_path())
  on.exit(close(m), add = TRUE)
  expect_null(m$projector)
  expect_false(m$vision)
  expect_no_match(paste(capture.output(print(m)), collapse = "\n"), "projector:")
})

test_that("print.llm shows the projector on a vision handle", {
  m <- stub_llm(projector = "/models/mmproj-Qwen2-VL-2B-Instruct-f16.gguf")
  out <- paste(capture.output(print(m)), collapse = "\n")
  expect_match(out, "projector:")
  expect_match(out, "mmproj-Qwen2-VL-2B-Instruct-f16.gguf", fixed = TRUE)
  expect_true(m$vision)
})

test_that("the committed fixture equals the canonical repo image byte-for-byte", {
  # Guards the two copies (tests/vision/red-square.png = the golden/demo
  # image; the packaged fixture) against silent drift. Runs in the repo layout
  # only (the installed package has no repo root) — per-commit CI checks out
  # the full repo, so it runs there.
  fixture <- vision_fixture("red-square.png")
  canonical <- file.path(
    testthat::test_path(), "..", "..", "..", "tests", "vision", "red-square.png"
  )
  skip_if_not(file.exists(canonical), "repo-root canonical image not present")
  expect_identical(
    readBin(fixture, "raw", n = file.size(fixture) + 10),
    readBin(canonical, "raw", n = file.size(canonical) + 10)
  )
})

# --- [MODEL] the pinned VLM: load, answer, mismatch, degenerate dims -----------

test_that("[MODEL] llm(projector=) loads a VLM and the handle reflects it", {
  m <- llm(vlm_model_path(), projector = vlm_mmproj_path())
  on.exit(close(m), add = TRUE)
  expect_true(m$vision)
  expect_identical(m$projector, vlm_mmproj_path())
  out <- paste(capture.output(print(m)), collapse = "\n")
  expect_match(out, "projector:")
})

test_that("[MODEL] the VLM answers a factual question about the committed image", {
  m <- llm(vlm_model_path(), projector = vlm_mmproj_path())
  on.exit(close(m), add = TRUE)
  answer <- llm_generate(
    m, "What color is the square?",
    images = vision_fixture("red-square.png"),
    max_tokens = 16, temperature = 0
  )
  expect_type(answer, "character")
  expect_length(answer, 1L)
  expect_match(answer[[1]], "red", ignore.case = TRUE)
})

test_that("[MODEL] a mismatched mmproj names both embedding sizes", {
  # The Qwen2-VL-2B mmproj produces width-1536 embeddings; the Qwen2.5-0.5B
  # text model expects width 896 — the engine's own check refuses the pair and
  # the condition carries both sizes (reject-not-clamp, hard rule 8b).
  qwen <- qwen_model_path()
  mmproj <- vlm_mmproj_path()
  cnd <- tryCatch(
    llm(qwen, projector = mmproj),
    condition = function(c) c
  )
  expect_s3_class(cnd, "relm_error_image")
  expect_true(is.numeric(cnd$expected) || is.integer(cnd$expected))
  expect_true(is.numeric(cnd$actual) || is.integer(cnd$actual))
  expect_false(identical(cnd$expected, cnd$actual))
  expect_match(conditionMessage(cnd), as.character(cnd$expected))
  expect_match(conditionMessage(cnd), as.character(cnd$actual))
})

test_that("[MODEL] an mmproj passed as the model is a classed error, not a crash", {
  expect_error(llm(vlm_mmproj_path()), class = "relm_error")
})

test_that("[MODEL] a text GGUF passed as the projector is a classed image error", {
  # Resolve the paths BEFORE the tryCatch: the skip conditions the helpers
  # raise must not be swallowed by the condition handler.
  vlm <- vlm_model_path()
  qwen <- qwen_model_path()
  cnd <- tryCatch(
    llm(vlm, projector = qwen),
    condition = function(c) c
  )
  expect_s3_class(cnd, "relm_error_image")
})

test_that("[MODEL] degenerate-but-legal dimensions never abort (audit req 4)", {
  m <- llm(vlm_model_path(), projector = vlm_mmproj_path())
  on.exit(close(m), add = TRUE)
  for (name in c("tiny-1x1.png", "thin-16384x1.png", "tall-1x16384.png")) {
    # Contract: classed condition OR a successful generation — never a
    # process-killing abort. Reaching expect_true at all proves no abort.
    result <- tryCatch(
      llm_generate(
        m, "Describe this.",
        images = vision_fixture(name),
        max_tokens = 4, temperature = 0
      ),
      relm_error = function(c) c
    )
    expect_true(
      is.character(result) || inherits(result, "relm_error"),
      info = name
    )
  }
})

test_that("[MODEL] an intervened handle derived from a vision handle keeps images working", {
  m <- llm(vlm_model_path(), projector = vlm_mmproj_path())
  on.exit(close(m), add = TRUE)
  m2 <- llm_steer(m, layer = 12, direction = rep(0.0001, m$hidden_size), coef = 1)
  on.exit(close(m2), add = TRUE)
  # The R slots mirror the engine fact (the vision context lives on the shared
  # model), and generation with an image actually works on the derived handle.
  expect_true(m2$vision)
  expect_identical(m2$projector, m$projector)
  answer <- llm_generate(
    m2, "What color is the square?",
    images = vision_fixture("red-square.png"),
    max_tokens = 8, temperature = 0
  )
  expect_type(answer, "character")
})

test_that("[MODEL] the CPU greedy continuation matches the unpatched upstream reference", {
  # The harness-B vision golden (same-implementation leg, D-026 point 6):
  # reference = the UNPATCHED upstream llama-mtmd-cli at b9726, CPU-only,
  # greedy on the committed red-square image (tests/llm-golden/vision/ has the
  # exact reproduction command + tooling). The engine runs on the CPU backend
  # for comparability with the CPU-only reference build; greedy on identical
  # CPU code makes byte-exact text the observable equivalent of a
  # token-for-token match (the CLI does not expose token ids). [MODEL]-gated,
  # repo layout only (the golden lives at the repo root, outside the package);
  # nightly workflow wiring is WP-V4 — never per-commit (no synthetic vision
  # model exists).
  golden <- file.path(
    testthat::test_path(), "..", "..", "..",
    "tests", "llm-golden", "vision", "goldens", "greedy-red-square.txt"
  )
  skip_if_not(file.exists(golden), "vision golden not present (repo layout only)")
  m <- llm(vlm_model_path(), projector = vlm_mmproj_path(), backend = "cpu")
  on.exit(close(m), add = TRUE)
  ans <- llm_generate(
    m, "What color is the square?",
    images = vision_fixture("red-square.png"),
    max_tokens = 32, temperature = 0
  )
  ref <- readChar(golden, file.size(golden), useBytes = TRUE)
  expect_identical(ans[[1]], ref)
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
  # cross-build ATOL leg is the binding WP-V4 item). Recorded on macOS arm64,
  # CPU backend; atol 1e-5 covers run-to-run identity on the recording
  # platform. [MODEL] + repo-layout gated; nightly wiring is WP-V4.
  golden <- file.path(
    testthat::test_path(), "..", "..", "..",
    "tests", "llm-golden", "vision", "goldens", "embed-red-square-mean.csv"
  )
  skip_if_not(file.exists(golden), "embedding pin not present (repo layout only)")
  skip_if_not(
    Sys.info()[["sysname"]] == "Darwin" &&
      R.version[["arch"]] %in% c("aarch64", "arm64"),
    "the embedding pin is recorded on macOS arm64 (CPU)"
  )
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
