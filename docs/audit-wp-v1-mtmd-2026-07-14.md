# WP-V1 boundary security audit — re-vendor of libmtmd at b9726 (PR #32 gate)

**Auditor:** security-auditor agent · **Date:** 2026-07-14 · **Scope:** `origin/main...wp-v1-revendor-mtmd` (5 commits, 62 files).
**Verdict: SHIP-YES for WP-V1 · Option A ADEQUATE (no escalation to Option B) · §5 lists the BINDING WP-V2 requirements.**

This is the first of the two mandatory audits required by `docs/phase11-vision-plan.md` (§4 risk 2, §5 WP-V1 founder gates) and D-026. All checks were re-run independently; nothing was taken on the coder's word. File:line citations refer to the vendored tree at `rebirth/src/llama.cpp/` and the crate at `rebirth/src/rust/rebirth-llm/`.

---

## 1. Supply-chain integrity — VERIFIED CLEAN

| Claim | Result | Evidence |
|---|---|---|
| Tarball is the pinned upstream artifact | PASS | `shasum -a 256` of `b9726.tar.gz` = `117e95a5…f2e0`, matching VENDORING.md |
| Every added vendored file byte-identical to upstream | PASS | Independent `cmp` of all 51 added files: **50/50 unpatched files identical**; the single divergence is `tools/mtmd/CMakeLists.txt` (the patch-0002 target) |
| Patch 0002 touches only the two CMakeLists, build logic only | PASS | `diff -u` of both committed files vs upstream reproduces exactly the hunks in `patches/0002-rebirth-wp-v1-mtmd-library-build.diff`; zero C/C++ source semantics touched |
| G4 + reverse-apply coherence | PASS | `patches/verify_vendored_tree.sh`: `OK (G4)` + `OK (coherence)` |
| Pre-patch SHA genuinely upstream-derived (not merely self-consistent) | PASS | The pruned tree was **rebuilt from upstream tarball bytes** using the committed file list; the independently computed digest equals the recorded pre-patch SHA `1c8148f3…1289`. This proves the *entire* committed tree is upstream bytes + patches 0001/0002, nothing smuggled |
| NOTICE accuracy | PASS | stb_image v2.30 dual "MIT OR Public Domain" (in-file); miniaudio v0.11.25 dual "Public Domain OR MIT-0" (in-file). NOTICE matches both |

## 2. Future attack surface (nothing below is reachable in WP-V1; all becomes reachable only via WP-V2 code that does not yet exist)

### (a) Decode paths and WP-V2 entry points
- `mtmd_init_from_file()` (`mtmd.cpp:795-800`, wrapped in try/catch) → `clip_model_load` — GGUF parse of the **projector file** (untrusted-input class).
- `mtmd_helper_bitmap_init_from_buf()` (`mtmd-helper.cpp:514`) — the single file-bytes decode gateway: audio sniff at `:523`, else `stbi_load_from_memory` at `:542`, else video (compiled out).
- `mtmd_tokenize()` (`mtmd.cpp:1424-1432`, try/catch present) → image preprocessing (`mtmd-image.cpp` resize/slice math on bitmap dims).
- `mtmd_helper_eval_chunks()` — n_batch-aware interleaved decode (`mtmd-helper.cpp:253/:346` assert `n_batch > 0`, our own param).

### (b) stb_image v2.30 — version and format risk
`stb_image.h:1` identifies v2.30 (2024-05-31), the newest tagged release, containing the 2.28 "many error fixes, security errors" batch — i.e. the CVE-2021-42715/42716 (HDR/PNM) and CVE-2022-28041 (GIF integer overflow) era is fixed. Central integer-overflow guards are present (`stbi__mul2sizes_valid`/`stbi__mad2sizes_valid`, `stb_image.h:1014-1041`; `STBI_MAX_DIMENSIONS = 1<<24`, `:795-796`). All nine decoders are compiled (no `STBI_ONLY_*`), but with the allow-list only JPEG/PNG/BMP/GIF are dispatchable — stb's format tests are pure magic checks, so the historically fuzz-bug-rich low-value formats (PNM/HDR/PIC/PSD/TGA) become unreachable. **Riskiest allow-listed format: GIF** (LZW state machine + palette machinery, longest bug tail, CVE-2022-28041 lineage) — and via this path stb decodes only the *first frame*, so its user value for a VLM is near zero. **Recommendation: drop GIF from the WP-V2 allow-list** (JPEG/PNG/BMP, or JPEG/PNG-only). Not a blocker — a founder call; JPEG/PNG are the best-fuzzed decoders in existence, BMP is small and simple.

