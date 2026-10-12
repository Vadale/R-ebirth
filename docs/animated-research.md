# relm in motion

Two short animations show what the package lets you observe and compare. Every
plotted value comes from the recorded [first-use study](research-first-use.md).
The plots use base R; the animation rendering loads no model and performs no
inference. They are narrated data replays, not recordings of an RStudio session.

## 1. Measure an intervention inside the model

![Recorded layer-12 activations, exact zero control and residual-addition differences, with first-state next-token probabilities.](media/research/activation-intervention.gif)

[MP4 video](media/research/activation-intervention.mp4) ·
[Static view, without motion](media/research/activation-intervention.png)

The sequence uses the first live state from the direct envelope question:

1. **Observe:** show all 896 residual coordinates at layer 12.
2. **Control:** a derived handle with addition coefficient zero has exactly the
   same recorded trace, first-state logits, generated text and sampled token IDs
   as the original in this run.
3. **Intervene:** show a fixed coefficient of one, then the difference from the
   original. The values come from the saved `llm_compare()` table; the prompt,
   captured position and preceding generated-token prefix match.

Coordinates appear in index order, with no selection of dramatic neurons and no
interpolation between coefficients. The vertical scales stay fixed across all
three scenes. The lower panel has its own labelled scale so the smaller changes
remain visible; it is not on the activation panel's scale.

The right panel shows the recorded top-five next-token probabilities at that
same first state. These are model probabilities, **not confidence that an answer
is true**. They do not sum to one because the other vocabulary entries are not
shown. Both conditions actually sampled the same first token, ` New`, under
greedy generation. Later states are not substituted for this aligned comparison.

## 2. Follow token events and compare outputs

![Recorded text and cumulative character counts across two generations, with a marker at their first token divergence.](media/research/token-stream.gif)

[MP4 video](media/research/token-stream.mp4) ·
[Static view, without motion](media/research/token-stream.png)

Each frame advances through saved `on_token` events. The text panels preserve
both full responses, including newlines and the unfinished ending at the token
cap. The graph counts committed text characters against sampled-token position.
The original finishes at 33 tokens; addition reaches the fixed 48-token limit.
The zero condition exactly duplicates the original and is identified rather than
drawn as another overlapping line.

The runs share three sampled tokens and diverge at the fourth. They were recorded
**separately**. Equal token positions after divergence do not imply equal input
histories, and the animation makes no same-input activation comparison there.
Playback uses six display frames per second with opening/closing holds; it is
deliberately slower than the recorded generation and is not a latency benchmark.
Original elapsed times remain in the saved events.

The prompt supplies no city information. Both responses invent missing facts.
That failure is part of the demonstration: inspecting an intervention is useful
even when it does not improve the answer. These two conditions do not establish
general effectiveness, model quality, safety or debiasing.

## Reproduce the pictures without rerunning the experiment

From a clone of the repository, with R and an existing `ffmpeg` executable:

```sh
Rscript --vanilla examples/animated-research/render.R
```

This reads the committed RDS records, verifies alignment, zero-control identity,
coordinate differences and the token/text event order, then makes PNG frames,
GIFs and silent MP4s. It does not load relm, download a model or regenerate the
research results. Base R is the only R requirement; ffmpeg is a maintainer media
tool, not a relm dependency. An optional first argument changes the output folder.

- [Rendering source](../examples/animated-research/render.R)
- [Original collection recipe](../examples/research-first-use/recorded/executed-recipe.R)
- [Saved results](../examples/research-first-use/recorded/all-results.rds) and
  [aligned comparison](../examples/research-first-use/recorded/direct-comparison.rds)
- [Plot coordinates](media/research/activation-values.csv) and
  [text/character-count sequence](media/research/stream-values.csv)
- [Media provenance and checksums](media/research/manifest.json)

The on-screen calls are abbreviated excerpts; use the linked collection recipe
for the required model metadata, callbacks and provenance. The renderer handles
the observed one-token/one-text event alternation in this saved run and refuses a
different pattern rather than inventing a mapping. It is not a generic stream
collector or a new package API.

Recorded environment: relm 0.4.0, source `3bd5da7`, cached
Qwen2.5-0.5B-Instruct Q8_0, CPU, context 512, raw completion, seed 3107,
temperature zero, top-p 0.95, maximum 48 tokens. The direction was constructed
from two separate pairs with a fixed coefficient; there was no retuning.
The R 4.5.3-build/4.5.1-host warning remains in the original study. See its
[full provenance and limitations](research-first-use.md).
