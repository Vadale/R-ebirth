# WP5 — Interventions (`llm_steer` + `llm_ablate`): implementation plan

**Author:** architect agent · **Date:** 2026-07-06 · **Status:** planning artifact for founder review.
**Scope:** ROADMAP §3/§5 Phase 2 / WP5 ("Interventions"), the intervention core of the anatomy lab. WP4 (`llm_trace()`) is merged to `main` (HEAD `8d2c1ec`); Phase 1 complete. Branch `wp5-interventions` (to be created).

This is an **implementation plan, not a decision-spike.** D-012 already decided the mechanism — **steering = llama.cpp's native control-vector path (zero patch); ablation = a minimal, guarded vendored patch at `build_cvec`, pre-authorized** — and D-014 settled `attn_out` semantics. So this document maps that settled mechanism onto the approved API surface, sizes the real patch honestly, and defines the golden-first numerical gate. **I do not edit `DECISIONS.md`, any root planning doc, or any `.R`/`.rs`/`.cpp`/`.py` source** — the founder appends any accepted ADR and the coder writes the code from this plan.

Nothing here changes the approved API surface: `llm_steer(m, layer, direction, coef = 1, positions = "all")`, `llm_ablate(m, layer, neurons, value = 0, component = "residual")`, the new-handle contract (§2 class table), and `rebirth_error_intervention` (§6) are **binding (D-003)**; this plan decides only the *implementation* behind that fixed surface.

**Two genuinely-new founder-level items surfaced from the b9726 source** (§1.4, §5.4, §12): (1) the **patch-application mechanism** — WP5 is the *first* vendored patch, so how it lands (committed patched tree vs build-time apply) must be settled; a **proposed ADR D-015** is drafted at the end. (2) The **native control-vector's structural layer-0 gap** — steering the first transformer block (API `layer = 1`) is not expressible through the native path; the plan recommends an honest classed error and flags the alternative. Everything else is settled by D-012/D-014 and specified below.

The precedent docs are `docs/wp4-trace-plan.md` (D-012/D-013), `docs/wp3-embed-plan.md` (D-011), and `docs/wp1-plan.md` (D-005/D-006); this follows their structure.

---

## 0. What is fixed before we start (verified against the vendored b9726 source)

Every row was checked by reading the file cited — this is the plan's evidence base.

| Fact | Source (verified, b9726) |
|---|---|
| Approved API: `llm_steer(m, layer, direction, coef = 1, positions = "all")` → **new `llm` handle** (adds `coef * direction` to the residual at `layer` for the positions); `direction` = numeric length `hidden_size`; the original handle is untouched; interventions compose (stacking sums). `llm_ablate(m, layer, neurons, value = 0, component = "residual")` → **new handle** with the listed 1-based `neurons` of `component` at `layer` forced to `value`. Both errors → `rebirth_error_intervention` (dimension/layer validation). | `API-GRAMMAR.md` §4/§6, `[approved]` binding (D-003) |
| The `llm` class is **immutable from R**: interventions return a *new* handle sharing the underlying weights; they never mutate an existing handle. Copying the R object never copies model memory. `interventions` (list) slot holds the active specs (empty for a fresh handle). | `API-GRAMMAR.md` §2 |
| **Steering is the native control-vector path.** Public C API `llama_set_adapter_cvec(ctx, data, len, n_embd, il_start, il_end)` (returns 0/-1) → `ctx->set_adapter_cvec(...)` → `cvec->apply(model, data, len, n_embd, il_start, il_end)` + `sched_need_reserve = true`. At graph build, `graph_params` sets `.cvec = cvec.get()`; `llm_graph_context.cvec = params.cvec`; each arch calls `cur = build_cvec(cur, il)`; `build_cvec` → `cvec->apply_to(ctx0, cur, il)` → `ggml_add(ctx, cur, layer_dir)` iff `tensor_for(il) != nullptr`. **Zero patch.** | `include/llama.h` L694-700; `src/llama-context.cpp` L3803-3813, L1285-1298, L2406, L37; `src/llama-graph.cpp` L1061, L1079-1083; `src/llama-adapter.cpp` L14-29 |
| **The native cvec buffer is laid out "from layer 1" and has no slot for engine layer 0.** `init()`: `tensors.push_back(nullptr)` for layer 0 ("there's never a tensor for layer 0"), then real F32 `n_embd`-wide tensors for `il = 1..n_layer-1`. `apply()` copies `data + n_embd*(il-1)` into `tensors[il]`. `tensor_for(il)` returns null for `il = 0` (and outside `[layer_start, layer_end]`). **Consequence:** the native path can steer engine layers `1..n_layer-1` (API layers `2..n_layer`) only — **API `layer = 1` (engine `il = 0`, the first block) is structurally unreachable** (§1.4). | `src/llama-adapter.cpp` L63-75 (esp. L65), L94-134 (esp. L124-131), L14-20 |
| **`build_cvec` is the residual choke point but NOT universal** (D-012): **106 of 134** model graphs call it, including every pinned/CI/demo arch — llama (`models/llama.cpp` L223), qwen2 (`models/qwen2.cpp` L129), gemma3 (`models/gemma3.cpp` L194). BERT-class encoders, SSMs, and some MoEs do not. So `llm_steer`/`llm_ablate` share one support matrix; an unsupported arch must raise `rebirth_error_intervention`, never silently no-op (D-012, D-014). | `grep build_cvec src/models/*.cpp` = 106/134; the three call sites cited |
| The residual **`l_out-<il>` is the post-`build_cvec` value** (`ggml_add` of the second residual, then `build_cvec`, then `cb(cur,"l_out",il)`). So a steer/ablation applied inside `build_cvec` lands exactly on `l_out-<il>` and propagates to the next block's input — the API's "adds to the residual stream at `layer`" and "residual component" both resolve to this site. | `src/models/llama.cpp` L220-224; `src/models/qwen2.cpp` L129-130 |
| The context params mirror is **unchanged** by WP5: the two new C symbols (`llama_set_adapter_cvec`, the new `llama_set_intervene`) take pointers + lengths, not by-value structs. The existing size-160 ABI test (`ffi.rs` L320-348) still fully covers the layout. No `ggml_tensor` struct mirror is needed (ablation is a native graph op, not a host tensor write — `ggml_backend_tensor_set` is deliberately still **not** declared). | `ffi.rs` L110-149, L280-302, L320-348 |
| The generation path is **stateless across calls**: `logits_for_tokens`/`generate_prompt` call `clear_memory()` (`llama_get_memory` + `llama_memory_clear`) before decoding. The KV cache is per-call; the cvec/intervene adapters live on the context and persist. So an intervention handle can own a **persistent** context with the intervention applied once, and every generate/logits call re-decodes cleanly against it. | `src/rust/rebirth-llm/src/generate.rs` L269-276, L351-360, L558 |
| The engine already exposes the exact numerical building block the golden gate needs: `LoadedModel::logits_for_tokens(&self, tokens) -> Logits` (teacher-forced, no sampling), used by WP2's `synthetic_logits.rs`. **`llm_logits` (the R-facing Phase-2 entry) is NOT implemented and is NOT WP5 scope** — the synthetic golden gate calls `logits_for_tokens` directly, exactly as `synthetic_logits.rs` does. | `generate.rs` L349-360; `tests/synthetic_logits.rs` |
| The numpy oracle already has an intervention-ready shape: `hidden_states(weights, tokens, capture=)` computes the per-layer residual `x` and snapshots `residual` at exactly the `build_cvec` site (after both residual adds, `.copy()` at L230). Extending it with an `intervene` hook at that same point produces the steered/ablated logits with no drift to the existing logit/embedding/activation goldens. | `tests/llm-golden/synthetic/reference_forward.py` L138-233 (esp. L223-230) |
| **The vendored tree is pruned** (D-006): `common/` (the upstream `control_vector_load` helper) and `tools/`/`examples/` are absent. We build the cvec/intervene buffers ourselves in R/Rust — which we do anyway. | `ls common tools examples` → absent |
| Patch discipline (D-006): patches live in `rebirth/src/llama.cpp/patches/` as annotated unified diffs; the set is kept as small as upstream allows so `vendor-bump` stays mechanical. **patches/ is currently empty — WP4 added zero patches (observation is zero-patch), so WP5's ablation hook is the project's FIRST vendored patch** (§5.4 / D-015). | `patches/README.md`; `patches/` empty |
| No new background Rust thread in WP5: steering and ablation are synchronous, on the R main thread, so D-008 gate G2 is not re-touched (the G2 tripwires from WP4 remain). No new dependency (R or Rust) is introduced by the recommended path (§5.4). | `DECISIONS.md` D-008 G2; ROADMAP §5 WP5 FORBIDDEN |

