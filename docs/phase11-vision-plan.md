# Phase 11 — Vision / multimodal (v0.2.0): plan, WP breakdown & decision drafts

**Author:** architect agent · **Date:** 2026-07-14 · **Status:** **APPROVED by the founder on 2026-07-14** — D-026 accepted (audio = Option A), the §7 grammar entries approved (D-003). The binding records live in `DECISIONS.md` (D-026) and `API-GRAMMAR.md`; this document remains the phase's planning artifact.
**Scope:** ROADMAP §3 Phase 11 (multimodal, pulled forward to `v0.2.0` per **D-023**). Phase 3 shipped `v0.1.0` (`relm`, text-only). Branch of record for the phase: TBD by the founder; each WP gets its own branch.

This is the **single plan document** for the phase. It contains: the feasibility findings (verified against the upstream `b9726` tarball, not assumed), a ranked risk register, the WP breakdown (WP-V1…V4), a **draft ADR D-026** (`status: proposed`), draft **API-GRAMMAR entries** (`[proposed]`), an honest "what could force a vendor bump" section, and the founder's open inputs.

**I write only this file.** I do not edit `DECISIONS.md`, `API-GRAMMAR.md`, `ROADMAP.md`, `ARCHITECTURE.md`, or any source. The founder appends the accepted ADR and approves the grammar entries **before** any code is written (D-003 change protocol). Nothing here changes an accepted decision; where my tarball inspection contradicts a ROADMAP/D-023 assumption, I flag it in §2 (Corrections) rather than silently adapting.

The precedent doc for structure is `docs/wp3-embed-plan.md`.

---

## 0. What is fixed / verified before we start (evidence, not assumption)

All "b9726:" citations are from the upstream release tarball
`https://github.com/ggml-org/llama.cpp/archive/refs/tags/b9726.tar.gz`, downloaded to the scratchpad and **SHA256-verified** against the pinned value in `rebirth/src/llama.cpp/VENDORING.md`:

```
117e95a59967e91b097d1bfdf62c3d10e8d08aec01be8548a093dcceecf9f2e0  b9726.tar.gz   ✓ matches the pin
```

| Fact | Evidence (verified 2026-07-14) |
|---|---|
| The vendored tree is `b9726`, pruned of the **entire** multimodal subsystem. No `tools/`, no `vendor/`, `include/` has only `llama.h`+`llama-cpp.h`. | `rebirth/src/llama.cpp/` (`ls`: no `tools`, no `vendor`); `include/`; VENDORING.md "Removed" list |
| The **VLM text decoders are already vendored**: `gemma4.cpp`, `qwen2vl.cpp`, `qwen3vl.cpp`, `qwen3vlmoe.cpp`. Only the **vision side** (encoder + glue + image preprocessing) is missing. | `rebirth/src/llama.cpp/src/models/` |
| `libmtmd` is a **buildable library target** at b9726 (`add_library(mtmd …)`), containing `clip.cpp` + `mtmd.cpp` + `mtmd-image.cpp` + `mtmd-audio.cpp` + `mtmd-helper.cpp` + `models/*.cpp`. Clip is compiled **into** libmtmd; it is **one** archive (`libmtmd.a`), not two. | b9726:tools/mtmd/CMakeLists.txt L8–54 |
| libmtmd links **only `ggml` + `llama`** (both already built) + `Threads`. It is **explicitly forbidden** from linking `llama-common` (a `FATAL_ERROR` guard). The library's core sources include **no `common/` headers** — only clip's own headers, `ggml.h`/`gguf.h`/`ggml-backend.h` (vendored), and `llama.h` (vendored). | b9726:tools/mtmd/CMakeLists.txt L62–65, L110–116; `#include` scan of mtmd.cpp/clip.cpp/mtmd-image.cpp |
| Clip supports the target projector types at b9726: `PROJECTOR_TYPE_QWEN2VL`, `QWEN25VL`, `QWEN3VL`, `GEMMA3`, `GEMMA4V` (+ many more). | b9726:tools/mtmd/clip-impl.h L314–366 |
| The C API surface for T1/T2 exists and is stable-ish (marked experimental): `mtmd_init_from_file(mmproj, text_model, params)`, `mtmd_context_params_default()`, `mtmd_free`, `mtmd_bitmap_init(nx,ny,rgb)`, `mtmd_tokenize(ctx, chunks, text, bitmaps, n)`, `mtmd_encode_chunk`, `mtmd_get_output_embd`, `mtmd_support_vision`, `mtmd_decode_use_non_causal`, `mtmd_decode_use_mrope`, `mtmd_get_cap_from_file`, `mtmd_default_marker`. | b9726:tools/mtmd/mtmd.h L109–319 |
| `mtmd_init_from_file` takes a `const llama_model *` — it **shares our already-loaded model**, no double-load. The mtmd context is a separate vision-encoder handle bound to that model pointer. | b9726:tools/mtmd/mtmd.h L115–117 |
| The **interleaved decode is a tested upstream helper**: `mtmd_helper_eval_chunks(mctx, lctx, chunks, n_past, seq_id, n_batch, logits_last, &new_n_past)` runs `llama_decode` on text chunks and `mtmd_encode_chunk`→`mtmd_get_output_embd`→`llama_decode` on image chunks, **chunking by `n_batch`** and handling the gemma3 non-causal mask + qwen-vl M-RoPE positions internally. | b9726:tools/mtmd/mtmd-helper.h L74–108; mtmd-cli.cpp L261–295 (canonical flow) |
| The image-embedding decode hook is `llama_batch.embd` (`float * embd`); its byte size per image chunk is `llama_model_n_embd_inp(model) * n_tokens * sizeof(float)`. | b9726:include/llama.h L240–248, L563; mtmd.h L284–287 |
| **Image file → RGB decode** is done by **`stb_image.h`** (single header, public domain); **`mtmd-helper.cpp` also unconditionally includes `miniaudio.h`** (audio decode, public domain / MIT-0) with `MINIAUDIO_IMPLEMENTATION`. Both live in the pruned in-repo `vendor/`. Video (`sheredom/subprocess.h` + `std::thread`) is fully `#ifdef MTMD_VIDEO`-guarded. | b9726:tools/mtmd/mtmd-helper.cpp L28–41; b9726:vendor/stb/stb_image.h L1 ("public domain"); b9726:vendor/miniaudio/miniaudio.h |
| `mtmd-debug.*` debug functions are **defined inside `mtmd.cpp`** (L2040–2102); only the header `debug/mtmd-debug.h` is needed by the library. `legacy-models/` is referenced only from README (doc-only). `tests/`, `mtmd-cli.cpp`, `deprecation-warning.cpp`, the `.jpeg/.mp3/.mp4` fixtures are executables/tests, not library inputs. | b9726:tools/mtmd/mtmd.cpp L2040–2102; grep `legacy-models` → README only |
| **Build reachability:** the root gates `add_subdirectory(tools)` behind `if (LLAMA_BUILD_COMMON AND LLAMA_BUILD_TOOLS)` — both are **OFF** in our `build.rs`. So libmtmd is **not reachable** with our current flags; the re-vendor needs a **build-system change** to build the library-only mtmd target without common/ and without the CLI tools. | b9726:CMakeLists.txt L217–218; `rebirth/src/rust/rebirth-llm/build.rs` L63–67 |
| Untrusted-input aborts — **[corrected by the WP-V1 audit, F10]**: the planning-time claim of a `GGML_ASSERT(width/height ≤ 46000)` in clip.h does not exist at b9726 (grep-verified). The actual guards are stb-side (`STBI_MAX_DIMENSIONS = 1<<24` + alloc-overflow checks); the uncatchable asserts reachable from hostile input live in the projector-GGUF load (`clip.cpp:1248-1249, :1322`) and degenerate-dims preprocessing (`mtmd-image.cpp:120-121, :393`). `mtmd.cpp` catches C++ exceptions internally (14 `try/catch`) but `mtmd_helper_bitmap_init_from_buf` does not (a `bad_alloc` there would abort). Binding pre-decode caps: `docs/audit-wp-v1-mtmd-2026-07-14.md` §5. | WP-V1 audit (2026-07-14) |
| One vendored patch exists today (`0001-rebirth-wp5-ablation-intervene.diff`, D-012/D-015); three SHAs pin the tree (tarball / pre-patch / post-patch), and CI `verify_vendored_tree.sh` asserts G4 (post-patch SHA) + the reverse-apply coherence check. | `rebirth/src/llama.cpp/VENDORING.md`; patches/ |
| Model registry schema (D-024): `alias,url,sha256,size_bytes,license,notes`; two Apache-2.0 Qwen text aliases pinned. `llm_download` fetches **one URL per alias**, fail-closed on SHA256. | `rebirth/inst/models.csv`; D-024 |
| The reserved future slot exists: "multimodal arguments to `llm()` / `llm_generate(images = )` (Phase 11)". | API-GRAMMAR.md §7 L156 |

