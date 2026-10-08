# F6e first PR matrix: portability corrections and unresolved numeric checks

The first PR63 matrix on `3a818f48fc9e623ec4bb04d6cfd48b8f8e397f18`
failed six of nine jobs. Vendored integrity, supply-chain checks and the macOS
x86_64 engine link passed. The matrix is not accepted and its failed receipts
remain unchanged. No tolerance, original bitwise assertion, frozen golden or
native vendor source is changed by these corrections.

## R 4.6 state inspection

The macOS R 4.6.1 compiler rejected the previous C accessor's removed non-API
`FRAME`, `HASHTAB`, `ENCLOS`, `ATTRIB` and `Rf_findVarInFrame3` declarations.
It is not sufficient to infer compatibility from an older cached object or a
permissive compiler. Actual R 4.6 compilation remains a required CI outcome.

The internal `rebirth_model_state` factory now creates an unhashed environment
with the two existing `ptr` and `closed` bindings. Its names are locked; values
remain mutable for close and synchronization. The pointer's previously empty
protected slot holds a weak reference whose key is this exact environment.
The query verifies that provenance, the empty parent, absent attributes and
binding values without enumerating an untrusted environment or allocating an
unbounded `env.profile()` result. Arbitrary user-constructed states are refused.
The weak key does not retain the state or delay its existing R finalizer.

R 4.6 uses `R_GetBindingType` before `R_getVar`; delayed, already-forced and
active bindings are refused before evaluation. R <= 4.5 retains its declared
unforced accessor behind a compile-time version branch. R 4.6 does not compile
or link that branch. No private R structure layout is copied or redeclared.
The C factory/query frame retains the previous conservative 128-byte charge.
The compiled 27-field native profile is numerically unchanged on the local
R 4.5.1 build, including the 1512-byte response envelope.

There is one additional four-slot weak reference per state. The R inventory
explicitly charges all three weak references, increasing two-state weak-reference
storage by 160 bytes on the checked host. Original handles now also use an
unhashed state, so their old hash-table storage is no longer present. No old
exact total is reused as an acceptance result for this new state representation.
There are no new Rust model owners, registry entries, public exports or dependencies.

The local C-only harness passes 24 new controls, including forced collection at
every allocation, weak-key collection while the external pointer remains rooted,
forged hashed/unhashed state refusals and unforced promises. It does not exercise
a model. Its first wrong-pointer fixture used R's shared S4 `externalptr` prototype;
that failed control is retained and was corrected to allocate distinct pointer
SEXPs using `R_MakeExternalPtr`. The C23 shim build retains an installed R header
warning about an unsupported clang warning pragma; it is not suppressed. The
actual production C build and fresh link have no compiler warnings.

Default/private clippy and no-spill compilation passed. A fresh default DLL was
linked from the current C object and nine bound static archives. Generated
wrappers exposed one previously omitted, already registered internal budget-error
selftest, in addition to the new factory. Only the generated wrapper bytes were
corrected; the successful native build was carried without recompilation.
The affected fresh installation has 261 source-matching functions and silent
codetools checks. No model or inference calls occurred in these local steps.

## R fixture corrections

Eight projection helpers were defined in separate `test-*.R` files. Package CI
isolates those test environments, causing twelve affected cases to fail lookup.
Their definitions moved to `helper-projection.R`; the initial helper-only check
proved identical parsed function and test bodies and passed the twelve cases.
New state-factory fixtures use the existing real empty-handle selftest instead of
R's shared empty external-pointer prototype.

Two additional CI failures were stale fixtures: the checksum interruption mock
had four formals while the schema-aware stream calls five, so it failed before
signalling an interruption; the print-count stub used atomic numbers instead of
intervention records. The corrected mock accepts and checks schema1, and the
print fixture supplies two real-shaped steer/ablate records. Existing byte-cap,
interruption-cleanup and count assertions remain in place.

The first affected installed run completed fifteen cases with only two failures:
the owner-inventory tests still expected the old weak-reference totals. Their
exact expected totals change from 1272/992 to 1432/1152, independently accounted
for by two additional 80-byte weak references. Those two cases plus the checksum
and print fixtures passed in a four-case correction run. Its CSV collector failed
on testthat's nested result column after the RDS had been saved; the result was
recovered from that RDS without repeating tests. The carried thirteen successful
cases plus these four corrected cases comprise seventeen model-free cases.
The external testthat built-under-R-4.5.2 warning on R 4.5.1 remains explicit.

CI also found unqualified `new` and `setNames` calls in projection internals.
They now name the existing base-R `methods` and `stats` namespaces explicitly.
Reversing only those qualifications reconstructs all three prior files exactly.
Current source passes codetools against the installed namespace's imports and
actual native-symbol registrations, without attached default-package fallback.
Two inspector drafts omitted the registrations and then assumed their count;
both are retained. No test or model replay was needed for this qualification.
The old-R branch still uses its declared unforced legacy accessor, so its
non-API check note remains possible; local success is not an R 4.6 check claim.

## Numeric failures remain open

The Linux pruning test failed its existing bitwise comparison between all-output
and last-output policies, with a first observed maximum final-logit difference of
`2.980232238769531e-7`. Same-policy replays and the following fixed-token history
were bitwise equal in that retained record. The small size of the difference is
not an acceptance argument or proof of its cause. The original assertion remains
unchanged. A separate, explicitly invoked tiny-model diagnostic compares original,
zero and active projection under both output policies, repeats each policy and
retains raw final/history logits and actual before/after site coordinates. It
preserves the original same-row bound and does not replace failed acceptance.

The strict frozen reference self-check failed a `manifest.json` byte comparison.
Its temporary generated bytes were deleted by the original checker, so the exact
difference is not yet known. The local original environment is macOS arm64 with
NumPy Accelerate; no assertion about the failed runner's BLAS follows from its
OS label alone. The new CI wrapper invokes the same unchanged strict checker once
and retains generated bytes only on failure, along with actual BLAS/SIMD/runtime
information. It preserves exception propagation and frozen input hashes. It does
not regenerate committed goldens, relax comparisons or turn a failure green.
Two new model-free retention controls pass; no reference producer was rerun locally.

The next candidate remains a diagnostic/correction candidate, not a completed
F6e acceptance. Existing scientific results, graphics, documentation, installed
operational scopes and instrumented receipts retain their original source
provenance. No consumed efficacy prompts or accepted independent goldens are rerun.

The first new diagnostic run failed in its own last-only logit accessor: it used
compact output slot zero where `llama_get_logits_ith` requires the original last
input-token index four. The two original/all observations and complete failure
are retained. The correction changes only that diagnostic index. The corrected
Mac CPU run produced all twelve records, 1152 final/history logit values and 256
same-row coordinates. Same-policy replays were bitwise equal; on this host all
three cross-policy comparisons were also bitwise equal. The sequential f64
same-row recomputation matched all coordinates exactly. Actual CPU placement
and zero-of-four offload receipts are retained. This does not resolve the Linux
failure. An initial owner inspector used Python's compensated `sum` rather than
the operator's sequential accumulation, and initially missed a first marker
prefixed by Rust's test runner. Both collector corrections used retained output;
no native execution or tolerance changed for them.
