# WP13 — Native Linux CUDA and measured performance

Status: started 2026-10-17 under D-050. Branch `codex/linux-cuda`, based on
integrated PR68 `0dae279a8c96e8a10868c932026aeb2c6a224977`. This is the execution
plan, not a claim that CUDA currently builds or passes acceptance.

## Scope and acceptance

The founder now has native Linux and an RTX 2060 Mobile (6 GiB, compute capability
7.5), without Windows. Replace the WSL2 prerequisite with this actual Linux host.
Deliver a working optional CUDA build and measured improvements on this hardware.
Windows support stays deferred; a future ordinary VM can check CPU installation,
but does not establish GPU availability without passthrough or another GPU route.

**WP13 acceptance:** “harness B green on native Linux/CUDA; installed R package
executes the supported research workflow with verified GPU placement; a frozen,
reproducible benchmark reports throughput, latency, memory and observation costs
against an explicit baseline without weakening correctness or resource guards.”

The previous criterion, “harness B green on CUDA (WSL2); binary `install.packages`
works on Windows”, is retained as history. D-050 changes the first environment
and defers the second obligation; this phase does not pass Windows by proxy.

## Starting facts and first deliverable

- Driver 580.178.04 and the GPU work outside the execution sandbox. The earlier
  sandbox-only nvidia-smi error is not a driver fault. R 4.6.1, CMake and GCC are
  present; CUDA Toolkit, Rust/Cargo and the required R packages are absent.
- Current distro metadata offers CUDA 13.3.1 and GCC 15; system GCC is 16.
  Select and record a compatible toolkit/compiler/driver combination before
  installation. Do not bypass compiler checks or replace the working driver
  as an incidental package-manager dependency. System installation needs local
  administrator authentication; `sudo -n true` currently refuses.
- The engine has a default-off `cuda` feature and passes `GGML_CUDA` to CMake.
  The FFI crate does not forward this feature, and the package/native archive
  link lists do not yet include the CUDA backend/runtime. A flag alone is not
  end-to-end support. Inspect device selection, capability reporting and capture/
  intervention barriers before declaring any research API supported on CUDA.
- First deliverable: an isolated CUDA build/install route, a small real device
  execution and actual placement receipts. Keep the ordinary CPU build usable
  without a CUDA SDK, NVIDIA GPU or new required R/Rust dependency.

## Current implementation checkpoint (2026-10-17)

The founder explicitly authorized tool installation and CUDA compilation/tests.
GCC15, Rust1.99.1, Ninja and the existing R runtime/test packages are installed.
Official CUDA13.3.1 redistributable components were SHA-verified and installed in
an isolated prefix without replacing driver580.178.04. A real sm75 CUDA kernel
passed allocation, launch, synchronization, 32 exact output values and cleanup.
This establishes basic toolchain/device execution, not relm correctness or speed.

The optional Linux build now forwards the CUDA feature through the FFI crate,
links ggml-cuda/cudart/cuBLAS/system driver, and leaves NCCL disabled for the
single-GPU scope. CUDA sources were restored unchanged from the already pinned
b10828 archive; G4 and reverse-patch coherence pass. Nine model-free R build
configuration cases pass. Existing numerical test binaries select actual CUDA
with the feature, preserving their frozen inputs and thresholds.

The first native compilation and19targeted CUDA tests passed, with actual
model/KV/compute device buffers and complete tiny-model offload. The initial
placement test wrongly interpreted the retained -1all-layer metadata sentinel;
its failure is preserved, and only that test was corrected before completing
unrun gates. Tiny-model FlashAttention uses CPU; no speed claim follows.

The bounded projection bridge admits proven default CUDA device buffers and
uses synchronous backend copies into the existing charged row. Actual native
checks passed on MLP and attention:256independently recomputed coordinates,
maximum error0 at the existing same-input bound;224zero/live identity values;
real worker live updates, cancellation, restore and poison isolation. Original
lint/test-fixture failures are preserved; no runtime guard was weakened.