---

## 1. Executive summary

Vision at b9726 is **feasible with a re-vendor at the same tag — no version bump** — because b9726 already ships (a) the VLM text decoders we vendored and (b) a complete, buildable `libmtmd`/clip supporting Qwen2-VL / Qwen2.5-VL / Qwen3-VL and Gemma 3 / Gemma 4 vision. The work is exactly what D-023 sized it as: un-prune and build a **second native library**, add a **hand-written image-preprocess + vision-encode FFI**, wire the **`llama_batch.embd` interleaved decode** through the tested upstream helper, and expose **T1** (`llm(projector=)` + `llm_generate(images=)`) and **T2** (`llm_embed(images=)`) behind approved grammar entries, with a new harness-B **vision golden category**. T3 (interpretability of the vision tower) stays out (a later research phase, per D-023). Estimated **~6.5 weeks across 4 WPs**.

The plan recommends the **lowest-risk, mostly-zero-patch** path: reuse upstream's tested `mtmd_helper_eval_chunks` for the interleaved decode (never reimplement the M-RoPE / non-causal-mask logic in Rust — that is a fails-silent trap the project's own D-012 principle forbids), constrain untrusted image input with a Rust-side magic-byte allow-list so the audio decoder is never reachable, and pin an **Apache-2.0 Qwen-VL** as the license-clean default with Gemma/MedGemma as the quality option.

### What protects v0.1.0 (the "does-not-break" guarantee)

The un-intervened **text** path is protected by byte-exact synthetic goldens (engine vs the numpy oracle; engine vs unpatched llama.cpp logits). The re-vendor **adds files and a build option**; it must not touch any byte of the existing `src/`/`ggml/` compiled sources on the text path. The formal guarantee stated in every WP acceptance:

> After the re-vendor, the WP2/WP3/WP4 synthetic goldens pass **byte-identically** — the recorded engine-vs-oracle maxima are unchanged (logits `1.99e-3`, embeddings `2.92e-3`, activations `3.73e-3`, per VENDORING.md), and the greedy token-for-token match vs unpatched llama.cpp is unchanged.

Mechanically this holds because (i) libmtmd is an **additional** archive linked only when a projector is used — the text `llm()`/`llm_generate()`/`llm_embed()`/`llm_trace()` paths never enter mtmd code; (ii) the ablation patch (`build_cvec`) is untouched; (iii) the vendored-tree SHAs are recomputed and re-asserted (G4) so any accidental change to a text-path source **fails CI loudly**. And `main` stays releasable at every merge: `DESCRIPTION` moves to a dev version **`0.1.0.9000`** for the phase (r-universe rebuilds `main` on push; a dev version is the honest label for an in-progress `main`), bumping to `0.2.0` only at the release WP.

---

## 2. Corrections to ROADMAP / D-023 assumptions (flag, do not silently adapt)

The tarball inspection contradicts three specifics in ROADMAP Phase 11 / D-023. None invalidates the phase; two make it **cheaper**, one adds a **real task**. Recording them here so the founder sees the delta; the WP list and the draft ADR reflect the corrected facts.

1. **"+ the pruned `common/`" is NOT needed.** ROADMAP Phase 11 and D-023 both say the re-vendor must restore "`common/`/`stb_image`". Verified: `libmtmd` is **explicitly forbidden** from linking `llama-common` (b9726:CMakeLists.txt L110–116, a `FATAL_ERROR`), and its core sources include **zero** `common/` headers. Only the CLI executables (which we do not build) need `common/`. **Consequence:** the re-vendor does **not** un-prune `common/` — it un-prunes `tools/mtmd/` (library sources) + `vendor/stb` (+ `vendor/miniaudio`, see §3.3). Simpler and smaller than the roadmap assumed.

2. **"libmtmd/clip" is one library, not two.** Clip is compiled into `libmtmd.a`; there is no separate `libclip`. Cosmetic, but the build emits one new archive.

3. **Building libmtmd needs a build-system change (a real task, not a flag flip).** The roadmap implies the library just needs restoring. In fact the root CMake gates all of `tools/` behind `LLAMA_BUILD_COMMON AND LLAMA_BUILD_TOOLS` (both OFF for us), and `tools/mtmd/CMakeLists.txt` also declares CLI/debug executables that link `llama-common`. So the re-vendor must add a **library-only mtmd build path** (a small vendored CMake change, or a build.rs second-configure — §3.2). This is scoped as WP-V1 and governed by D-015 patch discipline if it modifies the committed tree.

---

## 3. Feasibility findings (the decisions inside the phase)

