# Interventions (WP5, D-016): llm_steer() and llm_ablate() return a NEW llm
# handle -- a fresh context on the source model's shared, read-only weights, with
# the accumulated steering / ablation spec applied. The source handle is never
# mutated (reversibility = use the original object, D-003 / API-GRAMMAR section 2).

# Architecture support is NOT gated in R (D-021): the engine runs a runtime sentinel
# probe inside derive_with_interventions (probe.rs) that proves steering and ablation
# actually take effect on THIS model at the requested layers, raising
# rebirth_error_intervention (never a silent no-op) otherwise -- so any
# standard-residual decoder works, without a hand-maintained allow-list.
#
# This constant is DOCUMENTATION ONLY; it does NOT gate anything. It names the
# "behaviorally validated" tier: architectures that, beyond passing the runtime
# probe, also carry a committed WP5 intervention acceptance fixture -- llama via the
# exact numerical oracle (synthetic_intervene.rs), qwen2 via the [MODEL] valence +
# KL fixtures on Qwen2.5-0.5B. Surfaced by ?llm_steer / the model matrix; any other
# architecture still works when the probe passes, it is simply not (yet) in this
# fixture-backed tier.
INTERVENTION_VALIDATED_ARCHS <- c("llama", "qwen2")

#' Steer a model along a direction
#'
#' Returns a **new** `llm` handle that adds `coef * direction` to the residual
#' stream at `layer` during every subsequent forward pass (`llm_generate()`,
#' `llm_logits()`). The original handle is untouched: to remove the steering, use
#' the original object (reversibility is exact, D-003). Interventions compose --
#' see Details.
#'
#' @details
#' Steering is llama.cpp's native control-vector mechanism: a per-layer,
#' `hidden_size`-wide vector added to the residual at `layer`'s output, for **all
#' token positions** (hence `positions = "all"` is the only supported value in this
#' release; a position subset raises `rebirth_error_intervention`).
#'
#' **Composition.** Deriving from an already-steered or ablated handle carries its
#' full spec forward and adds the new one, then builds a single fresh context from
#' the original weights (contexts are never chained). Steering **stacks by
#' summation** -- two steers on the same layer add -- and the semantics are
#' **derivation-order-independent**: `m |> llm_steer(...) |> llm_ablate(...)`
#' produces the same forward pass as `m |> llm_ablate(...) |> llm_steer(...)`. A
#' steer never moves an ablated neuron: at the graph the ablation runs after the
#' steer (`(x + steer) * mask + add`), so a jointly steered-and-ablated neuron is
#' forced to the ablation `value` (D-016).
#'
#' **Layer 1 is not steerable.** The native control vector reserves engine index 0
#' and has no slot for the first transformer block, so `layer = 1` raises
#' `rebirth_error_intervention`. Steer a later layer (`2:m$layers`), or ablate
#' layer 1 with [llm_ablate()] (ablation covers every layer).
#'
#' **Not free.** Each `llm_steer()`/`llm_ablate()` call allocates a fresh context
#' on the shared weights -- a sub-second pause and real memory (its own KV cache,
#' ~hundreds of MB on the demo models), not a cheap copy. Hold a handful of
#' intervened handles, not hundreds.
#'
#' **Generation/logits only (for now).** Interventions apply to `llm_generate()`
#' and `llm_logits()`. [llm_embed()] and [llm_trace()] build their own fresh
#' contexts that do not inherit the adapters, so calling them on an intervened
#' handle raises `rebirth_error_embed` / `rebirth_error_trace` rather than silently
#' returning base (un-intervened) vectors mislabeled as steered.
#'
#' **Model support.** Interventions work on any standard-residual decoder. Before
#' the handle is returned, a runtime probe verifies on *this* model that steering
#' actually shifts the residual at each requested layer; if it would silently do
#' nothing (an architecture that does not route its residual through the choke point
#' the mechanism hooks), `rebirth_error_intervention` is raised instead of a no-op
#' handle. The `llama` and `qwen2` architectures are additionally *behaviorally
#' validated* -- they pass the valence-steering and KL-ablation acceptance fixtures;
#' any other architecture is enabled the moment it passes the probe.
#'
#' @param m An `llm` handle from [llm()].
#' @param layer Single 1-based transformer block to steer, in `2:m$layers` (layer
#'   1 is not steerable -- see Details).
#' @param direction Numeric vector of length `m$hidden_size`: the steering
#'   direction in residual space (finite, no `NA`).
#' @param coef Single finite number scaling `direction` (default `1`). Negative
#'   values steer the opposite way.
#' @param positions Which token positions to steer. Only `"all"` (the default) is
#'   supported in this release.
#' @return A new `llm` handle with the steering added to its accumulated
#'   `interventions`; the source handle is returned unchanged. `print()` shows the
#'   active intervention count and `summary()` lists them.
#' @seealso [llm_ablate()], [llm()], [llm_generate()]
#' @examplesIf nzchar(Sys.getenv("REBIRTH_TEST_MODEL_QWEN"))
#' m <- llm(Sys.getenv("REBIRTH_TEST_MODEL_QWEN"))
#' # A steering direction is any hidden_size-wide vector (here a placeholder).
#' dir <- rep(0.05, m$hidden_size)
#' steered <- llm_steer(m, layer = 8, direction = dir, coef = 2)
#' summary(steered) # lists the active intervention
#' # The original handle is untouched -- generation reproduces the base output.
#' identical(
#'   llm_generate(m, "Tell me about the sea.", max_tokens = 20, seed = 1),
#'   llm_generate(m, "Tell me about the sea.", max_tokens = 20, seed = 1)
#' )
#' close(steered)
#' close(m)
#' @export
llm_steer <- function(m, layer, direction, coef = 1, positions = "all") {
  if (!inherits(m, "llm")) {
    abort_argument("m", "`m` must be an `llm` handle returned by llm().")
  }
  ensure_open(m)
  layer <- validate_intervention_layer(m, layer)

  # The native control vector reserves engine index 0 (the first block), so it
  # cannot reach API layer 1 -- name the structural reason and both workarounds
  # (D-016 / plan section 1.4 addendum #4).
  if (layer == 1L) {
    abort_intervention(
      sprintf(
        paste0(
          "Steering layer 1 (the first transformer block) is not supported: the ",
          "native control-vector mechanism reserves engine index 0 and has no slot ",
          "for it. Steer a later layer (2:%d), or ablate layer 1 with llm_ablate() ",
          "(ablation covers every layer)."
        ),
        m$layers
      ),
      list(argument = "layer")
    )
  }

  if (!is.numeric(direction) || length(direction) != m$hidden_size ||
    anyNA(direction) || any(!is.finite(direction))) {
    abort_intervention(
      sprintf(
        "`direction` must be a finite numeric vector of length %d (the model's hidden size).",
        m$hidden_size
      ),
      list(argument = "direction")
    )
  }

  if (!is.numeric(coef) || length(coef) != 1L || is.na(coef) || !is.finite(coef)) {
    abort_intervention("`coef` must be a single finite number.", list(argument = "coef"))
  }

  # Only all-positions steering is expressible via the native control vector (the
  # add is unconditional across token columns); a position subset is backlogged.
  if (!(is.character(positions) && length(positions) == 1L && identical(positions, "all"))) {
    abort_intervention(
      paste0(
        "Only positions = \"all\" steering is supported: the native control vector ",
        "adds to every token position. Position-restricted steering is not yet ",
        "available."
      ),
      list(argument = "positions")
    )
  }

  entry <- list(
    kind = "steer",
    layer = as.integer(layer),
    direction = as.double(direction),
    coef = as.double(coef),
    positions = "all"
  )
  derive_intervened(m, entry)
}

