# D046: independent R admission arithmetic. No helper in this file arms a model.
projection_profile_fields <- c("version", "direction_arc_header_bytes", "plan_arc_bytes",
  "site_bytes", "runtime_bytes", "probe_state_bytes", "model_owner_bytes",
  "derive_frame_bytes", "callback_frame_bytes", "probe_frame_bytes", "residual_probe_fixed_bytes", "ffi_fixed_bytes",
  "adapter_fixed_bytes", "error_format_bytes", "metadata_owner_bytes", "slot_bytes",
  "proof_bytes", "projection_info_bytes", "cpp_access_frame_bytes", "cpp_name_frame_bytes",
  "ffi_command_bytes", "ffi_response_bytes", "ffi_registry_bytes", "ffi_handle_tag_bytes",
  "layout_checksum", "max_sites", "max_width")
projection_input_fields <- c("mode", "hidden_size", "layers", "previous_sites",
  "steer_entries", "ablate_entries", "source_baseline_values", "metadata_bytes",
  "metadata_scratch_bytes", "existing_direction_estimate", "r_projection_fixed_bytes",
  "r_adapter_bytes", "max_bytes", "backend", "production_armed")
projection_term_fields <- c("direction_bytes", "plan_bytes", "context_bytes", "frame_bytes",
  "probe_bytes", "projection_bytes", "residual_probe_bytes", "adapter_data_bytes", "adapter_fixed_bytes",
  "metadata_bytes", "r_projection_bytes", "r_adapter_bytes", "existing_direction_estimate",
  "total_bytes")
projection_config_fields <- c("mode", "layer", "component", "coef", "direction",
  "steer_entries", "ablate_entries", "existing_direction_estimate",
  "r_projection_fixed_bytes", "r_adapter_bytes", "max_bytes")

projection_memory_fail <- function() {
  direction_fail("projection_allocation", "Invalid or inexact projection allocation profile, inputs or response.")
}

# Validate names themselves, too: attributes on the names vector can retain an
# unrelated owner that ordinary list-level validation would miss.
projection_record <- function(x, fields) {
  if (!is.list(x) || is.object(x) || !identical(names(attributes(x)), "names") ||
      !is.null(attributes(names(x))) || !identical(names(x), fields)) projection_memory_fail()
  invisible(x)
}

projection_uint <- function(x, upper = 2^53 - 1) {
  if (!direction_number(x, 0, upper)) projection_memory_fail()
  as.double(x)
}

projection_add <- function(...) {
  total <- 0
  for (value in list(...)) {
    value <- projection_uint(value)
    if (value > (2^53 - 1) - total) projection_memory_fail()
    total <- total + value
  }
  total
}

projection_mul <- function(a, b) {
  a <- projection_uint(a); b <- projection_uint(b)
  if (b > 0 && a > floor((2^53 - 1) / b)) projection_memory_fail()
  a * b
}

projection_numeric_record <- function(x, fields) {
  projection_record(x, fields)
  for (name in fields) projection_uint(x[[name]])
  invisible(x)
}

projection_profile_validate <- function(p) {
  projection_numeric_record(p, projection_profile_fields)
  if (p$version != 2 || p$max_sites != 32 || p$max_width != 65536 ||
      p$direction_arc_header_bytes < 2 * .Machine$sizeof.pointer ||
      p$metadata_owner_bytes != 0 || p$ffi_handle_tag_bytes > 1024 ||
      p$layout_checksum >= 2^52) projection_memory_fail()
  for (key in setdiff(projection_profile_fields,
      c("metadata_owner_bytes", "ffi_registry_bytes", "layout_checksum"))) {
    if (p[[key]] == 0) projection_memory_fail()
  }
  if (p$runtime_bytes < 32 * p$proof_bytes ||
      p$callback_frame_bytes < 2 * p$projection_info_bytes +
        p$cpp_access_frame_bytes + p$cpp_name_frame_bytes ||
      p$ffi_fixed_bytes < p$ffi_response_bytes + p$ffi_registry_bytes ||
      p$derive_frame_bytes < p$ffi_command_bytes) projection_memory_fail()
  invisible(p)
}

