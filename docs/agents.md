# Use relm from an agent

relm runs local models in stock R. Use ordinary R data structures, read the
installed help, and keep observations separate from scientific conclusions.
Start at [llms.txt](../llms.txt). The [API surface](api-surface.csv) is derived
from source; it lists every export and registered S3 method. The
[compatibility policy](api-policy.md) defines what is stable.

## Inspect the environment first

```r
packageVersion("relm")
find.package("relm")
getNamespaceExports("relm")
args(relm::llm_generate)
help("llm_trace", package = "relm")
```

Restart R after an upgrade. Main, a tagged release, r-universe binaries and a CRAN
submission can contain different bytes despite similar version labels. Record the
installed version, source commit when available, model SHA-256, engine revision,
backend, R/platform, seed and actual input/settings alongside results.

Do not install packages, fetch models, start a service or write persistent output
merely because an example mentions it. Obtain the user's authorization for the
needed side effect. No API key or model server is required for local inference.
Supply a verified local model; never invent a model digest or engine revision.

## One independent example for every export

Each [script](../rebirth/inst/examples/agents/) defines `run_example()` without
executing it on source. Each script has all its own setup; no prior example or
workspace objects are needed. Use a fresh environment to avoid name collisions:

```r
example <- new.env()
source(system.file("examples", "agents", "llm_direction.R", package = "relm"),
       local = example)
direction <- example$run_example()  # synthetic, model-free API demonstration
```

These files arrive with the WP16 documentation build. With an older installation,
source the corresponding repository file explicitly instead. Check the function
signatures; do not assume installing an older release includes these scripts.

| Export | Example input / result |
| --- | --- |
| `llm` | Verified local GGUF → inspect and close a CPU handle |
| `llm_tokens` | Local model → encode/decode a short UTF-8 string |
| `llm_generate` | Local model → at most eight generated tokens and recorded seed |
| `llm_logits` | Local model → five next-token rows; truncated probabilities |
| `llm_embed` | Local model → two rows of embeddings |
| `llm_trace` | Local model → last-position layer-2 residual matrix |
| `llm_steer` | Local model → a new additive residual handle, then close |
| `llm_ablate` | Local model → a new residual ablation handle, then close |
| `llm_apply_direction` | Verified model/build → four fresh captures, recorded direction, zero-coefficient application |
| `llm_cancel` | Local model + later/promises → observe one live state and cancel cooperatively |
| `llm_download` | Explicit permission/cache directory → pinned download or verified cache reuse |
| `activations` | Formula marker and its documented outside-formula refusal |
| `llm_probe` | Synthetic grouped data + glmnet → development selection and separate held-out evaluation |
| `llm_direction` | Synthetic paired matrices → recorded unit direction |
| `llm_compare` | Synthetic aligned states → coordinate differences |
| `llm_timeline` | Synthetic state records → bounded applied-steering audit |

Native examples accept `model_path` and an independently known `expected_sha256`.
Use a supported text model with at least two layers (the pinned Qwen2.5 0.5B is
the documented small-model route). `llm_apply_direction` also requires the actual
`engine_revision` from the build record. None of these scripts downloads a model.
Only the downloader's explicit `allow_download = TRUE` enables that side effect.
Its registry alias verifies a pinned checksum; a bare URL alone is not verified
against a trusted expected checksum.

```r
example <- new.env()
source(system.file("examples", "agents", "llm_generate.R", package = "relm"),
       local = example)
# Set these from your own verified model record, not from an agent's guess:
answer <- example$run_example(model_path, expected_sha256)
```

CI executes the five model-free examples and eleven public usage/refusal checks,
parses every script and checks inventory coverage. It does **not** download a
large model or represent missing model execution as success. A separately
recorded local run checks the ten native paths with fresh bounded inputs. This
distinction also applies to optional, guarded model chunks in the six vignettes.

## Choose the observation and manage ownership

- `llm_trace()` observes a prompt forward pass; `on_state` observes generation.
  Derived/intervened handles refuse ordinary trace/embed; use live observation
  where supported. Do not relabel an original-model trace as an edited one.
- Start with one layer, `positions = "last"`, one component and a bounded token
  count. `spill = FALSE` refuses a capture over budget. A spilled trace is a
  zero-row proxy: use `as.matrix(trace, layer = ...)`, not `nrow()` as its data size.
- Keep handles in their owning process and close them with function-scoped
  `on.exit(close(m))`. Derived handles share weights, not cross-process ownership.
  Only one native operation is active per process; async requires an event loop.
- Async returns a promise. Retain it and handle rejection as well as fulfillment;
  pump `later` in a script. Cancellation is cooperative, not a hard stop or a
  partial-success result. Callbacks run on R's thread; preserve callback errors.
- `llm_compare()` needs the complete preceding sampled history. Divergent
  prefixes withhold numerical differences. Top-k tables cannot establish a full
  distribution KL. Returning a coefficient to zero does not erase earlier KV.
- Direction construction, coefficient selection and final evaluation need
  disjoint declared data. Synthetic examples and consumed holdouts establish no
  new efficacy claim. Probe association is not causal use; JSON shape is not truth.

## Handle errors and preserve results

```r
result <- tryCatch(relm::llm("missing-model.gguf"),
  relm_error_model_load = function(e) list(class = class(e), message = conditionMessage(e)))
```

Use the installed help's specific condition class and structured fields. Report
unsupported capabilities, timeouts and failed checks. Do not retry a refused
model blindly, swallow warnings, weaken filters/tolerances or turn a skip into a
pass. Preserve raw output before correcting a collector. Treat RDS and native
model/projector inputs as trusted-input boundaries; checksums do not make hostile
RDS safe. Persistent exports belong to an explicit caller-chosen directory.

For full workflows see [research guidance](research-guide.md),
[the complete walkthrough](../examples/research-workflow/README.md),
[supported scope](supported-workflow.md) and [installation](getting-started.md).
