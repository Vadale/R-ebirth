# A first-use experiment with the released package

**Question:** when an unmarked sealed envelope provides no evidence about a
letter's contents, does explicitly permitting “insufficient evidence” change
unsupported city assertions? What changes after a fixed residual addition?

A separate agent chose this question and ran it once using public documentation
and installed help. It loaded one cached model, made four construction traces
and six short generations, and exported the actual results. Read the
[assessment and limitations](../../docs/research-first-use.md) before treating
this as a research finding.

## Inspect the recorded result without a model

The [full output table](recorded/outputs.csv) contains every response, including
the failed answers. [The figure](recorded/response-review.png) shows all four
distinct texts; zero controls exactly duplicated the originals. The
[activation comparison](recorded/direct-comparison.png) is an actual base-R
plot of two aligned first observations, not an illustrative reconstruction.
All files in `recorded/` belong to the original execution; do not overwrite them.

The RDS files preserve attributes and saved observations. Only load trusted RDS
files. They allow analysis and replotting without another model call. The exact
[executed recipe](recorded/executed-recipe.R) retains host paths as provenance;
use the portable `run.R` for a new study instead.

`recorded/render-recorded-evidence.R` is the original model-free producer of the
response-review image and manual annotations. Those annotations describe this
fixed corpus only; do not use them as a scorer for new responses. It retains the
original host output path, as does the executed study source.

## Adapt the recipe to your own question

The portable [run.R](run.R) places all prompt strings and fixed generation
settings at the top. Read it before running. To adapt just the research question,
edit the prompt **texts**, preserving IDs, row order, split labels and pair roles.
Keep the two construction pairs,
reserved selection prompt and two evaluation formulations distinct. No selection
is performed here: the coefficient is fixed at 1 before generation. The required
selection manifest row remains reserved and unexecuted.

This is not a general settings runner. CPU and context 512 are fixed in the load
call, and no `stop` argument is passed to generation; changing those fields in
the metadata list alone would misdescribe the run. Keep the supplied settings,
48-token bound, layer and coefficient for this recipe. A different experiment
design must update the corresponding calls and provenance together.

The recorded configuration uses **relm 0.4.0 from release commit `3bd5da7`**, R ≥ 4.5,
existing `later >= 1.4.8` and `promises >= 1.5.0`, and the pinned
Qwen2.5-0.5B-Instruct Q8_0 GGUF. The script checks those identities before loading.
It deliberately does not install packages or download models.

Run the script with `Rscript --vanilla` in a background process, or as an RStudio
background job without workspace import/export. Set these environment variables
for that process:

| Variable | Value |
| --- | --- |
| `MODEL_PATH` | Required: your existing pinned Qwen GGUF file |
| `RELM_LIBRARY` | Optional: the library containing the intended relm installation |
| `OUTPUT_DIR` | A new directory, whose parent exists; default `research-onboarding-output` |

For example, from the repository root on macOS/Linux, replace the model path and
choose a new output name. This launch template runs in the background and retains
console output; it is not another recorded execution of the study:

```sh
MODEL_PATH="/absolute/path/to/qwen2.5-0.5b-instruct-q8_0.gguf" \
OUTPUT_DIR="my-study" \
Rscript --vanilla examples/research-first-use/run.R > my-study.log 2>&1 &
```

Inspect `my-study/STATUS.txt` and `my-study.log` after completion. Do not run this
command just to see the results already provided in `recorded/`.

Do not edit the expected model/source identities just to bypass a failed check.
For another package build or model, first review and update the study's provenance
and compatibility assumptions. The recipe is intentionally pinned, not a generic
experiment framework.

The portable variant changes configuration placement and filesystem selection
only. Its prompt/settings objects and experiment body were checked against the
executed source; it was parsed but not replayed. Original observations remain the
evidence, not a claim of another executed run.

## What the script records

- Original, zero and fixed-addition outputs for both formulations; no tuning.
- Prompt text/hashes, settings, traces, the recorded direction and first/last states.
- Token events, actual `prompt_end` finish reasons and sampled-state counts.
- Two 896-coordinate comparisons, configured-model and coefficient-history plots.
- The expected classed refusal when ordinary tracing is requested on an intervened
  handle, warnings, timings and explicit cleanup.

It requests cancellation if generation exceeds its watchdog; this is not an
operating-system timeout or memory guarantee. It refuses to reuse an existing
output directory and preserves partial files on failure. Inspect those files
before changing or rerunning a failed experiment.

This is a usability exercise on one question with two hand-written construction
pairs. It neither tests all relm capabilities nor establishes an effective
uncertainty direction. See the [API guide](../../docs/research-guide.md) for the
difference between prompt traces, live states and interpretation of plots.