### (c) Aborts/asserts reachable from attacker-controlled input (the D-008 G1 class)
- The planning-time cited `GGML_ASSERT(width/height ≤ 46000)` **does not exist at b9726** (grep-verified); the actual dimension guards are stb's `STBI_MAX_DIMENSIONS` + INT_MAX-byte allocation caps.
- From a hostile **projector GGUF**: uncatchable `GGML_ASSERT` aborts in `clip_model_load` — `clip.cpp:1248-1249` (missing `image_mean`/`image_std`), `:1322` (tile hparams). The `std::runtime_error` subset is safely caught (`mtmd.cpp:795-800`); the asserts are not. Same trust class as the main GGUF today; mitigated by registry SHA256 pins + docs.
- From a hostile **image**: stb itself fails closed (returns NULL), but degenerate decoded dimensions (1×16777215 etc.) flow into preprocessing assert-bearing math (`mtmd-image.cpp:120-121` crop bounds, `:393` resize weights) — must be cut off by Rust-side dimension caps (binding req. 3).
- `mtmd_helper_video_*` stubs in a `MTMD_VIDEO=OFF` build are `GGML_ASSERT(false)` aborts (`mtmd-helper.cpp:1034, :1044`) — WP-V2 must simply never declare them.
- **Memory-DoS**: stb allows up to INT_MAX bytes per decode; a small crafted PNG can legally expand to ~2 GB u8 + a second 2 GB copy in `mtmd_bitmap` (`mtmd.cpp:45-47` `resize` + `memcpy`) + ~4× more as f32 in clip — enough to OOM the 16 GB target machine. Also: `mtmd_helper_bitmap_init_from_buf` has **no try/catch**, so a `std::bad_alloc` there unwinds through the C ABI into Rust = abort. Both are killed by the pre-decode pixel cap (binding req. 3).
- `(size_t)nx * ny * 3` in `mtmd_bitmap` (`mtmd.cpp:45`) can wrap only for nx,ny near 2^32 — unreachable via stb (dims ≤ 2^24), reachable only if WP-V2 called raw `mtmd_bitmap_init` with unchecked dims (binding req. 6).

### (d) system/popen/threads/signals/globals in the vendored additions
- All `subprocess_create` / ffmpeg / `std::thread feeder` code is inside `#ifdef MTMD_VIDEO` (`mtmd-helper.cpp:39-42, :624-`); `build.rs` sets `MTMD_VIDEO=OFF` and `sheredom/` is pruned, so accidentally re-enabling it **fails the build loudly** (missing header). Good failure mode.
- No `sprintf`/`strcpy`/`strcat`/`alloca` in any mtmd source. No signal handlers.
- Threads: audio mel-spectrogram preprocessing spawns `n_threads-1` workers (`mtmd-audio.cpp:463-466`) — audio-path only, sealed by the gate; the image path creates no threads (D-008 G2 holds).
- Env-sensitive globals: `std::getenv("MTMD_BACKEND_DEVICE")` (`clip.cpp:184`) and `MTMD_DEBUG_EMBEDDINGS` (`clip.cpp:224`) — informational; document at WP-V2.

