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
test_that("projection scalar scan refuses hidden owners duplicate sites and nonfinite scaling", {
    iv <- projection_owner_entry()
    good <- projection_owner_scan(list(), iv, 3L, 4L)
    expect_identical(good$previous_sites, 0)
    expect_error(projection_owner_scan(list(iv), iv, 3L, 4L), class = "relm_error_intervention")
    second <- iv
    second$component <- "attn_out"
    expect_identical(projection_owner_scan(list(iv), second, 3L, 4L)$previous_sites, 1)
    for (key in c("names_attribute", "direction_attribute", "norm", "layer", "component")) {
        bad <- iv
        if (key == "names_attribute") 
            bad <- structure(bad, names = structure(names(bad), hidden = raw(4096)))
        if (key == "direction_attribute") 
            names(bad$direction) <- letters[1:3]
        if (key == "norm") 
            bad$direction[[1]] <- 2
        if (key == "layer") 
            bad$layer <- 0L
        if (key == "component") 
            bad$component <- "residual"
        expect_error(projection_owner_scan(list(), bad, 3L, 4L), class = "relm_error_intervention")
    }
    s <- list(kind = "steer", layer = 2L, direction = rep(3e+38, 3), coef = 2, positions = "all")
    expect_error(projection_owner_scan(list(), s, 3L, 4L), class = "relm_error_intervention")
    a <- list(kind = "ablate", layer = 2L, neurons = c(2L, 1L), value = 0, component = "residual")
    expect_error(projection_owner_scan(list(), a, 3L, 4L), class = "relm_error_intervention")
})