# This is deliberately independent of the native expression tree: enumerate
# unique payload owners first, then their descriptors and the transient probe.
projection_memory_bound <- function(profile, inputs) {
  projection_profile_validate(profile)
  projection_numeric_record(inputs, projection_input_fields)
  p <- profile; i <- inputs
  if (!i$mode %in% 0:1 || !i$backend %in% 0:2 || !i$production_armed %in% 0:1 ||
      i$hidden_size < 1 || i$hidden_size > p$max_width ||
      i$layers < 1 || i$layers > .Machine$integer.max ||
      i$previous_sites > p$max_sites || i$previous_sites + i$mode > p$max_sites ||
      i$max_bytes < 1 || i$max_bytes > 512 * 2^20) projection_memory_fail()
  h <- i$hidden_size; depth <- i$layers; old <- i$previous_sites; new <- i$mode
  sites <- old + new
  out <- setNames(as.list(rep(0, length(projection_term_fields))), projection_term_fields)
  if (sites > 0) {
    directions <- projection_mul(sites, projection_add(projection_mul(h, 8), p$direction_arc_header_bytes))
    plan_owners <- if (new == 0) 1 else 1 + (old > 0)
    entry_owners <- if (new == 0) old else old + sites
    runtime_owners <- if (new == 0) 2 else plan_owners
    plans <- projection_add(projection_mul(plan_owners, p$plan_arc_bytes),
      projection_mul(entry_owners, p$site_bytes))
    contexts <- projection_add(projection_mul(runtime_owners, p$runtime_bytes),
      projection_mul(projection_mul(runtime_owners, h), 4), projection_mul(2, p$model_owner_bytes))
    frames <- projection_add(p$derive_frame_bytes, p$callback_frame_bytes,
      p$ffi_fixed_bytes, p$error_format_bytes)
    probe <- projection_add(projection_mul(h, 20), p$direction_arc_header_bytes,
      p$plan_arc_bytes, p$site_bytes, p$runtime_bytes, p$probe_state_bytes,
      p$model_owner_bytes, p$probe_frame_bytes)
    out$direction_bytes <- directions; out$plan_bytes <- plans
    out$context_bytes <- contexts; out$frame_bytes <- frames; out$probe_bytes <- probe
    out$projection_bytes <- projection_add(directions, plans, contexts, frames, probe)
    # H is positive and bounded: 8H is a multiple of 8, with R's small pools.
    row_growth <- live_r_vector_bytes(projection_mul(8, h)) - 48
    out$r_projection_bytes <- projection_add(i$r_projection_fixed_bytes,
      projection_mul(old + 2 * new, row_growth))
  }
  hd <- projection_mul(h, depth)
  # The sequential uncached residual sentinels own two dense F32 buffers,
  # one H-wide row and their compiled scalar-capture/context descriptors.
  # This separate conservative charge applies whenever either kind is requested.
  if (i$steer_entries > 0 || i$ablate_entries > 0) {
    out$residual_probe_bytes <- projection_add(projection_mul(8, hd),
      projection_mul(4, h), p$residual_probe_fixed_bytes)
  }
  source_baseline <- projection_mul(4, i$source_baseline_values)
  steer <- if (i$steer_entries > 0) projection_add(projection_mul(8, hd),
    projection_mul(4, h), projection_mul(projection_mul(8, h), i$steer_entries),
    projection_mul(4, i$steer_entries)) else 0
  ablate <- if (i$ablate_entries > 0) projection_add(projection_mul(8, hd),
    projection_mul(16, i$ablate_entries)) else 0
  out$adapter_data_bytes <- projection_add(source_baseline, steer, ablate)
  out$adapter_fixed_bytes <- p$adapter_fixed_bytes
  out$metadata_bytes <- projection_add(i$metadata_bytes, i$metadata_scratch_bytes, p$metadata_owner_bytes)
  out$r_adapter_bytes <- i$r_adapter_bytes
  out$existing_direction_estimate <- i$existing_direction_estimate
  out$total_bytes <- projection_add(out$projection_bytes, out$residual_probe_bytes, out$adapter_data_bytes,
    out$adapter_fixed_bytes, out$metadata_bytes, out$r_projection_bytes,
    out$r_adapter_bytes, out$existing_direction_estimate)
  if (out$total_bytes > i$max_bytes) {
    relm_abort("relm_error_oom", "Projection owners and working copies exceed max_bytes.",
      list(reason = "projection_allocation", estimate_bytes = out$total_bytes, budget_bytes = i$max_bytes))
  }
  out
}

projection_config_validate <- function(config, hidden_size, layers) {
  projection_record(config, projection_config_fields)
  projection_uint(hidden_size, 65536); projection_uint(layers, .Machine$integer.max)
  if (hidden_size == 0 || layers == 0 || !direction_text(config$mode) ||
      !config$mode %in% c("new_site", "inherit") || !direction_text(config$component) ||
      !config$component %in% c("mlp_out", "attn_out") ||
      !direction_number(config$coef, -3.4028234663852886e38, 3.4028234663852886e38, FALSE) ||
      !is.double(config$direction) || !is.null(attributes(config$direction))) projection_memory_fail()
  for (key in c("layer", projection_config_fields[6:11])) projection_uint(config[[key]])
  if (config$max_bytes < 2^20 || config$max_bytes > 512 * 2^20) projection_memory_fail()
  if (config$mode == "inherit") {
    if (config$layer != 0 || config$component != "mlp_out" || config$coef != 0 ||
        length(config$direction) != 0) projection_memory_fail()
  } else {
    if (config$layer < 1 || config$layer > layers || length(config$direction) != hidden_size) projection_memory_fail()
    norm <- 0
    for (coordinate in seq_along(config$direction)) {
      x <- config$direction[[coordinate]]
      if (!is.finite(x)) projection_memory_fail()
      norm <- norm + x * x
    }
    if (!is.finite(norm) || abs(sqrt(norm) - 1) > 1e-12) projection_memory_fail()
  }
  invisible(config)
}

