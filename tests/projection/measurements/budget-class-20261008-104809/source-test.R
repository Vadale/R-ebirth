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
test_that("projection transport covers OOM fields and the bounded intervention alternative", {
    oom <- list(ok = FALSE, class = "relm_error_oom", message = "Projection owners and working copies exceed max_bytes. Reduce projection sites or increase max_bytes.", fields = list(estimate_bytes = 1520411, budget_bytes = 1520410))
    for (width in c(64, 150, 256)) {
        p <- projection_test_profile()
        p$error_format_bytes <- width
        intervention <- list(ok = FALSE, class = "relm_error_intervention", message = strrep("x", width), fields = list(reason = strrep("x", width)))
        fixed <- projection_transport_bytes(p)
        expect_gte(fixed$failure, as.double(utils::object.size(oom)))
        expect_gte(fixed$failure, as.double(utils::object.size(intervention)))
        expect_identical(fixed$failure, max(as.double(utils::object.size(oom)), as.double(utils::object.size(intervention))))
        expect_identical(fixed$total, sum(unlist(fixed[names(fixed) != "total"])))
    }
})
