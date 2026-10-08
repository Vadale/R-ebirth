# Spark single-user-turn chat fixtures

These model-free reference artifacts pin the narrow D-032 formatter to the
author's two exact template spellings at source-model revision
`0bcb35678590218655dff3765b9e61c83b35e9c4`:

- [`chat_template.jinja`](https://huggingface.co/XHToken/Spark-X2.5-4B/blob/0bcb35678590218655dff3765b9e61c83b35e9c4/chat_template.jinja),
  preserved verbatim, including its upstream comments and trailing newline.
- The `chat_template` string in
  [`tokenizer_config.json`](https://huggingface.co/XHToken/Spark-X2.5-4B/blob/0bcb35678590218655dff3765b9e61c83b35e9c4/tokenizer_config.json),
  decoded from JSON and stored as `tokenizer-chat-template.jinja` without an
  invented trailing newline.

Both source templates produce identical single-user-turn bytes. The downloaded
D-032 GGUF embeds the first spelling exactly. Runtime recognition compares the
complete source text; it does not infer a format from a model name or a few
marker substrings. Other Spark templates and message sequences are unsupported.
The source hashes are checked by `render-fixtures.py` and recorded alongside
each rendered fixture's SHA256 in `single-user-turn.json`.

The original source model and its template are Apache-2.0 licensed; attribution
is to XHToken. Existing upstream comments are preserved as source evidence.

Run the independent reference check from the repository root:

```sh
uv run --no-project --with 'jinja2==3.1.6' python \
  rebirth/src/rust/rebirth-llm/tests/fixtures/spark/render-fixtures.py
```

`--write` regenerates the committed reference bytes directly from those pinned
Jinja sources. Jinja2 is a development oracle, not a relm package or runtime
dependency. Rust's ordinary PR tests compare the formatter with the committed
bytes and require no Python, model or download.

Ordinary chat leaves `enable_thinking` unspecified, exercising the author's
default `true`; schema chat renders with `enable_thinking=false`. The expected
openers are `<think>` and `</think>` respectively. There is no output stripping
or repair. The default system text is lowercase and has a single preceding LF.
The official format places a start-of-sentence marker at each turn boundary
(three with the generation opener). `add_special=false` prevents the tokenizer
from prepending an extra BOS marker; `parse_special=true` recognizes the markers
already in the rendered bytes. Actual token IDs require the model-gated Spark
integration check in addition to these byte fixtures.
