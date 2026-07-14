# Shared validation for the `images` argument (WP-V2, D-026; API-GRAMMAR
# section 3). One normalizer so llm_generate() today and llm_embed() at WP-V3
# apply the identical pairing contract.

# Normalize `images` against `n_inputs` prompts/texts (API-GRAMMAR section 3):
#   * NULL -> NULL (text-only; the caller takes the unchanged text path).
#   * a bare character vector -> treated as `list(images)`, i.e. ONE image set;
#     with `n_inputs == 1` it pairs silently, otherwise it is recycled across
#     all inputs with a warning (the llm_trace(positions=) recycling contract).
#   * a list -> must be parallel to the inputs (`length(images) == n_inputs`),
#     each element a character vector of image file paths (`character(0)` =
#     none for that input).
# Type/length violations raise `relm_error_argument` (the offending argument is
# always "images"); file EXISTENCE is checked later by the caller/engine as the
# vision-domain `relm_error_image`. Returns NULL or a list of character vectors
# of length `n_inputs`.
normalize_images <- function(images, n_inputs, call = sys.call(-1L)) {
  if (is.null(images)) {
    return(NULL)
  }

  if (is.character(images)) {
    if (anyNA(images)) {
      abort_argument(
        "images", "`images` must not contain NA paths.",
        call = call
      )
    }
    sets <- list(images)
    if (n_inputs > 1L) {
      warning(
        "A bare `images` character vector was recycled across all ", n_inputs,
        " prompts (the same image set for each). Pass a list parallel to the ",
        "prompts to give each prompt its own images.",
        call. = FALSE
      )
      sets <- rep(sets, n_inputs)
    }
    return(sets)
  }

  if (is.list(images)) {
    if (length(images) != n_inputs) {
      abort_argument(
        "images",
        sprintf(
          paste0(
            "`images` must be a list parallel to the prompts: got %d element(s) ",
            "for %d prompt(s). Use character(0) for a prompt with no images."
          ),
          length(images), n_inputs
        ),
        call = call
      )
    }
    for (i in seq_along(images)) {
      el <- images[[i]]
      if (!is.character(el) || anyNA(el)) {
        abort_argument(
          "images",
          sprintf(
            paste0(
              "`images[[%d]]` must be a character vector of image file paths ",
              "without NA (character(0) for none)."
            ),
            i
          ),
          call = call
        )
      }
    }
    return(images)
  }

  abort_argument(
    "images",
    "`images` must be NULL, a character vector of image file paths, or a list of such vectors parallel to the prompts.",
    call = call
  )
}

# Pre-flight for a call that actually carries images: the handle must be a
# vision handle (loaded with `projector=`), and every path must name an
# existing readable file -- both vision-domain failures (`relm_error_image`),
# raised here with a clear R-side message before any native work.
check_images_usable <- function(m, image_sets, call = sys.call(-1L)) {
  if (is.null(image_sets) || !any(lengths(image_sets) > 0L)) {
    return(invisible(NULL))
  }
  if (!isTRUE(m$vision)) {
    abort_image(
      paste0(
        "This model was loaded without a projector, so it cannot take image ",
        "input. Reload it with llm(path, projector = <mmproj GGUF>) to enable ",
        "images."
      ),
      call = call
    )
  }
  for (set in image_sets) {
    for (p in set) {
      expanded <- path.expand(p)
      if (!nzchar(expanded) || !file.exists(expanded) || dir.exists(expanded)) {
        abort_image(
          sprintf(
            "Image file not found at '%s'. Check the path (each `images` entry must name an existing image file).",
            p
          ),
          list(path = p),
          call = call
        )
      }
    }
  }
  invisible(NULL)
}

# The per-image byte cap consulted only when images are present: the documented
# override `options(relm.image_max_bytes=)`, default 64 MB. The engine
# additionally enforces its own hard ceiling (2^31 - 1 bytes) and the
# dimension/pixel caps regardless of this option. Validated here so a broken
# option is a classed R error, not a boundary reject.
image_max_bytes <- function(call = sys.call(-1L)) {
  cap <- getOption("relm.image_max_bytes", 64 * 1024^2)
  if (!is.numeric(cap) || length(cap) != 1L || is.na(cap) || cap <= 0) {
    abort_argument(
      "relm.image_max_bytes",
      "options(relm.image_max_bytes=) must be a single positive number of bytes.",
      call = call
    )
  }
  as.double(cap)
}
