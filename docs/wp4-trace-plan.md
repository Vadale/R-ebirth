# WP4 — Activation taps + `llm_trace()`: day-1 spike, plan & ADRs

**Author:** architect agent · **Date:** 2026-07-06 · **Status:** planning artifact for founder review.
**Scope:** ROADMAP §3/§5 Phase 2 / WP4 ("Activation taps + `llm_trace()`"), the first WP of the anatomy lab. WP0/WP1/WP6a/WP2/WP3 merged to `main` (Phase 1 complete). Branch `wp4-trace`.

This document contains four deliverables:

1. **The day-1 spike findings** (mandatory first step of WP4, ROADMAP §5) — answered against the *actual* vendored engine at `rebirth/src/llama.cpp/` (tag **b9726**), not from memory:
   - **Q1 — Observation** (the `llm_trace` path): is Strategy A real? → **Yes, zero patch.**
   - **Q2 — Mutation** (decides WP5 `llm_ablate`): can the eval callback mutate a tensor so downstream compute sees it? → **Not fully settleable from source on Metal; the recommendation routes around it.**
2. **The WP4 implementation plan** — mapped to ROADMAP §5 WP4 Steps 2–6, golden-first, each step independently verifiable, with the WP4 ACCEPTANCE restated verbatim.
3. **ADR (proposed) D-012** — activation-tap strategy (observation + the ablation-mutation mechanism).
4. **ADR (proposed) D-013** — spill dependencies (`nanoarrow` + the Rust Arrow-IPC writer).

**I do not edit `DECISIONS.md` or any root planning doc, nor any `.R`/`.rs`/`.py` source** — the founder appends the accepted ADRs and the coder writes the code from this plan. Nothing here changes the approved API surface: `llm_trace(...)`, `as.matrix.rebirth_trace`, the `rebirth_trace` schema, and the condition classes (`API-GRAMMAR.md` §2/§4/§6) are **binding (D-003)**; this plan decides only the *implementation strategy* and the two new dependencies behind that fixed surface.

**The ROADMAP mandates a STOP for founder approval on the spike ADR before any implementation** (WP4 Step 1, and the WP4 FORBIDDEN list: "Any implementation before the spike ADR is approved"). Both ADRs below are written to be decision-ready.

The precedent docs are `docs/wp1-plan.md` (D-005/D-006) and `docs/wp3-embed-plan.md` (D-011); this follows their structure.

---

## 0. What is fixed before we start (verified against the vendored b9726 source)

Every row was checked by reading the file cited — this is the spike's evidence base.

| Fact | Source (verified, b9726) |
|---|---|
| `llm_trace(m, prompts, layers = NULL, positions = "last", components = "residual", spill = TRUE, spill_dir = NULL)` → `rebirth_trace`; `as.matrix.rebirth_trace(x, layer, component = "residual", ...)`; `print`/`summary`. Schema (exact order): `prompt_id`⟨int⟩, `token_pos`⟨int⟩, `token`⟨chr⟩, `layer`⟨int⟩, `component`⟨chr⟩, `neuron`⟨int⟩, `value`⟨dbl⟩. | `API-GRAMMAR.md` §2/§4, `[approved]` binding |
| The scheduler eval-callback typedef: `typedef bool (*ggml_backend_sched_eval_callback)(struct ggml_tensor * t, bool ask, void * user_data);` with the documented `ask` contract (ask=true → "do you want to observe this node?"; ask=false → "node computed, data ready; return false to cancel compute"). | `ggml/include/ggml-backend.h` L307–314 |
| The context params carry `cb_eval` + `cb_eval_user_data` (a `ggml_backend_sched_eval_callback` and a `void*`); llama copies them into `cparams` and installs them on the scheduler at context creation via `ggml_backend_sched_set_eval_callback`. Default is `nullptr`. | `src/llama-cparams.h` L53–54; `src/llama-context.cpp` L88–89, L1329, L3466–3467 |
| Our `#[repr(C)] llama_context_params` mirror already carries `cb_eval` / `cb_eval_user_data` (fields 22–23, opaque `*mut c_void`), currently passed as **null**. The struct was ABI-verified for WP3 (size = 160, guarded by an executable test). | `ffi.rs` L118–119, L96–133, L281–298 |
| **The callback invocation, verbatim** (the crux for both Q1 and Q2): the scheduler asks (`ask=true`) per node to batch un-observed nodes, computes the range `[j0..j1]` in one async submission, **`ggml_backend_synchronize`s**, then for the boundary node calls `ask=false` (data ready). Downstream nodes are in the *next* iteration, **not yet computed**. | `ggml/src/ggml-backend.cpp` L1677–1714 |
| Graph tensor names are set at construction by `ggml_format_name(cur, "%s-%d", name, il)` for `il ≥ 0`, else `ggml_set_name(cur, name)` (final norm, `il = -1`). So compute-graph node names are `"<name>-<il>"` with **0-based** `il`. | `src/llama-context.cpp` L2446–2452 |
| Component → tensor name (during a **plain** trace, no interventions): `residual` = `l_out-<il>`, `mlp_out` = `ffn_out-<il>`, `attn_out` = `attn_out-<il>` (llama/gemma) or `kqv_out-<il>` (qwen2, via `build_attn`). | `src/models/qwen2.cpp` L111/125/130; `src/models/llama.cpp` L172/195/221/224; `src/models/gemma3.cpp` L185/195; `src/llama-graph.cpp` L2261 |
| `build_cvec` (the residual choke point every arch routes through before `l_out`) is a **no-op when no control vector is loaded** (`tensor_for(il)==nullptr` → returns `cur` unchanged). This is why the double-`ffn_out` naming in `llama.cpp` (L195 raw FFN, L221 residual-add) collapses cleanly during a plain trace: L221's tensor is passed through `build_cvec` and re-named `l_out-il` at L224, leaving `ffn_out-il` = only the raw FFN output. | `src/llama-adapter.cpp` L22–29; `src/models/llama.cpp` L220–224 |
| Accessors the tap needs all exist, so **no `ggml_tensor` struct mirror is required**: `ggml_get_name` (name match), `ggml_nbytes`/`ggml_nelements` (size), `ggml_backend_tensor_get`/`_set` (host copy in/out). | `ggml/include/ggml.h` L736–738, L865; `ggml/include/ggml-backend.h` L92–93 |
| Metal buffers on Apple Silicon are **shared / host-visible unified memory** (`use_shared_buffers = has_unified_memory`; `newBufferWithBytesNoCopy … MTLResourceStorageModeShared`). Relevant to Q2: `ggml_backend_tensor_get/_set` are host memcpys, not PCIe DMA. | `ggml/src/ggml-metal/ggml-metal-device.m` L832–841; `ggml-metal-context.m` L313, L354–356 |
| Last-layer output pruning: at `il == n_layer-1` the graph does `ggml_get_rows(cur, inp_out_ids)`, keeping only flagged output positions — **unless** `n_outputs == n_tokens`, in which case the map is the identity. So flagging *all* prompt tokens as outputs makes every layer's tapped tensor carry all `n_tokens` rows in token order (uniform indexing). | `src/models/qwen2.cpp` L106–108; `src/models/llama.cpp` L174–176; `src/llama-graph.cpp` L222 |
| **The vendored tree is pruned** (D-006): `tools/` and `examples/` are absent, so the `llama-imatrix` precedent is **not in-tree**. The observation evidence therefore comes from reading the scheduler invocation itself (stronger than reading a tool). | `VENDORING.md`; `ls tools examples` → absent |
| Synthetic golden model = a faithful **2-layer `llama` decoder** (`arch=llama`, `n_embd=32`, `n_layer=2`, `n_head=4`, SwiGLU, F32, `no_vocab`), input `INPUT_TOKENS=[1,7,13,22,5,31,44,2]`. It uses `src/models/llama.cpp`, so `attn_out-{0,1}`, `ffn_out-{0,1}`, `l_out-{0,1}` are all present and exactly recomputable in numpy — **all three components are golden-testable exactly**. | `tests/llm-golden/synthetic/synthetic_model.py` L32–58; `reference_forward.py` L174 |
| First background Rust thread appears in WP4 (the spill sink) → **reopens D-008 gate G2** (`Send`/`Sync` enforcement). Index discipline (1-based↔0-based only in `rebirth-ffi`, property-tested) applies to `layers`/`positions`/`neurons`. | `DECISIONS.md` D-008 G2; `ARCHITECTURE.md` §3/§4 |
| No new dependency (R or Rust) without an approved ADR — the spill path needs two (D-013). | ROADMAP §5 WP4 FORBIDDEN; D-006 |

