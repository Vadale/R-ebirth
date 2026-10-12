# Animated research figures

`render.R` creates the two [public animations](../../docs/animated-research.md)
from the committed D049 observations. It uses base R and an existing ffmpeg
executable. It never loads relm or runs a model.

Run from the repository root:

```sh
Rscript --vanilla examples/animated-research/render.R
```

Outputs go to `docs/media/research`, or to the first command-line argument.
The optional second argument selects `activation`, `stream`, or `all` (default).
The script preserves every displayed coordinate and both full responses, checks
the actual token/text event order and uses fixed axes. The GIF/MP4 playback
schedule is a presentation choice, not a record of wall-clock inference speed.
Static PNGs offer the same final figures without animation.

The original collection recipe and data stay in
[`research-first-use/recorded`](../research-first-use/recorded). Do not rerun that
experiment or retune its outputs to reproduce these media.