#' Ablate neurons in a model
#'
#' Returns a **new** `llm` handle with the listed 1-based `neurons` of `component`
#' at `layer` forced to `value` during every subsequent forward pass
#' (`llm_generate()`, `llm_logits()`). The original handle is untouched: to remove
#' the ablation, use the original object (reversibility is exact, D-003).
#'
#' @details
#' Ablation forces `x[neuron] := value` at the residual choke point -- a native
#' graph op (`x * mask + add`), reversible by construction. Unlike steering it
#' covers **every** layer, including layer 1.
#'
#' **Composition.** Deriving from an already-steered or ablated handle carries its
#' full spec forward and adds the new one, then builds a single fresh context from
#' the original weights (contexts are never chained). Ablation is a **union,
#' last-write-wins** per `(layer, neuron)` -- a later ablation of the same neuron
#' overrides its value. The semantics are **derivation-order-independent**:
#' `m |> llm_ablate(...) |> llm_steer(...)` produces the same forward pass as
#' `m |> llm_steer(...) |> llm_ablate(...)`, and a steer never moves an ablated
#' neuron (the ablation runs after the steer at the graph, `(x + steer) * mask +
#' add`, forcing the neuron to `value`, D-016).
#'
#' **Not free.** Each `llm_ablate()`/`llm_steer()` call allocates a fresh context
#' on the shared weights -- a sub-second pause and real memory (its own KV cache),
#' not a cheap copy.
#'
#' **Generation/logits only (for now).** Interventions apply to `llm_generate()`
#' and `llm_logits()`. [llm_embed()] and [llm_trace()] on an intervened handle
#' raise `rebirth_error_embed` / `rebirth_error_trace` rather than silently
#' returning base vectors mislabeled as ablated.
#'
#' Only `component = "residual"` ablation is supported in this release (the shared
#' choke point); `"attn_out"`/`"mlp_out"` raise `rebirth_error_intervention`.
#'
#' **Model support.** Interventions work on any standard-residual decoder; before the
#' handle is returned, a runtime probe verifies on *this* model that the ablation
#' takes effect at each requested layer, raising `rebirth_error_intervention` rather
#' than silently doing nothing. `llama` and `qwen2` are additionally *behaviorally
#' validated* (the valence / KL acceptance fixtures); other architectures are enabled
#' once they pass the probe.
#'
#' @param m An `llm` handle from [llm()].
#' @param layer Single 1-based transformer block, in `1:m$layers`.
#' @param neurons A non-empty vector of 1-based neuron indices in
#'   `1:m$hidden_size` to force to `value`.
#' @param value Single finite number the neurons are forced to (default `0`).
#' @param component Which sub-layer to ablate. Only `"residual"` (the default) is
#'   supported in this release.
#' @return A new `llm` handle with the ablation added to its accumulated
#'   `interventions`; the source handle is returned unchanged. `print()` shows the
#'   active intervention count and `summary()` lists them.
#' @seealso [llm_steer()], [llm()], [llm_generate()]
#' @examplesIf nzchar(Sys.getenv("REBIRTH_TEST_MODEL_QWEN"))
#' m <- llm(Sys.getenv("REBIRTH_TEST_MODEL_QWEN"))
#' ablated <- llm_ablate(m, layer = 5, neurons = c(10, 42, 128))
#' # Composition is order-independent: these two derivations behave identically.
#' dir <- rep(0.05, m$hidden_size)
#' a <- m |> llm_ablate(layer = 5, neurons = 10) |> llm_steer(layer = 6, direction = dir)
#' b <- m |> llm_steer(layer = 6, direction = dir) |> llm_ablate(layer = 5, neurons = 10)
#' summary(a)
#' close(a)
#' close(b)
#' close(ablated)
#' close(m)
#' @export
llm_ablate <- function(m, layer, neurons, value = 0, component = "residual") {
  if (!inherits(m, "llm")) {
    abort_argument("m", "`m` must be an `llm` handle returned by llm().")
  }
  ensure_open(m)
  layer <- validate_intervention_layer(m, layer)

  if (!is.numeric(neurons) || length(neurons) == 0L || anyNA(neurons) ||
    any(!is.finite(neurons)) || any(neurons != round(neurons)) ||
    any(neurons < 1L) || any(neurons > m$hidden_size)) {
    abort_intervention(
      sprintf(
        paste0(
          "`neurons` must be a non-empty vector of 1-based integers in 1:%d ",
          "(the model's hidden size)."
        ),
        m$hidden_size
      ),
      list(argument = "neurons")
    )
  }

  if (!is.numeric(value) || length(value) != 1L || is.na(value) || !is.finite(value)) {
    abort_intervention("`value` must be a single finite number.", list(argument = "value"))
  }

  # Only residual ablation is the shared build_cvec choke point in this release;
  # attn_out / mlp_out ablation would need distinct per-component patch sites.
  if (!(is.character(component) && length(component) == 1L &&
    identical(component, "residual"))) {
    abort_intervention(
      paste0(
        "Only component = \"residual\" ablation is supported. Ablating \"attn_out\" ",
        "or \"mlp_out\" is not yet available."
      ),
      list(argument = "component")
    )
  }

  entry <- list(
    kind = "ablate",
    layer = as.integer(layer),
    neurons = sort(unique(as.integer(neurons))),
    value = as.double(value),
    component = "residual"
  )
  derive_intervened(m, entry)
}