The production release-mode R installation and fresh-prompt workflow now pass.
Wrapper generation reuses the native release profile; CUDA PIC and runtime rpath
are verified on the actual installed DLL. A single profile and the frozen final
three-configuration benchmark are complete. The 1 ms live-timer candidate failed
the predefined performance criterion and was rejected; runtime timers remain
unchanged. Missing original benchmark native logs are disclosed, with separate
zero-inference placement receipts. All failures and slower results are retained.
See [implementation and exact evidence](wp13-linux-cuda-implementation.md).

The integrated parent review is complete, with no independent-review claim.
Final ordinary CI and PR integration remain. No more benchmark configurations,
old acceptance replays or new broad reviews are planned.


## Implementation and verification order

1. Prepare tools and a separate R library; record versions and source/model
   hashes. Use bounded build parallelism on this 16 GB desktop. Run lengthy
   installs/builds in the background, with one reused monitor and sparse checks.
2. Complete explicit optional CUDA feature forwarding, archive/runtime linking
   and package configuration. Use the existing public `backend = "cuda"` and
   `gpu_layers` grammar. No new exports or vendor kernel patches are preapproved. Restore the pruned
   CUDA directory unchanged from the pinned b10828 archive (D-050 addendum).
3. Exercise the committed tiny GGUFs on actual CUDA against frozen numerical
   references and same-input operator checks. Preserve the existing tolerances,
   same-backend determinism, zero identity, ownership, cancellation, budget and
   transfer checks. GPU copies and barriers need actual device evidence; a
   requested backend or successful compilation is insufficient.
4. Run a bounded installed-package workflow: generation, selected tracing,
   supported interventions and async/live observations. Report unsupported sites
   explicitly. Do not replay consumed efficacy prompts or treat tiny-model text
   quality as an optimization target.
5. Profile and optimize only measured bottlenecks. Freeze the performance recipe
   below before timing. Keep old failures and candidate results, including slower
   candidates. Repeat only affected checks after a real change.
6. One integrated review, relevant local checks and the final required CI matrix;
   document installation, exact support and measured tradeoffs. Stop when the
   acceptance criterion passes and material findings are resolved.

## Bounded performance protocol

Use an existing pinned GGUF that fits 6 GiB and is representative of useful
generation; tiny numerical fixtures are not the performance benchmark. Freeze
model hash, prompts/token IDs, context/output lengths, seed, quantization,
precision, software versions and all settings. Separate cold load from warmed
generation, prompt processing from decode, and native timing from R delivery.

Compare CPU and CUDA under equivalent declared settings; separately compare the
initial CUDA implementation with optimized CUDA. A smaller model or changed
precision is a different experiment, not a like-for-like speedup.
Record prompt tokens/s, generated tokens/s, first-token latency, process memory,
VRAM, actual offload, temperature and clocks. Record the baseline desktop GPU
load and power state; do not overclock or change system power policy implicitly.

Measure plain generation, filtered capture, static intervention and live
observation separately. Saved animation playback is never timing evidence.
After one profiling pass, test at most four justified configurations, with one
warm-up and three measured repetitions each. Use fresh prompts, retain every
timing and summarize median/range. Additional work needs a concrete remaining
bottleneck; no indefinite parameter sweep or unsupported “maximum possible” claim.

## Phase 9 and Windows boundary

After WP13, begin CRAN preparation with CUDA optional and the ordinary CPU/Metal
package independently installable/testable. CRAN normally requires portability
to at least two major R platforms and recommends win-builder when maintainers
lack Windows. Linux/macOS acceptance is relevant but does not guarantee admission.
Include a Windows CPU build/check feasibility gate during Phase 9; fix a concrete
CRAN blocker then or disclose the platform limitation for CRAN's decision.
Native Windows CUDA and interactive VM testing can follow later.

References: [CRAN policy](https://cran.r-project.org/web/packages/policies.html),
[NVIDIA Linux installation guide](https://docs.nvidia.com/cuda/cuda-installation-guide-linux/contents.html),
[supported workflow](supported-workflow.md). Existing numerical and research
limitations, prior source-bound acceptances and frozen holdouts remain intact.
