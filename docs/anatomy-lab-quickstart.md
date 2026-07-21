# rebirth — the 10-minute anatomy lab (macOS / Apple Silicon)

A hands-on first session. You will **build `rebirth`** (this validates the Metal
build on your Mac), **load a local model**, **trace its activations** on one
sentence, and **steer** its generation. This is the same path the `[MODEL]`
acceptance tests exercise — if it runs clean here, the Mac build is good.

Budget ~10 minutes, most of it the first compile.

---

## 0. Prerequisites (one-time)

```bash
R --version            # need >= 4.5
cargo --version        # Rust toolchain (install via https://rustup.rs if missing)
cmake --version        # needed to build the vendored llama.cpp
xcode-select -p        # Xcode Command Line Tools (clang + Metal); install with `xcode-select --install`
```

**Quit the Ollama app before the session.** It keeps models resident and would
compete for the 16 GB of unified memory (and the GPU). `rebirth` never uses
Ollama — but its downloaded blobs are plain GGUF files you can reuse (step 1).

---

## 1. Point at a model file

`rebirth` takes a path to a GGUF file. The fastest source is a model Ollama has
already downloaded — its blobs are ordinary GGUF:

```bash
ollama list                              # what you already have
ollama show qwen2.5:1.5b --modelfile     # or any small model you see listed
#   -> copy the path on the line starting with `FROM /Users/.../blobs/sha256-...`
```

That `FROM` path is a plain GGUF you can hand to `llm()`. A 0.5B or 1.5B Qwen is
ideal for a first run. (No Qwen in Ollama? Download one GGUF from its Hugging
Face GGUF repo, e.g. `Qwen/Qwen2.5-0.5B-Instruct-GGUF`, and use that path.)

---

## 2. Build and load rebirth

From the repository root, in R:

```r
# install.packages("devtools")   # if you don't have it
devtools::load_all("rebirth")
```

The **first** build compiles the vendored llama.cpp with Metal and the Rust
core — expect several minutes and a lot of compiler output. That is normal and
is exactly the Metal build we want to confirm works on your machine. Subsequent
loads are fast.

---

## 3. Load the model and a sanity check

```r
m <- llm("/Users/.../blobs/sha256-....")   # the path from step 1
print(m)                                    # arch, layers, hidden_size, context
m$layers        # number of transformer blocks
m$hidden_size   # width of the residual stream

llm_generate(m, "The capital of France is", max_tokens = 12, temperature = 0)
```

If that returns text, inference works end-to-end on Metal.

---

## 4. The anatomy — trace activations

Capture the residual stream at a few layers, at the last token of a sentence:

```r
tr <- llm_trace(m, "The cat sat on the mat.",
                layers = c(1, 6, 12), positions = "last", components = "residual")

print(tr)          # what was captured (prompts x layers x positions x neurons)
summary(tr)        # per-layer activation magnitude summary
head(tr)           # the tidy long data.frame: prompt_id, token_pos, layer, neuron, value

M <- as.matrix(tr, layer = 6, component = "residual")
dim(M)             # rows = captured positions, cols = neurons (= hidden_size)
```

`tr` is a plain `data.frame` — every base-R and tidyverse verb works on it.
This *is* the "AI neuroscience" surface: the model's internal state as data.

---

## 5. The intervention — steer the valence

Build a steering **direction** from a contrast (mean "positive" residual minus
mean "negative" residual at one layer), then bias generation along it:

```r
L   <- round(m$layers / 2)          # a middle layer (steering needs layer >= 2)
pos <- c("I feel wonderful and joyful", "What a delightful, happy day")
neg <- c("I feel miserable and hopeless", "What a terrible, gloomy day")

Mp <- as.matrix(llm_trace(m, pos, layers = L), layer = L)   # 2 x hidden_size
Mn <- as.matrix(llm_trace(m, neg, layers = L), layer = L)
direction <- colMeans(Mp) - colMeans(Mn)                    # length hidden_size

happy <- llm_steer(m, layer = L, direction = direction, coef = 4)

# same prompt, base vs steered — watch the tone shift:
llm_generate(m,     "Let me tell you about my day. ", max_tokens = 30, temperature = 0.7)
llm_generate(happy, "Let me tell you about my day. ", max_tokens = 30, temperature = 0.7)
```

`happy` is a *separate* handle over the same weights; `m` is untouched. Tune
`coef` (try 2, 6, 10) to dial the effect from subtle to overwhelming. A negative
`coef` steers the other way. This is *audit / investigate / quantify* — never a
claim that the model was "made happy".

---

## 6. (bonus) Ablate neurons

Force a few residual units to zero at a layer and see generation react:

```r
abl <- llm_ablate(m, layer = L, neurons = c(1, 2, 3), value = 0)
llm_generate(abl, "Let me tell you about my day. ", max_tokens = 30, temperature = 0.7)
```

---

## 7. Clean up

```r
close(m)        # and close(happy), close(abl) — frees the model from memory
```

---

## What this proved

- The **Metal build works** on your Mac (the whole vendored-llama.cpp + Rust +
  extendr stack compiled and ran).
- **Taps, steering, and ablation** run locally and return plain R objects.

Anything that errored, printed oddly, or felt slow — note it and send it over;
that feedback is worth more than a green CI run. Once you confirm this runs
clean, it becomes the repository's quickstart.
