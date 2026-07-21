# WP1 — Vendored engine + model loading: plan & architecture decisions

**Author:** architect agent · **Date:** 2026-07-04 · **Status:** planning artifact for founder review.
**Scope:** ROADMAP §3 Phase 0 / WP1 ("Vendored engine + model loading"), current WP. WP0 merged to `main`.

This document contains three deliverables:

1. **ADR (proposed) D-005** — Rust crate layout: how the R package links the workspace engine.
2. **ADR (proposed) D-006** — llama.cpp vendoring and native build.
3. **WP1 implementation breakdown** — TDD-first, ordered, mapped to `API-GRAMMAR.md` and the WP1 acceptance criteria, with each step tagged *doable now* vs *blocked on the founder's model files*.

The two ADRs are written in `DECISIONS.md` format and marked `proposed`. **I do not edit `DECISIONS.md` or any root planning doc** — the founder integrates accepted ADRs. Both ADRs are decisions WP1 cannot start without, because they determine where source physically lives and how it builds.

Nothing here changes the approved API surface (`API-GRAMMAR.md` §3 `llm()`, `close.llm`, `print.llm`, `summary.llm`; §2 the `llm` class; §6 condition classes). All of that is binding (D-003) and is implemented, not altered.

---

## Deliverable 1 — ADR (proposed) D-005: Rust crate layout

```
## D-005 — Rust crate layout: the package-embedded workspace
- Date: 2026-07-04 · Status: proposed
```

### Context / problem

WP0 left two disconnected Rust trees:

- **What the package actually builds:** `rebirth/src/rust/` — a *standalone* extendr crate whose `[package] name` and `[lib] name` are both `rebirth`. `rebirth/src/Makevars` runs `cargo build --lib --manifest-path=./rust/Cargo.toml` (from `src/`, `./rust` = `src/rust`), producing `librebirth.a`, linked `-lrebirth`. `document.rs` (a `[[bin]]` in that crate) generates `../R/extendr-wrappers.R` by calling `rebirth::get_rebirth_metadata()`.
- **What ARCHITECTURE §2 specifies but WP0 orphaned:** a top-level `rust/` workspace with `rebirth-ffi` (the unsafe SEXP boundary) depending on `rebirth-llm` (the R-free engine). Nothing in the package build references it; only `.github/workflows/rust.yaml` (`working-directory: rust`) compiles it.

Two binding constraints must be reconciled:

- **ARCHITECTURE §2 (three-layer separation):** `rebirth-ffi` is the extendr boundary crate holding *all* `unsafe`; `rebirth-llm` is a normal safe crate with **no R types**, independently `cargo test`-able and reusable under the permissive licence (the future-fork-links-the-same-engine guarantee, §13). This separation is a settled design property, not negotiable in WP1.
- **ARCHITECTURE §9 (self-contained build for R CMD check / CRAN):** `R CMD build` tars only the `rebirth/` package directory, and `R CMD check` unpacks it into a private tempdir. Anything referenced by a path that escapes `rebirth/` (`../rust`, `../vendor`) **does not exist at check/CRAN build time** → the build fails. CRAN additionally forbids network access and out-of-package references and requires vendored crates.

The top-level `rust/` location (sketched in `SOLO-PHASE-PLAN.md` §4 and the stack table) is therefore **incompatible with the self-containment requirement** as a *build source*. This is a genuine technical fact that invalidates the §4 layout sketch for build purposes; this ADR supersedes that sketch and its acceptance implies a one-line update to §4 (founder territory — see "Consequences").

### Name-coupling facts (must be preserved to keep churn ≈ 0)

The following are all keyed on the identifier/string `rebirth` and are threaded through generated/committed files; keeping them fixed keeps `R CMD check` green with no edits:

| Artifact | Depends on | Keep as |
|---|---|---|
| `src/entrypoint.c` | `R_init_rebirth` → `R_init_rebirth_extendr` | unchanged |
| `src/rebirth-win.def` | exports `R_init_rebirth` | unchanged |
| `NAMESPACE` / wrapper header | `useDynLib(rebirth, .registration = TRUE)` | unchanged |
| `document.rs` | `rebirth::get_rebirth_metadata()`, `make_r_wrappers(true, "rebirth")` | unchanged |
| `Makevars` | `librebirth.a`, `-lrebirth` | unchanged |

`R_init_rebirth_extendr` and `get_rebirth_metadata` are generated from the **extendr module name** in `extendr_module! { mod rebirth; }`, which is independent of the Cargo *package* name. `librebirth.a` / `-lrebirth` derive from the **Cargo `[lib] name`**, also independent of the package name. Cargo permits `[package] name != [lib] name`. This is the lever that lets us honour the `rebirth-ffi` name without touching any generated coupling.