# Guard the observation entry points (llm_embed / llm_trace) against an intervened
# handle. Their fresh contexts do NOT inherit a handle's steering/ablation adapters
# (D-016), so running them on an intervened handle would return BASE vectors
# mislabeled as intervened -- the silent-mislabeling class D-012/D-014 forbid.
# Interventions apply to generation/logits only in this release.
guard_not_intervened <- function(m, class, what, call = sys.call(-1L)) {
  if (length(m$interventions) > 0L) {
    rebirth_abort(
      class,
      paste0(
        what, ": interventions currently apply to generation and logits only ",
        "(llm_generate / llm_logits). Use the original, un-intervened handle for ",
        "embedding and tracing."
      ),
      call = call
    )
  }
  invisible(m)
}

# --- internal: validation, composition, and the derived-handle constructor ---

# Validate a single 1-based `layer` in 1:m$layers; return it as an integer.
validate_intervention_layer <- function(m, layer, call = sys.call(-1L)) {
  if (!is.numeric(layer) || length(layer) != 1L || is.na(layer) || !is.finite(layer) ||
    layer != round(layer) || layer < 1L || layer > m$layers) {
    abort_intervention(
      sprintf(
        "`layer` must be a single integer in 1:%d (a 1-based transformer block).",
        m$layers
      ),
      list(argument = "layer"),
      call = call
    )
  }
  as.integer(layer)
}