---

## 1. The spike — findings

### 1.1 Q1 — Observation: **Strategy A is real. Zero patch.**

**Confirmed.** llama.cpp exposes exactly the observation hook `ARCHITECTURE.md` §5 promised, and the mechanism is settled at b9726 by reading the scheduler itself.

The callback loop (`ggml-backend.cpp` L1682–1713), in words:

1. For each graph node the scheduler calls `callback_eval(t, ask=true, user_data)` — "does the user want to observe node `t`?" It batches consecutive *un-wanted* nodes into one compute range `[j0..j1]`, stopping at the first node the user wants.
2. It computes the range in one `ggml_backend_graph_compute_async`, then **`ggml_backend_synchronize`** (L1706) — the range's outputs are now fully computed and, for the boundary node, host-readable.
3. It calls `callback_eval(t, ask=false, user_data)` for the wanted boundary node — **data ready**. (Returning `false` here cancels the rest of the compute; the tap always returns `true`.)

So the tap is precisely:

- **ask=true handler:** return `true` iff `t`'s name matches the capture spec (a cheap prefix/parse of `ggml_get_name(t)` against the requested `{component → name}` set and the requested layer set). This makes each wanted tensor a compute boundary.
- **ask=false handler:** the tensor is computed; `ggml_backend_tensor_get(t, host_buf, 0, ggml_nbytes(t))` copies its `n_embd × n_tokens` f32 to a host buffer; select the requested positions' rows and push them to the sink. Return `true`.

**Zero patch.** The only additions are FFI *declarations* (accessors) and *writing* the already-mirrored `cb_eval`/`cb_eval_user_data` — no llama.cpp source is touched. This preserves the harness-B baseline (an unpatched build at the same tag is behaviourally identical, `VENDORING.md`) and keeps `vendor-bump` mechanical.

**Tap-off overhead = 0, structurally.** The callback is installed only on a **dedicated, transient trace context** created per `llm_trace` call (the D-011 pattern), never on the generation context. When `cb_eval == nullptr` the scheduler takes the `if (!sched->callback_eval)` fast path (L1677) with no per-node calls. So generation and every non-trace path pay literally nothing — the `< 2%` acceptance budget is met by construction, and the benchmark script only has to *demonstrate* it.

