# WP5 acceptance fixture 1 of 2: STEERING MEANINGFULLY SHIFTS VALENCE.
# (ROADMAP section 5 / docs/wp5-intervention-plan.md section 7.2, Fable-5 addendum #13.)
#
# The exact numerical effect of a steer and its bit-for-bit reversibility are proven
# in Rust against the numpy oracle (tests/synthetic_intervene.rs). This fixture
# proves the SEMANTIC claim the numerical gate cannot: steering along a committed
# valence direction shifts the *meaning* of free-generated text -- positive with a
# positive coefficient, negative with a negative one -- on held-out neutral prompts.
#
# The synthetic in-repo GGUF is no_vocab (no text generation), so this fixture is
# [MODEL]-gated on RELM_TEST_MODEL_QWEN (Qwen2.5-0.5B-Instruct Q8_0). It SKIPS
# cleanly in CI and runs on the founder's Mac / nightly (plan section 10). Greedy
# decoding (temperature = 0) is deterministic, so the run is reproducible.
#
# ADVERSARIAL DESIGN -- this fixture must FAIL on a no-op intervention. Three guards
# below catch a spurious pass (see the [MODEL] test): coef = 0 must not move the
# output at all; a SHUFFLED direction (same norm, permuted across neurons -- the
# valence structure destroyed) must not reproduce the positive shift; and the
# original handle must be byte-unchanged after steering. If steering "did something"
# only because deriving a handle perturbs generation, or because any vector of that
# magnitude nudges word statistics, these guards fail.
#
# Artifacts (committed, under fixtures/):
#   * valence-lexicon.csv        -- an ORIGINAL sentiment word list (no AFINN/3rd-party).
#   * valence-direction.csv      -- the steering direction, a MODEL-DERIVED golden
#                                   pinned by SHA256, emitted by make-valence-direction.R.
#   * make-valence-direction.R   -- the provenance script (diff-in-means on base Qwen).

# The pinned SHA256 of valence-direction.csv (emitted by make-valence-direction.R).
# Regenerating the artifact updates this (golden discipline / the golden-update skill).
DIRECTION_SHA256 <- "b81deee797a69f8bfcb7e053d9d5bbfdb6bd2a438ef5d7bbd75aa4a96eb37cac"

# The direction was derived at, and is steered at, this 1-based API layer (mid-late
# of Qwen2.5-0.5B's 24 blocks), with this coefficient -- both chosen by a documented
# layer x coef sweep (2026-07-06) as the cleanest, most robust valence-shift site.
# Kept in lock-step with make-valence-direction.R's DIRECTION_LAYER.
VALENCE_LAYER <- 18L
VALENCE_COEF <- 10

qwen_model_path <- function() {
  p <- path.expand(Sys.getenv("RELM_TEST_MODEL_QWEN"))
  skip_if_not(
    nzchar(p) && file.exists(p),
    "RELM_TEST_MODEL_QWEN is not set to an existing GGUF file"
  )
  p
}

valence_fixture_path <- function(name) {
  p <- testthat::test_path("fixtures", name)
  skip_if_not(file.exists(p), paste0(name, " fixture is missing"))
  p
}

# The lexicon as two character vectors (positive / negative words).
read_valence_lexicon <- function() {
  lex <- utils::read.csv(
    valence_fixture_path("valence-lexicon.csv"),
    comment.char = "#", stringsAsFactors = FALSE
  )
  list(
    positive = lex$word[lex$polarity == "positive"],
    negative = lex$word[lex$polarity == "negative"]
  )
}

# The committed steering direction as a plain numeric vector.
read_valence_direction <- function() {
  d <- utils::read.csv(
    valence_fixture_path("valence-direction.csv"),
    comment.char = "#", stringsAsFactors = FALSE
  )
  d$value
}

# Valence of a string: (#positive - #negative) lexicon hits per word. Whole-word,
# case-insensitive; normalised by length so longer outputs are not over-weighted. A
# RELATIVE proxy -- the fixture asserts shifts, never an absolute sentiment value.
valence_score <- function(text, lexicon) {
  words <- tolower(unlist(strsplit(text, "[^A-Za-z]+")))
  words <- words[nzchar(words)]
  if (!length(words)) return(0)
  (sum(words %in% lexicon$positive) - sum(words %in% lexicon$negative)) / length(words)
}

# Held-out NEUTRAL prompts (committed with this fixture): everyday, low-affect asks,
# none seeded with sentiment words -- so any valence shift comes from the steering,
# not the prompt. Deliberately disjoint from make-valence-direction.R's contrast set.
VALENCE_NEUTRAL_PROMPTS <- c(
  "Tell me about the weather today.",
  "Describe a typical morning in a city.",
  "Write a sentence about a train station.",
  "Explain what happens at a market.",
  "Describe the room you are in.",
  "Tell me about a walk in the park.",
  "Write about a cup of coffee.",
  "Describe a street at night.",
  "Tell me about going to the library.",
  "Describe a bus ride across town."
)

# --- fixture integrity (no model; runs in CI) -------------------------------

# Guards the committed artifacts so a corrupted / mis-edited fixture is caught in CI
# (no model needed), before the [MODEL] test would silently score the wrong thing.
test_that("the valence lexicon is well-formed and two-sided", {
  lex <- read_valence_lexicon()
  # Defect caught: an empty polarity (scoring collapses to one-sided) or dup/NA words.
  expect_gte(length(lex$positive), 10L)
  expect_gte(length(lex$negative), 10L)
  all_words <- c(lex$positive, lex$negative)
  expect_false(anyNA(all_words))
  expect_true(all(nzchar(all_words)))
  expect_identical(anyDuplicated(all_words), 0L) # no word is both/ repeated
  expect_true(all(all_words == tolower(all_words))) # matched lowercase
})