# Append `entry` to the source handle's accumulated interventions, flatten the
# FULL list into the dense boundary arrays, derive a fresh handle from the source's
# shared weights, and wrap it. Topology-independent: the source may be a base or an
# already-derived handle -- the whole accumulated spec is re-sent, and the engine
# builds ONE fresh context from the original weights (never a chain).
derive_intervened <- function(m, entry, call = sys.call(-1L)) {
  interventions <- c(m$interventions, list(entry))
  flat <- flatten_interventions(interventions, m$hidden_size)
  payload <- rebirth_check(
    rebirth_intervene(
      m$ptr, as.integer(m$hidden_size), as.integer(m$layers),
      flat$steer_layers, flat$steer_vectors,
      flat$ablate_layers, flat$ablate_neurons, flat$ablate_values
    ),
    call = call
  )
  # Share the source's path (same underlying weights); new_llm() gives the derived
  # handle its own state env + finalizer, so it frees independently of the source.
  new_llm(payload, m$path, interventions)
}

# Flatten an accumulated interventions list into the dense parallel arrays the
# rebirth_intervene() boundary consumes (1-based indices; the boundary converts to
# 0-based). Steering: one row per steer entry, its coef*direction vector at
# `steer_vectors[(i-1)*hidden_size + seq_len(hidden_size)]`, with `steer_layers[i]`
# its layer (the engine sums rows on the same layer). Ablation: one
# (layer, neuron, value) triple per ablated neuron (the engine unions them,
# last-write-wins in this list order).
flatten_interventions <- function(interventions, hidden_size) {
  steer_layers <- integer(0)
  steer_vectors <- double(0)
  ablate_layers <- integer(0)
  ablate_neurons <- integer(0)
  ablate_values <- double(0)

  for (iv in interventions) {
    if (identical(iv$kind, "steer")) {
      steer_layers <- c(steer_layers, iv$layer)
      steer_vectors <- c(steer_vectors, iv$coef * iv$direction)
    } else if (identical(iv$kind, "ablate")) {
      k <- length(iv$neurons)
      ablate_layers <- c(ablate_layers, rep(iv$layer, k))
      ablate_neurons <- c(ablate_neurons, iv$neurons)
      ablate_values <- c(ablate_values, rep(iv$value, k))
    }
  }

  list(
    steer_layers = as.integer(steer_layers),
    steer_vectors = as.double(steer_vectors),
    ablate_layers = as.integer(ablate_layers),
    ablate_neurons = as.integer(ablate_neurons),
    ablate_values = as.double(ablate_values)
  )
}
