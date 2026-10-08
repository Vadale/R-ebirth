# F6d model-free fixtures; ordinary Mac/Linux R checks, no inference.
direction_test_fixture <- function(n = 3L, h = 4L) {
  ids <- paste0("pair-", seq_len(n))
  control <- matrix(rep(c(1, 2, -1, 0.5), length.out = n * h), n, h,
    dimnames = list(ids, as.character(seq_len(h))))
  target <- control + matrix(rep(c(2, -1, 0.25, 3, 1, 2), length.out = n * h), n, h)
  hashes <- sprintf("%064x", seq_len(2L * n + 2L))
  context <- list(
    model = list(sha256 = paste(rep("a", 64), collapse = ""), architecture = "qwen2",
      quantization = "Q8_0", hidden_size = as.integer(h), layers = 24L,
      engine_revision = "synthetic-test-record"),
    capture = list(component = "residual", positions = "last", input_format = "raw_text",
      tokenizer = "gguf_embedded", add_special = TRUE, parse_special = FALSE,
      template_sha256 = NULL, context_length = 512L, backend = "cpu", relm_version = "0.3.0"),
    pairs = data.frame(pair_id = ids, target_sha256 = hashes[seq_len(n)],
      control_sha256 = hashes[n + seq_len(n)], target_pos = rep(3L, n), control_pos = rep(4L, n)),
    splits = data.frame(prompt_sha256 = hashes,
      split = c(rep("construction", 2L * n), "selection", "evaluation")),
    seed = NULL)
  list(target = target, control = control, context = context)
}

direction_test_build <- function(x = direction_test_fixture(), ...) {
  llm_direction(x$target, x$control, x$context, layer = 2L, ...)
}

direction_test_handle <- function(record) {
  state <- new.env(parent = emptyenv()); state$closed <- FALSE
  structure(c(record[c("architecture", "quantization", "hidden_size", "layers")],
    list(state = state, ptr = NULL, interventions = list())), class = "llm")
}
projection_test_profile <- function() {
    p <- setNames(as.list(rep(64, length(projection_profile_fields))), projection_profile_fields)
    p$version <- 2
    p$direction_arc_header_bytes <- 16
    p$runtime_bytes <- 8192
    p$derive_frame_bytes <- 1024
    p$callback_frame_bytes <- 512
    p$ffi_fixed_bytes <- 1024
    p$metadata_owner_bytes <- 0
    p$ffi_handle_tag_bytes <- 24
    p$layout_checksum <- 1234
    p$max_sites <- 32
    p$max_width <- 65536
    p
}
projection_test_inputs <- function(mode = 1, h = 32, old = 0) {
    list(mode = mode, hidden_size = h, layers = 3, previous_sites = old, steer_entries = 2, ablate_entries = 3, source_baseline_values = h * 3, metadata_bytes = 0, metadata_scratch_bytes = 0, existing_direction_estimate = 1000, r_projection_fixed_bytes = 2000, r_adapter_bytes = 3000, max_bytes = 512 * 2^20, backend = 0, production_armed = 1)
}
projection_test_config <- function() {
    list(mode = "new_site", layer = 1, component = "mlp_out", coef = 1, direction = c(1, rep(0, 31)), steer_entries = 2, ablate_entries = 3, existing_direction_estimate = 1000, r_projection_fixed_bytes = 2000, r_adapter_bytes = 3000, max_bytes = 512 * 2^20)
}
projection_owner_model <- function(h = 3L, interventions = list()) {
    structure(list(ptr = new("externalptr"), state = new.env(parent = emptyenv()), path = "model.gguf", architecture = "llama", parameters = 1000, quantization = "f32", layers = 4L, hidden_size = h, context_length = 64L, backend = "cpu", projector = NULL, vision = FALSE, interventions = interventions, .context_train = 64L, .size_bytes = 1024, .vocab_size = 48L, .description = "tiny"), class = "llm")
}
projection_owner_entry <- function(h = 3L, layer = 1L, component = "mlp_out") {
    list(kind = "project", layer = layer, component = component, direction = c(1, rep(0, h - 1L)), coef = 1)
}
projection_binding_fixture <- function() {
    e <- new.env(parent = environment(projection_prepare))
    for (name in c("projection_prepare", "projection_derive")) {
        fn <- get(name, envir = parent.env(e))
        environment(fn) <- e
        e[[name]] <- fn
    }
    e$profile <- projection_test_profile()
    e$events <- character()
    e$closed <- 0L
    e$last_config <- NULL
    e$rebirth_projection_allocation_profile <- function() {
        e$events <- c(e$events, "profile")
        e$profile
    }
    e$rebirth_projection_state_facts <- function(state, ptr) {
        e$events <- c(e$events, "facts")
        list(hash_slots = 29, bindings = 2, c_finalizer_bytes = 8)
    }
    e$rebirth_projection_preflight <- function(ptr, config) {
        e$events <- c(e$events, "preflight")
        e$last_config <- config
        i <- projection_test_inputs()
        i$mode <- as.double(config$mode == "new_site")
        i$hidden_size <- 3
        i$layers <- 4
        i$previous_sites <- as.double(config$mode == "inherit")
        for (key in c("steer_entries", "ablate_entries", "existing_direction_estimate", "r_projection_fixed_bytes", "r_adapter_bytes", "max_bytes")) i[[key]] <- config[[key]]
        i$source_baseline_values <- 0
        i$metadata_bytes <- 0
        i$metadata_scratch_bytes <- 0
        i$backend <- 0
        list(ok = TRUE, armed = FALSE, profile = e$profile, inputs = i, terms = projection_memory_bound(e$profile, i))
    }
    e$rebirth_projection_construct <- function(ptr, config, sl, sv, al, an, av) {
        e$events <- c(e$events, "construct")
        e$last_config <- config
        e$flat <- list(sl, sv, al, an, av)
        list(ok = TRUE, ptr = new("externalptr"))
    }
    e$rebirth_handle_close <- function(ptr) {
        e$closed <- e$closed + 1L
        invisible(NULL)
    }
    e
}
# D046 public routing checks with real artifact validation and isolated boundaries.
projection_application_env <- function() {
  e <- new.env(parent = environment(llm_apply_direction))
  for (name in c("llm_apply_direction", "derive_intervened")) {
    f <- get(name, envir = parent.env(e)); environment(f) <- e; e[[name]] <- f
  }
  e$seen <- NULL; e$calls <- 0L
  e$projection_derive <- function(m, entry, max_bytes, existing_direction_estimate,
                                 direction_application = FALSE) {
    e$calls <- e$calls + 1L
    e$seen <- list(m = m, entry = entry, budget = max_bytes,
      estimate = existing_direction_estimate, application = direction_application)
    structure(list(marker = TRUE), class = "llm")
  }
  e
}

