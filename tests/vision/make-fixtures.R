# Deterministic generator for the WP-V2 vision test fixtures (D-026).
#
# Everything here is drawn/authored by this script with base R only
# (grDevices + writeBin), so every committed fixture is license-clean by
# construction. The COMMITTED BYTES are canonical (the golden-update
# discipline): rerun this script only to regenerate a fixture deliberately,
# on the platform noted in the commit message, and commit the result with the
# reason. Run from the repository root:
#
#     Rscript tests/vision/make-fixtures.R
#
# Outputs:
#   tests/vision/red-square.png                  the canonical demo/golden image
#   rebirth/tests/testthat/fixtures/vision/      the packaged test fixtures
#     red-square.png       byte-identical copy of the canonical image
#     red-square.jpg       the same scene as JPEG (grDevices::jpeg)
#     red-square.bmp       the same scene as BMP (grDevices::bmp)
#     tiny-1x1.png         1 x 1 red pixel (degenerate-dims, audit req 4)
#     thin-16384x1.png     16384 x 1 (at the dimension cap, audit req 4)
#     tall-1x16384.png     1 x 16384 (at the dimension cap, audit req 4)
#     wav-magic.bin        RIFF/WAVE audio magic (must be rejected)
#     mp3-sync.bin         MPEG frame-sync magic FF FB (must be rejected)
#     mpeg-loose-sync.bin  the loosest sync miniaudio sniffs, FF E0 (rejected)
#     id3-magic.bin        ID3-tagged MP3 magic (must be rejected)
#     flac-magic.bin       fLaC magic (must be rejected)
#     gif-1x1.gif          a real minimal GIF89a — GIF is DROPPED (rejected)
#     truncated.png        the PNG signature + partial IHDR (rejected)
#     truncated.jpg        a JPEG SOI cut before any header (rejected)
#     truncated.bmp        a BMP magic cut before the info header (rejected)
#     overdims.png         a syntactically valid PNG header claiming
#                          100000 x 4 pixels (rejected by the pre-decode
#                          dimension cap, never decoded)
#     overpixels.png       a valid header claiming 16000 x 16000 (each side
#                          under the dimension cap, the product over the
#                          pixel cap; rejected pre-decode)
#     garbage.bin          fixed non-image bytes (rejected)