---

## 1. The mechanism — findings

### 1.1 Steering (`llm_steer`) maps directly onto the native control vector — zero patch

Confirmed from source (the row-2/-3 citations in §0). A control vector is a per-layer, `n_embd`-wide F32 tensor **added to the residual** at the `build_cvec` site — which is exactly `l_out-<il>`, the residual stream at the block's output. `llm_steer(m, layer, direction, coef, positions = "all")` is therefore:

1. Compute the steer vector `v = coef * direction` (length `hidden_size`, in R/Rust).
2. Place it in the cvec buffer at the slot for engine layer `il = layer - 1`, and register `il_start = il_end = il` (or a contiguous range if the accumulated spec spans several layers — the buffer is one flat `n_embd × n_layer` array and `layer_start`/`layer_end` bound the active range).
3. `llama_set_adapter_cvec(ctx, buffer, len, n_embd, il_start, il_end)` on the intervention handle's context.
4. Every subsequent `llm_generate`/logits forward pass adds `v` to the residual at that layer, for **all token positions** (`ggml_add` broadcasts the 1D vector across all columns).

**Composition is additive and free.** Steering a steered handle stacks both: the accumulated buffer is the **element-wise sum** of every steer vector at each layer. Control vectors compose by addition, so the summed buffer is exactly correct — computed on our side in plain R vector ops (§3.2), never as engine state to mutate.

### 1.2 Ablation (`llm_ablate`) is a minimal guarded `build_cvec` patch — full layer coverage by construction

D-012 pre-authorized this. `x[k] := value` is not a fixed additive vector (it depends on the computed activation), so it cannot reuse the cvec. It **is** expressible as a native two-op graph transform on the residual:

```
x' = x ⊙ mask + add          (per layer, broadcast over token columns)
  where  mask[k] = 0, add[k] = value   for each ablated neuron k
         mask[k] = 1, add[k] = 0        otherwise
```

`ggml_mul(ctx, x, mask)` zeros the ablated rows; `ggml_add(ctx, ·, add)` sets them to `value`. Both `mask` and `add` are `n_embd`-wide 1D F32 tensors — allocated exactly like the cvec's per-layer tensors, set by a host copy. This is a **new sibling adapter `llama_adapter_intervene`** threaded through `llm_graph_context` the same way `cvec` is, applied inside `build_cvec` **after** the cvec add (so on a jointly-steered-and-ablated neuron the forced value wins — the documented composition). The exact hunks are §5.

**Deliberately unlike the cvec, our intervene adapter allocates tensors for ALL layers `il = 0..n_layer-1` (buffer offset `n_embd*il`, no `-1`), so ablation has full layer coverage — including engine `il = 0` (API `layer = 1`).** This is why the synthetic golden can ablate *both* blocks of the 2-layer model (§7.1), and it is the structural reason ablation reaches a layer that native-cvec steering cannot (§1.4).

**Native, so no host-mutation question.** The ablation is standard ggml ops (`ggml_mul`/`ggml_add`) built into the compute graph; each backend's kernels compute them exactly as they compute every other op. There is **no** cross-submission host-mutation-visibility question — that was the modifying-eval-callback path D-012 rejected precisely because source could not certify it on Metal. A graph op has no such gap. **No empirical CPU+Metal probe is warranted before the coder starts** (§1.5).

### 1.3 Architecture coverage and the mandatory unsupported-arch error

> **Superseded (WP7.5a part-2, D-021):** the static `INTERVENTION_SUPPORTED_ARCHS`
> allow-list described below is replaced by a **runtime sentinel intervention probe**
> (`rebirth-llm/src/probe.rs`) that proves `build_cvec` + the native cvec path actually
> take effect on *this* model at the requested layers before a handle is returned —
> catching the same silent-no-op case per model instead of by a hand-maintained string
> list. The R `INTERVENTION_SUPPORTED_ARCHS` hard-stop is gone; the retargeted
> `INTERVENTION_VALIDATED_ARCHS` names only the documentation "behaviorally validated"
> tier and does not gate. Current source of truth: `docs/wp7.5-model-matrix.md`. The
> paragraphs below are kept as the WP5-era design record.

`build_cvec` is present in all pinned/CI/demo archs but only 106/134 graphs (§0). For an arch that never calls `build_cvec` (e.g. BERT-class), our intervene adapter's `apply_to` would **never be invoked** → the ablation would silently not apply → a handle that *claims* an intervention but generates unablated output. D-012/D-014 forbid exactly this silent no-op.

**Detection (implements the D-012/D-014 mandate):** a curated `INTERVENTION_SUPPORTED_ARCHS` allow-list in the engine, seeded with the **verified, tested** archs — `llama`, `qwen2`, `gemma3` — and checked against the model's `general.architecture` at `llm_steer`/`llm_ablate` time (fail fast, before any decode). An unlisted arch → `rebirth_error_intervention` naming the arch and the supported set. The `vendor-bump` skill re-verifies each listed arch still calls `build_cvec` (a `grep` assertion in `models/`). Growing the list = adding test coverage for that arch, not merely a string — honest by construction (we claim only what a golden covers). This mirrors WP4's "unmatched component/arch → `rebirth_error_trace`" philosophy.

Steering and ablation share this one allow-list (the native cvec is *also* a no-op on a non-`build_cvec` arch), satisfying D-012's "one support matrix."

### 1.4 GENUINELY NEW — the native cvec cannot steer API `layer = 1` (engine `il = 0`)

The native control-vector buffer reserves index 0 for "no layer" and holds real tensors only for `il = 1..n_layer-1` (§0, `llama-adapter.cpp` L65/L124-131). So **steering the first transformer block's residual output — API `layer = 1` — is structurally unreachable through the native path.** On the synthetic 2-layer model this is stark: native cvec can steer *only* engine `il = 1` (API layer 2); on Qwen2.5-1.5B (28 blocks) it is 1 of 28 unreachable (API layer 1). Ablation is unaffected (our adapter covers `il = 0`, §1.2).

This is undocumented anywhere and must not become a silent no-op. **Options (one recommendation):**