projection_application_artifact <- function(component = "mlp_out", layer = 2L) {
  f <- direction_test_fixture(); f$context$capture$component <- component
  x <- llm_direction(f$target, f$control, f$context, layer)
  list(x = x, context = f$context$model, m = direction_test_handle(f$context$model))
}

test_that("direction operators are exact plain strings before artifact work", {
  e <- projection_application_env(); touched <- 0L
  e$direction_validate <- function(...) { touched <<- touched + 1L; stop("unexpected validation") }
  for (op in list("pro", "PROJECT", NA_character_, c("add", "project"), c(named = "project"), 1)) {
    expect_error(e$llm_apply_direction(NULL, NULL, NULL, operator = op), class = "relm_error_argument")
  }
  expect_identical(touched, 0L)
  expect_identical(tail(names(formals(llm_apply_direction)), 1L), "operator")
  expect_identical(formals(llm_apply_direction)$operator, "add")
})

test_that("projection application routes validated first and last component sites", {
  for (component in c("mlp_out", "attn_out")) for (layer in c(1L, 24L)) {
    f <- projection_application_artifact(component, layer); e <- projection_application_env()
    result <- e$llm_apply_direction(f$m, f$x, f$context, coef = -1, operator = "project")
    expect_s3_class(result, "llm")
    expect_identical(e$seen$entry, list(kind = "project", layer = layer,
      component = component, direction = f$x$value, coef = -1))
    expected <- direction_validate(f$x, extra_bytes = 4 * as.double(object.size(f$context)))$estimate_bytes
    expect_identical(e$seen$estimate, expected)
    expect_identical(e$seen$budget, 64 * 2^20)
    expect_true(e$seen$application)
  }
})

test_that("operator mismatch tampering and foreign provenance precede derivation", {
  component <- projection_application_artifact(); residual <- projection_application_artifact("residual")
  e <- projection_application_env()
  e$llm_steer <- function(...) stop("unexpected additive derivation")
  expect_error(e$llm_apply_direction(component$m, component$x, component$context), class = "relm_error_intervention")
  expect_error(e$llm_apply_direction(residual$m, residual$x, residual$context, operator = "project"), class = "relm_error_intervention")
  bad <- component$x; bad$value[1] <- bad$value[1] + .01
  expect_error(e$llm_apply_direction(component$m, bad, component$context, operator = "project"), class = "relm_error_intervention")
  foreign <- component$context; foreign$sha256 <- paste(rep("b", 64), collapse = "")
  expect_error(e$llm_apply_direction(component$m, component$x, foreign, operator = "project"), class = "relm_error_intervention")
  expect_identical(e$calls, 0L)
})

test_that("projection coefficients retain zero and reject hidden or non-f32 values", {
  f <- projection_application_artifact(); e <- projection_application_env()
  for (coef in list(NA_real_, Inf, 4e38, c(1, 2), c(named = 1), structure(1, hidden = raw(8)))) {
    expect_error(e$llm_apply_direction(f$m, f$x, f$context, coef = coef, operator = "project"), class = "relm_error_intervention")
  }
  expect_identical(e$calls, 0L)
  e$llm_apply_direction(f$m, f$x, f$context, coef = 0L, operator = "project")
  expect_identical(e$seen$entry$coef, 0)
})

