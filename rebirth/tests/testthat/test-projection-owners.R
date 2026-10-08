test_that("projection state inventory adds hash bindings and both finalizer types", {
  plain <- list(hash_slots = 0, bindings = 2, c_finalizer_bytes = 8)
  hashed <- plain; hashed$hash_slots <- 29
  # Independent R64 inventory: 112 binding bytes + 112 conservative symbol
  # bytes + 56 logical bytes + three80-byte weakrefs + 56-byte C function owner.
  expect_identical(relm:::projection_state_bytes(plain), 576)
  expect_identical(relm:::projection_state_bytes(hashed), 856)
  expect_identical(relm:::projection_state_bytes(hashed) - relm:::projection_state_bytes(plain),
    as.double(object.size(vector("list", 29L))))
  for (key in c("bindings", "c_finalizer_bytes")) {
    bad <- plain; bad[[key]] <- bad[[key]] + 1
    expect_error(relm:::projection_state_bytes(bad), class = "relm_error_intervention")
  }
  bad <- plain; bad$hash_slots <- 2^53
  expect_error(relm:::projection_state_bytes(bad), class = "relm_error_intervention")
})

test_that("projection scalar scan refuses hidden owners duplicate sites and nonfinite scaling", {
  iv <- projection_owner_entry()
  good <- relm:::projection_owner_scan(list(), iv, 3L, 4L)
  expect_identical(good$previous_sites, 0)
  expect_error(relm:::projection_owner_scan(list(iv), iv, 3L, 4L), class = "relm_error_intervention")
  second <- iv; second$component <- "attn_out"
  expect_identical(relm:::projection_owner_scan(list(iv), second, 3L, 4L)$previous_sites, 1)
  for (key in c("names_attribute", "direction_attribute", "norm", "layer", "component")) {
    bad <- iv
    if (key == "names_attribute") bad <- structure(bad, names = structure(names(bad), hidden = raw(4096)))
    if (key == "direction_attribute") names(bad$direction) <- letters[1:3]
    if (key == "norm") bad$direction[[1]] <- 2
    if (key == "layer") bad$layer <- 0L
    if (key == "component") bad$component <- "residual"
    expect_error(relm:::projection_owner_scan(list(), bad, 3L, 4L), class = "relm_error_intervention")
  }
  s <- list(kind = "steer", layer = 2L, direction = rep(3e38, 3), coef = 2, positions = "all")
  expect_error(relm:::projection_owner_scan(list(), s, 3L, 4L), class = "relm_error_intervention")
  a <- list(kind = "ablate", layer = 2L, neurons = c(2L, 1L), value = 0, component = "residual")
  expect_error(relm:::projection_owner_scan(list(), a, 3L, 4L), class = "relm_error_intervention")
})

test_that("projection boundary arrays preserve mixed residual order without changing inputs", {
  first <- list(kind = "steer", layer = 2L, direction = c(2, 4, 6), coef = .5, positions = "all")
  second <- first; second$coef <- -.5
  a <- list(kind = "ablate", layer = 3L, neurons = c(1L, 3L), value = 2, component = "residual")
  b <- a; b$neurons <- 3L; b$value <- -1
  ivs <- list(first, projection_owner_entry(), a, second)
  original <- serialize(ivs, NULL)
  counts <- relm:::projection_owner_scan(ivs, b, 3L, 4L)
  flat <- relm:::projection_flatten(ivs, b, 3L, counts)
  expect_identical(flat, list(steer_layers = c(2L, 2L), steer_vectors = c(1, 2, 3, -1, -2, -3),
    ablate_layers = c(3L, 3L, 3L), ablate_neurons = c(1L, 3L, 3L), ablate_values = c(2, 2, -1)))
  expect_identical(serialize(ivs, NULL), original)
  expect_identical(relm:::projection_flat_bytes(counts, 3L), as.double(object.size(flat)))
  expect_identical(counts$steer_entries, 2)
  expect_identical(counts$ablate_entries, 3)
  bad <- counts; bad$steer_entries <- 1
  expect_error(relm:::projection_flatten(ivs, b, 3L, bad), class = "relm_error_intervention")
  bad <- counts; bad$steer_entries <- 2^52
  expect_error(relm:::projection_flat_bytes(bad, 3L), class = "relm_error_intervention")
})