### Decision

**Consolidate all native crates into a single cargo workspace embedded inside the package at `rebirth/src/rust/`, and delete the orphaned top-level `rust/`. The extendr boundary crate is `rebirth-ffi` with its `[lib] name` kept as `rebirth`; `rebirth-llm` is a workspace sibling and a path dependency of `rebirth-ffi`.**

Physical layout:

```
rebirth/                                  # the R package (unchanged position)
└── src/
    ├── Makevars(.in) / Makevars.win.in   # build -p rebirth-ffi; link native libs (D-006)
    ├── entrypoint.c                       # UNCHANGED
    ├── rebirth-win.def                    # UNCHANGED
    ├── llama.cpp/                          # vendored engine source (D-006), ships in tarball
    └── rust/                               # the workspace (was the standalone crate)
        ├── Cargo.toml                      # [workspace] members = ["rebirth-ffi","rebirth-llm"]
        │                                   #   + [profile.release] lto/codegen-units (moved up)
        ├── Cargo.lock                      # committed (one lockfile)
        ├── vendor-config.toml              # already referenced by Makevars (unchanged)
        ├── rebirth-ffi/
        │   ├── Cargo.toml                  # [package] name = "rebirth-ffi"
        │   │                               # [lib] name = "rebirth", crate-type = ["rlib","staticlib"]
        │   │                               # dependencies: extendr-api = "0.9", rebirth-llm = { path = "../rebirth-llm" }
        │   ├── document.rs                 # [[bin]] name = "document" (moved here, body unchanged)
        │   └── src/lib.rs                  # extendr_module! { mod rebirth; } + boundary code
        └── rebirth-llm/
            ├── Cargo.toml                  # build-dependencies: cmake (see D-006, authorized there)
            ├── build.rs                    # cmake build of ../../llama.cpp (D-006)
            └── src/lib.rs                  # engine lifecycle + FFI decls + RebirthError (R-free)
```

Concrete mechanical consequences (the entire diff of the layout move):

1. `rebirth/src/rust/Cargo.toml` becomes a **virtual workspace manifest** (`[workspace] members`, `resolver = "2"`, and the `[profile.release]` block moved here — profiles only apply at the workspace root).
2. The existing standalone crate's `src/lib.rs` + `document.rs` move under `rebirth-ffi/`; its `Cargo.toml` gains `[package] name = "rebirth-ffi"`, keeps `[lib] name = "rebirth"` and `crate-type = ["rlib","staticlib"]`, and adds the `rebirth-llm` path dependency.
3. `rebirth-llm` and `rebirth-ffi` move from the top-level `rust/` into `rebirth/src/rust/`; the top-level `rust/` directory is deleted.
4. `Makevars(.in)` / `Makevars.win.in`: the cargo invocations gain `-p rebirth-ffi` (a virtual workspace root has no default package, so `--lib` and `--bin document` must name the package: `cargo build -p rebirth-ffi --lib …` and `cargo run -p rebirth-ffi --bin document …`). `STATLIB`/`LIBDIR`/`-lrebirth` are **unchanged** (lib name still `rebirth`; workspace members share `rust/target/`). Native-library link flags added per D-006.
5. `.github/workflows/rust.yaml`: `working-directory: rust` → `rebirth/src/rust`.
6. `.Rbuildignore` already ignores `src/rust/target` and `src/rust/vendor`; keep. Ensure the vendored `src/llama.cpp/` source is **not** ignored (it must ship) while its build artifacts are (D-006).

`document.rs`'s output path `../R/extendr-wrappers.R` is **unchanged and still correct**: `cargo run` inherits the invocation CWD (`rebirth/src/`), so `../R` resolves to `rebirth/R/` regardless of which member the bin lives in.

### Why

