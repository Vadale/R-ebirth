# Windows static archive naming

Run39156167138/job117759716649 on `49a15c2` passed the real Rtools ABI/API
preflight and compiled all seven engine/bridge archives. The original job still
failed: relm's build script searched for `libggml.a`, while the pinned upstream
`ggml/CMakeLists.txt` removes the `lib` prefix on Windows. Actual outputs include
`ggml.a`, `ggml-cpu.a`, `ggml-base.a`; the other four retain their prefix.
No final package link/install/tests or model acceptance is claimed.

The owned collector now selects those actual Windows source names and copies
the same bytes to the existing canonical `lib*.a` destinations for Cargo/R.
Search roots, required archive list, missing-file refusal and link directives
are unchanged. Unix source names retain their prefix, including CUDA/Metal.
No vendor bytes, CMake/compiler flags, kernels, dependencies, API or numerical
bounds changed. Existing source/archive hashes and the real Rtools receipt were
independently verified from saved data, without replaying native compilation.

Two new standalone controls passed (seven old tests filtered), covering the
seven observed Windows names and all nine Unix CPU/GPU archive stems. Formatting
and focused build-support Clippy passed with warnings denied. An optional full
build-script Clippy attempt could not complete because the cached cmake rlib was
built by Rust1.96, incompatible with current1.99; its original diagnostic remains
in build-lint-1.log. No dependency rebuild or misleading full-lint pass follows.
Full current build-script Clippy remains in the normal automatic CI job.

The real Windows job retains two upstream Git-probe 'not a git repository'
messages and one boundary-project CMake unused C/ASM flag warning. They did not
stop those native builds; this is not a globally warning-free claim. Source and
package check outcomes remain separate. Small compiled local controls stay local;
windows-artifact.zip contains only the original 678-byte receipt artifact.
