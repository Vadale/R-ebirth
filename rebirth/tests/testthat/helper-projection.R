# Shared projection fixtures load before test files in isolated testthat environments.
# Helpers moved from test files; pointer fixtures allocate distinct native shells.

# Model-free D046 admission controls. Synthetic layouts are deliberate test data,
# not measurements of this machine. The execution collector separately binds
# this R twin to native receipts carrying the actual compiled FFI profile.
projection_test_profile <- function() {
  p <- setNames(as.list(rep(64, length(relm:::projection_profile_fields))),
    relm:::projection_profile_fields)
  p$version <- 2; p$direction_arc_header_bytes <- 16; p$runtime_bytes <- 8192
  p$derive_frame_bytes <- 1024; p$callback_frame_bytes <- 512; p$ffi_fixed_bytes <- 1024
  p$metadata_owner_bytes <- 0; p$ffi_handle_tag_bytes <- 24
  p$layout_checksum <- 1234; p$max_sites <- 32; p$max_width <- 65536
  p
}
projection_test_inputs <- function(mode = 1, h = 32, old = 0) {
  list(mode = mode, hidden_size = h, layers = 3, previous_sites = old,
    steer_entries = 2, ablate_entries = 3, source_baseline_values = h * 3,
    metadata_bytes = 0, metadata_scratch_bytes = 0, existing_direction_estimate = 1000,
    r_projection_fixed_bytes = 2000, r_adapter_bytes = 3000,
    max_bytes = 512 * 2^20, backend = 0, production_armed = 1)
}
projection_test_config <- function() {
  list(mode = "new_site", layer = 1, component = "mlp_out", coef = 1,
    direction = c(1, rep(0, 31)), steer_entries = 2, ablate_entries = 3,
    existing_direction_estimate = 1000, r_projection_fixed_bytes = 2000,
    r_adapter_bytes = 3000, max_bytes = 512 * 2^20)
}

# Runs in ordinary package tests without a model. Actual native binding is a
# separate frozen tiny-model gate; these doubles test R sequencing and cleanup.
projection_binding_fixture <- function() {
  e <- new.env(parent = environment(relm:::projection_prepare))
  for (name in c("projection_prepare", "projection_derive")) {
    fn <- get(name, envir = parent.env(e)); environment(fn) <- e; e[[name]] <- fn
  }
  e$profile <- projection_test_profile()
  e$events <- character(); e$closed <- 0L; e$last_config <- NULL
  e$rebirth_projection_allocation_profile <- function() {
    e$events <- c(e$events, "profile"); e$profile
  }
  e$rebirth_projection_state_facts <- function(state, ptr) {
    e$events <- c(e$events, "facts")
    list(hash_slots = 29, bindings = 2, c_finalizer_bytes = 8)
  }
  e$rebirth_projection_preflight <- function(ptr, config) {
    e$events <- c(e$events, "preflight"); e$last_config <- config
    i <- projection_test_inputs()
    i$mode <- as.double(config$mode == "new_site"); i$hidden_size <- 3; i$layers <- 4
    i$previous_sites <- as.double(config$mode == "inherit")
    for (key in c("steer_entries", "ablate_entries", "existing_direction_estimate",
        "r_projection_fixed_bytes", "r_adapter_bytes", "max_bytes")) i[[key]] <- config[[key]]
    i$source_baseline_values <- 0; i$metadata_bytes <- 0; i$metadata_scratch_bytes <- 0
    i$backend <- 0
    list(ok = TRUE, armed = FALSE, profile = e$profile, inputs = i,
      terms = relm:::projection_memory_bound(e$profile, i))
  }
  e$rebirth_projection_construct <- function(ptr, config, sl, sv, al, an, av) {
    e$events <- c(e$events, "construct"); e$last_config <- config
    e$flat <- list(sl, sv, al, an, av)
    list(ok = TRUE, ptr = relm:::rebirth_selftest_new_handle())
  }
  e$rebirth_handle_close <- function(ptr) { e$closed <- e$closed + 1L; invisible(NULL) }
  e
}

projection_owner_model <- function(h = 3L, interventions = list()) {
  structure(list(ptr = new("externalptr"), state = new.env(parent = emptyenv()),
    path = "model.gguf", architecture = "llama", parameters = 1000,
    quantization = "f32", layers = 4L, hidden_size = h, context_length = 64L,
    backend = "cpu", projector = NULL, vision = FALSE, interventions = interventions,
    .context_train = 64L, .size_bytes = 1024, .vocab_size = 48L, .description = "tiny"), class = "llm")
}
projection_owner_entry <- function(h = 3L, layer = 1L, component = "mlp_out") {
  list(kind = "project", layer = layer, component = component,
    direction = c(1, rep(0, h - 1L)), coef = 1)
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
