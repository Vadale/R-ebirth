# Initial F6b native verification: failed before tests

Source manifest SHA256: a5eb343eaf506c148b559f6d2a4b0f5ac1c81547c8480eb253c6fb2401854788.
The format check passed. Clippy failed with result_large_err at the three
AsyncStartFailure return signatures: the newly retained steering baseline
increased the error variant to at least160bytes. No native product test, FFI
test or cached-model case executed. This is not functional acceptance.

The complete driver, stage logs/status, exact source manifest, candidate diff
and changed-source archive are retained. In parallel, the focused review
identified an additional initially-zero probe peak absent from the steering
allocation ledger; it is a source finding, not an observed runtime test failure.
Both require narrow correction before resuming the unexecuted gates. No warning
suppression, weaker bound or blind retry is accepted.