**The imatrix precedent** (`ARCHITECTURE.md` §5's "strongest evidence") is genuine but **external** — the prune (D-006) dropped `tools/`, so it is not in our tree. That is fine and arguably better: the evidence above is the scheduler's own invocation code + the documented `ask` contract, which is more authoritative than a tool's usage. Upstream `llama-imatrix` does exactly this (register `cb_eval`, at ask=false `ggml_backend_tensor_get` the matched tensor) — our design matches it.

### 1.2 Q1 — component → tensor-name map (the capture matcher)

During a **plain forward pass** (no interventions — which is exactly what `llm_trace` runs, API-GRAMMAR §4 "no sampling"), the final names are clean and consistent for the residual and MLP components; the attention component is architecture-dependent:

| API component | Engine tensor name | Verified in | Note |
|---|---|---|---|
| `residual` | `l_out-<il>` | qwen2 L130, llama L224, gemma3 L195 | the block-output residual stream (post-attn+FFN, post-`build_cvec`). Consistent across all archs. |
| `mlp_out` | `ffn_out-<il>` | qwen2 L125, llama L195, gemma3 L185 | the raw FFN/MLP sub-layer output (before the residual add). The `llama.cpp` L221 re-use of `ffn_out` is renamed to `l_out` by `build_cvec`+L224 during a plain trace, so no collision. MoE archs name it `ffn_moe_out-<il>` — out of WP4 scope (no pinned MoE model). |
| `attn_out` | `attn_out-<il>` (llama, gemma) **or** `kqv_out-<il>` (qwen2) | llama L172; qwen2 via `build_attn`→`llama-graph.cpp` L2261 | **architecture-dependent.** The tap matches the alias set `{attn_out, kqv_out}` for this component. |

**Design consequence:** the matcher is a tiny per-architecture alias table, not a hard-coded name. WP4 ships it for the three demo/CI families (llama, qwen2, gemma3) plus the alias fallback; an unknown architecture with no match for a requested component → `rebirth_error_trace` naming the component and architecture (honest, never a silent empty capture). The **synthetic model is `llama`**, so all three components are matched and golden-tested exactly in CI.

**Layer index:** `<il>` in the name is **0-based** (the C loop `for (int il = 0; il < n_layer; ++il)`). API layer `1` → engine `il = 0`. This is the canonical off-by-one site — the 1-based→0-based conversion happens **only** in `rebirth-ffi` (ARCHITECTURE §4), and the property test round-trips it. The name parse (`"l_out-7"` → `il = 7` → API `layer = 8`) is the natural place a bug would hide, so it gets an explicit unit test on top of the property test.

**Position indexing (a real correctness gotcha).** Because of the last-layer `get_rows` prune (`§0` table), intermediate layers carry all `n_tokens` rows but the *last* layer carries only `n_outputs` rows unless `n_outputs == n_tokens`. To make row→`token_pos` mapping uniform and bug-resistant, the trace decode **flags all prompt tokens as outputs** (`ubatch.output[i]=1` ∀ i), so every tapped tensor has `n_tokens` rows in token order; the `positions` filter is then applied purely in host-side assembly. Cost: the final layer computes all positions even when `positions = "last"` — negligible for trace-length prompts, and capture memory is unaffected (the tap copies only the requested positions' rows). Optimization (flag only requested positions + a per-layer row map) is a backlog note, not WP4.

### 1.3 Q2 — Mutation: **cannot be fully settled from source on Metal; the recommendation routes around it.**

**The question** (decides WP5 `llm_ablate`): can a *modifying* eval-callback write `t->data` at ask=false such that downstream compute sees the change?

**What source establishes (positive):**
- ask=false fires **after** `ggml_backend_synchronize` (L1706), so on the **CPU backend** `t`'s buffer is host memory and directly writable; the tapped tensor's consumers (next layer's norm + residual add) are in the *next* scheduler iteration — **not yet computed** — so a write to `t` should propagate. `ggml-alloc` cannot have freed/reused `t`'s buffer yet, because its consumers have not run.
- On **Metal**, buffers are **shared unified memory** (`§0`), so `ggml_backend_tensor_set` is a host memcpy into a host-visible buffer, and the write sits between two fully-synchronized command-buffer submissions. This is *plausibly* visible to the next submission.

**What source cannot settle (the honest gaps):**
- **Metal command-buffer / cache visibility** of a host `tensor_set` performed *between* two submissions is not provable from reading ggml-metal — it depends on Metal's memory model and whether ggml re-uploads or caches. Shared storage makes it likely, not certain.
- **`ggml-alloc` buffer reuse / inplace aliasing:** for distinct `add`/`matmul` results (`l_out`, `ffn_out`, `attn_out`) aliasing is unlikely, but the allocator's inplace planning is not something I will certify from source for a *correctness-critical, always-on* intervention.

**Why this does not block, and the single recommendation.** WP4 (`llm_trace`) needs **only observation**, which is fully settled — so the Q2 uncertainty does not gate the current WP at all. For WP5 ablation, rather than resolve the Metal uncertainty, the recommendation **routes around it with a minimal native patch**, because ablation is a fundamentally different beast from a trace: it is **always-on** (it lives on the handle and applies to *every* `llm_generate` forward pass), composable, and must be **bit-for-bit reversible** (WP5 acceptance). For that profile a graph-native op is simply better engineering than a host round-trip on the generation hot path:

> **Recommended ablation mechanism: a minimal, single-site vendored patch at the residual choke point `llm_graph_context::build_cvec` (`src/llama-graph.cpp` L1079).** Every architecture routes its block-output residual through `build_cvec` before `l_out` (verified: qwen2 L129, llama L223, gemma3). Extend it (or add a sibling `build_intervene`) to apply a registered per-layer ablation mask — forcing the listed neurons of the residual to `value` — **guarded so it is byte-identical to the unpatched build when no ablation is registered for that layer**. This is native (Metal computes it as an op — no host-mutation-visibility question), generation-hot-path efficient (no per-node callback), architecture-agnostic for the default `component = "residual"`, and cleanly reversible (absent whenever no handle registers it, so the original-handle bit-for-bit acceptance holds by construction). The patch is one function + the plumbing to thread the spec into `llm_graph_context` (mirroring exactly how the existing control-vector `cvec` is threaded), each hunk annotated, living in `rebirth/src/llama.cpp/patches/` — squarely inside the D-006 patch budget.

The **modifying eval-callback** (ARCHITECTURE §5's listed option 1) is retained only as the **named zero-patch fallback**, for a founder who prioritizes "no vendored patch, ever" over hot-path cleanliness. That path is *not recommended* and, if chosen, **requires the empirical probe below before WP5** — I will not certify Metal mutation from source. Note §5 explicitly charters the spike to make this call ("Decision made by a 1-day spike"), so recommending option 2 is the spike exercising its mandate with evidence, not a contradiction of a settled decision.

**Empirical probe (required only if the founder picks the zero-patch callback fallback; NOT required for WP4 or for the recommended patch path).** A throwaway `#[cfg(test)]` in `rebirth-llm` on the **synthetic** model, run on **both** `BackendKind::Cpu` and `BackendKind::Metal`:
1. Create a context with a modifying eval-callback; at ask=false for `l_out-0`, zero neuron 0 of every token row via `ggml_backend_tensor_set`.
2. Run the full forward pass; capture the final logits.
3. Compare to a numpy oracle (extend `reference_forward.py`) that zeros the same neuron of the layer-0 output residual.
4. **Assert** engine logits match the *ablated* oracle within F32 tolerance **and** differ from the unablated oracle, and that the result is bit-stable across repeated runs on each backend. Print the max-abs-diff per backend.
If both backends pass reliably → the callback path is viable (adopt it). If Metal fails/is nondeterministic → the patch path (already the recommendation) is mandatory. **The parent agent orchestrates this probe if and only if the founder rejects the patch.**

**Steering (WP5, for completeness — not the spike's question):** confirmed to need **zero patch** — `build_cvec`/`llama_adapter_cvec::apply_to` (`src/llama-adapter.cpp` L22–29) *is* llama.cpp's native control-vector mechanism, adding a per-layer vector to the residual. `llm_steer` maps onto it directly, as `ARCHITECTURE.md` §5 states. (Ablation cannot reuse it: forcing `x[k] := value` is not expressible as a fixed additive vector, since it depends on the computed activation — so ablation genuinely needs the callback-or-patch decision above.)

---

## 2. FFI additions (`rebirth-llm/src/ffi.rs`) + the ABI checkpoint

### 2.1 New `extern "C"` symbols — the observation tap (WP4)

A new `// --- activation taps (WP4) ---` section. No `ggml_tensor` struct mirror (accessors only), honoring D-006's minimal, hand-written surface:

```rust
/// Opaque `struct ggml_tensor` (never dereferenced from Rust; passed to the
/// accessors below). The scheduler hands one to the eval callback per graph node.
#[repr(C)]
pub struct ggml_tensor { _opaque: [u8; 0] }

/// The scheduler eval callback (ggml-backend.h L314). ask=true → "observe this
/// node?"; ask=false → "node computed, data ready" (return false cancels compute).
pub type GgmlSchedEvalCallback =
    extern "C" fn(t: *mut ggml_tensor, ask: bool, user_data: *mut c_void) -> bool;

extern "C" {
    pub fn ggml_get_name(t: *const ggml_tensor) -> *const c_char;   // ggml.h L865
    pub fn ggml_nbytes(t: *const ggml_tensor) -> usize;            // ggml.h L738
    pub fn ggml_nelements(t: *const ggml_tensor) -> i64;           // ggml.h L736
    /// Copy tensor data to host (Metal→host memcpy on Apple silicon). ggml-backend.h L93.
    pub fn ggml_backend_tensor_get(t: *const ggml_tensor, data: *mut c_void, offset: usize, size: usize);
    // ggml_backend_tensor_set (L92) is added ONLY if the ablation callback fallback is chosen (D-012).
}
```

`cb_eval` / `cb_eval_user_data` are **already in the mirror** (`ffi.rs` L118–119); WP4 is the first code to *write* them (currently null), exactly as WP3 was the first to write `pooling_type`. We set `cb_eval = trace_trampoline as *mut c_void` and `cb_eval_user_data = Box::into_raw(capture_state) as *mut c_void` on the trace context's params.

### 2.2 ABI checkpoint (security-auditor, D-008)

No struct changes, so the existing `context_params_embedding_fields_have_the_expected_abi` test (`ffi.rs` L281–298, size = 160) already covers the layout WP4 relies on. Add one cheap assertion to it — `assert!(p.cb_eval.is_null() && p.cb_eval_user_data.is_null())` — so the two pointer fields WP4 now writes are pinned to their b9726 default offsets by a value check, not merely the size guard. **Security-auditor checkpoint at the WP4 boundary:** confirm the accessor signatures match `ggml.h`/`ggml-backend.h` at the vendored tag and that the trampoline is `extern "C"` with `catch_unwind` inside (a panic must never unwind across the C ABI into the scheduler — see §4.2).

---

## 3. Rust engine surface (`rebirth-llm`, R-free)

New module **`rebirth/src/rust/rebirth-llm/src/trace.rs`** (mirrors how `generate.rs`/`embed.rs` isolate an algorithm), wired via `mod trace;` + re-exports in `lib.rs`. All C-FFI `unsafe` minimal and individually SAFETY-commented (D-009); no R types anywhere.

### 3.1 Capture spec (engine-native, 0-based)

```rust
/// What to capture. All indices are ENGINE-native (0-based) — the 1-based→0-based
/// conversion already happened in rebirth-ffi (ARCHITECTURE §4).
pub struct CaptureSpec {
    pub layers: Option<Vec<u32>>,       // None = all blocks
    pub positions: Positions,           // Last | All | Explicit(Vec<u32>)
    pub components: Vec<Component>,      // subset of {Residual, AttnOut, MlpOut}
}
pub enum Component { Residual, AttnOut, MlpOut }
```

A per-architecture matcher resolves `Component` → the name alias set (§1.2) once at context setup:

```rust
/// Names to match for each requested component, for this model's architecture.
/// residual→["l_out"], mlp_out→["ffn_out"], attn_out→["attn_out","kqv_out"].
fn component_names(arch: &str, comp: Component) -> &'static [&'static str];
```

### 3.2 The tap and its state

```rust
/// Lives behind cb_eval_user_data; touched ONLY on the R (decode) thread.
struct CaptureState<'a> {
    spec: &'a ResolvedSpec,          // component name-set + layer set + n_embd
    prompt_id: u32, token_positions: &'a [u32],  // this prompt's flagged positions
    sink: BoundedSender<CaptureRow>, // plain Rust data → sink thread (§3.4)
    error: Option<RebirthError>,     // a copy/send failure aborts the pass cleanly
}
```

- **ask=true:** parse `ggml_get_name(t)` into `(base, il)`; return `true` iff `base ∈ spec.names && il ∈ spec.layers`. Cheap; no allocation.
- **ask=false:** validate `ggml_nbytes(t) == n_tokens * n_embd * 4` (F32, expected shape — a mismatch → record `RebirthError::Trace` and return `false` to cancel, never a silent bad capture); `ggml_backend_tensor_get` the tensor into a reused host `Vec<f32>`; for each requested position, slice its `n_embd` row and `sink.send(CaptureRow{ prompt_id, token_pos, layer=il, component, values })`. Bounded channel → **backpressure**, never unbounded buffering (WP4 FORBIDDEN).

The forward pass itself reuses the SAFETY-reviewed `Batch` from `generate.rs`/`embed.rs`, filling `logits/output` flags for all tokens (§1.2) and decoding on a **dedicated trace context** (below).

### 3.3 The dedicated trace context (D-011 pattern)

`engine.rs` gains a `TraceContext` RAII wrapper next to `Context`/`EmbeddingContext`, created per `llm_trace` call with `cb_eval`/`cb_eval_user_data` set, dropped (RAII) at call end. This keeps the generation context pristine (zero tap-off overhead) and needs no interior mutability on the `Arc`-shared handle (keeps D-008 G2 simple — see §6). Sizing follows the embed precedent: `n_batch = n_ubatch ≥ longest prompt` so each prompt decodes in one pass; a prompt longer than `context_length` → `rebirth_error_context_overflow` before allocation.

### 3.4 Spill sink (the first background thread — G2)

A `SpillSink` owns a `std::thread` that drains the bounded channel and writes Arrow IPC incrementally (§5, D-013). **It handles only plain Rust `CaptureRow` data — never an `Robj`, `SEXP`, or a `Model`/`Context` handle** (ARCHITECTURE §3). The handle stays on the R thread. This is the first Rust thread in the project, so it **reopens D-008 gate G2**; §6 states how it is honored. When the estimate is under budget (§5), the sink runs in-memory (a `Vec<CaptureRow>`) with no thread and no Arrow dependency touched.

### 3.5 Public engine API

```rust
impl LoadedModel {
    /// Trace pre-tokenized ids (the golden path; no tokenizer needed).
    pub fn trace_token_batch(&self, batches: &[&[i32]], spec: &CaptureSpec, sink: TraceSink)
        -> Result<TraceMeta, RebirthError>;
    /// R-facing: tokenize each text then trace. One trace context for the batch.
    pub fn trace_texts(&self, texts: &[&str], spec: &CaptureSpec, sink: TraceSink)
        -> Result<TraceMeta, RebirthError>;
    /// Exact-value building block for the synthetic golden: per-(layer,component)
    /// activations for a raw id sequence, in memory.
    pub fn activations(&self, ids: &[i32], spec: &CaptureSpec)
        -> Result<Vec<CaptureRow>, RebirthError>;
}
```

`error.rs` gains `Trace { reason: String }` → class `"rebirth_error_trace"`, and `Oom { estimate_bytes: u64, suggestion: String }` → class `"rebirth_error_oom"` (predictive; §5), both following the §1.8 message shape.

---

## 4. FFI boundary (`rebirth-ffi/src/lib.rs`)

### 4.1 The spec plumbing — index conversion here and nowhere else (ARCHITECTURE §4)

R passes **1-based** `layers`/`positions` (validated in R). `rebirth-ffi` converts to 0-based **exactly once** via the named helpers `to_engine_index`/`from_engine_index`, builds the `CaptureSpec`, and returns results with `layer`/`token_pos` mapped **back** to 1-based. **Property test** (WP4 deliverable): for every `layer ∈ 1..=n_layer` and `pos`, `from_engine_index(to_engine_index(x)) == x`; and an explicit unit test that a name parse `"l_out-7"` surfaces as API `layer = 8`. This is the canonical defect class (ARCHITECTURE §4) — it gets both tests.

### 4.2 The entry + the trampoline

```rust
// R has validated m/prompts/layers/positions/components/spill/spill_dir.
#[extendr]
fn rebirth_trace(ptr: Robj, prompts: Vec<String>, layers: Robj, positions: Robj,
                 components: Vec<String>, spill: bool, spill_dir: Robj,
                 budget_bytes: f64) -> Robj { /* with_model → build spec → predictive OOM
                 (§5) → run trace_texts → return columns or spill-file handles */ }
```

- **The trampoline** `extern "C" fn trace_trampoline(t, ask, ud) -> bool` recovers `&mut CaptureState` from `ud` and dispatches (§3.2). It is wrapped in `catch_unwind` internally: a panic inside the callback must **not** unwind across the C ABI into the ggml scheduler — on panic it records `RebirthError::Internal`, returns `false` (cancel compute), and the outer boundary surfaces `rebirth_error_internal`. (Security-auditor checkpoint.)
- `with_model` (existing) provides the outer `catch_unwind` + closed/foreign-pointer guard.
- The runs are **sequential over prompts** (API-GRAMMAR §1.5, Phases 0–4), one `prompt_id` at a time.

---

## 5. Spill design (ARCHITECTURE §6) + the predictive OOM

- **Estimate before running** (ARCHITECTURE §5): `bytes ≈ n_prompts × n_positions × n_layers × n_components × hidden_size × 4` (+ Arrow overhead). Computed in Rust from the resolved spec + tokenized lengths.
- **Budget:** `min(2 GB, 20% RAM)`, overridable by `options(rebirth.trace_budget = <bytes>)` (resolved in R, passed as `budget_bytes`).
- **Decision:**
  - estimate ≤ budget → **in-memory** (no thread, no Arrow dependency exercised).
  - estimate > budget & `spill = TRUE` → stream to **Arrow IPC** (Feather v2) files under the session spill dir; returned object loads lazily.
  - estimate > budget & `spill = FALSE` → **`rebirth_error_oom` before allocation**, carrying `estimate_bytes` (structured field) and a message naming the filters that would fit (e.g. "reduce `layers=` to a band, or set `positions='last'`; estimate 6.1 GB > budget 2.0 GB").
- **Writer (Rust, D-013):** the sink thread writes the exact 7-column `rebirth_trace` schema incrementally via `arrow-ipc`, record-batches chunked by `(prompt, layer)` so `as.matrix()` can skip to a slice. Each file footer carries the capture spec + model SHA (integrity: a reopened file whose spec ≠ the object's attributes → `rebirth_error_trace`, ARCHITECTURE §6).
- **Location + cleanup:** `tools::R_user_dir("rebirth", "cache")/spill/<session-id>/trace-<n>.arrow`; session dir registered for cleanup at R exit (`reg.finalizer` on a session sentinel + startup sweep of dirs > 7 days old). This is the second (and only other) sanctioned disk writer (API-GRAMMAR §1.9).
- **Reader (R, D-013):** a spilled `rebirth_trace` holds file paths in attributes; `nanoarrow` reads lazily on first data access; `as.matrix(layer, component)` reads only the needed batches; `print`/`summary` never force a full load.

---

## 6. Threading (ARCHITECTURE §3) + D-008 gate G2

- The **forward pass + eval callback run on the R (decode) thread** — WP4 has no sampling and no async, so the whole capture is synchronous on the caller's thread. No SEXP is constructed off-thread; results materialize as an R data.frame only at the boundary exit.
- The **spill sink thread handles only plain Rust `CaptureRow`s over a bounded channel** — it never touches R, a `SEXP`, or a `Model`/`Context` handle. Backpressure via the bounded channel (never unbounded — WP4 FORBIDDEN).
- **This reopens D-008 G2** (first background thread). Honored by: (a) the handle and its raw pointers are used only on the R thread — the sink receives owned plain data, so the `unsafe impl Send + Sync` is never actually exercised across threads by WP4; (b) add the G2-recommended `debug_assert!` thread-id check in the `Model`/`Context` getters + `Drop`, so any future code that *does* hand a handle to a thread trips in debug. **Security-auditor checkpoint at the WP4 boundary** (D-008 explicitly gates G2 on "before any background Rust thread exists").

---

## 7. Golden-first test plan (Harness B extension)

### 7.1 Synthetic activation golden (exact oracle) — `[SYNTHETIC]`, runs in CI

Via the **`golden-update` skill** (the only sanctioned way to touch goldens), extend the numpy oracle exactly as WP3 did for embeddings:

- Refactor `reference_forward.py` so the three per-layer component tensors are named intermediates: for each layer `il`, `attn_out[il]` (attention sub-layer output), `mlp_out[il]` (= `ffn_out`, FFN sub-layer output), `residual[il]` (= `l_out`, block output). These are pure extractions of tensors the oracle already computes on its way to the logits — so **`logits.npy` must not drift** (`python reference_forward.py --check` enforces it, plus the same-machine determinism assertion).
- Emit `goldens/activations.npy` + `.csv`: shape `[n_layer=2, n_components=3, n_tokens=8, n_embd=32]`, float64, plus `activations_sha256` in `metadata.json`.

**Rust integration test** `tests/synthetic_trace.rs` (mirrors `synthetic_embed.rs`; the numerical **de-risking gate**, proving the tap is correct before any R work): load the synthetic GGUF on CPU; `activations(&INPUT_TOKENS, spec=all-layers/all-positions/all-components)`; assert each captured `(layer, component, token, neuron)` value within `ATOL` of the oracle (F32-engine vs F64-oracle; start from the logits test's tolerance and tighten to observed — pre-LM-head hidden states have a *smaller* F32/F64 gap than logits). This realizes acceptance "synthetic-model activations match the fp32 golden exactly" (the synthetic's "HF fp32 golden" is the numpy oracle — it is not an HF model).

### 7.2 CI-model activation golden — `[MODEL]`, gated / nightly (coordinated with WP6b)

- A golden-generation script extracts Qwen2.5-0.5B per-layer `residual`/`attn_out`/`mlp_out` via **HF transformers fp32** forward hooks (test tooling, pinned venv). Test asserts engine-vs-HF **within documented tolerance AND rank-correlation ≥ 0.999 per layer** (acceptance). Gated on `REBIRTH_TEST_MODEL_QWEN`; the **nightly 0.5B tolerance runs and the off-by-one mutation test are WP6b** (ROADMAP), which WP4 Step 6 coordinates with — WP4 delivers the synthetic exact golden + the HF generation script; WP6b wires the nightly + mutation test.

### 7.3 R argument/error + method tests — `[NOW]`, CI

Using a stubbed/fixture `llm`: each bad `m`/`prompts`/`layers`/`positions`/`components`/`spill` → its `rebirth_error_argument` (with `argument` field); over-budget + `spill=FALSE` → `rebirth_error_oom` carrying `estimate_bytes` (constructed spec, no model needed); `print`/`summary`/`as.matrix` format tests on a constructed `rebirth_trace` (both in-memory and a tiny committed spill fixture). The 4B-spill acceptance is `[MODEL]` on the founder's Mac (§10).

### 7.4 Tap-off overhead benchmark — committed script

A committed benchmark (`tests/perf/trace-off-overhead.R` or a `cargo bench`) times generation with vs without a trace context in flight and asserts `< 2%`. Structurally near-zero (the generation context never has `cb_eval`), so this documents rather than fights the budget.

---

## 8. Step-by-step implementation order (mapped to ROADMAP §5 WP4 Steps 2–6)

Guiding rule: **no implementation until D-012 (+ D-013) is founder-approved** (WP4 Step 1 STOP). Then goldens/tests first; small commits; a Rust panic reaching R (or the scheduler) is a bug.

**Step 2 — Capture-spec plumbing (ROADMAP Step 2).** `[NOW]`
`CaptureSpec` + `Component` in `trace.rs`; the per-arch name matcher; `rebirth-ffi` 1-based→0-based conversion via `to_engine_index`/`from_engine_index`; R-side validation of `layers`/`positions`/`components`/`spill`/`spill_dir`.
- **Verify:** the §4.1 property test + the `"l_out-7"→layer 8` unit test; R argument tests (§7.3). `cargo test`, `devtools::test`.

**Step 3 — The tap (ROADMAP Step 3).** `[NOW] structure / [SYNTHETIC] values`
FFI accessors + trampoline (§2); `TraceContext` (§3.3); `CaptureState` ask=true/ask=false (§3.2); bounded channel; reuse `Batch` with all-tokens flagged (§1.2); the trampoline's internal `catch_unwind` (§4.2). Guarded so tap-off installs no callback.
- **Verify:** `activations()` returns correctly-shaped data on the synthetic model; `cargo clippy -D warnings`, `fmt --check`.

**Step 4 — `rebirth_trace` assembly + methods (ROADMAP Step 4).** `[NOW]`
`rebirth_trace` (exact 7-column schema/order, API-GRAMMAR §2) with attributes (`model`, `spilled`, `spill_files`, `prompts`); `print.rebirth_trace` (dims + capture spec, never data), `summary.rebirth_trace` (per layer/component: n, mean|value|, spill status), `as.matrix.rebirth_trace(x, layer, component)` (one slice → matrix, rownames `"<prompt_id>.<token_pos>"`). `token` column via `llama_token_to_piece` (degenerate/NA for the `no_vocab` synthetic — the golden tests `value`, not `token`; noted honestly).
- **Verify:** method format tests on a constructed trace (§7.3); the synthetic exact golden test (§7.1) — **the de-risking gate**.

**Step 5 — Spill (ROADMAP Step 5).** `[NOW] logic / [MODEL] 4B run` · **gated on D-013**
Predictive estimate + `rebirth_error_oom` (before allocation, with `estimate_bytes` + filter suggestion); budget `min(2 GB, 20% RAM)` + `options(rebirth.trace_budget=)`; Arrow-IPC writer (Rust, feature-gated `spill`) on the sink thread; session spill dir under `R_user_dir` + cleanup; `nanoarrow` lazy reader; integrity footer.
- **Verify:** OOM predictive test (`spill=FALSE` over budget → classed condition, no allocation); a tiny in-CI spill round-trip (write → `nanoarrow` read → `as.matrix` slice equals in-memory); the **4B-on-16GB spill+complete** acceptance is `[MODEL]` (§10).

**Step 6 — Activation goldens into harness B (ROADMAP Step 6).** `[SYNTHETIC] CI / [MODEL] nightly`
Wire the synthetic exact golden into per-commit CI (§7.1); deliver the HF Qwen activation-golden generation script; coordinate the nightly 0.5B tolerance + rank-corr and the mutation test with **WP6b**.
- **Verify:** synthetic activation golden green per-commit; HF script produces goldens reproducibly (golden-update documented).

**Step 7 — Phase-boundary hygiene.** `[NOW]`
`simplifier` (mandatory at phase end / >~500 lines); `reviewer`; `security-auditor` at the FFI/unsafe/threads boundary (confirm §2.2 ABI assert, the trampoline `catch_unwind`, the G2 thread-id guard, no unbounded buffering); `doc-writer` once acceptance passes.

**Blocked-now summary**

| WP4 acceptance criterion | Status | Where |
|---|---|---|
| Synthetic-model activations match the fp32 golden exactly | **[SYNTHETIC]** (CI) | Steps 3,4,6 |
| CI-model within tolerance AND rank-corr ≥ 0.999/layer | **[MODEL]** nightly (with WP6b) | Step 6 |
| 4B trace on 16 GB spills and completes; session survives | **[MODEL]** | Steps 5 → 10 |
| Tap-off overhead < 2% (committed benchmark) | **[NOW]** structural | Steps 3,7 |
| R CMD check clean; cargo test green | **[NOW]** | Steps 2–6 |

---

## 9. WP4 ACCEPTANCE (verbatim, ROADMAP §5) — the definition of done

**ACCEPTANCE**
- Synthetic-model activations match HF fp32 goldens exactly.
- CI-model activations within documented tolerance AND rank-correlation >= 0.999 per layer.
- A deliberately full trace of the 4B model on the 16 GB Mac spills to disk and completes; the session survives.
- Tap-off generation overhead < 2% (benchmark script committed).
- R CMD check clean; cargo test green.

**FORBIDDEN**
- Any implementation before the spike ADR is approved; unbounded buffering; vendored patches beyond what the approved ADR allows; hand-edited goldens.

(Honored: observation adds **zero** patch — no vendored patch enters in WP4 at all; the only WP4 patch would be the WP5 ablation site, which D-012 pre-authorizes and which is not written in WP4. Buffering is bounded (§3.4). Goldens are numpy/HF-generated via the golden-update skill, never hand-edited. The spike ADR (D-012) precedes all implementation.)

---

## 10. `[MODEL]` acceptance on the founder's Mac

Once the spike ADRs are accepted and Steps 2–6 are green in CI, the founder runs the two `[MODEL]` items locally: (1) MedGemma-1.5-4B Q4 full trace (all layers, all positions) → predictive estimate exceeds budget → spills to Arrow IPC → completes, session survives (RSS stays bounded, files cleaned); (2) Qwen2.5-0.5B activation golden within tolerance + rank-corr ≥ 0.999/layer (with `REBIRTH_TEST_MODEL_QWEN`). These close the WP.

---

## 11. Scope discipline (backlog notes — NOT WP4 scope; for a future `DECISIONS.md` note)

Per planning rule 5, out-of-scope ideas go to a backlog note, not the WP list:
- **`attn_out`/`mlp_out` ablation** (beyond the default `residual`) — needs per-component patch sites (no shared choke point); WP5 default is `residual` (API-GRAMMAR §4). Head ablation is already a ROADMAP WP5 "stretch."
- **Tracing a steered/ablated handle** — an intervention changes the graph (`build_cvec` non-no-op / the ablation patch active), so component names/values shift; WP4 traces a *plain* forward pass. Trace-during-intervention is a deliberate later question (Phase 6 live introspection).
- **Position-filtered last-layer compute** (flag only requested outputs + a per-layer row map) — a compute optimization over the uniform "flag-all-outputs" indexing (§1.2); negligible for trace-length prompts.
- **Multi-sequence batched tracing** (several prompts per `llama_decode`) — a throughput optimization; WP4 processes prompts sequentially (API-GRAMMAR §1.5).
- **MoE `ffn_moe_out` capture** — no pinned MoE model; add when one is pinned.

---

## 12. What the founder must decide, and the exact next action

**Founder decisions (both ADRs are founder-level):**
1. **Accept / amend D-012** (activation-tap strategy). This is the ROADMAP-mandated spike-ADR STOP: **no WP4 code starts until it is approved.** Its two halves:
   - *Observation (WP4):* eval-callback, **zero patch** — settled from source, low risk. This is all WP4 needs.
   - *Ablation (WP5):* the recommended **minimal `build_cvec`-site patch** vs the zero-patch **modifying-eval-callback fallback**. Choosing the fallback triggers the empirical Metal+CPU probe (§1.3) before WP5. **Recommendation: approve the patch** (robust, native, generation-safe, minimal, reversible).
2. **Accept / amend D-013** (spill dependencies): the R package **`nanoarrow`** + the Rust **`arrow-ipc`** writer (minimal subcrates, `default-features = false`), feature-gated. Required by the WP4 4B-spill acceptance. **Recommendation: approve both.** (Optional: if minimizing the dependency surface matters more than the 4B-spill acceptance in this WP, split spill into WP4b — see D-013 "Alternatives rejected"; **not recommended**, it defers an acceptance criterion.)

**Is an empirical probe required before you present to the founder?** **No.** Q1 (observation) is settled from source, and the recommended ablation path (the patch) sidesteps Q2 entirely; D-012 pre-authorizes the callback fallback + its probe as a named contingency, so there is no second sign-off. Run the §1.3 probe **only** if the founder rejects the patch and picks the zero-patch callback.

**Exact next action:** founder reviews **D-012** and **D-013** (below). On acceptance I integrate both into `DECISIONS.md` as accepted entries (and note the WP4 patch-budget consequence for `vendor-bump`), then the `coder` starts WP4 at **Step 2** (capture-spec plumbing), proceeding to Step 3 (the tap) and Step 4's synthetic activation golden — the numerical de-risking gate — before spill and the `[MODEL]` acceptance.

---

## Deliverable 3 — ADR (proposed), ready to append to `DECISIONS.md`

```
## D-012 — activation-tap strategy (observation + ablation-mutation mechanism)
- **Date:** 2026-07-06 · **Status:** proposed
- **Decision:** the WP4 day-1 spike, run against the vendored engine at b9726, decides:
  **(A) Observation (`llm_trace`, WP4): Strategy A, zero vendored patch.** Tap the forward
  pass via llama.cpp's scheduler eval callback (`ggml_backend_sched_eval_callback`; the
  `cb_eval`/`cb_eval_user_data` context params already mirrored at `ffi.rs:118-119`,
  currently null). A dedicated, transient **trace context** is created per `llm_trace` call
  (the D-011 embedding-context pattern) with `cb_eval` set to a Rust `extern "C"` trampoline
  and `cb_eval_user_data` a boxed capture-state pointer; the generation context never gets a
  callback, so tap-off overhead is zero (`ggml-backend.cpp` takes the no-callback fast path).
  At `ask=false` — fired *after* `ggml_backend_synchronize`, so the data is ready — the matched
  tensor is copied host-side via `ggml_backend_tensor_get`. Tensors are matched by name:
  `l_out-<il>`=residual, `ffn_out-<il>`=mlp_out, `attn_out-<il>`(llama/gemma) or
  `kqv_out-<il>`(qwen2)=attn_out, `<il>` the 0-based engine layer; the matcher is a small
  per-architecture alias table, and an unmatched component→`rebirth_error_trace` (never a
  silent empty capture). New FFI = the opaque `ggml_tensor` type + accessors
  `ggml_get_name`/`ggml_nbytes`/`ggml_nelements`/`ggml_backend_tensor_get` (no struct mirror),
  honoring D-006's minimal surface; the existing size-160 ABI test gains a `cb_eval` null-default
  assertion. Zero patch keeps the harness-B baseline and `vendor-bump` untouched by WP4.
  **(B) Ablation (`llm_ablate`, WP5): a minimal single-site vendored patch** at the residual
  choke point `llm_graph_context::build_cvec` (`src/llama-graph.cpp`), which every architecture
  routes its block-output residual through before `l_out` — extended (or a sibling
  `build_intervene`) to apply a registered per-layer ablation mask, **guarded so it is
  byte-identical to the unpatched build when no ablation is registered** (preserving the
  harness-B baseline and the WP5 bit-for-bit reversal acceptance). It is native (Metal computes
  it as an op — no host-mutation question), generation-hot-path efficient (no per-node callback),
  architecture-agnostic for the default `component="residual"`, and lives in
  `rebirth/src/llama.cpp/patches/` with each hunk annotated (D-006 patch budget). The modifying
  eval-callback (ARCHITECTURE §5 option 1) is retained ONLY as a named zero-patch fallback and,
  if chosen, requires an empirical Metal+CPU mutation probe before WP5 (source cannot certify
  cross-submission host-mutation visibility on Metal). Steering (WP5) is confirmed to need zero
  patch — it maps onto the native control-vector `build_cvec`/`apply_to` path. Full analysis and
  the exact probe in `docs/wp4-trace-plan.md`.
- **Why:** the scheduler's own invocation code (`ggml-backend.cpp` L1677-1714) plus the
  documented `ask` contract (`ggml-backend.h` L307-314) prove observation works with no patch —
  stronger evidence than the (pruned, external) imatrix tool. The dedicated trace context keeps
  the generation path pristine and the `<2%` tap-off budget met by construction. For ablation,
  the source-provable facts (ask=false fires post-synchronize; next-layer consumers are not yet
  computed; Metal is shared unified memory) make a modifying callback *plausible* but not
  *certain* on Metal — and ablation is an always-on, composable, bit-for-bit-reversible
  generation-time intervention where a native graph op is simply the better engineering than a
  host round-trip on the hot path. `build_cvec` is the one shared residual choke point across
  architectures (verified qwen2/llama/gemma3), giving a single minimal patch site for the
  default component. Deciding (B) as the patch routes around the one thing source cannot settle,
  rather than shipping a correctness-critical path on an unproven mechanism. ARCHITECTURE §5
  explicitly charters the spike to make this call.
- **Alternatives rejected:** modifying eval-callback as the PRIMARY ablation mechanism
  (per-node `ask=true` overhead on every generated token, de-batches the scheduler at the
  ablation layer, and cross-submission Metal host-mutation is unproven from source — unacceptable
  for an always-on path); per-model patches at each `cb(...,"l_out"/"ffn_out"/"attn_out")` naming
  site (many sites across every arch → high `vendor-bump` cost, defeats the patch budget);
  mirroring the full `ggml_tensor` struct to write `t->data` directly (fragile ABI, larger unsafe
  surface than accessors); installing `cb_eval` on the generation context (non-zero tap-off
  overhead, perturbs the pristine generation path); reusing the control-vector API for ablation
  (a fixed additive vector cannot express `x[k]:=value`, which depends on the computed activation).
- **Patch-budget note (flagged for the founder):** WP4/observation adds **zero** vendored
  patches; the only patch this ADR authorizes is the single `build_cvec`-site ablation hook,
  landed in WP5, annotated, re-applied by `vendor-bump`. If the founder prefers the zero-patch
  callback fallback for ablation, the §1.3 probe must pass on Metal+CPU first.
```

---

## Deliverable 4 — ADR (proposed), ready to append to `DECISIONS.md`

```
## D-013 — spill dependencies (Arrow IPC writer + reader)
- **Date:** 2026-07-06 · **Status:** proposed
- **Decision:** authorize two NEW dependencies for the WP4 `llm_trace(spill=)` path — the R
  package **`nanoarrow`** (lazy Arrow-IPC reader) and the Rust **`arrow-ipc`** writer with its
  minimal required subcrates (`arrow-array`, `arrow-buffer`, `arrow-data`, `arrow-schema`, and
  their `flatbuffers` transitive), `default-features = false` (no compression codecs, chrono,
  parquet, csv, or json). Spill writes **Feather v2 (Arrow IPC file)** with the exact 7-column
  `rebirth_trace` schema (`prompt_id, token_pos, token, layer, component, neuron, value`),
  record-batched by `(prompt, layer)` so `as.matrix()` reads only a slice; the file footer
  carries the capture spec + model SHA for the staleness fail-safe (ARCHITECTURE §6). R reads
  lazily via `nanoarrow` (paths in the object's attributes; `print`/`summary` never force a
  load). The Rust writer sits behind a `spill` **cargo feature** (default on), so a no-spill
  build carries none of it and the in-budget in-memory path exercises no Arrow code. Exact
  versions are pinned at implementation and `Cargo.lock`/`src/rust/vendor.tar.xz` committed
  (arrow-rs = the current stable release at WP4 start; `nanoarrow` = current CRAN). Full
  analysis in `docs/wp4-trace-plan.md`.
- **Why:** `nanoarrow` is purpose-built for lightweight, lazy Arrow reading — a small C core with
  no heavy transitive tree and a clean CRAN footprint — which is exactly the ARCHITECTURE §6
  reader role and the `SOLO-PHASE-PLAN.md`/CLAUDE.md stack-table intent (naming a dep there is
  not approval — this ADR is). `arrow-ipc` is the mainstream, correct, maintained Arrow-IPC
  writer; hand-rolling IPC + flatbuffers is error-prone and unjustified for a fixed 7-column
  schema, and `default-features = false` strips the codec/parquet/chrono weight so the vendored
  CRAN tarball grows only by the format's irreducible core. The 4B-on-16GB spill test is a WP4
  acceptance criterion, so the writer is load-bearing for WP4 and cannot be deferred out of it
  without dropping that criterion (a founder call, offered below).
- **Alternatives rejected:** the full **`arrow` R package** (a large bundled C++ Arrow build —
  slow install, heavier CRAN presence, no benefit for lazy slice reads that `nanoarrow` does
  natively; ARCHITECTURE §14 pre-flags `nanoarrow` as the Phase-2 choice, `arrow` only if
  lazy-read needs grow); the full **`arrow` Rust crate with default features** (pulls compression
  codecs, parquet, csv/json, chrono — dead transitive weight in the vendor tarball); **hand-written
  Arrow IPC** (correctness risk, no upstream maintenance, off the WP's critical path); **polars or
  a custom columnar format** (larger dep and/or a non-standard file R cannot read with a light
  reader); **deferring spill entirely** (would drop the WP4 "4B trace spills and completes"
  acceptance — recorded as a possible WP4a/WP4b split if the founder prioritizes minimizing the
  dependency surface over that criterion in this WP; not recommended, since spill is the 16 GB
  rule's whole point and every later trace-heavy phase needs it).
- **CRAN implication:** all Rust crates are vendored via `cargo vendor` into `src/rust/vendor.tar.xz`
  (ARCHITECTURE §9); the arrow-rs subtree enlarges that tarball — expected and prepared for at
  Phase 9, an installed-size NOTE at worst. `nanoarrow` is a normal `Imports:` in DESCRIPTION.
  Both are permissively licensed (Apache-2.0), compatible with the package's MIT OR Apache-2.0.
- **Dependency authorization (flagged for the founder — the no-new-dependency rule):** this ADR
  is the required approval for `nanoarrow` (R) and `arrow-ipc` + its minimal subcrates (Rust).
  No other new dependency is authorized. Recommendation: **approve both; keep spill in WP4,
  feature-gated.**
```

---

## Addendum — Fable 5 second review (2026-07-06): accepted corrections

The founder delegated the D-012/D-013 call to Fable 5, which independently concurred with both recommendations (the `build_cvec` patch for ablation; approve the spill deps now) and corrected four things. The **accepted** ADRs in `DECISIONS.md` already fold these in; the implementer follows the corrected versions, not the pre-review §0–§11 wording above where they differ.

**Corrections to D-012 (mostly WP5, one WP4 doc fix):**
1. **`build_cvec` is NOT universal** (this doc's §0/§1.2/§1.3 overstate it). Verified: 106/134 model graphs at b9726 call it; BERT-class encoders, SSMs, and some MoEs do not. All pinned/CI/demo archs (llama, qwen2, gemma3) DO — so WP4's synthetic (llama) and the CI Qwen are unaffected, and the trace matcher's "unmatched component → `rebirth_error_trace`" (§1.2) already covers an unknown arch. The consequence is WP5's: `llm_ablate`/`llm_steer` share one support matrix, and WP5 must **detect a no-choke-point arch and raise `rebirth_error_intervention`, never silently no-op.**
2. **Patch size is ~5 files / ~100–200 lines** (threading the spec through `llm_graph_context` mirrors the cvec plumbing), not "one function." Still inside the D-006 budget; WP5 sizing should assume this.
3. **Backlog:** Phase 18 ESM-2/DNABERT encoders are BERT-class → neither native steering nor this ablation choke point; the encoder intervention path is an open Phase-18 question.

**Corrections to D-013 (WP4 Step 5 — the implementer applies these):**
4. **Verify the pinned `nanoarrow` reader's random-access support at Step 5 day 1.** Its IPC reader has historically been stream-format-first; §5's "Feather v2 file + skip-to-slice via footer" assumes file-format random access. If unavailable at the pinned version, use the **IPC stream format with sequential message-skipping** over the `(prompt, layer)` batching (cheap, zero API change). D-013 is therefore worded "file or stream, fixed at implementation."
5. **Store `value` as float32 on disk** (engine truth; widened to R double at read, exact) and **dictionary-encode `token`/`component`** — ~halves spill size at zero information cost. The R-visible `rebirth_trace` schema (§2/§7) is unchanged; this is the on-disk encoding only.

**Correction to D-012 from implementation (coder, 2026-07-06):** the `attn_out` component matcher is **per-architecture, NOT the `{attn_out,kqv_out}` union** this doc's §1.2/§3.1 suggested. Verified at b9726: a llama graph names a post-projection `attn_out-<il>` (the golden's definition) AND a pre-projection `kqv_out-<il>`, so the union would capture the wrong tensor; qwen2 and gemma3 build attention through the shared `build_attn` and name only `kqv_out-<il>` (pre-projection) — there is no `attn_out-<il>`, so matching it would silently capture nothing (the pre-review "gemma→`attn_out`" was wrong). The matcher was first implemented as llama→`attn_out`, qwen2/gemma3→`kqv_out`. **Resolved by D-014 (2026-07-06, founder delegated to Fable 5):** that cross-architecture inconsistency (post-projection on llama, pre-projection on qwen2/gemma3 — and pre-projection is not even `hidden_size` wide on gemma3/MedGemma, breaching API-GRAMMAR §4) is a silent mislabeling the honesty limits forbid. `attn_out` is pinned to the **post-projection** output everywhere; llama→`attn_out`, and qwen2/gemma3 (which name no post-projection tensor at b9726) raise `rebirth_error_trace` listing the available components rather than substitute `kqv_out`. A naming-only vendored patch to expose it on qwen2/gemma3 is chartered for WP5/WP6b (its own ADR). WP4 tests only llama's post-projection `attn_out` (the synthetic golden), so WP4 correctness is unaffected.

Nothing else in §0–§12 changes. Observation (WP4) remains zero-patch; the coder starts at Step 2.
