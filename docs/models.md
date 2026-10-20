# Choose and change a model

relm is not tied to Qwen. Load a compatible local **GGUF** file with `llm()`;
the generation call stays the same when you change the file. Compatibility
depends on the architecture supported by relm's pinned engine, the model's
metadata and the operation you want to run. A successful text generation does
not establish support for tracing, embeddings, projection or vision.

Start with [installation](getting-started.md). The examples below are instructions
for an explicit user run, not new model-validation or performance results.

## Choose a pinned download

The bundled [registry](../rebirth/inst/models.csv) records exact URLs, revisions,
SHA-256 digests, byte sizes and licenses. These are the five current aliases:

| Alias | File download, decimal units | Intended use / limit |
| --- | --- | --- |
| `qwen2.5-0.5b-instruct-q8_0` | 676 MB | Small text model used for the bounded research examples |
| `qwen2.5-1.5b-instruct-q4_k_m` | 1.12 GB | Larger text model used in the demos; results from 0.5B do not transfer automatically |
| `spark-x2.5-4b-q8_0` | 4.38 GB | Optional text model with a separate validation record; activation tracing is unsupported |
| `qwen2-vl-2b-instruct-q4_k_m` | 986 MB | Vision-language model; image input needs the matching projector below |
| `qwen2-vl-2b-instruct-mmproj-f16` | 1.33 GB | Vision projector, not a standalone language model |

All five entries record Apache-2.0. Download size is **not** required RAM/VRAM:
weights, context/KV, compute buffers and captured R objects add separate costs.
The vision pair downloads about 2.32 GB in total. Quantization labels describe
the weight format; they do not guarantee a particular speed or answer quality.

Inspect the registry shipped with your actual installation without downloading:

```r
registry <- read.csv(
  system.file("models.csv", package = "relm"),
  colClasses = "character", na.strings = character(), check.names = FALSE
)
registry[c("alias", "size_bytes", "license")]
```

To switch the small Qwen example to Qwen 1.5B, change the alias:

```r
# Explicit download on first use; a matching cached file is reused.
path <- relm::llm_download("qwen2.5-1.5b-instruct-q4_k_m")

generate_text <- function(path, prompt) {
  m <- relm::llm(path, backend = "cpu", context_length = 512L)
  on.exit(close(m), add = TRUE)
  relm::llm_generate(m, prompt, max_tokens = 32L,
                    temperature = 0, seed = 17L)
}
generate_text(path, "Explain what a confidence interval describes in two sentences.")
```

`llm_download()` verifies registry files against their pinned digest. An unknown
alias produces `relm_error_download` listing the available aliases. A newer
registry can differ from the one in an older installation; inspect the installed
registry rather than assuming an alias exists.

`chat = TRUE`, the generation default, applies the model's chat template.
Use `chat = FALSE` for raw continuation. A model needs an appropriate template
for chat; changing that flag is a deliberate change to the input format.

## Bring a different local GGUF

Obtain a GGUF from a source you trust, follow its license/access requirements,
and verify its SHA-256 against an independently recorded expected digest. Then
pass that file to the same function:

```r
# Reuses generate_text() above; this call performs no download.
generate_text("models/my-model.gguf", "Summarize the purpose of a control group.")
```

This is a path example, not a certified model name. A `.gguf` extension alone
does not prove compatibility. relm uses a pinned, patched llama.cpp revision;
support added to a newer upstream engine is not automatically present here.
GGUF models and projectors are parsed by native code, so a checksum identifies
bytes but does not make an untrusted file safe.

`llm_download("https://...")` also accepts a direct HTTPS URL. Unlike a registry
alias, that route has no trusted expected digest: it reports the computed hash,
does not claim verified provenance, and fetches the URL again on another call.
For a reproducible experiment, retain the verified local file, its digest,
source revision and license. The single-file registry is not a general model
catalog or an authenticated/gated-download client.

## Match the model to the research operation

| Operation | What to check when changing models |
| --- | --- |
| Text / constrained JSON | Supported architecture, tokenizer and chat template; JSON shape does not establish factual correctness |
| Embeddings | Supported embedding route/pooling; vectors from different models are not a shared coordinate system |
| Prompt trace / live observation | Supported architecture, component, layer and position; Spark tracing is explicitly refused |
| Additive steering / ablation | Supported intervention site and the new model's dimensions; loading alone does not validate the intervention |
| Static projection | Recorded scope is dense Llama `attn_out`/`mlp_out` and dense Qwen2 `mlp_out`; no arbitrary-architecture or MoE promise |
| Images | A supported vision-language model plus its own matching projector; no vision-encoder tracing claim |

See the [supported workflow](supported-workflow.md) and
[Spark validation record](spark-native-validation.md) for the actual tested
operations and limits. The [historical model matrix](wp7.5-model-matrix.md)
also names its producing engine/build; old results do not certify a newer build.

Start a new model with a short generation and the **specific** observation you
need, keeping warnings and classed refusals visible. Do not retry unsupported
operations blindly. Reduce capture scope before scaling up: one layer,
`positions = "last"` and a bounded token count. A direction recorded for another
model/checkpoint must not be reused just because the vectors have the same length.
Construct and evaluate a new direction with declared, disjoint data.

## Use a matched vision pair

```r
# Two explicit downloads; later calls reuse matching cached files.
model_path <- relm::llm_download("qwen2-vl-2b-instruct-q4_k_m")
projector_path <- relm::llm_download("qwen2-vl-2b-instruct-mmproj-f16")

describe_image <- function(model_path, projector_path, image_path) {
  m <- relm::llm(model_path, projector = projector_path,
                 backend = "cpu", context_length = 4096L)
  on.exit(close(m), add = TRUE)
  relm::llm_generate(m, "Describe what is visible.",
                    images = list(image_path), max_tokens = 32L,
                    temperature = 0, seed = 17L)
}
# Supply your actual local image:
# describe_image(model_path, projector_path, "images/example.png")
```

Do not combine a model with an unrelated projector. Matching dimensions alone
are not evidence that the pair belongs together. See the
[vision guide](../rebirth/vignettes/vision.qmd) for other local pairs and limits.

## Record the experiment, including the backend

CPU is the explicit starting point above. `backend = "auto"` selects available
compiled backends in priority order: Metal, CUDA, CPU. It does not benchmark
them. Requesting `"cuda"` needs an actual CUDA-enabled installation; see
[Linux CUDA](linux-cuda.md). Close the current handle before loading another
large model if you do not need both resident.

Record the installed relm version/source, engine revision, model/projector
digests, backend, context, prompt/template, generation settings and returned
seed. Different models, quantizations and backends can change both answers and
timings; the measured Qwen CUDA result is not a benchmark of other models.

The [agent examples](agents.md) already accept a local `model_path` and an
independently known `expected_sha256`; changing models does not require editing
their code. Their required capabilities still apply (for example two layers
and supported tracing for the direction example). Keep the expected digest
independent of the file being checked.
