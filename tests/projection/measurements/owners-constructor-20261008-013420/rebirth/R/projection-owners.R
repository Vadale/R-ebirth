# D046 constructor-owned R materialization. Internal and not publicly armed.
# State facts must come from the bounded native R-host query, not env.profile().
projection_model_fields <- c("ptr", "state", "path", "architecture", "parameters",
  "quantization", "layers", "hidden_size", "context_length", "backend", "projector",
  "vision", "interventions", ".context_train", ".size_bytes", ".vocab_size", ".description")

projection_owner_size <- function(x) as.double(utils::object.size(x))

projection_owner_settings <- function(m) {
  settings <- attr(m, "projection", exact = TRUE)
  if (is.null(settings)) return(NULL)
  projection_record(settings, c("max_bytes", "existing_direction_estimate"))
  direction_budget(settings$max_bytes)
  projection_uint(settings$existing_direction_estimate)
  settings
}

projection_state_bytes <- function(facts) {
  projection_numeric_record(facts, c("hash_slots", "bindings", "c_finalizer_bytes"))
  if (facts$bindings != 2 || facts$c_finalizer_bytes != .Machine$sizeof.pointer) projection_memory_fail()
  projection_r_fingerprint()
  # R's NewWeakRef allocates a four-slot vector; MakeCFinalizer allocates a
  # raw vector of sizeof(R_CFinalizer_t). Shared package finalizer closures
  # are not duplicated per handle. Binding cells and symbols are conservative.
  node <- projection_owner_size(pairlist(NULL))
  weak <- projection_owner_size(vector("list", 4L))
  if (node != 56 || weak != live_r_vector_bytes(32)) projection_memory_fail()
  hash <- if (facts$hash_slots == 0) 0 else live_r_vector_bytes(projection_mul(8, facts$hash_slots))
  projection_add(hash, 2 * node, 2 * projection_owner_size(as.name("ptr")),
    projection_owner_size(FALSE), 2 * weak, live_r_vector_bytes(facts$c_finalizer_bytes))
}

projection_entry_validate <- function(iv, h, depth) {
  if (!is.list(iv) || length(iv) < 1 || !direction_text(iv$kind)) projection_memory_fail()
  if (iv$kind == "steer") {
    projection_record(iv, c("kind", "layer", "direction", "coef", "positions"))
    if (!identical(iv$positions, "all") || !is.double(iv$direction) ||
        !is.null(attributes(iv$direction)) || length(iv$direction) != h ||
        !direction_number(iv$coef, -3.4028234663852886e38, 3.4028234663852886e38, FALSE)) projection_memory_fail()
    for (j in seq_len(h)) {
      value <- iv$direction[[j]]
      if (!is.finite(value) || !is.finite(value * iv$coef) ||
          abs(value * iv$coef) > 3.4028234663852886e38) projection_memory_fail()
    }
    low <- 2
  } else if (iv$kind == "ablate") {
    projection_record(iv, c("kind", "layer", "neurons", "value", "component"))
    if (!identical(iv$component, "residual") || !is.integer(iv$neurons) ||
        !is.null(attributes(iv$neurons)) || length(iv$neurons) > h ||
        !direction_number(iv$value, -3.4028234663852886e38, 3.4028234663852886e38, FALSE)) projection_memory_fail()
    previous <- 0L
    for (j in seq_along(iv$neurons)) {
      value <- iv$neurons[[j]]
      if (is.na(value) || value <= previous || value > h) projection_memory_fail()
      previous <- value
    }
    low <- 1
  } else if (iv$kind == "project") {
    projection_record(iv, c("kind", "layer", "component", "direction", "coef"))
    if (!direction_text(iv$component) || !iv$component %in% c("mlp_out", "attn_out") ||
        !is.double(iv$direction) || !is.null(attributes(iv$direction)) ||
        length(iv$direction) != h ||
        !direction_number(iv$coef, -3.4028234663852886e38, 3.4028234663852886e38, FALSE)) projection_memory_fail()
    norm <- 0
    for (j in seq_len(h)) {
      value <- iv$direction[[j]]
      if (!is.finite(value)) projection_memory_fail()
      norm <- norm + value * value
    }
    if (!is.finite(norm) || abs(sqrt(norm) - 1) > 1e-12) projection_memory_fail()
    low <- 1
  } else projection_memory_fail()
  if (!is.integer(iv$layer) || !direction_number(iv$layer, low, depth)) projection_memory_fail()
  invisible(iv)
}