### 3.1 Re-vendor at b9726 vs a vendor bump — **re-vendor at b9726 (no bump)**

b9726's clip supports **both** required tiers:
- **License-clean default:** Qwen2-VL / **Qwen2.5-VL** / Qwen3-VL (`PROJECTOR_TYPE_QWEN2VL/QWEN25VL/QWEN3VL`), Apache-2.0, whose text decoders are already vendored.
- **Quality option:** Gemma 3 / Gemma 4 vision + MedGemma (`PROJECTOR_TYPE_GEMMA3/GEMMA4V`).

Nothing the phase's exit deliverable needs is missing at b9726, so re-vendoring at the **same tag** is correct — it keeps the ablation patch, the text goldens, and the unpatched-reference comparator all at one pin, and avoids paying the full harness-B re-validation bill a bump would incur (D-021's conditional-bump playbook). §8 lists exactly what would *later* force a bump.

### 3.2 Prune-manifest widening + the build integration

**Add to the vendored tree** (widen VENDORING.md's "Kept" set):
- `tools/mtmd/`: `clip.cpp`, `clip.h`, `clip-impl.h`, `clip-model.h`, `clip-graph.h`, `mtmd.cpp`, `mtmd.h`, `mtmd-image.cpp`, `mtmd-image.h`, `mtmd-audio.cpp`, `mtmd-audio.h`, `mtmd-helper.cpp`, `mtmd-helper.h`, `models/*.cpp` + `models/models.h`, `debug/mtmd-debug.h`, and the mtmd `CMakeLists.txt` (modified to a library-only target — see below).
- `vendor/stb/stb_image.h` (image decode).
- `vendor/miniaudio/miniaudio.h` (needed to *compile* `mtmd-helper.cpp`; see §3.3 for the audio-surface decision).
- **Keep pruned:** `tools/mtmd/{tests,legacy-models,mtmd-cli.cpp,deprecation-warning.cpp,debug/mtmd-debug.cpp,*.md,*.jpeg,*.mp3,*.mp4}`, all of `common/`, `vendor/{cpp-httplib,nlohmann,sheredom}`.

**Build integration** (WP-V1). Two viable mechanisms; the plan recommends the first:
- **(Recommended) A minimal vendored build-system change** — a root option `LLAMA_BUILD_MTMD` that `add_subdirectory(tools/mtmd)` for the **library target only**, plus guarding the mtmd CLI/debug executables (and the `llama-common` FATAL check) behind `if (LLAMA_BUILD_TOOLS)`. `build.rs` sets `LLAMA_BUILD_MTMD=ON`, `MTMD_VIDEO=OFF`, keeps `LLAMA_BUILD_TOOLS=OFF`/`LLAMA_BUILD_COMMON=OFF`. This **fails loud** on a future vendor-bump (a CMake merge conflict), which is the D-015-preferred failure mode. It becomes part of the committed patch set → recompute the three SHAs, keep G4 + coherence green.
- **(Alternative, zero-patch) A `build.rs` second cmake configure** pointed at `tools/mtmd` with a generated library-only `CMakeLists`. Keeps the vendored tree unpatched, but `build.rs` must then track the mtmd source list across bumps (a missed `models/*.cpp` is a link error — fails loud, but a manual sync burden). Recorded as the fallback if the founder prefers no second patch.

`build.rs` then relocates `libmtmd.a` next to `librelm.a`/`libllama.a` and emits the link flags (same pattern as the existing archive relocation, build.rs L114–194). On macOS arm64 clip runs on **Metal** automatically (it uses the shared ggml backend registry via `mtmd_context_params.use_gpu`; no clip-specific shader work). On Linux/x86_64-mac it builds CPU-only exactly like libllama — clip is pure ggml, no platform-specific code.

### 3.3 The miniaudio question (a genuine sub-decision — founder/security-auditor call)

`mtmd-helper.cpp` unconditionally `#include`s `miniaudio.h` (with `MINIAUDIO_IMPLEMENTATION`, ~96k LOC) to provide `mtmd_helper_bitmap_init_from_buf`, which **auto-detects audio vs image by magic bytes**. We want the tested `mtmd_helper_eval_chunks` decode from the same file, so we must compile `mtmd-helper.cpp`. Two options:

- **(Recommended) Option A — vendor `stb_image.h` + `miniaudio.h`, compile `mtmd-helper.cpp` unchanged (zero source patch), and constrain untrusted input in Rust.** We do **not** call the audio-auto-detecting `mtmd_helper_bitmap_init_from_buf` on raw user files; the image FFI first applies a **magic-byte allow-list** (JPEG `FF D8 FF`, PNG `89 50 4E 47`, BMP `42 4D`, GIF `47 49 46`) in Rust and rejects anything else with `relm_error_image`, so the miniaudio code path is **unreachable** from the R API. *(Superseded at WP-V2: GIF was DROPPED from the allow-list — the WP-V1 audit's §2b recommendation, accepted; the shipped list is JPEG/PNG/BMP with the full 8-byte PNG magic.)* Cost: ~96k LOC of an unused audio library sits in the tree (a bigger eventual CRAN tarball, D-013's concern; a Phase-9 item, fine for r-universe now).
- **Option B — vendor `stb_image.h` only; a second small vendored patch to `mtmd-helper.cpp`** guarding the miniaudio include + the audio branch behind an off-by-default `RELM_ENABLE_AUDIO`. Physically removes the audio parser (smallest attack surface + smallest tree) at the cost of a second source patch (moves the post-patch SHA again; adds vendor-bump re-apply work).

**Recommendation: Option A**, consistent with the project's D-012 bias ("prefer zero patch; patch only when necessary") — the magic-byte gate already makes audio unreachable, so a patch is not *necessary*. Option B is the escalation the **security-auditor** may require at the WP-V1 gate if it wants the parser physically absent; both are pre-authorized in the draft ADR so the coder does not stall.

### 3.4 T1 flow (generation with images) — reuse the tested helper

Per the mtmd-cli canonical flow (b9726:mtmd-cli.cpp L180–295), integrated into our engine:
1. `llm(path, projector=)` → load the model (existing path) **and** `mtmd_init_from_file(mmproj, model_ptr, params)` → an mtmd context stored on the handle. `use_gpu` follows the handle backend; `cb_eval = NULL` (no tracing of the vision tower — T3 is out).
2. `llm_generate(m, prompt, images=)` → for each prompt: build the marker text, decode each image path to RGB (Rust magic-byte gate → stb via `mtmd_bitmap_init`), `mtmd_tokenize` → chunks, then **`mtmd_helper_eval_chunks(…, n_batch, logits_last=TRUE, &new_n_past)`** to ingest text+image (honoring the n_batch chokepoint internally), then continue with the **existing sampler loop** from `new_n_past` (unchanged generation code). This reuses upstream's non-causal/M-RoPE handling; we do not reimplement it.

### 3.5 T2 flow (image embedding) — the harder one, scoped honestly

`llm_embed(m, x, images=)` embeds a (text, image) input into one vector. The D-011 embeddings context (`embeddings=true`, `pooling_type=NONE`) accepts image embeddings through `batch.embd`, but the encoder-side subtleties (gemma3 non-causal image mask; qwen-vl M-RoPE positions) must be respected on the *embedding* decode, not only on generation. WP-V3 begins with a **day-1 spike** to confirm the interleaved ingest can run inside the NONE-pooling embedding context (or, if that proves fragile, to fall back to encoding the multimodal prompt through the generation-style context and pooling the last-layer hidden states over the text+image positions). The plan does **not** promise a specific internal mechanism before the spike; the *contract* (a pooled vector per input) is fixed, the mechanism is the spike's output (a short proposed-ADR addendum if it diverges from D-011).

---

## 4. Risk register (ranked)

| # | Risk | L×I | Mitigation / where handled |
|---|------|-----|----------------------------|
| 1 | **Re-vendor / G4 SHA mechanics** — recomputing the three VENDORING.md SHAs, keeping G4 + reverse-apply coherence green after adding files (and possibly a second patch). A stale SHA silently disables the drift gate. | M×H | WP-V1: recompute tarball/pre-patch/post-patch SHAs; `verify_vendored_tree.sh` must be green in the same PR; if Option B or the CMake patch lands, its diff goes in `patches/` and the coherence check must reproduce the pre-patch SHA. **Text goldens byte-identical** is the paired proof nothing else moved. |
| 2 | **Image parsing = untrusted input** (stb_image CVE history; uncatchable aborts reachable from hostile inputs — projector-GGUF asserts + degenerate-dims preprocessing; the planning-time "46000" clip assert does not exist at b9726, per WP-V1 audit F10). | M×H | **Mandatory security-auditor gate** (ROADMAP): magic-byte allow-list before decode (§3.3); validate image dimensions/pixel-count in Rust **before** the FFI (reject-not-clamp, hard rule 8b → `relm_error_image`) so no assert-bearing preprocessing math is reached; decode on the R main thread (no new threads → D-008 G2 preserved); confirm mtmd's C API catches internally (14 try/catch verified). **WP-V1 audit outcome (2026-07-14): SHIP-YES, Option A adequate; the BINDING WP-V2 requirements live in `docs/audit-wp-v1-mtmd-2026-07-14.md` §5.** |
| 3 | **`batch.embd` decode path vs hard rule 8a** — a new decode path must not be guarded only by `≤ n_ctx`; it must chunk by `n_batch` and ship an over-`n_batch` regression test. | M×M | Use `mtmd_helper_eval_chunks(n_batch)` (chunks internally) rather than a hand-rolled decode; WP-V2 ships an over-`n_batch` regression test = a multimodal prompt whose **text** portion exceeds `n_batch` must still decode (the hard-rule-8a artifact for this path). |
| 4 | **Memory on 16 GB** — model weights + KV + the clip compute graph + image embeddings + the R session. A 3B VLM + fp16 mmproj + a large image can spike. | M×H | Pin a 3B-class default (§6); size the clip graph via `image_max_tokens` in `mtmd_context_params`; free image embeddings after ingest (one-shot, not a growing capture — no spill needed, but note the peak). `[MODEL]` acceptance runs on the founder's Mac with Ollama stopped. |
| 5 | **mmproj / model mismatch** — a projector built for a different text model (wrong embd dim / arch) must be a **classed error, not a clamp or a crash**. | M×M | `mtmd_init_from_file` returns `nullptr` on failure and exposes `clip_n_mmproj_embd`; WP-V2 validates the mmproj embd dim against `llama_model_n_embd_inp` and raises `relm_error_image` naming both sizes (reject-not-clamp, hard rule 8b). A test feeds a mismatched pair. |
| 6 | **Cross-platform build** — does libmtmd build on Linux + macOS x86_64 cross with our flag set and the Metal path? | L×M | Clip is pure ggml (no platform code); it builds CPU-only on Linux/x86 exactly like libllama, Metal on arm64 via the shared backend. WP-V1 CI builds all three targets (the existing matrix). `MTMD_VIDEO=OFF` removes the only external-tool dependency (ffmpeg). |
| 7 | **Vendor-tarball / CRAN size** — miniaudio (~96k LOC) + stb + mtmd enlarge the eventual CRAN `vendor.tar.xz`. | L×M | Phase-9 concern (D-013 already flags tarball size as a CRAN NOTE); Option B (§3.3) removes miniaudio if the size becomes a blocker. Not a v0.2.0 blocker (r-universe builds online). |
| 8 | **T2 embedding mechanism uncertainty** (§3.5). | M×M | WP-V3 opens with a spike; the contract is fixed, the mechanism is the spike output; a proposed-ADR addendum if it diverges from D-011. T2 can slip to a v0.2.1 without blocking the v0.2.0 exit (T1 is the exit deliverable) — recorded as the WP-V3 fallback. |
| 9 | **Text goldens drift after re-vendor** (the v0.1.0-breaks failure). | L×H | The paired acceptance in every WP: WP2/WP3/WP4 synthetic goldens byte-identical; G4 SHA re-asserted; libmtmd linked but not on the text path. |

---

## 5. Work-package breakdown (WP-V1…V4)

Sizing: ~6.5 weeks total, each WP ≤ 2 weeks, one in flight (ordering rules). Golden-first: the vision golden category lands **with** the first numerical vision feature (WP-V2). Each acceptance line is a command / test / measurable threshold. Each WP states **where** each test runs (hard rule 8e): `[CI]` per-commit CI; `[NIGHTLY]` nightly `[MODEL]` job; `[MAC]` founder's Mac (Metal), never gates a PR.

### WP-V1 — Re-vendor + build `libmtmd` (the second native library)

**Goal.** Widen the prune manifest at b9726 to include the mtmd library sources + `vendor/stb` (+ `vendor/miniaudio`, §3.3); make `build.rs` produce and link `libmtmd.a` on all three targets; recompute and re-assert the three VENDORING.md SHAs; update NOTICE. **No FFI, no R API, no image decode yet** — this WP only makes the library build, link, and coexist with the byte-identical text path.

**In scope.** Prune-manifest widening (VENDORING.md); the library-only build integration (§3.2, recommended CMake option or the build.rs fallback); `MTMD_VIDEO=OFF`; archive relocation + link flags for `libmtmd.a`; SHA recompute (tarball SHA unchanged; pre-/post-patch SHAs move); `verify_vendored_tree.sh` updated; NOTICE lists stb_image (public domain) + miniaudio (public domain / MIT-0) + libmtmd (MIT, same as llama.cpp); a Rust smoke test that links libmtmd and calls `mtmd_context_params_default()`.

**Out of scope.** Any image FFI / preprocessing; any R API; `common/` (not needed, §2).

**Acceptance (copy-paste-ready).**
- `[CI]` `cargo build -p rebirth-llm` produces `libmtmd.a` on macOS arm64 (Metal), Ubuntu x86_64, and the macOS x86_64 cross-build; the R SHLIB link succeeds (`R CMD check` clean on macOS arm64 + Linux).
- `[CI]` `bash rebirth/src/llama.cpp/patches/verify_vendored_tree.sh` is green: the committed tree digest equals the **new** post-patch SHA (G4), and reverse-applying `patches/*.diff` reproduces the pre-patch SHA (coherence).
- `[CI]` the WP2/WP3/WP4 **synthetic goldens pass byte-identically** — `cargo test -p rebirth-llm` reports the unchanged maxima (logits `1.99e-3`, embeddings `2.92e-3`, activations `3.73e-3`); the greedy token-for-token match vs unpatched llama.cpp is unchanged.
- `[CI]` a `cargo test` smoke test loads no model, calls `mtmd_context_params_default()` across the FFI, and asserts the returned struct's documented defaults (an ABI guard for the new by-value `mtmd_context_params`, mirroring the D-011 `context_params` ABI test).
- `[CI]` `NOTICE` names stb_image + miniaudio + libmtmd with licenses; `grep` finds no `common/` file added.

**Test plan (golden-first).** No new numerical golden here (no feature yet); the golden is "the text path is unchanged," enforced by the byte-identical synthetic goldens + the re-asserted tree SHA. The ABI smoke test is the model-free per-commit guard for the new struct.

**CI wiring.** All `[CI]` (per-commit): the three-target build matrix + `verify_vendored_tree.sh` + text goldens + the ABI smoke test.

**Founder gates.** **security-auditor** at the WP boundary (new C parser sources vendored: stb_image + miniaudio + clip's image preprocessing) — this is the first of the two mandatory audits; it decides Option A vs Option B (§3.3). reviewer + founder diff review.

### WP-V2 — Image FFI + T1 (`llm(projector=)`, `llm_generate(images=)`) + the vision golden category

**Goal.** Hand-written `extern "C"` FFI over mtmd (D-006 minimal surface); Rust-side image loading with the magic-byte allow-list + dimension caps; `projector=` on `llm()`; `images=` on `llm_generate()`; the new harness-B **vision golden category**; classed `relm_error_image`.

**In scope.** The FFI symbols the T1 flow needs (`mtmd_init_from_file`, `mtmd_context_params_default`, `mtmd_free`, `mtmd_bitmap_init`/`mtmd_bitmap_free`, `mtmd_tokenize`, `mtmd_input_chunks_*`, `mtmd_helper_eval_chunks`, `mtmd_support_vision`, `mtmd_default_marker`, `clip_n_mmproj_embd` for the mismatch check) *(superseded at WP-V2: `mtmd_bitmap_init` is deliberately NOT declared — audit binding req 6, the decode helper is the single bitmap constructor — and `clip_n_mmproj_embd` is not exposed by the mtmd.h C API (it takes a `clip_ctx` the API never surfaces), so the mismatch is surfaced from the engine's own init-time check via the captured log, both sizes named)*; the interleaved ingest via `mtmd_helper_eval_chunks(n_batch)` then the existing sampler loop; mmproj/model-arch mismatch → `relm_error_image` (reject-not-clamp); the `images` pairing/recycling semantics (§7); a committed test image (small, license-clean, e.g. a solid-color or simple synthetic PNG for the deterministic gate + a real photo for `[MAC]`).

**Out of scope.** T2 embeddings (WP-V3); T3 vision-tower trace/steer/ablate; multi-image-per-marker interleaving beyond "images before text" (backlog); an `relm_image` S3 type (v1 = file paths, D-023 backlog); audio.

**Acceptance.**
- `[MAC]` a pinned Qwen-VL + mmproj (§6) answers a factual question about the committed test image (`llm_generate(m, "What color is the square?", images = list("tests/vision/red-square.png"))` returns a string containing the correct colour); the founder's showcase run is recorded.
- `[NIGHTLY]`/`[MAC]` **vision golden (same-implementation leg, per D-018 logic):** greedy (`temperature = 0`, fixed seed) generation on the committed image + prompt matches, **token-for-token**, the output of the **unpatched upstream `llama-mtmd-cli` at b9726** on the same image+prompt+backend (CPU); and `mtmd_get_output_embd` for that image matches the reference build within `ATOL 1e-3` on CPU (same code, same backend → near-exact — no HF cross-check is used for T1, that would be a T3-style tower check which is out of scope). *(Superseded at WP-V2, D-026 addendum: the shipped WP-V2 gate is the byte-exact greedy TEXT leg — the upstream CLI exposes no token ids — and the `mtmd_get_output_embd` ATOL-1e-3 leg is deferred to WP-V4 as a BINDING requirement: the phase does not close and v0.2.0 is not tagged without it.)*
- `[CI]` **over-`n_batch` regression test** (hard rule 8a): a multimodal prompt whose text portion exceeds `n_batch` decodes without a `GGML_ASSERT` abort (model-free where possible via a stubbed tiny path, else `[NIGHTLY]`).
- `[CI]` model-free unit tests: the magic-byte allow-list accepts JPEG/PNG/BMP *(GIF was dropped at WP-V2 per the accepted WP-V1 audit §2b recommendation — a GIF must be REJECTED)* and rejects audio/garbage with `relm_error_image`; an oversized-dimension input is rejected **before** the FFI; a mismatched mmproj/model pair → `relm_error_image` naming both embd sizes; `images` on a handle loaded without a projector → `relm_error_image`.
- `[CI]` the text `llm_generate()` path (no `images`) is byte-identical; `R CMD check` clean; `cargo test` green.

**Test plan (golden-first).** The vision golden category is defined here: reference = unpatched upstream `llama-mtmd-cli` at b9726 (built in the harness-B tooling like the existing unpatched-llama.cpp comparator), deterministic greedy, fixed committed image + prompt. **Byte-exact** on the generated token ids (same-implementation leg); **tolerance `ATOL 1e-3`** on the raw image embeddings (CPU same-backend). No in-repo synthetic vision model exists (unlike the 2-layer text GGUF), so the vision golden is a **`[MODEL]`/`[NIGHTLY]` gate, never per-commit** — this is stated honestly; per-commit CI covers the build, the text goldens, the FFI ABI/error paths, and the magic-byte gate. (A synthetic tiny-clip GGUF oracle is a possible future de-risk — §8 backlog — not required for v0.2.0.)

**CI wiring.** `[CI]` model-free FFI/error/magic-byte tests + text-path byte-identity + `R CMD check`; `[NIGHTLY]` the vision golden on a small pinned VLM; `[MAC]` the showcase + the token-for-token reference match on Metal.

**Founder gates.** **security-auditor** (second mandatory audit — the image FFI is the untrusted-input entry point); reviewer; founder diff review + `[MAC]` acceptance run.

### WP-V3 — T2 (`llm_embed(images=)`)

**Goal.** Image (+ optional text) embedding into a base `matrix` row, reusing the T1 encode path.

**In scope.** A **day-1 spike** (§3.5) to fix the embedding mechanism inside/around the D-011 context; the `images` argument on `llm_embed` with the same pairing/recycling as `llm_generate`; the pooled vector per input; a golden.

**Out of scope.** T3; multi-image; reranking.

**Acceptance.**
- `[MAC]` `llm_embed(m, x = "", images = list("tests/vision/cat.png"))` returns a `1 × hidden_size` matrix; the embedding of a cat image is closer (cosine) to the text embedding of "a cat" than to "a car" (a committed, non-cherry-picked similarity fixture with margin).
- `[NIGHTLY]`/`[MAC]` golden: the pooled image embedding matches the unpatched-reference build within the documented tolerance (same-implementation leg).
- `[CI]` model-free: `images` without a projector → `relm_error_image`; `images`/`x` length-pairing errors → `relm_error_argument`; dims equal `m$hidden_size`.
- `[CI]` the text `llm_embed()` path is byte-identical; `R CMD check` clean.

**Test plan.** Golden-first on the pooled vector (tolerance leg); the similarity fixture is the property test (ranking, not a tuned threshold), mirroring WP3's approach.

**CI wiring.** `[CI]` model-free + text-path byte-identity; `[NIGHTLY]`/`[MAC]` the embedding golden + similarity.

**Founder gates.** reviewer; founder `[MAC]` acceptance. If the spike shows T2 is materially harder than a WP allows, T2 slips to v0.2.1 (Risk #8) without blocking the v0.2.0 exit — a founder call at the spike review.

### WP-V4 — Harness-B nightly wiring + docs + registry + release `v0.2.0`

**Goal.** Formalize the vision golden in nightly CI; ship docs + a vision vignette; add the Qwen-VL + mmproj registry entries (D-024 flow); phase-end simplifier + security-auditor sweep; tag `v0.2.0`.

**In scope.** The `[NIGHTLY]` vision-golden workflow (fail-closed model pin, never gates PRs — mirrors the existing `nightly-model-tolerance.yaml`); `inst/models.csv` entries for the default Qwen-VL model + its mmproj (two aliases, §6; SHA256 pinned, fail-closed per D-024); roxygen examples (`@examplesIf` gated on a `RELM_TEST_MODEL_VLM` env var, since CI has no VLM); a Quarto vignette "a VLM answering questions about an image, locally"; README/pkgdown/`NEWS.md` update; version bump `0.1.0.9000 → 0.2.0`; the `release` skill (matrix, tag, r-universe verification).

**Out of scope.** CRAN (Phase 9); T3; Gemma auto-download (ToU-gated → local path per D-023, showcased but not the CI/reproduction default).

**Acceptance.**
- `[CI]` `R CMD check --as-cran` clean on the built tarball; every export documented; every example executes or is properly `@examplesIf`-guarded.
- `[MAC]`/`[NIGHTLY]` the nightly vision-golden workflow is green three consecutive nights before the tag (mirrors WP6b's discipline).
- `[MAC]` `llm_download("qwen2.5-vl-3b-instruct-q4_k_m")` **and** `llm_download("qwen2.5-vl-3b-instruct-mmproj-f16")` fetch + SHA256-verify fail-closed; the vignette runs end-to-end from the README on the **Apache-2.0 Qwen-VL default** (the stranger-reruns acceptance, on a license-clean model).
- `[CI]` `NEWS.md` documents T1+T2; `install.packages("relm", repos = <r-universe>)` works on clean R after the tag.

**Test plan.** No new numerical golden; this WP wires the WP-V2/V3 goldens into nightly and validates the release.

**CI wiring.** `[CI]` `R CMD check --as-cran` + docs examples; `[NIGHTLY]` the vision golden; `[MAC]` the founder's release verification.

**Founder gates.** phase-end **simplifier** (mandatory at phase end) + **security-auditor** final sweep; founder runs the release + verifies the r-universe install (the `release` skill).

---

## 6. Model-pin proposal (SHA256 pinned at implementation via the D-024 flow)

The registry needs a **model + mmproj pair** per VLM. Since `llm_download` fetches one URL per alias (D-024), the cleanest is **two aliases per VLM** (a `-mmproj` companion) — **zero schema change** to `inst/models.csv`. `llm(path = <model>, projector = <mmproj>)`.

| Role | Alias(es) | Approx size | License | Notes |
|---|---|---|---|---|
| **License-clean default (showcase + reproduction)** | `qwen2.5-vl-3b-instruct-q4_k_m` + `qwen2.5-vl-3b-instruct-mmproj-f16` | ~1.9 GB + ~1.35 GB (≈ 3.3 GB) | **Apache-2.0** (Qwen2.5-VL-3B; **founder verifies** — the 3B/7B are Apache-2.0, the 72B is the Qwen license) | Fits the 16 GB Mac (~10–11 GB free) with Ollama stopped. |
| *(Superseded at WP-V4 — founder signs at the release gate)* | `qwen2-vl-2b-instruct-q4_k_m` + `qwen2-vl-2b-instruct-mmproj-f16` | ~0.99 GB + ~1.33 GB | **Apache-2.0** (verified from the HF card of `ggml-org/Qwen2-VL-2B-Instruct-GGUF`, tag `license:apache-2.0`) | The 3B row above was written on the "founder verifies" assumption; verification found **Qwen2.5-VL-3B is NOT Apache-2.0** (its license is the Qwen Research License class), so the shipped v0.2.0 registry default is the **Qwen2-VL-2B** pair — Apache-2.0, and the exact artifacts every WP-V2/V3/V4 acceptance and golden was validated against. |
| **Lighter option (founder's Mac / smaller nightly)** | `qwen2-vl-2b-instruct-q4_k_m` + `qwen2-vl-2b-instruct-mmproj-f16` | ~1.5 GB + ~0.9 GB | Apache-2.0 | The smallest reasonable VLM; there is **no sub-1 GB VLM**, so vision goldens are `[MODEL]`/nightly, never per-commit (§5 WP-V2). |
| **Quality option (not CI, not auto-download)** | Gemma 3 4B vision / **MedGemma-4B** + mmproj | ~3–4 GB | Gemma Terms of Use (gated) | **Local path only** (D-023 CI/reproduction split; a plain libcurl fetch 401s on the ToU token gate, D-024). Thesis-era; parked. |

Exact GGUF/mmproj artifact URLs + SHA256s are chosen and pinned at WP-V4 implementation time (a reputable source that produced the mmproj **for b9726's clip** — a converter-version mismatch is a §8 bump trigger). `size_bytes`/`license`/`notes` follow the existing rows.

---

## 7. Draft API-GRAMMAR entries — approved 2026-07-14 (the binding text lives in `API-GRAMMAR.md` §3/§6)

Per D-003's change protocol, these are drafted here and require **founder sign-off** before any code. They realize the reserved slot at API-GRAMMAR §7 L156. **Nothing is implemented until the founder approves these entries.** No other new export.

**Amend `llm()` (§3) — add one argument:**

> `llm(path, context_length = 4096, gpu_layers = NULL, backend = c("auto","metal","cuda","cpu"), mmap = TRUE, projector = NULL)`
> `projector` = a path to an **mmproj GGUF** (or a registry alias resolved to a path) enabling image input; `NULL` (default) = text-only, unchanged. When set, `llm()` also initializes the vision encoder bound to the loaded model; a projector whose input embedding size does not match the model raises `relm_error_image` (naming both sizes — reject-not-clamp). New handle slots: `projector` (chr path or `NULL`), `vision` (lgl). `print.llm` shows the projector when present. **Attachment point justification:** the projector is a session property fixed at load (it shares the model pointer — `mtmd_init_from_file(mmproj, model)`), exactly like the model file, so it belongs on `llm()`, not on each call.

**Amend `llm_generate()` (§3) — add one argument:**

> `llm_generate(m, prompt, max_tokens = 256, temperature = 0.8, top_p = 0.95, seed = NULL, chat = TRUE, stop = NULL, images = NULL)`
> `images = NULL` (default) = text-only, unchanged. Otherwise a **list parallel to `prompt`**: `images[[i]]` is a character vector of image **file paths** for prompt `i` (`character(0)` for none). A bare character vector is treated as `list(images)` and requires `length(prompt) == 1` (else recycled with a warning if lengths differ — the same recycling contract as `llm_trace(positions=)`). Each prompt's images are inserted **before** its text (the common VLM convention; interleaved-marker control is a backlog capability). Returns a character vector of `length(prompt)` (names preserved); the `prompt_id` mapping is one output per prompt (unchanged). Requires a handle loaded with `projector=`; images on a text-only handle raise `relm_error_image`. Errors: `relm_error_image` (decode/parse failure, projector mismatch, no-projector), `relm_error_argument` (bad `images` type/length), `relm_error_context_overflow` (combined text+image tokens exceed `context_length` — message states by how much).

**Amend `llm_embed()` (§3) — add one argument:**

> `llm_embed(m, x, pooling = c("mean","last","model"), normalize = TRUE, images = NULL)`
> `images` pairs with `x` by the **same rule** as `llm_generate(images=)` (list parallel to `x`; a bare vector requires `length(x) == 1`/recycled-with-warning). Returns the base `matrix`, one row per input (per (text, image) pair); rownames as today. Requires a projector; images on a text-only handle raise `relm_error_image`. Errors: `relm_error_image`, `relm_error_argument`.

**Add one condition class (§6):**

> `relm_error_image` — raised by `llm()` (projector load/mismatch), `llm_generate()`, `llm_embed()` — image decode/parse failure, unsupported/oversized image, mmproj-model mismatch, or images supplied to a non-vision handle. Carries structured fields where useful (`expected`/`actual` embd size on mismatch; `path` on a decode failure). **Justification for a new class rather than reuse:** a runtime image-decode failure during generate/embed is not a model-load failure (`relm_error_model_load`) nor an argument type error (`relm_error_argument`); image parsing is a distinct, security-relevant failure surface deserving its own catchable class. `relm_error_argument` still covers `images` type/length validation; `relm_error_context_overflow` still covers the combined-length overflow.

**Memory-safe defaults (grammar rule 6):** every new argument defaults to `NULL` (zero cost on the text path); image-encoder buffers are freed after ingest (one-shot, not a growing capture — no spill needed, but the 16 GB peak = weights + KV + clip graph + image embeddings is documented).

---

## 8. What could force a vendor bump (honest section)

Re-vendoring at b9726 is correct **today**; these are the specific facts that would flip it to the D-021 conditional-bump playbook (newest `bNNNN` ≥ ~2 weeks old, diff-review the now-larger patch set, full harness-B re-validation including rebuilding the unpatched reference at the new tag, 3-working-day timebox → else revert):

1. **A target mmproj won't load at b9726's clip** — e.g. the founder wants a model whose only good GGUF/mmproj was produced by a converter newer than b9726's clip format (GGUF mmproj key drift). Mitigation first: pin an mmproj known to load at b9726 (WP-V4). If none exists for a required model → bump.
2. **A known image-preprocessing or projector bug in b9726's clip** for the chosen model (check upstream issues for the specific `PROJECTOR_TYPE_*` at pin time). The token-for-token vision golden vs the unpatched b9726 reference would *not* catch this (both share the bug); a `[MAC]` sanity check against the model card is the backstop.
3. **A CVE in the vendored `stb_image.h` / `miniaudio.h`** requiring an upstream fix (the supply-chain gate does not cover vendored C; the vendored-tree SHA + upstream advisories are the watch). Option B (§3.3) removing miniaudio narrows this.
4. **T2's spike (§3.5) reveals an embedding-path bug fixed only upstream** after b9726.

None of these is expected for the Qwen-VL default (its projector types are first-class at b9726); they are the honest tripwires.

---

## 9. Open founder inputs (what only the founder decides) + exact next action

**Founder decisions (block implementation):**
1. **Accept / amend draft ADR D-026** (§ below) — re-vendor at b9726, the library-only build integration, the audio-surface choice (Option A recommended vs Option B), the model pins, and the `0.1.0.9000` dev-version discipline.
2. **Approve the API-GRAMMAR `[proposed]` entries** (§7) — `projector=`, `images=` (×2), `relm_error_image` — per the D-003 change protocol. No vision code is written until these are approved.
3. **Audio-surface call (§3.3):** Option A (zero-patch, vendor miniaudio, magic-byte gate) vs Option B (a second patch dropping miniaudio). Recommendation: Option A, with the security-auditor empowered to escalate to Option B at the WP-V1 gate.

**Founder inputs (needed by WP-V4, not by WP-V1):**
4. **Verify the exact Qwen-VL license + pin the GGUF/mmproj SHA256** (§6) — Qwen2.5-VL-3B is expected Apache-2.0; confirm the specific artifact.
5. **HF / Gemma ToU** for the MedGemma / Gemma-vision **quality option** (local path only, non-blocking; thesis-era, parked).

**Nothing here relitigates an accepted decision.** D-023 (vision as a dedicated v0.2.0 phase; T3 out), D-006 (vendoring + minimal FFI), D-015 (patch discipline), D-018 (golden acceptance logic), D-024 (download/registry) all stand; D-026 is additive and cites them. The one substantive correction to a prior assumption — `common/` is **not** needed — is flagged in §2 (it makes the phase cheaper, not different in shape) and does not require superseding D-023, which described the scope at the goal level.

**Exact next action:** founder reviews **D-026** (§ below) + the §7 grammar entries. On acceptance of D-026, the founder appends it to `DECISIONS.md` and the §7 entries move to `[proposed]→approved` in `API-GRAMMAR.md`; I hand off **WP-V1** to the `coder` (branch `wp-v1-revendor-mtmd`), whose first act is the prune-manifest widening + SHA recompute, gated by the **security-auditor** on the newly vendored parser sources before any FFI work begins.

---

## Draft ADR — accepted 2026-07-14 and appended to `DECISIONS.md` as D-026 (the DECISIONS.md text is binding)

```
## D-026 — Vision (v0.2.0): re-vendor libmtmd at b9726, a second native library, T1+T2 only
- **Date:** 2026-07-14 · **Status:** proposed — founder approval required
- **Context:** Phase 11 (vision, pulled forward to v0.2.0 per D-023) is current. The
  vendored b9726 tree was pruned of the entire multimodal subsystem, but the VLM TEXT
  decoders (gemma4/qwen2vl/qwen3vl) are already vendored. Verified against the b9726
  tarball (SHA256 117e95a5…f2e0, matching the pin): (a) libmtmd is a buildable library
  at b9726 that links only ggml+llama and is explicitly forbidden from linking
  llama-common — so common/ is NOT needed (correcting the ROADMAP/D-023 "+ common/"
  assumption); (b) clip supports QWEN2VL/QWEN25VL/QWEN3VL and GEMMA3/GEMMA4V — both the
  Apache-2.0 default and the Gemma quality tier; (c) the interleaved image+text decode
  is a tested upstream helper (mtmd_helper_eval_chunks, n_batch-aware, handling the
  gemma3 non-causal mask + qwen-vl M-RoPE internally); (d) image decode uses stb_image,
  and mtmd-helper.cpp also pulls miniaudio; (e) libmtmd is unreachable with our current
  LLAMA_BUILD_TOOLS=OFF/LLAMA_BUILD_COMMON=OFF flags, needing a library-only build path.
- **Decision:**
  1. Re-vendor at the SAME tag b9726 (no version bump) — clip already supports every
     target model, keeping the ablation patch, the text goldens, and the unpatched
     reference all at one pin. §8 of docs/phase11-vision-plan.md lists what would later
     force a bump (D-021 playbook).
  2. Widen the prune manifest to add tools/mtmd (library sources + models/ + the
     debug header) and vendor/stb/stb_image.h; recompute the three VENDORING.md SHAs
     and keep G4 + reverse-apply coherence green. common/ is NOT restored.
  3. Build libmtmd.a as a SECOND native archive via a library-only build integration
     (a minimal vendored CMake option LLAMA_BUILD_MTMD, recommended; or a build.rs
     second-configure, fallback), MTMD_VIDEO=OFF; Metal on macOS arm64, CPU elsewhere,
     same pattern as libllama. Any committed-tree change joins the D-015 patch set.
  4. Audio surface: vendor miniaudio and compile mtmd-helper.cpp unchanged (Option A,
     zero source patch), with a Rust-side image magic-byte allow-list so the audio
     decoder is unreachable from the R API; the security-auditor may escalate to
     Option B (a second small patch dropping miniaudio) at the WP-V1 gate. Both are
     pre-authorized so the coder does not stall.
  5. Scope = T1 (llm(projector=) + llm_generate(images=)) + T2 (llm_embed(images=)),
     file-paths-only, single-image-before-text, per the API-GRAMMAR [proposed] entries
     (projector=, images= ×2, relm_error_image), which need separate founder sign-off
     (D-003). The interleaved decode reuses mtmd_helper_eval_chunks (never a hand-rolled
     M-RoPE/non-causal reimplementation — the D-012 fails-silent trap). T3 (vision-tower
     trace/steer/ablate), an relm_image S3 type, multi-image, and audio stay OUT
     (D-023 backlog).
  6. A new harness-B vision golden category: same-implementation leg only — token-for-
     token greedy match + image-embedding ATOL 1e-3 vs the UNPATCHED upstream
     llama-mtmd-cli at b9726 (per D-018 logic; no HF cross-check, that would be a
     T3 tower check). No in-repo synthetic vision model exists, so the vision golden
     is a [MODEL]/nightly gate, never per-commit; per-commit CI covers the build, the
     byte-identical text goldens, the FFI ABI/error paths, and the magic-byte gate.
  7. Dev-version discipline: DESCRIPTION moves to 0.1.0.9000 for the phase (main stays
     releasable at every merge; r-universe rebuilds main on push), bumping to 0.2.0 at
     the release WP with the tag.
  8. Model pins (SHA256 pinned at WP-V4 via D-024): default = Apache-2.0 Qwen2.5-VL-3B
     + its mmproj (two aliases, no models.csv schema change); Gemma/MedGemma the local-
     path quality option (ToU-gated, per D-023's CI/reproduction split).
- **Why:** vision at b9726 needs no bump (clip already supports the targets), so the
  risky operation stays a contingency (D-021), not a prerequisite; reusing the tested
  interleaved-decode helper honors the n_batch chokepoint (hard rule 8a) and avoids a
  fails-silent M-RoPE reimplementation (D-012); the magic-byte gate + reject-not-clamp
  dimension checks (hard rule 8b) keep the untrusted image surface auditable; the
  byte-identical text goldens + re-asserted tree SHA are the formal "v0.1.0 does not
  break" guarantee; the dev-version keeps main honestly labeled while r-universe builds.
- **Alternatives rejected:** a vendor bump now (pays the full harness-B re-validation
  bill for arch support b9726 already has — kept only as the §8 contingency); restoring
  common/ (verified unnecessary — libmtmd forbids llama-common); reimplementing the
  interleaved decode in Rust (duplicates tested M-RoPE/non-causal logic, a fails-silent
  risk); a build.rs mtmd source list without a CMake option (manual sync burden across
  bumps — the fallback, not the default); folding T3 into this phase (T3 is research
  and breaks the D-018 residual golden on a non-causal SigLIP encoder — D-023); shipping
  vision as a v0.1.0 patch instead of a versioned phase (mis-sized, D-023).
```
