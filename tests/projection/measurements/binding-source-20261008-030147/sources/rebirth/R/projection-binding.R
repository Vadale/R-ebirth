# Internal D046 binding. No exported operator calls this path yet. The native
# constructor entry is unavailable in default builds until combined acceptance.

# Named, measured fixed materializations for the new workflow. The H-dependent
# payloads remain in the independent direction/adapter terms. These prototypes
# cover the preparation envelope, response-twin/matching records, handle-only
# result, and the inventory's two temporary shallow model/entry skeletons.
# Sum their lifetimes conservatively; this is not an allocator/RSS reserve.
projection_binding_workspace <- function(profile) {
  projection_profile_validate(profile)
  numeric_record <- function(fields) setNames(as.list(rep(0, length(fields))), fields)
  model <- structure(setNames(vector("list", length(projection_model_fields)),
    projection_model_fields), class = "llm")
  model$ptr <- new("externalptr")
  model$state <- new.env(hash = FALSE, parent = emptyenv())
  attr(model, "projection") <- list(max_bytes = 0, existing_direction_estimate = 0)
  owners <- list(
    terms = numeric_record(projection_term_fields),
    input_match = numeric_record(projection_input_fields),
    preparation = list(config = NULL, inventory = NULL, profile = NULL,
      response = NULL, workspace_bytes = 0),
    result = list(ok = TRUE, ptr = new("externalptr")),
    source_measurement = model, candidate_measurement = model,
    scan_entry = list(kind = "project", layer = 0L, component = "attn_out",
      direction = double(), coef = 0))
  projection_owner_size(owners)
}

projection_prepare <- function(m, entry, max_bytes, existing_direction_estimate) {
  budget <- direction_budget(max_bytes)
  existing_direction_estimate <- projection_uint(existing_direction_estimate)
  if (!is.list(m) || !identical(class(m), "llm") ||
      !identical(names(m), projection_model_fields) ||
      !is.null(attributes(names(m))) || typeof(m$ptr) != "externalptr" ||
      !is.environment(m$state)) projection_memory_fail()
  # The native state query rejects active bindings/promises before inspecting
  # their values. Do not substitute ensure_open()/env.profile() on this path.
  profile <- relm_check(rebirth_projection_allocation_profile())
  projection_profile_validate(profile)
  facts <- relm_check(rebirth_projection_state_facts(m$state, m$ptr))
  inventory <- projection_owner_inventory(m, entry, facts, profile, budget,
    existing_direction_estimate)
  settings <- projection_owner_settings(m)
  new <- identical(entry$kind, "project")
  if (!new && (is.null(settings) || settings$max_bytes != budget ||
      settings$existing_direction_estimate != existing_direction_estimate)) projection_memory_fail()
  workspace_bytes <- projection_binding_workspace(profile)
  config <- list(mode = if (new) "new_site" else "inherit",
    layer = if (new) as.double(entry$layer) else 0,
    component = if (new) entry$component else "mlp_out",
    coef = if (new) as.double(entry$coef) else 0,
    direction = if (new) entry$direction else double(),
    steer_entries = inventory$counts$steer_entries,
    ablate_entries = inventory$counts$ablate_entries,
    existing_direction_estimate = existing_direction_estimate,
    r_projection_fixed_bytes = projection_add(inventory$r_projection_fixed_bytes, workspace_bytes),
    r_adapter_bytes = inventory$r_adapter_bytes, max_bytes = budget)
  projection_config_validate(config, m$hidden_size, m$layers)
  direction_admit(projection_add(config$r_projection_fixed_bytes, config$r_adapter_bytes,
    existing_direction_estimate), budget)
  response <- relm_check(rebirth_projection_preflight(m$ptr, config))
  backend <- match(m$backend, c("cpu", "metal", "cuda")) - 1L
  if (is.na(backend)) projection_memory_fail()
  projection_response_validate(response, config, m$hidden_size, m$layers,
    inventory$counts$previous_sites, backend, profile)
  list(config = config, inventory = inventory, profile = profile,
    response = response, workspace_bytes = workspace_bytes)
}

projection_derive <- function(m, entry, max_bytes, existing_direction_estimate) {
  prepared <- projection_prepare(m, entry, max_bytes, existing_direction_estimate)
  # Allocate scaled residual arrays only after the combined authoritative/R twin
  # has admitted all owners. The native constructor repeats current-source and
  # dynamic-registry admission before any native copy or context creation.
  arrays <- projection_flatten(m$interventions, entry, m$hidden_size,
    prepared$inventory$counts)
  if (projection_owner_size(arrays) !=
      projection_flat_bytes(prepared$inventory$counts, m$hidden_size)) projection_memory_fail()
  payload <- relm_check(rebirth_projection_construct(m$ptr, prepared$config,
    arrays$steer_layers, arrays$steer_vectors, arrays$ablate_layers,
    arrays$ablate_neurons, arrays$ablate_values))
  complete <- FALSE
  on.exit(if (!complete && is.list(payload) && typeof(payload$ptr) == "externalptr")
    try(rebirth_handle_close(payload$ptr), silent = TRUE), add = TRUE)
  projection_record(payload, c("ok", "ptr"))
  if (!identical(payload$ok, TRUE) || typeof(payload$ptr) != "externalptr") projection_memory_fail()
  result <- projection_new_llm(m, payload$ptr, entry, prepared$config$max_bytes,
    prepared$config$existing_direction_estimate)
  complete <- TRUE
  result
}
