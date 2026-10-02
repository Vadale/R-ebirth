# WP10 streaming acceptance

Contract: [D-038 plan](../../docs/wp10-streaming-plan.md). Current execution state:
[implementation ledger](../../docs/wp10-implementation.md). Planned gates are not
passing results; measurement directories retain original failures and scope.

- `rebirth-llm/src/text_stream/tests.rs`: native decoder correspondence and
  actual vocabulary-only detokenization, UTF-8/stops, a pinned-source fixture,
  exhaustive small alphabets and the 8 MiB stop near-match regression. No model
  download. The [proof](../../docs/wp10-text-decoder.md) explains stable prefixes.
- `rebirth-llm/src/async_job.rs`: bounded row/byte capacity, wait/cancel races,
  ownership through final acknowledgement, failure/shutdown under backpressure
  and synthetic token parity. The `async` release-profile job covers these gates.
- `rebirth/tests/testthat/test-llm-stream*.R`: typed R batches, file/identity/
  callback failures, reentrancy, ordering, memory and model-gated parity. All
  ordinary R CI legs run download-free cases; cached Qwen/VLM gates are explicit.
- [Foreground demo](../demos/demo-streaming.R): starts only when called, keeps
  a last-128-token window, and offers bounded full collection for illustration.
  Actual RStudio acceptance additionally records native-active independent R
  execution, at least five seconds of generation and ten heartbeats.

The unchanged full-generation decoder and numerical goldens remain authorities.
Do not regenerate expected results to fit streaming errors. Queue payload limits
exclude caller retention, model/backend memory and allocator overhead; materialized
R and intermediate conversion buffers have their own conservative estimates.

CSV bytes preserve quoted text, including CRLF. Base R `read.csv()` normalizes
quoted CRLF to LF; that reader limitation is recorded separately from raw-byte
writer parity. Literal `"NA"` and missing numeric/logical cells use the documented
typed reader. No CSV reader is exported by relm.

Run native checks serially with `RUST_TEST_THREADS=1`, as in CI, and use a fresh
installed package for R gates after wrapper regeneration. Long verification uses
one detached pipeline with durable phase status; do not start duplicate builds,
poll logs repeatedly or repeat unrelated WP9/service/release acceptance.