projection_response_validate <- function(response, config, hidden_size, layers,
                                         previous_sites, backend, profile) {
  projection_record(response, c("ok", "armed", "profile", "inputs", "terms"))
  if (!identical(response$ok, TRUE) || !identical(response$armed, FALSE)) projection_memory_fail()
  projection_config_validate(config, hidden_size, layers)
  projection_profile_validate(profile)
  projection_profile_validate(response$profile)
  # The registry is dynamic; obtain this profile for this call, never cache it.
  if (!identical(response$profile, profile)) projection_memory_fail()
  i <- response$inputs
  projection_numeric_record(i, projection_input_fields)
  want <- list(mode = as.double(config$mode == "new_site"), hidden_size = as.double(hidden_size),
    layers = as.double(layers), previous_sites = as.double(previous_sites),
    steer_entries = config$steer_entries, ablate_entries = config$ablate_entries,
    existing_direction_estimate = config$existing_direction_estimate,
    r_projection_fixed_bytes = config$r_projection_fixed_bytes, r_adapter_bytes = config$r_adapter_bytes,
    max_bytes = config$max_bytes, backend = as.double(backend), production_armed = 1,
    metadata_bytes = 0, metadata_scratch_bytes = 0)
  for (name in names(want)) if (i[[name]] != want[[name]]) projection_memory_fail()
  if (i$source_baseline_values > 0 && config$steer_entries == 0) projection_memory_fail()
  projection_numeric_record(response$terms, projection_term_fields)
  expected <- projection_memory_bound(profile, i)
  for (name in projection_term_fields) if (response$terms[[name]] != expected[[name]]) projection_memory_fail()
  invisible(expected)
}

projection_r_fingerprint <- function() {
  ns <- c(0L, 1L, 2L, 3L, 4L, 5L, 8L, 9L, 16L, 17L, 33L)
  actual <- vapply(ns, function(n) as.double(utils::object.size(double(n))), numeric(1))
  if (.Machine$sizeof.pointer != 8L || !identical(actual, live_r_vector_bytes(8 * ns)) ||
      as.double(utils::object.size(new("externalptr"))) != 64 ||
      as.double(utils::object.size(new.env(hash = FALSE, parent = emptyenv()))) != 56 ||
      as.double(utils::object.size(pairlist(a = 0, b = 0))) != 336) projection_memory_fail()
  actual
}

# Fixed transport objects are measured, not inferred from an arbitrary reserve.
# Source/candidate model/record skeletons and residual working copies are supplied
# by the constructor separately; this function accounts only for the boundary.
projection_transport_bytes <- function(profile) {
  projection_profile_validate(profile)
  projection_r_fingerprint()
  zeros <- function(fields) setNames(as.list(rep(0, length(fields))), fields)
  response <- list(ok = TRUE, armed = FALSE, profile = profile,
    inputs = zeros(projection_input_fields), terms = zeros(projection_term_fields))
  command <- list(mode = "new_site", layer = 0, component = "attn_out", coef = 0,
    direction = double(), steer_entries = 0, ablate_entries = 0,
    existing_direction_estimate = 0, r_projection_fixed_bytes = 0, r_adapter_bytes = 0, max_bytes = 0)
  failure <- as.double(utils::object.size(list(ok = FALSE, class = "relm_error_intervention",
    message = strrep("x", profile$error_format_bytes),
    fields = list(reason = strrep("x", profile$error_format_bytes)))))
  oom_failure <- as.double(utils::object.size(list(ok = FALSE, class = "relm_error_oom",
    message = paste0("Projection owners and working copies exceed max_bytes. ",
      "Reduce projection sites or increase max_bytes."),
    fields = list(estimate_bytes = 0, budget_bytes = 0))))
  # The constructor uses empty 64-byte external-pointer skeletons. Populated
  # pointers include their tags in object.size; charge the two tag vectors and
  # one identity-verified interned type name explicitly over the empty skeletons.
  tags <- projection_add(2 * live_r_vector_bytes(8),
    live_r_vector_bytes(projection_add(profile$ffi_handle_tag_bytes, 1)))
  fixed <- list(profile = as.double(utils::object.size(profile)),
    response = as.double(utils::object.size(response)),
    command = as.double(utils::object.size(command)),
    failure = max(failure, oom_failure), tags = tags)
  fixed$total <- do.call(projection_add, fixed)
  fixed
}
