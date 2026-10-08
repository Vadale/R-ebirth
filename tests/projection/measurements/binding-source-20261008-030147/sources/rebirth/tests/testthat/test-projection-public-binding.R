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
    list(ok = TRUE, ptr = new("externalptr"))
  }
  e$rebirth_handle_close <- function(ptr) { e$closed <- e$closed + 1L; invisible(NULL) }
  e
}

test_that("projection preparation charges workflow objects independently of vector width", {
  p <- projection_test_profile()
  bytes <- relm:::projection_binding_workspace(p)
  expect_gt(bytes, as.double(object.size(setNames(as.list(rep(0, 14)), relm:::projection_term_fields))))
  expect_true(is.double(bytes) && length(bytes) == 1L && is.finite(bytes))
  expect_identical(relm:::projection_binding_workspace(p), bytes)
})

test_that("projection preparation binds actual inventory and native response before arrays", {
  e <- projection_binding_fixture(); m <- projection_owner_model(); iv <- projection_owner_entry()
  prepared <- e$projection_prepare(m, iv, 64 * 2^20, 0)
  expect_identical(e$events, c("profile", "facts", "preflight"))
  expect_identical(prepared$config$r_projection_fixed_bytes,
    prepared$inventory$r_projection_fixed_bytes + prepared$workspace_bytes)
  expect_identical(prepared$config$r_adapter_bytes, prepared$inventory$r_adapter_bytes)
  expect_identical(prepared$config$direction, iv$direction)
  expect_identical(prepared$response$terms,
    relm:::projection_memory_bound(prepared$profile, prepared$response$inputs))
  expect_identical(e$closed, 0L)
  expect_null(attr(m, "projection", exact = TRUE))
})

test_that("projection preparation rejects altered native scope and charges before allocation", {
  for (field in c("hidden_size", "layers", "previous_sites", "r_projection_fixed_bytes")) {
    e <- projection_binding_fixture(); original <- e$rebirth_projection_preflight
    e$rebirth_projection_preflight <- function(...) {
      value <- original(...); value$inputs[[field]] <- value$inputs[[field]] + 1; value
    }
    expect_error(e$projection_derive(projection_owner_model(), projection_owner_entry(), 64 * 2^20, 0),
      class = "relm_error_intervention")
    expect_false("construct" %in% e$events)
  }
  e <- projection_binding_fixture(); m <- projection_owner_model()
  m$.description <- strrep("x", 600000L)
  expect_error(e$projection_derive(m, projection_owner_entry(), 2^20, 0), class = "relm_error_oom")
  expect_false("preflight" %in% e$events || "construct" %in% e$events)
})

test_that("projection derivation carries admitted arrays and creates independent R state", {
  e <- projection_binding_fixture(); m <- projection_owner_model(); iv <- projection_owner_entry()
  m$interventions <- list(list(kind = "steer", layer = 2L,
    direction = c(2, 4, 6), coef = .5, positions = "all"))
  derived <- e$projection_derive(m, iv, 64 * 2^20, 0)
  derived$state$closed <- TRUE # Empty native test pointer: never finalize via DLL.
  expect_identical(e$events, c("profile", "facts", "preflight", "construct"))
  expect_identical(e$flat, list(2L, c(1, 2, 3), integer(), integer(), double()))
  expect_identical(derived$interventions, c(m$interventions, list(iv)))
  expect_false(identical(derived$state, m$state))
  expect_null(env.profile(derived$state))
  expect_identical(derived$path, m$path)
  expect_identical(e$closed, 0L)
})

test_that("projection derivation closes delivered handle if R wrapping fails", {
  e <- projection_binding_fixture()
  e$projection_new_llm <- function(...) stop("forced R wrapper failure")
  expect_error(e$projection_derive(projection_owner_model(), projection_owner_entry(), 64 * 2^20, 0),
    "forced R wrapper failure", fixed = TRUE)
  expect_identical(e$closed, 1L)
  expect_identical(e$events, c("profile", "facts", "preflight", "construct"))
})

test_that("projection inherited residual uses recorded budget without a new site", {
  e <- projection_binding_fixture(); m <- projection_owner_model(interventions = list(projection_owner_entry()))
  attr(m, "projection") <- list(max_bytes = 32 * 2^20, existing_direction_estimate = 1024)
  entry <- list(kind = "ablate", layer = 1L, neurons = c(1L, 3L), value = 0, component = "residual")
  prepared <- e$projection_prepare(m, entry, 32 * 2^20, 1024)
  expect_identical(prepared$config$mode, "inherit")
  expect_identical(prepared$config$direction, double())
  expect_identical(prepared$config$layer, 0)
  expect_identical(prepared$config$ablate_entries, 2)
  expect_identical(prepared$response$inputs$previous_sites, 1)
  expect_error(e$projection_prepare(m, entry, 64 * 2^20, 1024), class = "relm_error_intervention")
  expect_error(e$projection_prepare(projection_owner_model(), entry, 32 * 2^20, 0), class = "relm_error_intervention")
})
