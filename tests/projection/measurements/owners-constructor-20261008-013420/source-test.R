projection_test_profile <- function() {
    p <- setNames(as.list(rep(64, length(projection_profile_fields))), projection_profile_fields)
    p$version <- 1
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
projection_owner_model <- function(h = 3L, interventions = list()) {
    structure(list(ptr = new("externalptr"), state = new.env(parent = emptyenv()), path = "model.gguf", architecture = "llama", parameters = 1000, quantization = "f32", layers = 4L, hidden_size = h, context_length = 64L, backend = "cpu", projector = NULL, vision = FALSE, interventions = interventions, .context_train = 64L, .size_bytes = 1024, .vocab_size = 48L, .description = "tiny"), class = "llm")
}
projection_owner_entry <- function(h = 3L, layer = 1L, component = "mlp_out") {
    list(kind = "project", layer = layer, component = component, direction = c(1, rep(0, h - 1L)), coef = 1)
}
test_that("projection inventory binds actual metadata and accumulated residual owners", {
    p <- projection_test_profile()
    facts <- list(hash_slots = 29, bindings = 2, c_finalizer_bytes = 8)
    s <- list(kind = "steer", layer = 2L, direction = c(2, 4, 6), coef = 0.5, positions = "all")
    m <- projection_owner_model(interventions = list(s))
    entry <- projection_owner_entry()
    got <- projection_owner_inventory(m, entry, facts, p, 64 * 2^20, 2^20)
    expect_gt(got$r_projection_fixed_bytes, 2 * as.double(object.size(m)))
    expect_identical(got$state_extra_bytes, 1272)
    flat <- list(steer_layers = 2L, steer_vectors = c(1, 2, 3), ablate_layers = integer(), ablate_neurons = integer(), ablate_values = double())
    expect_identical(got$r_adapter_bytes, as.double(object.size(s)) + as.double(object.size(flat)))
    wider <- m
    wider$.description <- strrep("x", 4000)
    more <- projection_owner_inventory(wider, entry, facts, p, 64 * 2^20, 2^20)
    expect_identical(more$r_projection_fixed_bytes - got$r_projection_fixed_bytes, 2 * (as.double(object.size(wider$.description)) - as.double(object.size(m$.description))))
    bad <- m
    bad$path <- new.env(parent = emptyenv())
    expect_error(projection_owner_inventory(bad, entry, facts, p, 64 * 2^20, 2^20), class = "relm_error_intervention")
    expect_error(projection_owner_inventory(m, entry, facts, p, 2^20, 2^20), class = "relm_error_oom")
})
test_that("projection candidate wraps an independent un-hashed state and shares unchanged entries", {
    m <- projection_owner_model()
    m$state$closed <- TRUE
    m$state$ptr <- m$ptr
    entry <- projection_owner_entry()
    ptr <- new("externalptr")
    derived <- projection_new_llm(m, ptr, entry, 64 * 2^20, 2^20)
    derived$state$closed <- TRUE
    expect_null(env.profile(derived$state))
    expect_identical(parent.env(derived$state), emptyenv())
    expect_identical(sort(ls(derived$state, all.names = TRUE)), c("closed", "ptr"))
    expect_false(identical(derived$state, m$state))
    expect_identical(derived$state$ptr, ptr)
    expect_identical(derived$interventions, list(entry))
    expect_length(m$interventions, 0L)
    expect_null(attr(m, "projection", exact = TRUE))
    expect_identical(projection_owner_settings(derived), list(max_bytes = 64 * 2^20, existing_direction_estimate = 2^20))
    for (name in projection_model_fields[!projection_model_fields %in% c("ptr", "state", "interventions")]) expect_identical(derived[[name]], m[[name]])
    next_entry <- entry
    next_entry$component <- "attn_out"
    facts <- list(hash_slots = 0, bindings = 2, c_finalizer_bytes = 8)
    inventory <- projection_owner_inventory(derived, next_entry, facts, projection_test_profile(), 64 * 2^20, 2^20)
    expect_identical(inventory$counts$previous_sites, 1)
    expect_identical(inventory$state_extra_bytes, 992)
    bad <- derived
    attr(bad, "projection")$hidden <- raw(100)
    expect_error(projection_owner_settings(bad), class = "relm_error_intervention")
})