- **Option A — respect D-012 (native steering); `layer = 1` steer → `rebirth_error_intervention`** with a clear message ("steering the first transformer block (layer 1) is not supported by the native control-vector mechanism; steer layers 2..N, or ablate layer 1"). *Cost:* trivial. *Risk:* low. *Consequence:* a narrow API asymmetry (layer 1 is ablatable but not steerable), documented; rarely hit in practice (steering vectors target mid-to-late layers). **Respects the settled decision.**
- **Option B — route steering through the ablation patch's adapter too** (add a per-layer steer-add alongside the mask/add), giving steering full `il = 0..n_layer-1` coverage and steer/ablate a single mechanism. *Cost:* a few extra lines in the already-present adapter (near-zero marginal patch). *Risk:* low. *Consequence:* steering is no longer "zero patch" — it **deviates from D-012's letter** ("steering needs zero patch, native control-vector path") and would need a one-line superseding note to D-012. Cleaner symmetry, but relitigates a settled decision for a narrow gain.

**Recommendation: Option A.** It respects D-012 verbatim (planning rule 1), keeps steering on the battle-tested native path, and the hole is narrow and honestly surfaced. Our intervene adapter's full-coverage design (§1.2) means Option B is *cheap to adopt later* if the founder finds the asymmetry unacceptable — recorded, not chosen.

Two smaller consequences of "steering = native cvec," both handled as documented limits (not blockers), both consistent with the approved default `positions = "all"`:

- **`positions` subset for steering is not natively expressible** (the cvec add is unconditional across token columns). `positions = "all"` (the default, and what the WP5 acceptance uses) maps perfectly; a position subset → `rebirth_error_intervention` ("position-restricted steering is not yet supported; use positions = 'all'"), with position-aware steering a backlog item (it needs graph-level position masking that neither the cvec nor a simple mask-add provides — genuinely out of scope). Ablation has **no** `positions` argument (all-positions by definition), so it is unaffected.
- **Ablation `component != "residual"` is not the shared choke point.** `build_cvec` is the residual site; `attn_out`/`mlp_out` ablation would need distinct per-component patch sites (the WP4 backlog note). WP5 implements `component = "residual"` (the approved default) and raises `rebirth_error_intervention` for the other two with a clear "only residual ablation is supported (attn_out/mlp_out ablation is a future capability)" message.

### 1.5 Is a probe warranted before coding? No.

WP4's spike could not settle the *modifying eval-callback* on Metal from source, so that path (had it been chosen) required an empirical CPU+Metal probe. **WP5 does not take that path.** Ablation is a native ggml graph op (`ggml_mul`/`ggml_add`) and steering is the native `ggml_add` control vector — both are ordinary graph nodes each backend computes by construction, with no host-mutation, no cross-submission visibility, and no scheduler de-batching. There is nothing source leaves unsettled for the coder to probe. The synthetic golden runs on **CPU in CI**; the founder runs the `[MODEL]` fixtures on **Metal** locally (§10). That is the empirical confirmation, and it is part of acceptance — **no separate spike/probe run is needed before implementation.** The coder starts at Step 1.

---

## 2. FFI additions (`rebirth-llm/src/ffi.rs`) + the ABI checkpoint

A new `// --- interventions (WP5) ---` section. **No struct-mirror change** (both symbols take pointers), so the size-160 ABI test is untouched and still authoritative.

```rust
extern "C" {
    // Steering — the native control vector (zero patch). Public API at
    // include/llama.h L694; impl llama-context.cpp L3803. Returns 0 on success,
    // -1 on n_embd mismatch. `data` is an n_embd x n_layer F32 buffer laid out
    // "from layer 1" (llama-adapter.cpp L124-131); it is copied synchronously, so
    // it need only outlive the call.
    pub fn llama_set_adapter_cvec(
        ctx: *mut llama_context, data: *const f32, len: usize,
        n_embd: i32, il_start: i32, il_end: i32,
    ) -> i32;

    // Ablation — the WP5 vendored patch's public API (§5). Registers per-layer
    // mask+add F32 buffers (n_embd x n_layer, from layer 0 — full coverage) so
    // build_cvec applies `x*mask + add`. NULL `mask` clears the intervention
    // (mirrors llama_set_adapter_cvec's NULL-data clear). Returns 0/-1. Copied
    // synchronously.
    pub fn llama_set_intervene(
        ctx: *mut llama_context, mask: *const f32, add: *const f32, len: usize,
        n_embd: i32, il_start: i32, il_end: i32,
    ) -> i32;
}
```

**ABI checkpoint (security-auditor, D-008):** no struct changes, so `context_params_embedding_fields_have_the_expected_abi` (`ffi.rs` L320-348, size 160) already covers everything WP5 relies on. The security-auditor checkpoint at the WP5 boundary confirms (a) the two setter signatures match `llama.h` L694 and the new patch decl at the vendored tag; (b) the `data`/`mask`/`add` buffers are Rust-owned, outlive the synchronous copy, and are never retained by the engine beyond it; (c) `ggml_backend_tensor_set` remains undeclared (ablation is a graph op, no host tensor write). No new `unsafe impl Send/Sync`, no new thread → D-008 G2 unchanged.

---

## 3. Rust engine surface (`rebirth-llm`, R-free)

New module **`rebirth/src/rust/rebirth-llm/src/intervene.rs`** (mirrors how `trace.rs`/`embed.rs`/`generate.rs` isolate an algorithm), wired via `mod intervene;` + re-exports in `lib.rs`. All C-FFI `unsafe` minimal and individually SAFETY-commented (D-009); no R types anywhere.

### 3.1 The intervention spec (engine-native, 0-based)

R accumulates the human-readable interventions list; it flattens the **whole accumulated list** into two dense, per-layer buffers before crossing the boundary (§3.2), so the engine surface is stateless and trivially testable:

```rust
/// A fully-accumulated intervention set, already summed/unioned in R (§3.2).
/// All indices ENGINE-native (0-based). Empty vecs = "that kind is absent".
pub struct InterventionSpec {
    pub n_embd: usize,
    pub n_layer: usize,
    /// Steering: flat n_embd*n_layer F32, row il = summed steer vectors for
    /// engine layer il (the native cvec buffer layout, from layer 1 — layer 0
    /// row is unused; R rejects a layer-1 steer, §1.4 Option A). None = no steer.
    pub steer: Option<Vec<f32>>,
    pub steer_il_range: Option<(i32, i32)>,   // inclusive [il_start, il_end]
    /// Ablation: flat n_embd*n_layer F32 mask and add (from layer 0 — full
    /// coverage). None = no ablation.
    pub ablate_mask: Option<Vec<f32>>,
    pub ablate_add: Option<Vec<f32>>,
    pub ablate_il_range: Option<(i32, i32)>,
}
```

### 3.2 Composition happens in R, as plain vector arithmetic

Because control vectors **sum** and ablations **union** (last-write-wins on a repeated `(layer, neuron)`), the whole accumulated spec is derivable in R from the interventions list without engine state:

- **Steer buffer:** zero `n_embd × n_layer`; for each `steer` entry add `coef * direction` into its layer's row. Repeated steers on a layer sum.
- **Ablation mask/add:** start `mask = 1`, `add = 0`; for each `ablate` entry set `mask[layer, neurons] = 0`, `add[layer, neurons] = value`. A later ablate on the same `(layer, neuron)` overrides its value (well-defined).