test_that("additive application preserves old dispatch and charges new artifact on projected source", {
  f <- projection_application_artifact("residual"); e <- projection_application_env(); additive <- NULL
  e$llm_steer <- function(m, layer, direction, coef, positions) {
    additive <<- list(m, layer, direction, coef, positions); structure(list(), class = "llm")
  }
  e$llm_apply_direction(f$m, f$x, f$context, coef = -.5)
  expect_identical(additive, list(f$m, 2L, f$x$value, -.5, "all"))
  expect_identical(e$calls, 0L)
  f$m$interventions <- list(list(kind = "project"))
  attr(f$m, "projection") <- list(max_bytes = 32 * 2^20, existing_direction_estimate = 512)
  e$llm_apply_direction(f$m, f$x, f$context, coef = .5, max_bytes = 48 * 2^20, operator = "add")
  expect_identical(e$seen$budget, 48 * 2^20)
  expect_gt(e$seen$estimate, 512)
  expect_identical(e$seen$entry, list(kind = "steer", layer = 2L, direction = f$x$value, coef = .5, positions = "all"))
  expect_true(e$seen$application)
})

test_that("ordinary residual derivation preserves the recorded projection admission", {
  e <- projection_application_env(); m <- direction_test_handle(direction_test_fixture()$context$model)
  m$interventions <- list(list(kind = "project"))
  attr(m, "projection") <- list(max_bytes = 32 * 2^20, existing_direction_estimate = 2048)
  for (entry in list(list(kind = "steer", layer = 2L, direction = rep(.25, 4), coef = 1, positions = "all"),
                     list(kind = "ablate", layer = 1L, neurons = 1L, value = 0, component = "residual"))) {
    e$derive_intervened(m, entry)
    expect_identical(e$seen$entry, entry)
    expect_identical(e$seen$budget, 32 * 2^20)
    expect_identical(e$seen$estimate, 2048)
    expect_false(e$seen$application)
  }
})

test_that("projection image requests and live projection revisions refuse without execution", {
  m <- direction_test_handle(direction_test_fixture()$context$model); m$vision <- TRUE
  m$interventions <- list(list(kind = "project", layer = 2L, coef = 1),
    list(kind = "steer", layer = 2L, coef = .5))
  expect_error(check_images_usable(m, list("absent.png")), "Projected handles", class = "relm_error_image")
  expect_null(check_images_usable(m, NULL))
  expect_null(check_images_usable(m, list(character())))
  expect_error(live_reply(list(steer = data.frame(intervention = 1L, coef = 0)),
    interventions = m$interventions), class = "relm_error_argument")
  reply <- live_reply(list(steer = data.frame(intervention = 2L, coef = 0)), interventions = m$interventions)
  expect_true(is.list(reply))
})

test_that("explicit direction inheritance uses a new combined budget and production preflight", {
  e <- projection_binding_fixture(); m <- projection_owner_model(interventions = list(projection_owner_entry()))
  attr(m, "projection") <- list(max_bytes = 32 * 2^20, existing_direction_estimate = 1024)
  entry <- list(kind = "steer", layer = 2L, direction = rep(.25, 3), coef = 1, positions = "all")
  z <- e$projection_prepare(m, entry, 48 * 2^20, 2048, direction_application = TRUE)
  expect_identical(z$config$max_bytes, 48 * 2^20)
  expect_identical(z$config$existing_direction_estimate, 2048)
  expect_identical(z$response$inputs$production_armed, 1)
  expect_error(e$projection_prepare(m, entry, 48 * 2^20, 2048), class = "relm_error_intervention")
  original <- e$rebirth_projection_preflight
  e$rebirth_projection_preflight <- function(...) { r <- original(...);r$inputs$production_armed <- 0;r }
  expect_error(e$projection_prepare(m, entry, 32 * 2^20, 1024), class = "relm_error_intervention")
})
test_that("projection responses bind every term and actual model fact before derivation", {
    p <- projection_test_profile()
    i <- projection_test_inputs()
    c <- projection_test_config()
    r <- list(ok = TRUE, armed = FALSE, profile = p, inputs = i, terms = projection_memory_bound(p, i))
    check <- function(x) projection_response_validate(x, c, 32, 3, 0, 0, p)
    expect_identical(check(r), r$terms)
    for (name in projection_term_fields) {
        bad <- r
        bad$terms[[name]] <- bad$terms[[name]] + 1
        expect_error(check(bad), class = "relm_error_intervention", info = name)
    }
    for (name in setdiff(projection_input_fields, "source_baseline_values")) {
        bad <- r
        bad$inputs[[name]] <- bad$inputs[[name]] + 1
        expect_error(check(bad), class = "relm_error_intervention", info = name)
    }
    bad <- r
    bad$armed <- TRUE
    expect_error(check(bad), class = "relm_error_intervention")
    bad <- r
    bad$profile$ffi_registry_bytes <- bad$profile$ffi_registry_bytes + 8
    expect_error(check(bad), class = "relm_error_intervention")
})