### (e) Is the audio decoder reachable without audio bytes? — NO (evidence)
`ma_decoder_*` appears in exactly one function: `audio_helpers::decode_audio_from_buf` (`mtmd-helper.cpp:461-498`). Its only caller is `mtmd_helper_bitmap_init_from_buf:530`, gated solely by `is_audio_file()` (`:523`, sniffing RIFF/WAVE, ID3 or MPEG sync `0xFF/0xE0`, fLaC at `:449-455`). The file-path variant (`:584-610`) delegates to the buf variant. `mtmd_bitmap_init_from_audio` (`mtmd.cpp:1710`) consumes pre-decoded PCM and never calls miniaudio; the whisper preproc runs only on bitmaps with `is_audio=true`, which only the two functions above create. **The magic sniff at `mtmd-helper.cpp:523` is the single gateway.** None of the four allow-listed magics can satisfy it (JPEG's second byte `0xD8 & 0xE0 = 0xC0 ≠ 0xE0`; PNG/BMP/GIF match nothing), so a fail-closed Rust allow-list on the same buffer provably seals miniaudio. Bonus hardening already in place: miniaudio is compiled `MA_API static` (`mtmd-helper.cpp:28`) — its symbols are not even exported from the archive, so no accidental Rust-side linkage is possible; `MA_NO_DEVICE_IO` etc. strip all device/thread machinery, leaving decode-only (WAV/FLAC/MP3).

Caveat the requirements fix in stone: the MP3 sniff is extremely loose (any `0xFF, 0xE0`-masked second byte routes a buffer into miniaudio), so the WP-V2 gate must be **allow-list, not audio-deny-list**, and must be applied to the exact bytes passed over FFI — never to a path the C++ side re-reads (TOCTOU).

## 3. Findings table

| # | Severity | Reachable now (WP-V1) | Reachable at WP-V2 | Finding | Location |
|---|---|---|---|---|---|
| F1 | High | No | Yes, unless gated | Loose audio sniff routes non-audio bytes into miniaudio; gate must be fail-closed allow-list on the same buffer | `mtmd-helper.cpp:450-454, :523` |
| F2 | High | No | Yes | Decompression-bomb memory-DoS: up to ~2 GB × multiple copies from a tiny file; OOM/session kill on the 16 GB target | `stb_image.h:795, :1014-1041`; `mtmd.cpp:45-47` |
| F3 | Medium | No | Yes | `mtmd_helper_bitmap_init_from_buf` has no try/catch; `bad_alloc` unwinds through C ABI into Rust = abort | `mtmd-helper.cpp:514-582` |
| F4 | Medium | No | Yes (user projector path) | Hostile mmproj GGUF hits uncatchable `GGML_ASSERT` in clip model load | `clip.cpp:1248-1249, :1322` |
| F5 | Medium | No | Yes | Degenerate decoded dims (1×N) can reach preprocessing asserts | `mtmd-image.cpp:120-121, :393` |
| F6 | Low | No | Yes | `size_t → int` narrowing of the buffer length into stb | `mtmd-helper.cpp:542`; `stb_image.h:423` |
| F7 | Low | No | Only if declared | Video stubs are `GGML_ASSERT(false)` aborts | `mtmd-helper.cpp:1034, :1044` |
| F8 | Low | No | Only if audio unsealed | Audio preproc spawns threads (D-008 G2 class) | `mtmd-audio.cpp:463-466` |
| F9 | Info | No | Yes | Env-var-sensitive backend/debug behavior in clip | `clip.cpp:184, :224` |
| F10 | Info | — | — | The planning-cited 46000-dimension assert does not exist at b9726; guards are stb-side | grep-verified |

**Reachable-now column is empty by construction and verified:** the diff adds zero R-facing code (no `R/` files changed; `DESCRIPTION`/`NEWS.md` only), and the sole new FFI declaration is `mtmd_context_params_default()` (one `extern` fn, consumed only by a `#[cfg(test)]` ABI test).

## 4. Option A verdict: ADEQUATE — do not escalate to Option B, conditional on §5

Justification: the gateway to miniaudio is a single, evidence-cited sniff point (§2e); the four allow-listed magics provably cannot trip it; miniaudio's symbols are archive-internal (`MA_API static`), so it cannot even be reached from Rust by accident. Option B would remove ~96k dormant lines from the binary but requires a *source* patch to `mtmd-helper.cpp`, breaking WP-V1's clean "patches touch only build files" property and adding permanent vendor-bump friction, to eliminate a risk that is only latent (it requires a WP-V2 gate bug to become live). The gate-bug risk is instead pinned by requirement 4 (a per-commit mutation-style test that the gate exists and rejects audio magics). **Escalation trigger, recorded:** if WP-V2 cannot implement requirements 1–2 exactly (fail-closed, same-buffer), Option B is pre-authorized and should then be taken.

## 5. Binding WP-V2 requirements

1. **Fail-closed magic allow-list in Rust**, on the raw file bytes: JPEG `FF D8 FF` (3 bytes), PNG `89 50 4E 47 0D 0A 1A 0A` (8 bytes), BMP `42 4D` (2 bytes), GIF `47 49 46 38 [37|39] 61` (full 6 bytes). Anything else → classed `relm_error_image` (reject-not-clamp, Hard rule 8b). Never route on file extension. **Recommended: drop GIF** (§2b rationale; founder call).
2. **Same-buffer contract:** Rust reads the file once; the identical buffer goes to `mtmd_helper_bitmap_init_from_buf`. Never call `mtmd_helper_bitmap_init_from_file` (`mtmd-helper.cpp:584-610`) — its C-side re-read reopens the sniff via TOCTOU/symlink swap.
3. **Pre-decode caps in Rust, before the decode FFI call:** (a) byte-length cap — hard-reject ≥ 2^31 bytes (F6), practical default far lower (e.g. 64 MB, documented option); (b) call `stbi_info_from_memory` (exported: `STBIDEF extern`, `stb_image.h:398, :7734`) and reject unless `1 ≤ nx, ny ≤ 16384` and `nx*ny ≤` a documented pixel cap (suggest ~33.5 Mpx default), computed in u64. This kills F2, F3 (bad_alloc becomes practically unreachable), F5, and the `mtmd.cpp:45` wrap corner simultaneously.
4. **Adversarial per-commit tests** (Hard rule 8e — state where each runs): truncated files of each allowed format; WAV/MP3-sync/FLAC magic buffers → must produce the image classed error (the audio-gate mutation proof, non-gameable); over-cap dimensions; degenerate dims (1×1, 1×16384, 16384×1) against the pinned projector under the `[MODEL]`/nightly gate — classed error or success, never abort.
5. **Projector provenance:** `llm(projector=)` documented as engine-trusted input (F4 — assert-bearing GGUF parse); registry pin with SHA256 via the D-024 flow; user-supplied paths allowed but documented as the same trust class as the main GGUF.
6. **Never declare in Rust:** `mtmd_helper_video_*` (F7), `mtmd_bitmap_init_from_audio`, or raw `mtmd_bitmap_init` with dimensions not taken from the immediately preceding stb decode (memcpy length contract, `mtmd.cpp:42-48`).
7. **`cb_eval` stays NULL** (T3 out of scope). If ever set, first replace the `*mut c_void` mirror field with a typed function pointer.
8. R docs state exactly the allow-listed formats — not the vendored `mtmd-helper.h:47` claim ("jpg, png, bmp, gif, etc.").
9. **Vendor-bump checklist addition:** re-verify at every bump that `is_audio_file` is still the only miniaudio gateway and re-run the ABI struct test (already size+value pinned in `ffi.rs`). Also note the inert upstream wart flagged by the reviewer: `tools/mtmd/CMakeLists.txt:106` references a `BUILD_INFO` target that does not exist at b9726 (harmless under our flags; may bite at a bump).

## 6. Build integration hygiene — CLEAN

- `build.rs`: no network, no `Command`, no nondeterministic inputs; adds only `LLAMA_BUILD_MTMD=ON` + `MTMD_VIDEO=OFF` and `mtmd` to `lib_stems`. `MTMD_VIDEO=OFF` is load-bearing (upstream cache default is ON) but its loss fails the build loudly (pruned `sheredom/`).
- `config.R`: `-lmtmd` in correct dependency order on all three platforms; twin-pin to `lib_stems` (Hard rule 8f) — now enforced by `rebirth-llm/tests/twin_pin_link_stems.rs` (added at the WP-V1 review gate).
- **ABI mirror** (`ffi.rs`): verified field-by-field against `mtmd.h:86-107` — order, types, and all defaults match `mtmd_context_params_default()` (`mtmd.cpp:240-256`); computed LP64 layout = 64 bytes, matching the size pin; `enum → c_int` correct for a negative-valued C enum; the function-pointer field mirrored as `*mut c_void` is acceptable while only null-checked, never invoked (req. 7).
- `NOTICE` / `vendor/README.md` / `VENDORING.md`: consistent, accurate; the three-SHA scheme correctly updated.

## 7. Verdict

**SHIP-YES — merge WP-V1 as-is.** Every added byte is proven upstream-identical or accounted for by a build-only patch; the tree SHAs and coherence gate pass and were independently reproduced from the pinned tarball; the only new FFI call is a by-value defaults getter with a pinned ABI test; nothing added is reachable from R input. The risk in this phase lives entirely in WP-V2, and it is constrained by the numbered requirements in §5 — they are the entire difference between "dormant parsers" and "remote-file-format attack surface".
