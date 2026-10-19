# PR71 service identity fixture correction

The original Linux oldrel/Rust1.85 job remains failed. Its package check passed
6,669 expectations with 81 scoped skips and zero errors/warnings/notes; the first
service ownership preflight then failed. The HTTP/process acceptance had not
started, so its artifact directory did not exist. Other ten jobs reported success.

Pinned ps1.9.3 accepts precise and legacy Linux boot-time representations. The
exact upstream psll_is_running body, with controlled OS/clock inputs and R scalar
plumbing, reproduces an owner whose time minus one second is still live. This
invalidates the test fixture assumption. Original runner timestamps were not
retained: the counterexample is not a reconstruction of its exact boot times.

Three persisted fixtures now use the epoch string; the direct ps handle uses
a POSIXct epoch. The same PID, original owners, assertions, runtime guards and
dependency pins remain unchanged. Inverse replacement reconstructs the complete
original test byte-for-byte. Four affected cases passed using actual installed
ps1.9.3, including an independent R reader. The real host observation accepts a
legacy birth and rejects epoch, with the original owner alive; the old minus-one
fixture did not fail on this local host. No model/HTTP/relm rebuild occurred.

Two draft control failures remain retained: a C stub indentation warning and a
missing POSIXct type for the direct handle. Only the fourth R case was rerun after
the type correction; the other three results were carried. Nine unrelated cases
were not replayed. The isolated C executable remains local; sources/logs and
original upstream notices are retained here. See owner.json for hashes/scopes.