This keeps the numeric composition in testable R code, matches the "new handle = base weights + accumulated spec" model exactly, and needs no interior mutability anywhere.

### 3.3 The intervention handle — a fresh context on shared weights (D-008 G2 answer)

The founder's G2 question — *interior mutability on the shared handle, or a per-steer context?* — resolves to **a per-intervention context, no interior mutability**, the D-011 pattern applied to a persistent (not transient) context:

```rust
impl LoadedModel {
    /// Build a NEW handle sharing this model's weights (Arc<Model> clone — no
    /// reload) with `spec` applied to a fresh context. The source handle's own
    /// context is never touched, so the original is bit-for-bit unchanged.
    pub fn derive_with_interventions(&self, spec: &InterventionSpec)
        -> Result<LoadedModel, RebirthError>;
}
```

- It clones the source's `Arc<Model>` (shared, read-only weights) and creates a **fresh `Context`** with the same `context_length`/`gpu_layers`/`mmap` (new accessors expose the source `Context`'s config; `Arc<Model>` stays private to `engine.rs`).
- It applies the spec to that fresh context: `llama_set_adapter_cvec` if `steer.is_some()`, `llama_set_intervene` if `ablate_mask.is_some()`. Both set `sched_need_reserve = true` inside the engine (the graph is re-reserved on the next decode).
- Interventions are **not** in the weights — they live in the per-context adapters — so cloning the `Arc` and building a *fresh* context yields a clean slate regardless of what the source handle carried. `derive_with_interventions` therefore works identically on the base handle or an already-derived one; R always passes the **full accumulated** spec, so the result is exactly base-weights + all interventions.
- No `unsafe impl Send + Sync` is exercised (each handle owns its context on the R main thread; nothing crosses a thread), so **D-008 G2 stays closed** — the same conclusion as D-011.

**Memory note (16 GB rule):** each intervention handle owns one context = one KV cache. The typical pattern (one steered/ablated handle held next to the original) is two contexts — fine. Many simultaneous intervention handles multiply KV memory; a shared-context or transient-per-call-context optimization is a **backlog note** (§11), not WP5.

### 3.4 Public engine API

```rust
impl LoadedModel {
    pub fn derive_with_interventions(&self, spec: &InterventionSpec)
        -> Result<LoadedModel, RebirthError>;                 // §3.3
    /// The supported-arch gate (§1.3): Err(Intervention{..}) if this model's
    /// architecture lacks the build_cvec choke point.
    pub fn check_intervention_supported(&self) -> Result<(), RebirthError>;
}
```

`error.rs` gains `Intervention { reason: String }` → class `"rebirth_error_intervention"`, following the `Embed`/`Trace` pattern (the full what-happened → cause → what-to-try message composed at the failure site, since the causes — dimension mismatch, invalid/unreachable layer, unsupported arch, unsupported component/positions — need distinct guidance). Its `error_fields` carry `reason` (mirroring `Trace`).

---

## 4. FFI boundary (`rebirth-ffi/src/lib.rs`)

### 4.1 Index conversion here and nowhere else (ARCHITECTURE §4)

R passes **1-based** `layer`/`neurons`/`positions`; `rebirth-ffi` converts to 0-based **exactly once** via the existing `to_engine_index`/`from_engine_index`, builds the `InterventionSpec`, and (for a returned handle) needs no outward index remap (the new handle just re-reports the same metadata as the source). The canonical off-by-one site is already property-tested (`lib.rs` L682-706); WP5 adds a unit test that a steer/ablate at API `layer = L` lands on engine `il = L-1` (via the dense-buffer row it writes).

### 4.2 The two entries — both funnel through one derive

Both R functions accumulate their interventions list, flatten it (§3.2), and call a single stateless boundary entry that rebuilds a fresh handle from the source's shared weights:

```rust
#[extendr]
fn rebirth_intervene(
    ptr: Robj,                       // the SOURCE handle (base or derived)
    steer: Vec<f64>, steer_layers: Vec<i32>,          // empty = no steer
    ablate_mask: Vec<f64>, ablate_add: Vec<f64>, ablate_layers: Vec<i32>, // empty = none
    n_embd: i32, n_layer: i32,
) -> Robj {
    with_model(&ptr, |model| {
        model.check_intervention_supported()?;        // §1.3 fail-fast
        let spec = build_intervention_spec(/* downcast f64->f32, engine ranges */)?;
        let derived = model.derive_with_interventions(&spec)?;   // §3.3
        let meta = derived.metadata();
        let new_ptr: Robj = ExternalPtr::new(LlmHandle::new(derived)).into();
        Ok(ok_payload(new_ptr, meta))                  // a fresh handle payload
    })
}
```

- `with_model` (existing) gives the outer `catch_unwind` + closed/foreign-pointer guard; the SOURCE handle is only read (its `Arc<Model>` cloned), never mutated.
- The dense arrays cross as R doubles (R has no f32) and are downcast to f32 for the engine buffers — the same upcast/downcast convention as `rebirth_embed`/`rebirth_trace`. Steering vectors chosen for the golden are exactly F32-representable so the downcast injects no error (§7.1).
- **All argument validation stays in R** (§4.3): `direction`/`neurons` length and range, `layer` in `1..n_layer`, the §1.4 `layer = 1` steer rejection, `positions`/`component` restrictions. The boundary sees a pre-vetted spec; the engine's only runtime error is the arch gate.

### 4.3 R surface (`rebirth/R/intervene.R` + `new_llm_derived`)

```r
llm_steer  <- function(m, layer, direction, coef = 1, positions = "all") { ... }
llm_ablate <- function(m, layer, neurons, value = 0, component = "residual") { ... }
```

Each: `ensure_open(m)`; validate (raising `rebirth_error_intervention` with an `argument`-style field for each bad input, and the §1.4/§1.5 honest-limit errors); append the new entry to `m$interventions`; flatten the full list (§3.2); call `rebirth_intervene(m$ptr, ...)`; wrap the payload in a **new** `llm` via `new_llm_derived(payload, m, new_interventions)` — a variant of `new_llm` that copies the source metadata, installs a **new `state` env + its own `reg.finalizer`** (the derived handle owns a distinct native context that must free independently), and sets `interventions = new_interventions`. The source object is returned unchanged. `print.llm`/`summary.llm` already render `interventions` (`llm.R` L240, L296) — WP5 only fills the list with structured entries (`list(kind, layer, ...)`), so "removal = use the original object" and the intervention count display work with no method change.

---

## 5. The vendored ablation patch (D-012 pre-authorized) — exact hunks

The patch **mirrors the existing control-vector plumbing** so `vendor-bump` stays mechanical. It extends `build_cvec` **in place** — so **zero `models/*.cpp` files change** (all 106 archs already call `build_cvec`), which is the single most important property for keeping the patch small and bump-cheap.

### 5.1 The one behavioural hunk — `src/llama-graph.cpp` `build_cvec` (L1079-1083)

```cpp
ggml_tensor * llm_graph_context::build_cvec(ggml_tensor * cur, int il) const {
    cur = cvec->apply_to(ctx0, cur, il);          // unchanged (native steering)
    cur = intervene->apply_to(ctx0, cur, il);     // WP5: no-op unless an ablation is registered for il
    return cur;
}
```