test_that("the committed valence direction is well-formed and matches its SHA256", {
  # Defect caught: a hand-edited / drifted direction artifact (golden discipline).
  # The SHA256 pin makes any byte change to the committed golden fail here.
  path <- valence_fixture_path("valence-direction.csv")
  expect_identical(unname(tools::sha256sum(path)), DIRECTION_SHA256)

  direction <- read_valence_direction()
  expect_length(direction, 896L) # Qwen2.5-0.5B hidden size
  expect_false(anyNA(direction))
  expect_true(all(is.finite(direction)))
  expect_equal(sqrt(sum(direction^2)), 1, tolerance = 1e-6) # L2-normalised
})

# --- [MODEL] acceptance: steering shifts valence ----------------------------

test_that("steering along the valence direction shifts generated valence (+ up, - down) [MODEL]", {
  model_path <- qwen_model_path()
  lexicon <- read_valence_lexicon()
  direction <- read_valence_direction()

  m <- llm(model_path)
  on.exit(close(m), add = TRUE)
  skip_if_not(
    length(direction) == m$hidden_size,
    "valence direction width does not match the model hidden size"
  )

  # Score valence over the held-out neutral prompts for a handle.
  score_over_prompts <- function(handle) {
    vapply(
      VALENCE_NEUTRAL_PROMPTS,
      function(p) {
        out <- llm_generate(handle, p, max_tokens = 48, temperature = 0, chat = FALSE)
        valence_score(out[[1]], lexicon)
      },
      numeric(1)
    )
  }
  generate_over_prompts <- function(handle) {
    vapply(
      VALENCE_NEUTRAL_PROMPTS,
      function(p) llm_generate(handle, p, max_tokens = 48, temperature = 0, chat = FALSE)[[1]],
      character(1)
    )
  }

  base_txt <- generate_over_prompts(m)
  base_val <- vapply(base_txt, valence_score, numeric(1), lexicon = lexicon)

  steer_pos <- llm_steer(m, VALENCE_LAYER, direction, coef = VALENCE_COEF)
  steer_neg <- llm_steer(m, VALENCE_LAYER, direction, coef = -VALENCE_COEF)
  on.exit(close(steer_pos), add = TRUE)
  on.exit(close(steer_neg), add = TRUE)
  pos_val <- score_over_prompts(steer_pos)
  neg_val <- score_over_prompts(steer_neg)

  # ---- the acceptance: +coef more positive than base, -coef more negative ----
  # Directional means (calibrated 2026-07-06: += +0.063, base +0.014, -= -0.017;
  # thresholds below sit well inside those margins so the fixture is not flaky).
  expect_gt(mean(pos_val), mean(base_val)) # +coef shifts valence positive
  expect_gt(mean(base_val), mean(neg_val)) # -coef shifts valence negative
  # Strong +/- contrast (observed +0.079; require a fraction of it, with slack).
  expect_gt(mean(pos_val) - mean(neg_val), 0.03)
  # Per-prompt majority in the expected direction (observed 9/10; require >= 7/10).
  # A one-off numeric wobble on one prompt cannot flip the verdict.
  expect_gte(sum(pos_val > neg_val), 7L)

  # ---- adversarial guard A: coef = 0 is a no-op --------------------------
  # A zero steer vector adds nothing, so greedy output is byte-identical to base and
  # valence is unchanged. Catches a bug where merely DERIVING a handle (or ignoring
  # coef) perturbs generation -- which would make the shift above spurious.
  steer_zero <- llm_steer(m, VALENCE_LAYER, direction, coef = 0)
  on.exit(close(steer_zero), add = TRUE)
  zero_txt <- generate_over_prompts(steer_zero)
  expect_identical(unname(zero_txt), unname(base_txt))

  # ---- adversarial guard B: a shuffled direction does not reproduce it -------
  # Permuting the direction across neurons preserves its norm but destroys the
  # valence structure. If ANY vector of this magnitude shifted valence positive, the
  # direction would not be carrying valence -- so the real positive shift must
  # clearly exceed the shuffled one. Averaged over fixed seeds for stability
  # (observed real shift +0.048 vs shuffled -0.005).
  real_shift <- mean(pos_val) - mean(base_val)
  shuffle_shifts <- vapply(c(101L, 202L, 303L), function(seed) {
    set.seed(seed) # deterministic permutation; base R, no dependency
    shuffled <- direction[sample.int(length(direction))]
    sh <- llm_steer(m, VALENCE_LAYER, shuffled, coef = VALENCE_COEF)
    on.exit(close(sh), add = TRUE)
    mean(score_over_prompts(sh)) - mean(base_val)
  }, numeric(1))
  expect_gt(real_shift, mean(shuffle_shifts) + 0.015)

  # ---- adversarial guard C: the source is unchanged after steering -----------
  # Reversibility at the R level: deriving steered handles must not touch the source
  # context, so its greedy generation reproduces byte-for-byte (the exact-value
  # counterpart is proven in synthetic_intervene.rs).
  base_after <- generate_over_prompts(m)
  expect_identical(unname(base_after), unname(base_txt))
})