# Scalar scan, with no second complete intervention list or scaled H-vector.
projection_owner_scan <- function(interventions, entry, h, depth) {
  if (!is.list(interventions) || !is.null(attributes(interventions))) projection_memory_fail()
  projection_uint(h, 65536); projection_uint(depth, .Machine$integer.max)
  if (h < 1 || depth < 1) projection_memory_fail()
  count <- length(interventions)
  out <- list(steer_entries = 0, ablate_entries = 0, previous_sites = 0,
    residual_records = 0, projection_records = 0)
  # At most 32 fixed-size site identifiers; do not grow a list with each entry.
  site_layers <- integer(32L); site_components <- integer(32L)
  for (at in seq_len(count + 1L)) {
    iv <- if (at <= count) interventions[[at]] else entry
    projection_entry_validate(iv, h, depth)
    if (iv$kind == "steer") {
      out$steer_entries <- projection_add(out$steer_entries, 1)
      out$residual_records <- projection_add(out$residual_records, projection_owner_size(iv))
    } else if (iv$kind == "ablate") {
      out$ablate_entries <- projection_add(out$ablate_entries, length(iv$neurons))
      out$residual_records <- projection_add(out$residual_records, projection_owner_size(iv))
    } else {
      site <- as.integer(out$previous_sites) + 1L
      if (site > 32L) projection_memory_fail()
      component <- if (iv$component == "mlp_out") 0L else 1L
      for (j in seq_len(site - 1L)) {
        if (site_layers[[j]] == iv$layer && site_components[[j]] == component) projection_memory_fail()
      }
      site_layers[[site]] <- iv$layer; site_components[[site]] <- component
      # Replacing only this borrowed record's vector creates a bounded shallow
      # skeleton; the H payload remains on the caller's unchanged record.
      skeleton <- iv; skeleton$direction <- double()
      out$projection_records <- projection_add(out$projection_records, projection_owner_size(skeleton))
      if (at <= count) out$previous_sites <- projection_add(out$previous_sites, 1)
    }
  }
  out
}

# Allocate each of the five boundary arrays once. The scalar fill preserves
# accumulated order, steering sums and last-write-wins ablation semantics.
projection_flatten <- function(interventions, entry, h, counts) {
  s <- counts$steer_entries; a <- counts$ablate_entries
  total <- projection_mul(s, h)
  if (max(s, a, total) > .Machine$integer.max) projection_memory_fail()
  steer_layers <- integer(s); steer_vectors <- double(total)
  ablate_layers <- integer(a); ablate_neurons <- integer(a); ablate_values <- double(a)
  si <- 0L; ai <- 0L
  for (at in seq_len(length(interventions) + 1L)) {
    iv <- if (at <= length(interventions)) interventions[[at]] else entry
    if (iv$kind == "steer") {
      si <- si + 1L
      if (si > s) projection_memory_fail()
      steer_layers[[si]] <- iv$layer
      for (j in seq_len(h)) steer_vectors[[(si - 1) * h + j]] <- iv$coef * iv$direction[[j]]
    } else if (iv$kind == "ablate") {
      for (j in seq_along(iv$neurons)) {
        ai <- ai + 1L
        if (ai > a) projection_memory_fail()
        ablate_layers[[ai]] <- iv$layer; ablate_neurons[[ai]] <- iv$neurons[[j]]
        ablate_values[[ai]] <- iv$value
      }
    }
  }
  if (si != s || ai != a) projection_memory_fail()
  list(steer_layers = steer_layers, steer_vectors = steer_vectors,
    ablate_layers = ablate_layers, ablate_neurons = ablate_neurons, ablate_values = ablate_values)
}

projection_flat_bytes <- function(counts, h) {
  empty <- list(steer_layers = integer(), steer_vectors = double(),
    ablate_layers = integer(), ablate_neurons = integer(), ablate_values = double())
  s <- counts$steer_entries; a <- counts$ablate_entries
  lengths <- c(projection_mul(4, s), projection_mul(projection_mul(8, s), h),
    projection_mul(4, a), projection_mul(4, a), projection_mul(8, a))
  projection_add(projection_owner_size(empty), sum(live_r_vector_bytes(lengths) - 48))
}