`intervene->apply_to` returns `cur` **unchanged when no mask is registered for `il`** (mirroring `cvec::apply_to`'s `tensor_for(il)==nullptr` early return), adding **no ggml node**. So when no ablation is registered, the emitted compute graph is **identical op-for-op** to the unpatched build → logits are **bit-identical on a given backend** → the harness-B baseline and the WP5 bit-for-bit reversal hold **by construction** (§6).

### 5.2 The plumbing hunks — mirroring `cvec` exactly (the ~5-file / ~100-200-line reality)

Honest sizing (D-012 flagged "~5 files, ~100-200 lines, not one function"). The real footprint is **7 files, ~13 hunks, ~130-180 lines** — **exactly the set of files the `cvec` feature itself touches**, so it does *not exceed* cvec-style plumbing, it replicates it:

| # | File | Hunk(s) | Mirrors (cvec) |
|---|---|---|---|
| 1 | `src/llama-adapter.h` | `struct llama_adapter_intervene` (per-layer `mask`/`add` tensors, `apply_to`/`apply`/`init`/`mask_for`) + `using ..._ptr` | L17-42 |
| 2 | `src/llama-adapter.cpp` | the impls (~70 lines; **allocates all `il = 0..n_layer-1`**, buffer offset `n_embd*il` — full coverage, §1.2) | L14-134 |
| 3 | `src/llama-context.h` | `set_intervene(...)` decl + `llama_adapter_intervene_ptr intervene;` member | L125, L279 |
| 4 | `src/llama-context.cpp` | ctor init `intervene(std::make_unique<...>())`; `set_intervene` impl (`intervene->apply(...)` + `sched_need_reserve = true`); `.intervene = intervene.get()` in `graph_params`; public `llama_set_intervene` C API | L37, L1285-1298, L2406, L3803-3813 |
| 5 | `include/llama.h` | `LLAMA_API int32_t llama_set_intervene(...)` decl | L694-700 |
| 6 | `src/llama-graph.h` | `const llama_adapter_intervene * intervene;` in `llm_graph_params` **and** in `llm_graph_context` | L601, L823 |
| 7 | `src/llama-graph.cpp` | `intervene(params.intervene)` in the ctor init-list + the §5.1 `build_cvec` hunk | L1061, L1079 |

Each hunk is annotated with why it exists; the diff lives in `patches/` (§5.4). This is **inside the D-006 patch budget** and adds **no new dependency**.

### 5.3 Architecture coverage restated

The patch is active only where `build_cvec` is called (106/134 archs, all pinned/CI/demo). The unsupported-arch case is caught **before** any decode by the §1.3 allow-list → `rebirth_error_intervention`, never a silent no-op. (This is orthogonal to the patch: the patch simply is not reached on a non-`build_cvec` arch, and the allow-list guarantees we error rather than return a mislabeled handle.)

### 5.4 GENUINELY NEW — how the first patch lands (→ proposed ADR D-015)

WP4 added **zero** patches, so WP5 is the project's first vendored patch, and the mechanism must be settled. It interacts with **D-008 G4** (CI recomputes the vendored pruned-tree SHA256 and asserts it matches `VENDORING.md`, to catch a *silent* change to the engine). Two options:

- **Option 1 (recommended) — commit the patched tree.** Apply the annotated diff to `src/llama.cpp/`, commit it, and update `VENDORING.md` to record **both** the upstream b9726 base SHA (provenance) **and** the new patched-tree SHA (what G4 asserts). The `patches/*.diff` remain as the human-readable, `vendor-bump`-reappliable delta. *Pros:* **no build-time patch tool, no new dependency, CRAN-robust** (CRAN/`R CMD INSTALL` compiles the tree as-is — the standard way R packages ship patched vendored C), G4 still catches silent drift (a deliberate documented patch that updates `VENDORING.md` is not silent). *Con:* the committed tree diverges from pristine upstream by the annotated patch (which is the whole point of a patch set; the diff makes it fully auditable).
- **Option 2 — keep the tree pristine, apply at build time.** `build.rs` applies `patches/*.diff` before cmake (the current `patches/README.md` wording). *Pro:* the committed tree stays diffable against upstream. *Con:* needs a patch mechanism at build time — either a fragile external `patch`/`git apply` (not guaranteed on every build host, notably the eventual Windows/CRAN matrix) **or a new Rust build-dependency** (a diff-applier crate — an ADR under the no-new-dependency rule, and more vendored surface).

**Recommendation: Option 1.** It is zero-dependency, CRAN-safe, honors G4, and keeps the annotated diff in `patches/` as the task requires. The coder updates `patches/README.md` and `VENDORING.md` accordingly (docs, not this plan). A **proposed ADR D-015** is drafted at the end; if the founder prefers Option 2 with a diff-applier crate, that path needs its own dependency ADR first.

*(Coordination, not WP5 core scope):* D-014 chartered a separate **naming-only** patch to expose post-projection `attn_out` on qwen2/gemma3 (for the WP6b HF trace golden). It is byte-identical computation and could ride WP5's patch PR to amortize one vendor-tree touch, **but it is a trace concern with its own ADR** — noted here only so the two patch efforts are sequenced, not merged into WP5's acceptance.

---

## 6. Bit-for-bit reversibility (WP5 acceptance) — by construction

The acceptance "using the original handle after creating steered/ablated ones reproduces original outputs bit-for-bit" holds **structurally**, on two independent grounds:

1. **The original handle's context is never touched.** `derive_with_interventions` clones the `Arc<Model>` (read-only weights) and builds a **separate** context; `llama_set_adapter_cvec`/`llama_set_intervene` are called only on the *derived* context. The original context has no cvec and no intervene registered, so its forward pass is identical to before any derivation. "Removal = use the original object" (D-003) is exact.
2. **The patch is a no-op on the un-intervened path.** Even on the derived-then-discarded path, `build_cvec` with no registered mask emits the identical graph (§5.1), so any handle with an empty spec is bit-identical to an unpatched build.

This is **provable exactly in Rust** on the synthetic model (same backend, same run → bitwise equality, not merely within tolerance): §7.1 step 4.

---

## 7. Golden-first test plan (Harness B extension) — the numerical gate before any R work

### 7.1 Synthetic intervention golden (exact oracle) — `[SYNTHETIC]`, runs in CI

Via the **`golden-update` skill** (the only sanctioned way to touch goldens), extend the numpy oracle, then gate the engine against it in Rust — exactly the WP4 `synthetic_trace.rs` pattern.

**Oracle extension (`reference_forward.py`).** Add an `intervene` parameter to `hidden_states(...)` that applies, at the existing `build_cvec` site (right after the second residual add, where `residual` is snapshotted, L223-230), for each layer `il`:

```python
if intervene and il in intervene.steer:  x = x + intervene.steer[il]          # coef*direction
if intervene and il in intervene.ablate: x[:, intervene.ablate[il].neurons] = intervene.ablate[il].value
```

so the steered/ablated `x` flows to `l_out-<il>` **and** downstream (the next block's input) — matching the engine. New golden arrays under `goldens/`: `intervene_steer_logits.npy` (steer engine `il = 1` — the only native-cvec-steerable layer on the 2-layer model, §1.4 — by a fixed, **exactly-F32-representable** vector, `coef = 1`), `intervene_ablate_logits.npy` (ablate a fixed neuron `k` of engine `il = 0`'s residual to `0` — exercising the full-coverage layer the native cvec *cannot* reach), and `intervene_both_logits.npy` (steer `il = 1` + ablate `il = 0`, composed). These are pure re-runs of the same forward pass, so the existing `logits`/`embeddings`/`activations` goldens **do not drift** (`python reference_forward.py --check` enforces this, plus the same-machine determinism assertion, plus the cross-consistency checks already in the oracle).

**Rust de-risking gate `tests/synthetic_intervene.rs`** (the numerical gate; mirrors `synthetic_logits.rs`/`synthetic_trace.rs`; CPU, download-free, per-commit CI). Load the synthetic GGUF; then:

1. `base = model.logits_for_tokens(&INPUT_TOKENS)` → assert within `ATOL` of committed `logits.npy` (the baseline).
2. `steered = model.derive_with_interventions(steer il=1 by v)?.logits_for_tokens(...)` → assert within `ATOL` of `intervene_steer_logits.npy` **AND** `max_abs_diff(steered, base) >> ATOL` (proves the steer had an effect — the honesty guard: a silent no-op fails here).
3. `ablated = model.derive_with_interventions(ablate il=0 neuron k)?.logits_for_tokens(...)` → assert within `ATOL` of `intervene_ablate_logits.npy` **AND** differs from `base` by `>> ATOL`.
4. **Reversal:** `model.logits_for_tokens(&INPUT_TOKENS)` **again** → assert **bitwise-equal** to step 1's `base` (same context, untouched by the derivations) — the strongest form of the bit-for-bit acceptance.
5. **Composition:** steer-then-ablate → assert within `ATOL` of `intervene_both_logits.npy`.
6. **Unsupported-arch / unreachable-layer:** assert the arch allow-list and the `layer = 1` steer rejection surface `RebirthError::Intervention` (unit-level, no special model needed).

`ATOL` starts from the WP2 logits tolerance (`1e-2`, observed F32-vs-F64 gap ~2e-3) and tightens to observed; the `>> ATOL` effect-size assertions make "the intervention did nothing" fail loudly. Value = 0 zeros exactly; the steer vector is exactly F32-representable — so the only gap is downstream F32 accumulation, the same regime the logits golden already tolerates.

### 7.2 CI-model statistical fixtures — `[MODEL]`, gated / nightly (with WP6b)

The two ROADMAP §5 WP5 acceptance fixtures, on Qwen2.5-0.5B (`REBIRTH_TEST_MODEL_QWEN`), with **committed, pinned inputs** so they are deterministic:

- **Steering shifts valence.** A committed held-out prompt set + a committed sentiment direction (a pinned `hidden_size` vector — derivable once via a `llm_trace` diff-in-means over a contrast set, but **pinned as a test artifact** so the fixture does not couple to trace and stays fast/deterministic; the full trace→direction pipeline is Demo A, WP7) + a valence scorer. **Executable threshold:** `mean valence(steer +coef) > mean valence(baseline) > mean valence(steer −coef)` with the per-prompt shift in the expected direction for a documented majority (e.g. a one-sided sign test p < 0.05, or a fixed minimum mean-shift), asserted in a `testthat` fixture.
- **Random vs targeted ablation (the honesty fixture).** Committed "targeted" neuron sets (e.g. a pinned high-|weight| or probe-selected set) vs matched-size random sets. **Executable threshold:** `effect(targeted) / effect(random) > T` for a documented `T`, where `effect` = mean KL divergence of the next-token distribution from baseline over the prompt set (or a permutation-test gap). This is the "matched-random ≈ null vs targeted" evidence that keeps the ablation claim honest.

Both are `[MODEL]` (skipped without the env var) and run in the nightly job coordinated with **WP6b**; WP5 delivers the fixtures + committed artifacts, WP6b wires the nightly cadence.

### 7.3 R argument/error + handle tests — `[NOW]`, CI

Using a stubbed/fixture handle: each bad `layer`/`direction`/`neurons`/`coef`/`value`/`component`/`positions` → its `rebirth_error_intervention` (with the offending field); the §1.4 `layer = 1` steer → the classed error; `positions` subset for steer → the classed error; `component != "residual"` for ablate → the classed error; an unsupported architecture → the classed error. **Handle contract:** deriving a steered/ablated handle leaves the source object's `interventions` empty and its `state$closed` false; `print.llm`/`summary.llm` show the derived handle's intervention count; closing the derived handle does not close the source (independent `state` envs); composition stacks the list. `[MODEL]` bit-for-bit at the R level (`llm_generate` with a fixed seed on the original handle == the pre-intervention golden string) is on the founder's Mac (§10).

---

## 8. Step-by-step implementation order (mapped to ROADMAP §5 WP5)

Guiding rule: **goldens/tests first; small commits; a Rust panic reaching R (or the graph) is a bug.** The `[NOW]`/`[SYNTHETIC]`/`[MODEL]` tags follow WP4.

**Step 1 — Oracle + golden extension (the numerical gate first).** `[SYNTHETIC]`
Extend `reference_forward.py` with the `intervene` hook and emit `intervene_{steer,ablate,both}_logits.npy` via the `golden-update` skill; `python reference_forward.py --check` proves no drift of the existing goldens.
- **Verify:** `--check` green; the new goldens load and differ from baseline by `>> ATOL`.

**Step 2 — The vendored patch (§5).** `[NOW] structure / [SYNTHETIC] values` · **first patch, D-015**
`llama_adapter_intervene` (adapter) + the 7-file plumbing; the `build_cvec` no-op-when-empty hunk; `llama_set_intervene` C API; land the annotated diff per the D-015 decision (recommended: commit patched tree + update `VENDORING.md`/`patches/README.md`). FFI decls for both setters (§2).
- **Verify:** the engine builds; **existing WP2/WP3/WP4 synthetic goldens still pass byte-identically** (proves the empty-path graph is unchanged); `cargo clippy -D warnings`, `fmt --check`; the G4 SHA check passes against the updated `VENDORING.md`.

**Step 3 — Engine intervention surface (§3).** `[NOW] structure / [SYNTHETIC] values`
`intervene.rs` with `InterventionSpec`; `LoadedModel::derive_with_interventions` (fresh context on cloned `Arc<Model>`, apply cvec/intervene); `check_intervention_supported` (arch allow-list); `error.rs` `Intervention` variant.
- **Verify:** `tests/synthetic_intervene.rs` (§7.1) steps 1-6 green on CPU — **the de-risking gate**: steer/ablate match the oracle, differ from baseline, and the base is bitwise-unchanged after derivation.

**Step 4 — FFI boundary + R surface (§4).** `[NOW]`
`rebirth_intervene` entry (index conversion + spec build + fresh-handle payload); `intervene.R` `llm_steer`/`llm_ablate` with all R-side validation and the §1.4/§1.5 honest-limit errors; `new_llm_derived`; the interventions-list composition (§3.2).
- **Verify:** the §4.1 layer-mapping unit test; R argument/error/handle tests (§7.3); `cargo test`, `devtools::test()`.

**Step 5 — Statistical fixtures + harness B coordination (§7.2).** `[MODEL] nightly (with WP6b)`
Committed prompt sets, pinned sentiment direction, targeted/random neuron sets, valence + KL scorers; the two `testthat` fixtures with executable thresholds, gated on `REBIRTH_TEST_MODEL_QWEN`.
- **Verify:** fixtures pass on the CI model locally; coordinate the nightly cadence with WP6b.

**Step 6 — Phase-boundary hygiene.** `[NOW]`
`simplifier` (mandatory at phase end / >~500 lines — WP5 will exceed it); `reviewer`; `security-auditor` at the FFI/patch boundary (confirm §2 ABI still 160, the two setters' SAFETY, the patch's bounds, no new thread); `doc-writer` once acceptance passes.

**Blocked-now summary**

| WP5 acceptance criterion | Status | Where |
|---|---|---|
| Steering shifts a valence score on held-out prompts | **[MODEL]** nightly (with WP6b) | Step 5 |
| Matched-random ablation ≈ null vs targeted (honesty fixture) | **[MODEL]** nightly (with WP6b) | Step 5 |
| Original handle reproduces outputs bit-for-bit after derivation | **[SYNTHETIC]** exact (CI) + **[MODEL]** (Mac) | Steps 3,7 / §10 |
| R CMD check clean; cargo test green | **[NOW]** | Steps 2-6 |

---

## 9. WP5 ACCEPTANCE (verbatim, ROADMAP §5) — the definition of done

**ACCEPTANCE**
- Steering along a sentiment direction measurably shifts a valence score on held-out prompts (statistical fixture, CI model, committed prompt sets).
- Ablating matched RANDOM neurons ~ null effect vs targeted ablation (the honesty fixture).
- Using the original handle after creating steered/ablated ones reproduces original outputs bit-for-bit.
- R CMD check clean; cargo test green.

**FORBIDDEN**
- In-place mutation of any handle; weight modification; new dependencies.

(Honored: interventions return **new** handles built on a fresh context over shared read-only weights — the source is never mutated (§3.3, §6), and "removal = use the original object" is exact. The patch touches **activations only** via a graph op (`x*mask + add`, `+ steer`) — **no weight is modified**; the adapters set no `llama_model` tensor. The recommended patch-application path (D-015 Option 1) adds **no new dependency** (steering reuses the native cvec; ablation is a source patch, not a crate). Bit-for-bit reversal is proven exactly in `synthetic_intervene.rs` (§7.1 step 4). Goldens are numpy-generated via the `golden-update` skill, never hand-edited.)

---

## 10. `[MODEL]` acceptance on the founder's Mac

Once Steps 1-4 are green in CI, the founder runs the `[MODEL]` items locally (Metal — the empirical confirmation §1.5 defers to): (1) the two statistical fixtures on Qwen2.5-0.5B (valence shift; targeted-vs-random ablation) with the documented thresholds; (2) the R-level bit-for-bit reversal — `llm_generate(original, prompt, seed = S)` **after** creating steered/ablated handles equals the pre-intervention generation byte-for-byte. These close the WP.

---

## 11. Scope discipline (backlog notes — NOT WP5 scope; for a future `DECISIONS.md` note)

Per planning rule 5, out-of-scope ideas go to a backlog note, not the WP list:

- **Full-coverage steering (API `layer = 1`)** — reachable only by routing steering through the intervene adapter (§1.4 Option B), a one-line-per-layer add on the adapter we already ship; deferred unless the founder adopts Option B (which supersedes D-012's "steering zero-patch").
- **Position-restricted steering** (`positions` a subset) — needs graph-level position masking neither the cvec nor a simple mask-add provides; the native path is all-positions.
- **`attn_out` / `mlp_out` ablation** (beyond the default `residual`) — distinct per-component patch sites (no shared choke point); the WP4 backlog note. Head ablation is the ROADMAP §3 WP5 "stretch" (only "if the ADR made it cheap" — it did not; it needs a `z`-object component, an API-GRAMMAR addition, D-014's chartered pre-projection component).
- **Tracing an intervened handle** — `llm_trace` builds its own transient trace context from the model (§0), which does **not** inherit a handle's interventions, so today tracing a steered/ablated handle traces the *base* forward pass. Reconciling this (apply the handle's interventions to the trace context) is deferred to WP6b/Phase 6 (live introspection). WP5 tests intervention effects via **logits/generation**, not via a concurrent trace.
- **Shared / transient intervention context** — the memory optimization over one persistent context (and KV cache) per intervention handle (§3.3), for holding many intervention handles on 16 GB.
- **`llm_logits`** (the R-facing Phase-2 entry) — a separate Phase-2 item, not WP5; the synthetic gate uses the engine's `logits_for_tokens` directly.

---

## 12. What the founder must decide, and the exact next action

**This is an implementation plan under the already-accepted D-012/D-014, so it needs no new spike.** Two genuinely-new items the b9726 source surfaced need a founder call before/at implementation:

1. **Patch-application mechanism (proposed ADR D-015, below).** WP5 is the first vendored patch; how it lands interacts with D-008 G4. **Recommendation: Option 1 — commit the patched tree, update `VENDORING.md` (both SHAs) and `patches/README.md`, keep the annotated diff in `patches/`.** Zero new dependency, CRAN-robust, G4-honest. (Option 2, build-time apply, needs a patch tool / diff-applier crate — a separate dependency ADR.)
2. **Steering the first block (API `layer = 1`, §1.4).** The native control vector cannot reach engine `il = 0`. **Recommendation: Option A — raise `rebirth_error_intervention` for a `layer = 1` steer** (respects D-012; honest; narrow). Option B (route steering through the ablation adapter for full coverage) is cheap given our adapter's design but deviates from D-012's "steering zero-patch" letter and would need a one-line superseding note — offered, not recommended.

Everything else is specified: the steering path (native cvec, §1.1), the ablation patch (§5, exact hunks), the handle/context model (§3.3, no interior mutability — the D-008 G2 answer), the arch allow-list (§1.3), the golden gate (§7.1), and the two documented honest limits (steer positions-subset; ablate non-residual component). **No empirical CPU+Metal probe is warranted** (§1.5): ablation is a native graph op, not the host-mutation callback D-012 rejected.

**Exact next action:** the founder reviews (1) proposed **D-015** and (2) the §1.4 steering-layer-1 recommendation. On acceptance the founder appends D-015 to `DECISIONS.md` (and, if Option B is chosen for §1.4, a one-line superseding note to D-012); then the `coder` starts WP5 at **Step 1** (oracle + golden extension — the numerical gate), proceeding to Step 2 (the patch) and Step 3's `synthetic_intervene.rs` de-risking gate before the R surface and the `[MODEL]` fixtures.

---

## Deliverable — ADR (proposed), ready to append to `DECISIONS.md`

```
## D-015 — vendored-patch application: commit the patched tree
- **Date:** 2026-07-06 · **Status:** proposed
- **Decision:** vendored llama.cpp patches (starting with the WP5 ablation hook at
  build_cvec, D-012) are APPLIED to the committed src/llama.cpp/ tree, not applied at
  build time. VENDORING.md records BOTH the upstream b9726 base tree SHA256 (provenance)
  AND the post-patch tree SHA256 (the value D-008 gate G4 asserts in CI). The annotated
  unified diff for each patch stays in src/llama.cpp/patches/ as the human-readable,
  vendor-bump-reappliable delta; patches/README.md is updated from "applied by build.rs"
  to "applied to the committed tree; patches/ is the provenance diff." build.rs is
  unchanged (it compiles the tree as-is). vendor-bump: fetch upstream, re-apply
  patches/*.diff, re-run harness B, re-record both SHAs.
- **Why:** WP5 is the project's first vendored patch, so the mechanism must be fixed once.
  Committing the patched tree needs NO build-time patch tool and NO new dependency (the
  no-new-dependency rule), and is CRAN/R-CMD-INSTALL-robust — CRAN's build farm compiles
  the tree as shipped, the standard way R packages distribute patched vendored C. G4's
  purpose is to catch a SILENT change to the engine; a deliberate, documented patch that
  updates VENDORING.md and lands an annotated diff in patches/ is not silent, so G4 still
  fires on any undocumented drift. The build_cvec hunk is a no-op on the un-intervened path
  (D-012), so the patched tree's default behaviour and every existing golden are unchanged
  (verified: WP2/WP3/WP4 synthetic goldens pass byte-identically after the patch).
- **Alternatives rejected:** apply patches at build time from build.rs (keeps the tree
  pristine-diffable, but needs either a fragile external `patch`/`git apply` not guaranteed
  on the eventual Windows/CRAN build matrix, or a new Rust diff-applier build-dependency —
  an ADR and more vendored surface, for no benefit the committed diff does not already give);
  keep the tree pristine and forgo patches (impossible — D-012 authorized the ablation patch,
  and a native graph op is the settled ablation mechanism); commit the patched tree WITHOUT
  recording the base SHA (loses upstream provenance and makes vendor-bump's re-apply
  unauditable).
- **Scope note:** authorizes the application MECHANISM only; each patch's CONTENT is
  governed by its own ADR (the ablation hook by D-012; the chartered attn_out naming patch,
  D-014, by its own). No new dependency is introduced by this decision.
```

---

## Addendum — independent review (2026-07-06): accepted corrections

The founder delegated the WP5 calls to an independent review, which verified every source citation at b9726, concurred with both recommendations (D-015 Option 1; layer-1 Option A), and surfaced corrections — three genuinely missed by §0–§12. These are **accepted and binding on the implementer**; where they differ from the body above, they win. Recorded as accepted **D-015** (with strengthenings) + **D-016** in `DECISIONS.md`.

**D-015 strengthenings (patch application):**
1. `VENDORING.md` records **three** SHAs, not two: upstream tarball SHA, the current **pre-patch** pruned-tree SHA (keep the existing row), and the new **post-patch** pruned-tree SHA (the value G4 asserts).
2. `vendor-bump` (and CI) gain a **patch-coherence check**: reverse-apply `patches/*.diff` to the committed tree, recompute the digest, assert it equals the recorded pre-patch SHA (catches the committed tree and the diff silently drifting apart).
3. **G4's CI SHA assertion does not exist yet** (verified: no workflow/script/`build.rs` computes or asserts the pruned-tree SHA). WP5 **Step 2 MUST wire it** — one CI step running the documented digest command and asserting it matches `VENDORING.md`. The body's "the G4 check passes" presumes a check that must first be created.

**Layer-1 steer (Option A) refinements:**
4. The `rebirth_error_intervention` message names the structural reason (native control-vector reserves engine index 0) and both workarounds (steer layers 2..N; ablate layer 1).
5. `vendor-bump` re-checks the index-0 reservation itself (`llama-adapter.cpp` L65/L127) — if upstream lifts it, we lift the error.

**Critical-pass findings (all accepted):**
6. **Compose order is MANDATED:** `intervene->apply_to` AFTER `cvec->apply_to`, so `(x+steer)⊙mask+add` forces the ablated neuron to exactly `value` (grammar §4). Document in both roxygen that the semantics are **derivation-order-independent** (`ablate|>steer` == `steer|>ablate`; a steer never moves an ablated neuron).
7. The intervene adapter registers tensors **only for layers with a genuine ablation** (detect non-identity rows at `apply()`), so an in-range untouched layer emits no `x*1+0` node.
8. Document that `llm_steer`/`llm_ablate` are **not free** (each derivation allocates a fresh context — a sub-second pause + ~100–300 MB KV/compute on the pinned models); add a §7.3 test that **closing the source handle first** leaves a derived handle working (`Arc<Model>` keeps weights alive).
9. **Arch allow-list honesty:** keep `{llama, qwen2, gemma3}` in the seed (mechanism is arch-generic; `build_cvec` verified at `gemma3.cpp` L194; erroring on the thesis-model family would be self-inflicted) BUT state the tiering — **llama + qwen2 = fixture-covered; gemma3 = source-verified at b9726, runtime fixture chartered for WP6b/thesis-era.** Amend the "we claim only what a golden covers" wording accordingly.
10. **CERTAIN SPEC FIX — §3.1 steer-buffer layout is wrong.** The native layout has **no layer-0 row**: engine layer `il`'s vector sits at offset `n_embd*(il-1)` (`llama.h` L691 "buffer starting from layer 1"; `llama-adapter.cpp` L127). Store the buffer natively (`n_embd*(n_layer-1)`, offset `il-1`) OR keep an `n_layer`-row internal form and pass `&steer[n_embd..]` at the FFI call — state which. As written, §3.1 misaligns every steer by one layer. Also place the oracle intervene hook **after** residual-add-2 (`reference_forward.py` L223) and **before** the L227 capture; and choose the ablated neuron + steer vector **by measured effect** (the synthetic model is random-seeded — a weak neuron makes the `>>ATOL` assertions marginal).
11. Document composition: steering **stacks by summation** (control vectors compose additively; sum in R = better f64 accumulation); ablation is a **union, last-write-wins** per `(layer, neuron)`.
12. **MISSED GAP — intervened-handle embed/trace silently compute the BASE pass.** `EmbeddingContext`/`TraceContext` are built fresh from the `Arc<Model>` and never inherit the intervention adapters, so `steered |> llm_embed()` would return base vectors *labeled* as steered (the silent-mislabeling class D-012/D-014 forbid). WP5 adds R-side guards: `llm_embed`/`llm_trace` on a handle with `length(interventions) > 0` raise `rebirth_error_embed`/`rebirth_error_trace` ("interventions currently apply to generation/logits only; embedding/tracing an intervened handle is not yet supported"). Two lines + two tests each; the capability stays backlogged.
13. **KL fixture is not computable in R at WP5** (`llm_logits` is out of scope; `llm_generate` returns character). The ablation honesty fixture is an **env-gated Rust integration test** (`rebirth-llm/tests/`, softmax + KL from `logits_for_tokens` over committed prompts — ROADMAP says "statistical fixture," so compliant). The valence steering fixture stays R `testthat` (via `llm_generate`) with a **small original committed lexicon** + a provenance script (no AFINN/third-party lexicon — licensing + no-new-dependency). An R-level KL twin is a backlog note for when `llm_logits` ships.
14. Patch hunk table gains one line: `intervene == other.intervene` in the graph-reuse equality (`llama-graph.h` L690, beside `cvec ==`). Hunk count 13 → 14; vacuously true today, but "mirror cvec exactly" means exactly.
15. Name the new public C symbol **`rebirth_set_intervene`** (not `llama_set_intervene`) — project-prefixed patch-added API = greppable provenance + no upstream-collision risk. The internal `llama_adapter_intervene` type may keep the mirror name.
16. Map non-zero returns from both C setters to `RebirthError::Intervention` (never ignore); keep `rebirth_intervene` package-internal (D-008 G3 not newly triggered); keep Step 2's "existing WP2/WP3/WP4 goldens pass byte-identically after the patch" as the empirical no-op proof; the D-014 attn_out naming patch rides as its own ADR/PR (it moves the patched-tree SHA a second time — sequence it).

Nothing else in §0–§12 changes. Steering = native (zero patch); ablation = the guarded `build_cvec` patch. The coder starts at Step 1 (oracle + goldens), Step 2 wiring G4.