canonical_dir <- file.path("tests", "vision")
fixture_dir <- file.path("rebirth", "tests", "testthat", "fixtures", "vision")
dir.create(canonical_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(fixture_dir, recursive = TRUE, showWarnings = FALSE)

# --- the drawn scene: a pure-red square centered on white ---------------------
# 224 x 224 with a 128 x 128 square: comfortably above the smallest visual
# resolutions VLM preprocessors upscale from, still a sub-kilobyte PNG.
draw_scene <- function() {
  op <- par(mar = c(0, 0, 0, 0))
  on.exit(par(op), add = TRUE)
  plot.new()
  plot.window(xlim = c(0, 1), ylim = c(0, 1), xaxs = "i", yaxs = "i")
  rect(0, 0, 1, 1, col = "white", border = NA)
  rect(0.215, 0.215, 0.785, 0.785, col = "red", border = NA)
}

render <- function(open_device, path) {
  open_device(path)
  draw_scene()
  dev.off()
  invisible(path)
}

red_square <- file.path(canonical_dir, "red-square.png")
render(function(p) png(p, width = 224, height = 224), red_square)
stopifnot(file.copy(red_square, file.path(fixture_dir, "red-square.png"),
  overwrite = TRUE
))
render(
  function(p) jpeg(p, width = 224, height = 224, quality = 95),
  file.path(fixture_dir, "red-square.jpg")
)
render(
  function(p) bmp(p, width = 224, height = 224),
  file.path(fixture_dir, "red-square.bmp")
)

# --- degenerate-but-legal dimensions (audit req 4: classed error or success,
# never abort — exercised against the pinned VLM under the [MODEL] gate) ------
solid_png <- function(path, width, height) {
  png(path, width = width, height = height)
  op <- par(mar = c(0, 0, 0, 0))
  plot.new()
  plot.window(xlim = c(0, 1), ylim = c(0, 1), xaxs = "i", yaxs = "i")
  rect(0, 0, 1, 1, col = "red", border = NA)
  par(op)
  dev.off()
  invisible(path)
}
solid_png(file.path(fixture_dir, "tiny-1x1.png"), 1, 1)
solid_png(file.path(fixture_dir, "thin-16384x1.png"), 16384, 1)
solid_png(file.path(fixture_dir, "tall-1x16384.png"), 1, 16384)

# --- adversarial magic-byte fixtures (audit req 4) ----------------------------
write_bytes <- function(path, bytes) {
  writeBin(as.raw(bytes), path)
  invisible(path)
}

# RIFF....WAVE — the exact prefix mtmd-helper's audio sniff keys on.
write_bytes(
  file.path(fixture_dir, "wav-magic.bin"),
  c(
    utf8ToInt("RIFF"), 0x24, 0x00, 0x00, 0x00, utf8ToInt("WAVE"),
    utf8ToInt("fmt "), rep(0x00, 20)
  )
)
# MPEG frame sync (FF FB = MPEG-1 layer 3) — miniaudio's mp3 route.
write_bytes(
  file.path(fixture_dir, "mp3-sync.bin"),
  c(0xFF, 0xFB, 0x90, 0x00, rep(0x00, 28))
)
# The loosest sync the sniff accepts: any 0xFF with the 0xE0 mask on byte 2.
write_bytes(
  file.path(fixture_dir, "mpeg-loose-sync.bin"),
  c(0xFF, 0xE0, 0x00, 0x00, rep(0x00, 28))
)
# ID3-tagged MP3.
write_bytes(
  file.path(fixture_dir, "id3-magic.bin"),
  c(utf8ToInt("ID3"), 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, rep(0x00, 24))
)
# FLAC.
write_bytes(
  file.path(fixture_dir, "flac-magic.bin"),
  c(utf8ToInt("fLaC"), 0x00, 0x00, 0x00, 0x22, rep(0x00, 27))
)
# A real, complete 1x1 GIF89a (hand-assembled, public-domain trivial): GIF is
# DROPPED from the allow-list and must be rejected at the magic stage.
write_bytes(
  file.path(fixture_dir, "gif-1x1.gif"),
  c(
    utf8ToInt("GIF89a"),
    0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00, # screen descriptor
    0xFF, 0x00, 0x00, 0xFF, 0xFF, 0xFF, # palette: red, white
    0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, # image desc
    0x02, 0x02, 0x44, 0x01, 0x00, # 1-pixel LZW data
    0x3B # trailer
  )
)

# Truncated files of each ALLOWED format: correct magic, unusable header.
red_square_bytes <- readBin(red_square, what = "raw", n = 20)
writeBin(red_square_bytes, file.path(fixture_dir, "truncated.png"))
write_bytes(file.path(fixture_dir, "truncated.jpg"), c(0xFF, 0xD8, 0xFF))
write_bytes(file.path(fixture_dir, "truncated.bmp"), c(utf8ToInt("BM"), 0x00, 0x00))

# Syntactically valid PNG headers with hostile dimension claims: signature +
# IHDR (8-bit RGB) + an empty IDAT chunk header — enough for the header probe
# to report the dimensions, so the pre-decode caps must reject them without
# ever starting a decode. The claims are chosen INSIDE stb's own header-scan
# limits (its info probe refuses anything it could not even decode), so it is
# provably relm's caps doing the rejecting:
#   overdims.png    100000 x 4      -> over the 16384 per-dimension cap
#   overpixels.png  16000 x 16000   -> 256 Mpx, over the 33,554,432-pixel cap
be32 <- function(n) {
  c(
    bitwAnd(bitwShiftR(n, 24), 0xFF), bitwAnd(bitwShiftR(n, 16), 0xFF),
    bitwAnd(bitwShiftR(n, 8), 0xFF), bitwAnd(n, 0xFF)
  )
}
hostile_png_header <- function(path, width, height) {
  write_bytes(
    path,
    c(
      0x89, utf8ToInt("PNG"), 0x0D, 0x0A, 0x1A, 0x0A,
      be32(13), utf8ToInt("IHDR"),
      be32(width), be32(height),
      0x08, 0x02, 0x00, 0x00, 0x00, # 8-bit, RGB, deflate, none, no interlace
      be32(0), # IHDR CRC placeholder (not checked by the header probe)
      be32(0), utf8ToInt("IDAT")
    )
  )
}
hostile_png_header(file.path(fixture_dir, "overdims.png"), 100000, 4)
hostile_png_header(file.path(fixture_dir, "overpixels.png"), 16000, 16000)

# Fixed garbage (no magic of any format).
write_bytes(
  file.path(fixture_dir, "garbage.bin"),
  c(utf8ToInt("this is not an image, and it never will be"), 0x00, 0x01, 0x02)
)

cat("fixtures written under", canonical_dir, "and", fixture_dir, "\n")
