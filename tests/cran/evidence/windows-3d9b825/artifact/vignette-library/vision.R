## -----------------------------------------------------------------------------
#| label: setup
#| include: false
# The live steps need the ~2.3 GB vision model pair; a checker (CRAN,
# r-universe) does not have it, and this vignette must never download
# gigabytes on its own. We therefore gate the model-touching chunks: they run
# when the pinned pair is already present (RELM_TEST_MODEL_VLM /
# RELM_TEST_MMPROJ_VLM point at the files, or the registry aliases are in the
# default llm_download() cache), and otherwise the recorded outputs of the
# same chunks -- from the pinned pair on the founder's machine -- are shown as
# text, clearly labelled. The images themselves are always drawn live.
have_env <- nzchar(Sys.getenv("RELM_TEST_MODEL_VLM")) &&
  nzchar(Sys.getenv("RELM_TEST_MMPROJ_VLM"))
cache_dir <- tools::R_user_dir("relm", "cache")
have_cache <- file.exists(file.path(cache_dir, "Qwen2-VL-2B-Instruct-Q4_K_M.gguf")) &&
  file.exists(file.path(cache_dir, "mmproj-Qwen2-VL-2B-Instruct-f16.gguf"))
run_real <- have_env || have_cache
run_download <- have_cache && !have_env # a cache hit: cheap, offline, verified
if (have_env) {
  model <- Sys.getenv("RELM_TEST_MODEL_VLM")
  mmproj <- Sys.getenv("RELM_TEST_MMPROJ_VLM")
}
if (run_real) suppressPackageStartupMessages(library(relm))


## -----------------------------------------------------------------------------
#| label: download
if (run_download) {
  library(relm)

  model  <- llm_download("qwen2-vl-2b-instruct-q4_k_m")     # ~1 GB, verified
  mmproj <- llm_download("qwen2-vl-2b-instruct-mmproj-f16") # ~1.3 GB, verified
}


## -----------------------------------------------------------------------------
#| label: load
if (run_real) {
  m <- llm(model, projector = mmproj)
  m
}


## -----------------------------------------------------------------------------
#| label: load-recorded
#| echo: false
if (isFALSE(run_real)) {
  # Recorded output of the chunk above (pinned pair, Apple-silicon Metal).
  cat('<llm> Qwen2-VL-2B-Instruct-Q4_K_M.gguf
  architecture:    qwen2vl
  parameters:      1.5 B
  quantization:    Q4_K_M
  layers x hidden: 28 x 1536
  context:         4096 tokens
  backend:         metal
  projector:       mmproj-Qwen2-VL-2B-Instruct-f16.gguf
  interventions:   0 active
')
}


## -----------------------------------------------------------------------------
#| label: draw-square
#| fig-width: 3
#| fig-height: 3
#| fig-alt: "A red square centered on a white background."
draw_square <- function() {
  op <- par(mar = c(0, 0, 0, 0))
  on.exit(par(op))
  plot.new()
  plot.window(xlim = c(0, 1), ylim = c(0, 1), xaxs = "i", yaxs = "i")
  rect(0, 0, 1, 1, col = "white", border = NA)
  rect(0.215, 0.215, 0.785, 0.785, col = "red", border = NA)
}
draw_square() # shown here ...

img <- file.path(tempdir(), "red-square.png")
png(img, width = 224, height = 224) # ... and saved as the file we hand the model
draw_square()
invisible(dev.off())


## -----------------------------------------------------------------------------
#| label: ask
if (run_real) {
  answer <- llm_generate(m, "What color is the square?",
    images = img, max_tokens = 32, temperature = 0
  )
  cat(answer)
}


## -----------------------------------------------------------------------------
#| label: ask-recorded
#| echo: false
if (isFALSE(run_real)) {
  # Recorded output of the chunk above (pinned pair; greedy, so reproducible).
  cat("The square is red.\n")
}


## -----------------------------------------------------------------------------
#| label: describe
if (run_real) {
  llm_generate(m, "Describe this image in one short sentence.",
    images = img, max_tokens = 40, temperature = 0
  ) |> cat()
}


## -----------------------------------------------------------------------------
#| label: describe-recorded
#| echo: false
if (isFALSE(run_real)) {
  cat("A red square on a white background.\n")
}


## -----------------------------------------------------------------------------
#| label: draw-cat
#| fig-width: 3
#| fig-height: 3
#| fig-alt: "A cartoon cat face: orange head, triangular ears, green eyes, whiskers."
draw_cat <- function() {
  op <- par(mar = c(0, 0, 0, 0))
  on.exit(par(op))
  plot.new()
  plot.window(xlim = c(0, 1), ylim = c(0, 1), xaxs = "i", yaxs = "i")
  rect(0, 0, 1, 1, col = "white", border = NA)
  orange <- "#E8853A"
  polygon(c(0.28, 0.40, 0.22), c(0.62, 0.72, 0.82), col = orange, border = "black")
  polygon(c(0.72, 0.60, 0.78), c(0.62, 0.72, 0.82), col = orange, border = "black")
  polygon(c(0.31, 0.37, 0.27), c(0.66, 0.71, 0.77), col = "pink", border = NA)
  polygon(c(0.69, 0.63, 0.73), c(0.66, 0.71, 0.77), col = "pink", border = NA)
  symbols(0.5, 0.52, circles = 0.24, inches = FALSE, add = TRUE,
    bg = orange, fg = "black"
  )
  symbols(c(0.41, 0.59), c(0.58, 0.58), circles = c(0.045, 0.045),
    inches = FALSE, add = TRUE, bg = "#9ACD32", fg = "black"
  )
  segments(c(0.41, 0.59), c(0.545, 0.545), c(0.41, 0.59), c(0.615, 0.615), lwd = 3)
  polygon(c(0.475, 0.525, 0.5), c(0.485, 0.485, 0.455), col = "pink", border = "black")
  segments(0.5, 0.455, 0.5, 0.42, lwd = 2)
  segments(0.5, 0.42, 0.45, 0.40, lwd = 2)
  segments(0.5, 0.42, 0.55, 0.40, lwd = 2)
  segments(rep(0.44, 3), c(0.46, 0.44, 0.42), rep(0.16, 3), c(0.50, 0.44, 0.38), lwd = 1.5)
  segments(rep(0.56, 3), c(0.46, 0.44, 0.42), rep(0.84, 3), c(0.50, 0.44, 0.38), lwd = 1.5)
}
draw_cat()

cat_img <- file.path(tempdir(), "cat.png")
png(cat_img, width = 224, height = 224)
draw_cat()
invisible(dev.off())


## -----------------------------------------------------------------------------
#| label: similarity
if (run_real) {
  e_img <- llm_embed(m, "", images = cat_img) # the image alone: one row
  e_txt <- llm_embed(m, c(cat = "a cat", car = "a car"))
  sims <- drop(tcrossprod(e_img, e_txt))
  round(sims, 3)
}


## -----------------------------------------------------------------------------
#| label: similarity-recorded
#| echo: false
if (isFALSE(run_real)) {
  # Recorded output of the chunk above (pinned pair, Apple-silicon Metal).
  cat("  cat   car \n0.319 0.275 \n")
}


## -----------------------------------------------------------------------------
#| label: close
if (run_real) {
  close(m)
}