test_that("projection inventory binds actual metadata and accumulated residual owners", {
  p <- projection_test_profile()
  facts <- list(hash_slots = 29, bindings = 2, c_finalizer_bytes = 8)
  s <- list(kind = "steer", layer = 2L, direction = c(2, 4, 6), coef = .5, positions = "all")
  m <- projection_owner_model(interventions = list(s))
  entry <- projection_owner_entry()
  got <- relm:::projection_owner_inventory(m, entry, facts, p, 64 * 2^20, 2^20)
  expect_gt(got$r_projection_fixed_bytes, 2 * as.double(object.size(m)))
  expect_identical(got$state_extra_bytes, 1432)
  expect_identical(got$scan_bytes, 2 * as.double(object.size(integer(32L))) +
    as.double(object.size(got$counts)) + as.double(object.size(facts)) +
    2 * as.double(object.size(0)) + as.double(object.size(got)))
  flat <- list(steer_layers = 2L, steer_vectors = c(1, 2, 3),
    ablate_layers = integer(), ablate_neurons = integer(), ablate_values = double())
  expect_identical(got$r_adapter_bytes, as.double(object.size(s)) + as.double(object.size(flat)))
  wider <- m; wider$.description <- strrep("x", 4000)
  more <- relm:::projection_owner_inventory(wider, entry, facts, p, 64 * 2^20, 2^20)
  expect_identical(more$r_projection_fixed_bytes - got$r_projection_fixed_bytes,
    2 * (as.double(object.size(wider$.description)) - as.double(object.size(m$.description))))
  bad <- m; bad$path <- new.env(parent = emptyenv())
  expect_error(relm:::projection_owner_inventory(bad, entry, facts, p, 64 * 2^20, 2^20), class = "relm_error_intervention")
  expect_error(relm:::projection_owner_inventory(m, entry, facts, p, 2^20, 2^20), class = "relm_error_oom")
})

test_that("projection flat capacity counts agree with real R vector pools at boundaries", {
  for (h in c(1L, 2L, 3L, 16L, 17L, 65536L)) {
    s <- list(kind = "steer", layer = 2L, direction = rep(.125, h), coef = 2, positions = "all")
    p <- projection_owner_entry(h)
    counts <- relm:::projection_owner_scan(list(s), p, h, 4L)
    flat <- relm:::projection_flatten(list(s), p, h, counts)
    expect_identical(relm:::projection_flat_bytes(counts, h), as.double(object.size(flat)))
    expect_identical(flat$steer_vectors, rep(.25, h))
  }
})

test_that("projection site count refuses thirty-third entry before new materialization", {
  ivs <- lapply(seq_len(32L), function(i) projection_owner_entry(1L, i))
  before <- serialize(ivs, NULL)
  expect_error(relm:::projection_owner_scan(ivs, projection_owner_entry(1L, 33L), 1L, 33L),
    class = "relm_error_intervention")
  expect_identical(serialize(ivs, NULL), before)
})

test_that("projection candidate wraps an independent un-hashed state and shares unchanged entries", {
  m <- projection_owner_model()
  m$state$closed <- TRUE; m$state$ptr <- m$ptr
  entry <- projection_owner_entry()
  ptr <- relm:::rebirth_selftest_new_handle()
  derived <- relm:::projection_new_llm(m, ptr, entry, 64 * 2^20, 2^20)
  # Empty native pointer fixtures never call the engine during finalization.
  derived$state$closed <- TRUE
  expect_null(env.profile(derived$state))
  expect_identical(parent.env(derived$state), emptyenv())
  expect_identical(sort(ls(derived$state, all.names = TRUE)), c("closed", "ptr"))
  expect_false(identical(derived$state, m$state))
  expect_identical(derived$state$ptr, ptr)
  expect_identical(derived$interventions, list(entry))
  expect_length(m$interventions, 0L)
  expect_null(attr(m, "projection", exact = TRUE))
  expect_identical(relm:::projection_owner_settings(derived),
    list(max_bytes = 64 * 2^20, existing_direction_estimate = 2^20))
  for (name in relm:::projection_model_fields[!relm:::projection_model_fields %in% c("ptr", "state", "interventions")])
    expect_identical(derived[[name]], m[[name]])
  next_entry <- entry; next_entry$component <- "attn_out"
  facts <- list(hash_slots = 0, bindings = 2, c_finalizer_bytes = 8)
  inventory <- relm:::projection_owner_inventory(derived, next_entry, facts,
    projection_test_profile(), 64 * 2^20, 2^20)
  expect_identical(inventory$counts$previous_sites, 1)
  expect_identical(inventory$state_extra_bytes, 1152)
  bad <- derived; attr(bad, "projection")$hidden <- raw(100)
  expect_error(relm:::projection_owner_settings(bad), class = "relm_error_intervention")
})