- **Self-contained by construction** (satisfies §9 / CRAN): every build input lives under `rebirth/src/`, so it is present in both the `R CMD build` tarball and the `R CMD check` tempdir. No `../` escape, no symlink, no configure-time copy.
- **Honours the three-layer separation** (satisfies §2): `rebirth-ffi` *is* the extendr boundary and links `rebirth-llm`; `rebirth-llm` stays R-free and independently testable (`cd rebirth/src/rust && cargo test -p rebirth-llm`). The §13 "fork links the same engine" guarantee is preserved.
- **≈ zero churn to green infrastructure** (the task's stated preference): entrypoint.c, the `.def`, NAMESPACE, `document.rs` body, and the `-lrebirth`/`librebirth.a` names are all untouched because we keep `[lib] name = "rebirth"` and the `mod rebirth;` module name. R CMD check stays green through the move (its only exports remain none until the FFI functions land).
- **Single source of truth:** the "top-level `rust/` for independent development" benefit is fully retained — the same workspace simply lives one directory deeper; CI points `cargo fmt/clippy/test` at `rebirth/src/rust`. No two-tree drift.
- **CRAN vendoring path already assumed:** `tools/config.R` and `.Rbuildignore` already reference `src/rust/vendor(.tar.xz)`; this layout is what they were written for.

### Alternatives rejected

- **A — Keep the standalone `src/rust` crate; path-depend on the top-level `../../../rust/rebirth-ffi` + `rebirth-llm`.** This is the literal WP0 state's "fix". Rejected: the `../../../rust` path escapes the package dir; it is absent in the R CMD check tempdir and forbidden by CRAN → the build fails exactly where §9 warns. (This is the orphaning bug, not a fix for it.)
- **B — Keep crates at top-level `rust/`; copy or symlink them into `src/rust/` at `configure` time.** Rejected: symlinks are not reliably preserved by `R CMD build` tarballing; copying duplicates source and invites drift; a nonstandard configure-time source-materialization step is exactly the build fragility CRAN's Rust policy and WRE discourage, and it defeats reproducibility.
- **C — Collapse everything into one flat crate at `src/rust` (engine + FFI + unsafe together).** The tempting minimum-churn move (it is nearly what WP0 already has). Rejected: it violates §2 — `rebirth-llm` would no longer be R-free or independently testable, the reusable/permissive-engine and future-fork-links-the-engine guarantees (§13) break, and the unsafe boundary stops being isolated (a direct hit to the security-auditor's remit and the "all unsafe in one crate" invariant).
- **D — Top-level workspace stays authoritative; a build script generates/vendors the package `src/` from it.** Rejected: two sources of truth, non-reproducible `R CMD build`, over-engineered for a solo project.

### Consequences (founder-territory follow-ups this ADR implies — I do not edit these)

- `SOLO-PHASE-PLAN.md` §4 layout sketch and the "Stack"/layout references show a top-level `rust/` and `vendor/`. On accepting D-005 (+ D-006), update them to note that the **build-consumed** workspace and vendored engine live under `rebirth/src/` (self-containment), and that a top-level `vendor/` — if retained — is provenance/records only (see D-006). This is an explicit supersession of a plan *sketch*, not a settled DECISIONS.md entry, so no prior ADR is contradicted.
- `rebirth-kernel` (Phase 17) is a *future* workspace member; the workspace is structured to accept it, but it is **not** created in WP1 (scope discipline; roadmap risk #7).

---

## Deliverable 2 — ADR (proposed) D-006: llama.cpp vendoring and native build

```
## D-006 — llama.cpp vendoring and native build
- Date: 2026-07-04 · Status: proposed
```

### Context / problem

WP1 must embed llama.cpp, build it as a static library (Metal on macOS arm64, CPU fallback, CUDA off until Phase 8), and link it — **without** breaking `R CMD check` (self-containment from D-005; timing) and without any source patch (taps are WP4). It must also not preclude harness B's separately-built *unpatched reference* (ARCHITECTURE §11), and it must set up the quarterly `vendor-bump` skill to be routine.

### Decision

**1. Vendor a pinned, pruned source snapshot of llama.cpp inside the package at `rebirth/src/llama.cpp/`.** Not a submodule, not a build-time download. Record the exact upstream tag + tree SHA256 + the prune manifest in `rebirth/src/llama.cpp/VENDORING.md`, and mirror the pin (tag + SHA256 + MIT `NOTICE`) in the repo-root `vendor/README.md`/`NOTICE`, which become **provenance records only** (no build inputs there). Prune to what the Metal+CPU build needs: drop `examples/`, `tools/`, `tests/`, `models/`, docs, CI, scripts, and non-CPU/non-Metal backends (CUDA/HIP/SYCL/Vulkan sources) — they return per-backend when their phase arrives (CUDA at Phase 8).

- *Why inside `src/`:* D-005 self-containment. A submodule is not included in `R CMD build` tarballs; a configure-time download violates CRAN's "no network at build" rule and breaks offline/reproducible/tempdir builds.
- *Why pruned:* keeps the tarball and build time down (see §Timing) and shrinks the security-auditor's surface (Phases 0–2 FFI/parsing scope). The prune manifest makes `vendor-bump` mechanical.
- *WP4 relationship:* `rebirth/src/llama.cpp/patches/` (created empty in WP1, populated in WP4) will hold the tap patch set, each hunk annotated (ARCHITECTURE §5, roadmap risk #1). WP1 applies **zero** patches.

**2. Build llama.cpp from `rebirth-llm/build.rs` via the `cmake` build-dependency crate**, so the entire native build stays under the single `cargo build` that Makevars already drives (ARCHITECTURE §9). build.rs configures upstream's own CMake (correct Metal shader handling, correct ggml backend registration) with a minimal option set, then emits `cargo:rustc-link-search` / `cargo:rustc-link-lib=static=…` and, on macOS, `cargo:rustc-link-lib=framework=Metal|Foundation|Accelerate`.

- **This ADR authorizes the new Rust build-dependency `cmake`** (the crate that shells out to the `cmake` binary), satisfying the "no new dep without an approved DECISIONS.md entry" rule for WP1's build path. No other new Rust dependency is authorized.
- **No `bindgen`.** The FFI surface WP1 needs is tiny (backend init/free; model load/free; a handful of metadata getters; context create/free). Declare those `extern "C"` **by hand** in `rebirth-llm` against the pinned `llama.h`. This avoids a `libclang`/`bindgen` dependency, keeps the unsafe FFI surface small and auditable, and pins us to an explicit, reviewed symbol list. *(The exact symbol names must be read off the pinned `llama.h` — the C API has been renamed across versions, e.g. `llama_load_model_from_file` → `llama_model_load_from_file`, `llama_new_context_with_model` → `llama_init_from_model`. The coder confirms the real names at the pinned tag; the build-link test in WP1 step 3 catches any mismatch immediately.)*

**3. Backend selection.**
- macOS arm64: `-DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON` (embed the Metal shader library into the binary — no runtime `.metallib` path dependency, essential for an installed package with an unpredictable CWD). Accelerate on. build.rs branches on `CARGO_CFG_TARGET_OS`/`TARGET_ARCH`.
- Linux / other: Metal off, CPU only.
- CUDA: a Cargo feature `cuda` (default **off**) that maps to `-DGGML_CUDA=ON`; not exercised until Phase 8. WP1 leaves it defined and unbuilt.
- Common: `-DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_TOOLS=OFF -DBUILD_SHARED_LIBS=OFF` (static). *(Exact option names verified at the pinned tag.)*

**4. Linking into the R shared object.** A Rust `staticlib` records — but does not physically bundle — the native C++ archives; those archives must reach R's final `$(SHLIB)` link. build.rs relocates the produced archives (`libllama.a`, and the ggml archives — recent llama.cpp splits ggml into `libggml.a` + `libggml-base.a` + `libggml-cpu.a` + `libggml-metal.a`; **the exact set is tag-dependent and must be confirmed**) into the shared `rust/target/<profile>/` dir alongside `librebirth.a`. `Makevars` `PKG_LIBS` then reads `-L$(LIBDIR) -lrebirth -lllama -lggml… ` plus, on macOS, `-framework Metal -framework Foundation -framework Accelerate` and `-lc++`. `RUSTFLAGS=--print=native-static-libs` (already in Makevars) is retained as the diagnostic that confirms the required native libs when the link is being brought up.

### Timing (not breaking R CMD check)

- A clean llama.cpp build is a few minutes single-threaded. Constraints and mitigations:
  - **CRAN `-j2` cap:** pass the thread limit through to cmake (`--parallel 2`), and never assume more.
  - **Prune + backend gating** (above) cut compile units substantially.
  - **CI caching:** cache `rebirth/src/rust/target/` keyed on `(pinned llama SHA256, rust-toolchain, Cargo.lock hash)` so only the first CI run and clean CRAN builds pay the cost; incremental local `R CMD INSTALL` reuses `target/`.
  - **Check-time budget:** compilation time is not the CRAN example-runtime limit; the real risk is an "installed size" / long-compilation NOTE, expected and acceptable for a C++-library-bundling package (prepared for at Phase 9, not blocking now). WP1 must keep the macOS + Linux CI wall-clock reasonable via the cache.
- `configure`/`configure.win` gain a **cmake presence + minimum-version check** with an actionable message (mirroring the existing cargo/rustc check in `tools/msrv.R`); `DESCRIPTION` `SystemRequirements` adds `cmake (>= 3.28)`. Binary users on r-universe never hit this.

### Harness B (unpatched reference) relationship — ARCHITECTURE §11

- WP1 applies **no** patches, so the vendored build and an upstream build at the same tag are behaviourally identical — this *is* the clean baseline that WP4's tap patch must later leave numerically undisturbed.
- WP1's obligation to harness B (which is built in WP6a, Phase 1) is only: make the **pinned tag + SHA256 the single canonical record** (`VENDORING.md`, mirrored in `vendor/README.md`) that both the package build and the future reference build consume, and keep the vendored tree buildable standalone so an identical reference can be produced from the same checkout (or the founder's separately-built "Reference llama.cpp (unpatched)" toolchain entry at the identical tag). No harness B code is written in WP1.

### Pinned tag — selection criteria + recommended candidate (founder finalizes)

I have **no web access** and cannot verify current tag numbers or their SHA256; the founder confirms and finalizes the exact tag against upstream. Selection criteria, in priority order:

1. **Immutable release tag**, not a branch (llama.cpp publishes `bNNNN` build-number tags). Reproducibility.
2. **Architecture coverage for our pinned models:** must include **gemma3** support (MedGemma 1.5 4B is Gemma-3-based) and **qwen2** (Qwen2.5). Gemma-3 support pushes the floor to a 2025 build.
3. **Stable observation/intervention APIs we depend on later:** `ggml_backend_sched_eval_callback` (WP4 taps) and the control-vector adapter API (WP5) present with settled signatures.
4. **Mature Metal on Apple silicon (M4)** and embedded-shader-library support.
5. **Settled C API names** (post the `llama_model_load_from_file` / `llama_init_from_model` renames) so the hand-written FFI list is stable across the quarterly bump.
6. **Not bleeding-edge:** at least ~2–4 weeks old at WP1 start so known-stable; MIT, no problematic bundled third-party.

**Recommended candidate:** the newest `bNNNN` release satisfying (1)–(6) as of WP1 start — in practice a **mid-to-late-2025 `b5xxx`–`b6xxx`-series tag** (illustrative range, *unverified* — do not treat the number as final). The founder pins the exact tag, records its tree SHA256 in `VENDORING.md`, and the same tag is used for the harness B reference build.

### Alternatives rejected

- **Git submodule for the source.** Rejected: submodules are not included in `R CMD build` tarballs and are not fetched by CRAN/r-universe package builds; the check tempdir would have an empty directory.
- **Download llama.cpp at `configure` time.** Rejected: violates CRAN "no network at build", breaks offline/reproducible builds and the disconnected check tempdir; a supply-chain and reproducibility regression.
- **Hand-compile the `.cpp`/`.metal` via the `cc` crate (no cmake).** Rejected: replicating ggml's backend registration and Metal shader embedding by hand is brittle and would drift from upstream every bump — the opposite of a routine `vendor-bump`. cmake is upstream's supported path.
- **Dynamically link a system/prebuilt `libllama`.** Rejected: no stable ABI across `bNNNN` tags, defeats the pinned-reproducible-build guarantee, and shifts an install burden onto users that r-universe binaries are meant to remove.
- **`bindgen`-generated FFI.** Rejected for WP1: adds a `libclang` toolchain dependency for a handful of symbols and enlarges/obscures the audited unsafe surface; revisit only if the FFI surface grows unmanageable.

---

## Deliverable 3 — WP1 implementation breakdown (TDD-first)

Refines the ROADMAP §5.3 WP1 prompt into ordered sub-steps. Each step notes its TDD entry point, the `API-GRAMMAR.md` entries it realizes, the WP1 acceptance criteria it advances, and whether it is **[NOW]** (buildable/testable today) or **[MODEL]** (blocked on the founder supplying local GGUF paths for Qwen2.5-0.5B-Instruct Q8_0 and MedGemma-1.5-4B Q4) or **[TAG]** (needs the founder to finalize the pinned llama.cpp tag, D-006).

Guiding rule (Session Preamble): tests first where practical; small steps; no export absent from `API-GRAMMAR.md`; a Rust panic reaching R is a bug.

### Step 0 — Land the D-005 layout move (prerequisite) — [NOW]
Apply the D-005 mechanical diff (consolidate the workspace under `rebirth/src/rust/`, rename the ffi package to `rebirth-ffi` keeping `[lib] name = "rebirth"`, wire the `rebirth-llm` path dep, move `[profile.release]` to the workspace root, `Makevars` `-p rebirth-ffi`, repoint `rust.yaml` to `rebirth/src/rust`, delete top-level `rust/`).
- **TDD/verify:** `R CMD check` stays clean (still zero exports); `cargo test`, `clippy -D warnings`, `fmt --check` green in the new location; `cargo build -p rebirth-ffi --lib` yields `librebirth.a`.
- **Acceptance advanced:** "R CMD check clean; cargo test green; CI green on both platforms" (baseline preserved through the move).

### Step 1 — Vendor llama.cpp (D-006 part 1) — [TAG]
Add the pinned, pruned `rebirth/src/llama.cpp/` snapshot; write `VENDORING.md` (tag + tree SHA256 + prune manifest); create empty `patches/`; update repo-root `vendor/README.md` + `NOTICE` provenance; adjust `.Rbuildignore` so source ships and artifacts don't.
- **TDD/verify:** a checked-in `tools/` or CI check recomputes the tree SHA256 and matches `VENDORING.md`; `R CMD build` tarball contains `src/llama.cpp/` and excludes build artifacts.
- **Acceptance advanced:** vendoring precondition for all engine steps. *Blocked only on the founder finalizing the tag; the vendoring action itself is mechanical once the tag is set.*

### Step 2 — Native build wiring: `rebirth-llm/build.rs` (D-006 parts 2–4) — [NOW, after Step 1]
cmake-crate build of the vendored tree (Metal+embedded-shaders on macOS arm64, CPU elsewhere, `cuda` feature off); prune/backend flags; relocate `libllama.a`/`libggml*.a` into `rust/target/<profile>/`; emit link flags + macOS frameworks; add `cmake` to `SystemRequirements` and the `configure` cmake check. Author the hand-written `extern "C"` declarations against the pinned `llama.h` (backend init/free, model load/free, metadata getters, context create/free).
- **TDD/verify (no model needed):** a `cargo test` in `rebirth-llm` that calls the backend-init/system-info FFI (e.g. initialize the backend, query build/system info, free) — **proves the vendored engine compiles, links, and the backend initializes without any model file**. This is the "linkage" gate and catches any C-API symbol-name mismatch immediately.
- **Acceptance advanced:** "unavailable backend → classed condition" foundation; whole-engine build under `R CMD INSTALL`.

### Step 3 — `rebirth-llm` engine lifecycle (safe, R-free) — [NOW for structure/errors; [MODEL] for real-load values]
Safe wrapper types with `Drop`: `Backend` (process-global init/free, ref-counted), `Model` (owns the loaded model pointer, exposes metadata: architecture, parameter count, transformer-block count, hidden/embedding size, training context length, quantization/file-type, and the resolved backend), `Context` (created from a `Model`, carrying `context_length`, `gpu_layers`, `mmap`). Define `RebirthError` — an enum mirroring `API-GRAMMAR.md` §6 / ARCHITECTURE §8 with structured fields: `ModelLoad{failing_check}`, `Backend{requested, available}`, `Closed`, `Internal{context}`. **No R types in this crate.**
- **TDD/verify — [NOW]:** unit tests for the error enum and its field payloads; **load-error paths without a real model** — a nonexistent path → `RebirthError::ModelLoad`; a truncated/garbage file written in the test → `ModelLoad` (not a panic/abort); requesting a backend the build lacks → `RebirthError::Backend`.
- **TDD/verify — [MODEL]:** metadata accessors return correct values, checked against the Qwen2.5-0.5B and MedGemma model cards (run only when `REBIRTH_TEST_MODEL_*` env vars point at the founder's GGUFs; skipped in CI).
- **API-GRAMMAR:** feeds the `llm` class slots (§2: `architecture`, `parameters`, `quantization`, `layers`, `hidden_size`, `context_length`, `backend`).
- **Acceptance advanced:** "summary(m) reports … verified against the model cards" (values), "corrupt/missing file → catchable condition, never a crash" (error paths, testable now).

### Step 4 — `rebirth-ffi` boundary: exports, panic-catching, condition mapping — [NOW]
Add the single FFI entry `#[extendr]` model-load function (all args pre-validated in R): it (a) converts any index-bearing/enum args once here (§4 discipline — none are 1-based indices yet, but `backend`/`gpu_layers` normalization lives here), (b) wraps the `rebirth-llm` call in `catch_unwind` — a caught panic becomes the `rebirth_error_internal` payload, (c) maps each `RebirthError` variant to a **structured error payload** `(class, message, fields)` returned to R rather than thrown raw. Also export the `close` and `is-closed` boundary calls and the closed-tag check that every future entry point will consult.
- **Condition-mapping mechanism (ARCHITECTURE §2 + §8, reconciled):** the *mapping* (which class, which fields) is decided here in `rebirth-ffi`; the actual classed condition is **raised in R** by one shared helper `rebirth_abort(class, message, fields)` that calls `stop(structure(class = c(<specific>, "rebirth_error", "error", "condition"), …))`. This keeps "condition raising happens in R" (§2) and "ffi decides the class + structured fields" (§8) both true, needs **no new dependency** (base `stop`/`simpleCondition`), and is unit-testable from R. The four WP1 classes: `rebirth_error_model_load`, `rebirth_error_backend`, `rebirth_error_closed`, `rebirth_error_internal`.
- **TDD/verify — [NOW]:** `testthat` tests that each error path yields the exact class (`expect_error(..., class = "rebirth_error_model_load")` etc.) and carries its structured fields; a forced panic in a test-only path maps to `rebirth_error_internal` (never reaches the console raw).
- **API-GRAMMAR:** realizes the error contract of §3 `llm()` and §6.
- **Acceptance advanced:** "Missing file, corrupt file, unavailable backend: classed conditions with actionable messages; never a crash."

### Step 5 — R layer: `llm()`, the `llm` S3 object, `print`/`summary` — [NOW for validation/formatting; [MODEL] for populated fields]
`R/llm.R`: `llm(path, context_length = 4096, gpu_layers = NULL, backend = c("auto","metal","cuda","cpu"), mmap = TRUE)` — **all validation and defaulting in R before the boundary** (§2): `path` a single existing readable string (else `rebirth_error_model_load` with the failing check named), `context_length` a positive integer, `gpu_layers` `NULL`-or-non-negative-integer, `backend <- match.arg(backend)`, `mmap` a bool. `backend = "auto"` resolves to metal on a Metal-enabled macOS arm64 build else cpu; an explicit backend the build lacks → `rebirth_error_backend`. Construct the S3 `llm` object = external pointer + the §2 metadata slots (empty `interventions` list). `print.llm` = one screen (file, architecture, parameters, quantization, layers × hidden size, context, backend, active-intervention count); `summary.llm` = a classed list adding memory footprint + tokenizer info + full intervention list, with its own print.
- **TDD/verify — [NOW]:** argument-validation tests (each bad arg → its classed condition, no engine call); `print`/`summary` format tests against a constructed/fixture `llm` object (metadata stubbed) so formatting is covered without a model.
- **TDD/verify — [MODEL]:** `summary(m)` on the real Qwen/MedGemma handles matches the model cards.
- **API-GRAMMAR:** §3 `llm()`, `print.llm`, `summary.llm`; §2 `llm` class.
- **Acceptance advanced:** load on the Mac; "summary(m) … verified against the model cards".
- **Docs note (honesty):** WP1 ships no in-repo tiny model (the synthetic GGUF arrives in WP6a, `llm_download` in WP8). So `llm()`'s roxygen runnable example cannot execute in CI yet; guard it (`@examplesIf` on a model-path env var / `\donttest`) and state this limitation. The "every example executes in CI" rule is fully met for `llm()` only once the synthetic model exists — flagged, not hidden.

### Step 6 — Deterministic close + GC finalizer (the two deallocation paths) — [NOW for logic; [MODEL] for real free/RSS] 
Implement `close.llm(con, ...)` → deterministic native free + tag the external pointer `closed`, returns `invisible(NULL)`; double-close is a no-op. Register a GC finalizer as the **safety net** (`reg.finalizer(<ptr env>, finalizer, onexit = TRUE)`) so an un-`close`d handle is freed at GC/exit. Every FFI entry consults the closed tag first → `rebirth_error_closed`. This is the ARCHITECTURE §3 two-path model: `close.llm` = deterministic ("free 5 GB now" on a 16 GB machine); finalizer = backstop; after either, use → `rebirth_error_closed`.
- **TDD/verify — [NOW]:** closed-tag logic — a handle marked closed (via the test path) → any use raises `rebirth_error_closed`; double-close is a no-op.
- **TDD/verify — [MODEL]:** real `close()` frees memory; **100× load/unload → flat RSS** (the finalizer/close leak check); a GC-only path (drop the binding, force `gc()`) also frees.
- **API-GRAMMAR:** §3 `close.llm`; §6 `rebirth_error_closed`.
- **Acceptance advanced:** "100× load/unload → flat RSS"; "closed handle → rebirth_error_closed".

### Step 7 — CI wiring + green — [NOW]
Add the native build to both CI targets (macOS-15 arm64 with Metal, ubuntu-24.04 CPU-only), with the `target/` cache keyed on the pinned llama SHA (D-006). Ensure `R CMD check` (error-on-warning) and the workspace `cargo` job are green with all **[NOW]** tests active and **[MODEL]** tests skipped (env-gated). No model download in CI.
- **Acceptance advanced:** "R CMD check clean; cargo test green; CI green on both platforms."

### Step 8 — Founder acceptance on real hardware — [MODEL]
Once the founder supplies the two GGUF paths (and accepts MedGemma HF terms), run the **[MODEL]** acceptance locally on the Mac mini: load both models; `summary(m)` correctness vs model cards; 100× load/unload flat RSS; corrupt/missing/backend conditions on real files. These are the WP1 acceptance items that cannot run in CI and close the WP.

### Blocked-now summary

| WP1 acceptance criterion (ROADMAP §5.3) | Status | Where |
|---|---|---|
| R CMD check clean; cargo test green; CI green both platforms | **[NOW]** | Steps 0,2,4,5,6,7 |
| Missing file / corrupt file / unavailable backend → classed condition, never a crash | **[NOW]** | Steps 3,4 (real-file variants reconfirmed in Step 8) |
| Loads Qwen2.5-0.5B Q8_0 and MedGemma-1.5-4B Q4 on the Mac | **[MODEL]** | Step 8 |
| `summary(m)` reports arch/params/quant/layers/hidden_size/context/backend, verified vs model cards | **[MODEL]** (logic/format [NOW]) | Steps 3,5 → 8 |
| 100× load/unload → flat RSS | **[MODEL]** | Step 6 → 8 |
| Pinned llama.cpp tag finalized | **[TAG]** (founder) | Step 1 |

Everything except the three real-model acceptance items and the tag pin is buildable and unit-tested now — exactly the WP1 design goal.

### Forbidden in WP1 (from the §5.3 prompt + plan §7)
Any llama.cpp source patch (taps are WP4); any generation/tokenization/embedding API (WP2/WP3); any export absent from `API-GRAMMAR.md`; new dependencies beyond the D-006-authorized `cmake` build-dep; weakening/skipping tests; `unwrap()` on the boundary.

---

## Summary & clearest recommendation

- **D-005 (crate layout) — my single clearest recommendation:** **consolidate all native crates into one cargo workspace embedded at `rebirth/src/rust/`, make `rebirth-ffi` the extendr boundary crate but keep its `[lib] name = "rebirth"` (and the `mod rebirth;` module name), and delete the orphaned top-level `rust/`.** This is the only option that is simultaneously self-contained for `R CMD check`/CRAN (§9), faithful to the three-layer `rebirth-ffi`/`rebirth-llm` separation (§2/§13), and ≈ zero-churn — `entrypoint.c`, `rebirth-win.def`, `NAMESPACE`, `document.rs`, and `-lrebirth`/`librebirth.a` are all untouched because package name and lib/module name are decoupled. R CMD check stays green through the move.
- **D-006 (engine vendoring/build):** vendor a pinned, pruned llama.cpp snapshot **inside `rebirth/src/llama.cpp/`**; build it from `rebirth-llm/build.rs` via the (newly authorized) `cmake` build-dep, Metal+embedded-shaders on macOS arm64 / CPU elsewhere / CUDA feature-off; hand-write the small `extern "C"` surface (no bindgen); pin one `bNNNN` tag by the stated criteria and feed the same pin to harness B's reference. No source patches in WP1.
- **WP1 execution:** land the layout move first (Step 0, keeps CI green), then vendor + wire the native build (proving linkage + backend-init with *no* model), then the R-free engine wrapper and its error paths, then the FFI boundary + classed-condition raising, then the R `llm()`/print/summary + close/finalizer, then CI. All non-model work is testable now.

### What the founder must decide
1. **Accept / amend D-005** (crate layout) — WP1 Step 0 depends on it.
2. **Accept / amend D-006** (vendoring + build), which includes authorizing the `cmake` Rust build-dependency and the `cmake` SystemRequirement.
3. **Finalize the pinned llama.cpp `bNNNN` tag** against upstream (I cannot verify tag numbers/SHA256; criteria in D-006) — unblocks Step 1.
4. **Supply the two local GGUF paths** (Qwen2.5-0.5B-Instruct Q8_0, MedGemma-1.5-4B Q4) and accept MedGemma HF terms — unblocks the Step 8 real-model acceptance (not needed for Steps 0–7).

### Exact next action
Founder reviews D-005 and D-006 above; on acceptance, I integrate both into `DECISIONS.md` as accepted entries (and note the implied one-line `SOLO-PHASE-PLAN.md` §4 layout updates), then the `coder` agent starts WP1 at **Step 0** (the layout move) using the §5.3 WP1 prompt. Steps 1–2 proceed as soon as the founder confirms the pinned tag; the real-model acceptance (Step 8) waits on the GGUF paths.
