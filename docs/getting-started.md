# Getting started with rebirth

This guide has two parts:

- **Part A — Install and try it** (for anyone, including a first run on your own
  machine).
- **Part B — Publish it** (for the maintainer: r-universe, tagging a release, and
  why CRAN comes later).

`rebirth` is a normal R package. The only reason installation needs any thought
is that it ships a Rust + C++ native engine (a vendored, patched `llama.cpp`), so
you either install a **prebuilt binary** (nothing to compile) or build **from
source** (needs a toolchain). Both are covered below.

---

## Part A — Install and try it

### Option 1 — Prebuilt binaries from r-universe (easiest, no toolchain)

Once the r-universe is live (see Part B), anyone can install a binary — no Rust,
no CMake, no compiler:

```r
install.packages(
  "rebirth",
  repos = c("https://vadale.r-universe.dev", getOption("repos"))
)
```

This works on macOS and Linux (Windows support is a later phase) and is the
recommended path for users.

### Option 2 — From source, straight from GitHub (works today)

If you have a build toolchain, you can install directly from the GitHub repo
right now, before any release is tagged. You need:

- **R** (>= 4.5)
- **Rust** — install with [`rustup`](https://rustup.rs)
- **CMake** (>= 3.28) — `brew install cmake` (macOS) / your distro's package
- a **C/C++ compiler** (Xcode command-line tools on macOS; `build-essential` on
  Debian/Ubuntu) and **xz**

Then, in R:

```r
# install.packages("remotes")
remotes::install_github("Vadale/R-ebirth", subdir = "rebirth")
# (pak::pak("Vadale/R-ebirth/rebirth") also works)
```

The first build compiles the vendored engine and takes several minutes; later
installs are faster.

### Option 3 — Local clone (for development)

```sh
git clone https://github.com/Vadale/R-ebirth.git
cd R-ebirth
```
```r
# in R, from the repo root:
devtools::install("rebirth")     # or: devtools::load_all("rebirth") to iterate
```

### First run (the smoke test)

This downloads a small, checksum-verified Apache-2.0 model (~675 MB) and generates
a few tokens. If this works, your install is good:

```r
library(rebirth)

path <- llm_download("qwen2.5-0.5b-instruct-q8_0")   # verified by SHA256
m <- llm(path)

# raw completion (chat = FALSE); the return is the continuation only:
llm_generate(m, "The capital of France is", chat = FALSE, max_tokens = 8, temperature = 0)

close(m)
```

### Run the two demos

Both reproduce end-to-end on the Apache-2.0 model — no Python, no gated download:

```r
vignette("topics-without-python", package = "rebirth")  # topic modelling
vignette("anatomy-lab",           package = "rebirth")  # locating sentiment in a model
```

The runnable demo scripts are in `tests/demos/` in a clone; the larger demo model
is `llm_download("qwen2.5-1.5b-instruct-q4_k_m")`.

### Troubleshooting

- **"cargo/rustc not found" or a CMake error while installing** — you're building
  from source without the toolchain. Install `rustup` + CMake (Option 2), or use a
  binary (Option 1).
- **macOS Metal** — used automatically on Apple Silicon; no configuration needed.
- **Memory (16 GB Macs)** — stick to the 0.5B / 1.5B models; big `llm_trace()`
  captures spill to disk automatically and never OOM the session.
- **Ollama running** — stop its server before heavy sessions; it keeps models
  resident and competes for RAM. (`rebirth` never depends on Ollama.)

---

## Part B — Publish it (maintainer)

### Publish to r-universe (no review, cannot be rejected)

r-universe is an **automatic build service**, not a gatekept repository like CRAN.
You point it at this repo and it builds and hosts binaries (macOS and Linux for
v0.1.0; Windows is a later phase); there is no human review and nothing to be
"accepted" or "rejected." Steps:

1. Sign in at [r-universe.dev](https://r-universe.dev) with your GitHub account.
2. Because this package lives in the **`rebirth/` subdirectory** of the repo (not
   at the repo root), r-universe needs to be told the subdir. Create a GitHub repo
   named **`<your-universe>.r-universe.dev`** (e.g. `Vadale.r-universe.dev`)
   containing a single file `packages.json`:

   ```json
   [
     { "package": "rebirth", "url": "https://github.com/Vadale/R-ebirth", "subdir": "rebirth" }
   ]
   ```

   (Confirm the exact field names against the current
   [r-universe docs](https://docs.r-universe.dev) — the `subdir` monorepo option
   is the key detail for our layout.)
3. Within roughly an hour, `https://<your-universe>.r-universe.dev/rebirth` goes
   live with binaries and a pkgdown site.

If your universe name is **not** `vadale`, tell the maintainer notes / update the
three places that hardcode the URL: the README badges + install block
(`rebirth/README.md`), the root `README.md`, and `rebirth/_pkgdown.yml`.

### Verify a clean install

On a machine without the toolchain (or a fresh R), confirm the binary path works:

```r
install.packages("rebirth", repos = c("https://<your-universe>.r-universe.dev", getOption("repos")))
library(rebirth); packageVersion("rebirth")   # 0.1.0
```

Then run the smoke test and one demo from Part A.

### Tag the release

Once you're happy, tag `v0.1.0` (this is the outward-facing step):

```sh
git tag -a v0.1.0 -m "rebirth 0.1.0"
git push origin v0.1.0
```

### Why not CRAN yet

CRAN is the restrictive, human-reviewed repository. This package is exactly the
kind CRAN scrutinizes hardest: a **vendored Rust crate**, a **patched, vendored
`llama.cpp`**, a **large native build**, and non-trivial `SystemRequirements`.
CRAN also expects a mature, stable API and a clean `R CMD check --as-cran`, and
submissions often take several rounds. The plan (see `ROADMAP.md`, Phase 9) is
therefore: **r-universe now** for real, installable binaries with zero acceptance
risk; **CRAN later**, once the package is stable and has users. How the code was
written (with or without AI assistance) is irrelevant to either — r-universe does
no review, and CRAN judges the code and policy compliance, not the author.