# Inventory only: no context, pointer, finalizer registration or public arming.
# Native must validate the real state and recheck authoritative counts/budget.
projection_owner_inventory <- function(m, entry, facts, profile, max_bytes,
                                       existing_direction_estimate) {
  budget <- direction_budget(max_bytes)
  if (!is.list(m) || !identical(class(m), "llm") ||
      !(setequal(names(attributes(m)), c("names", "class")) ||
        setequal(names(attributes(m)), c("names", "class", "projection"))) ||
      !is.null(attributes(names(m))) ||
      !identical(names(m), projection_model_fields)) projection_memory_fail()
  settings <- projection_owner_settings(m)
  for (name in projection_model_fields[!projection_model_fields %in% c("ptr", "state", "interventions")]) {
    value <- m[[name]]
    if (is.null(value) && name == "projector") next
    if (!typeof(value) %in% c("character", "double", "integer", "logical") ||
        length(value) != 1L || !is.null(attributes(value))) projection_memory_fail()
  }
  counts <- projection_owner_scan(m$interventions, entry, m$hidden_size, m$layers)
  if ((counts$previous_sites > 0) != !is.null(settings)) projection_memory_fail()
  direction_admit(projection_add(counts$residual_records, counts$projection_records,
    existing_direction_estimate), budget)
  # Metadata is shared, but measured twice conservatively. Environments are
  # replaced by empty un-hashed skeletons; their missing storage is added below.
  skeleton <- m
  skeleton$ptr <- new("externalptr")
  skeleton$state <- new.env(hash = FALSE, parent = emptyenv())
  skeleton$interventions <- list()
  candidate <- skeleton
  attr(candidate, "projection") <- list(max_bytes = budget,
    existing_direction_estimate = projection_uint(existing_direction_estimate))
  model_fixed <- projection_add(projection_owner_size(skeleton), projection_owner_size(candidate))
  roots <- projection_add(live_r_vector_bytes(8 * length(m$interventions)) - 48,
    live_r_vector_bytes(8 * (length(m$interventions) + 1)) - 48)
  transport <- projection_transport_bytes(profile)
  states <- projection_add(projection_state_bytes(facts),
    projection_state_bytes(list(hash_slots = 0, bindings = 2, c_finalizer_bytes = facts$c_finalizer_bytes)))
  # The scan's two 32-slot integer arrays, count record, and native fact record
  # have real prototypes. Their payloads never scale with the hidden width.
  scan_fixed <- projection_add(2 * projection_owner_size(integer(32L)),
    projection_owner_size(counts), projection_owner_size(facts))
  receipt <- list(r_projection_fixed_bytes = 0, r_adapter_bytes = 0,
    counts = counts, model_skeleton_bytes = 0, state_extra_bytes = 0,
    intervention_root_growth_bytes = 0, scan_bytes = 0, transport = transport)
  scan_fixed <- projection_add(scan_fixed, projection_owner_size(receipt))
  fixed <- projection_add(model_fixed, roots, transport$total, states,
    scan_fixed, counts$projection_records)
  adapter <- projection_add(counts$residual_records, projection_flat_bytes(counts, m$hidden_size))
  direction_admit(projection_add(existing_direction_estimate, fixed, adapter), budget)
  list(r_projection_fixed_bytes = fixed, r_adapter_bytes = adapter,
    counts = counts, model_skeleton_bytes = model_fixed, state_extra_bytes = states,
    intervention_root_growth_bytes = roots, scan_bytes = scan_fixed,
    transport = transport)
}

# The exact candidate shape used by the inventory. It is internal until the
# complete native transfer is enabled. Metadata and old entry objects are
# shared; only one N+1 reference list and a two-binding un-hashed state are new.
projection_new_llm <- function(m, ptr, entry, max_bytes, existing_direction_estimate) {
  if (typeof(ptr) != "externalptr") projection_memory_fail()
  complete <- FALSE
  on.exit(if (!complete) try(rebirth_handle_close(ptr), silent = TRUE), add = TRUE)
  settings <- list(max_bytes = direction_budget(max_bytes),
    existing_direction_estimate = projection_uint(existing_direction_estimate))
  state <- new.env(hash = FALSE, parent = emptyenv())
  state$closed <- FALSE; state$ptr <- ptr
  interventions <- vector("list", length(m$interventions) + 1L)
  for (at in seq_along(m$interventions)) interventions[[at]] <- m$interventions[[at]]
  interventions[[length(interventions)]] <- entry
  result <- m
  result$ptr <- ptr; result$state <- state; result$interventions <- interventions
  attr(result, "projection") <- settings
  reg.finalizer(state, finalize_llm_state, onexit = TRUE)
  complete <- TRUE
  result
}
