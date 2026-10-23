# Public API and version policy

The WP16 compatibility baseline is extended by the approved D055 capability
in relm 0.6.0, published on r-universe on 2026-10-23.
CRAN submission is pending. This policy does not announce a 1.0 release.

## What is stable

D055 adds the founder-approved optional `threads` argument to `llm()` while
preserving its default behavior. The existing sixteen exports, their other
named arguments/defaults and documented
return contracts are the frozen public baseline. Registered S3 methods are part
of that baseline too. See the machine-readable [surface](api-surface.csv), the
[approved grammar](../API-GRAMMAR.md) and the installed help for details.
`activations()` is a formula marker; the other operations use `llm`/`llm_*`.
Reserved names in the grammar are not implemented APIs.

Compatibility includes documented column names/types/order, 1-based indices,
classed errors and documented structured fields, ownership/close/cancellation,
bounded capture/spill, and supported intervention semantics. Callers should match
condition classes, not exact English messages. A new error subclass retains its
documented parents. Bug fixes restore the documented contract; they do not
silently redefine it. Model capability refusals remain explicit.

S3 accessors and documented attributes are supported. Private namespace helpers,
native symbols, pointer layout, internal caches and undocumented fields are not.
Do not call `relm:::` or serialize/fork a live handle. Versioned direction
artifacts have their own schema checks; new versions must retain supported old
schemas or provide an explicit migration before removal. Editable provenance is
not authentication of weights or scientific validity.

Stability does not promise identical generated text across package/engine/model
revisions, hardware or backends. Reproduce an experiment with the exact model
digest, build/backend, parameters and seed. The same-build determinism contract
and existing numerical/resource bounds remain unchanged. CUDA availability is a
build property; CPU/Metal/CUDA support and Windows cleanup limits remain those in
[supported workflows](supported-workflow.md).

## Version changes

Use `major.minor.patch`, following [Semantic Versioning](https://semver.org/).
The project adopts a stricter compatibility promise during 0.x than SemVer's
default initial-development allowance:

| Change | Version and process |
| --- | --- |
| Documentation, packaging or a compatible bug fix | Patch when a release is made; explain behavior corrections in NEWS |
| Compatible new public capability | Minor; approve its grammar/decision first and retain old calls |
| Incompatible public contract before 1.0 | Explicit founder-approved decision, minor increment, migration guide and deprecation notice; never silently change 0.5.x |
| Incompatible public contract from 1.0 | Major increment, approved decision, migration guide and advance notice |
| Development work without a release | Commit identity identifies it; never overwrite a published tag/archive or imply publication from DESCRIPTION alone |

A planned removal normally has at least one minor release with a documented
replacement and deprecation warning before removal in the permitted breaking
release. Security/correctness emergencies may shorten notice only through an
explicit recorded decision explaining impact. Never weaken bounds or conceal
diagnostics to preserve a green check.

Dependency/toolchain minimum increases, default changes and changes to supported
platforms need an explicit compatibility assessment. Optional capabilities must
remain optional. A newer Rust compiler does not replace the independent minimum
Cargo requirement. A CI pass is not evidence of CRAN policy acceptance.

## Thirty-day gate for 1.0

This is a project release criterion, not a CRAN requirement. It is **not complete**
at the WP16 PR merge. Start the window at the first post-merge `main` commit whose
complete ordinary required matrix (including documentation) is successful.
Record that UTC time, commit and workflow runs in the release evidence.

For thirty consecutive calendar days, retain the results for every main-branch
ordinary run and each scheduled gate actually configured for that period.
Failed, cancelled, timed-out or missing required results do not count as green;
an unresolved failure blocks release. After an affected correction has passed,
start a new window at that accepted main commit. Do not manufacture green days
with duplicate reruns or reinterpret a routed not-applicable job as executed
native coverage. Unrelated infrastructure failures need a documented disposition
and a successful required result before a new window starts.

At the end, inspect the interval once, resolve open compatibility defects, verify
the exact release artifact and obtain the release decision. The elapsed interval
does not automatically publish 1.0, imply adoption, or validate new model quality.
CRAN review and external-human usability feedback remain separately reported.
