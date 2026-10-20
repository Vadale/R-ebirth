# Modern single-user chat references (D-054)

The three source templates are immutable inputs, not a generic Jinja runtime.

| File | Upstream source and revision | SHA-256 |
| --- | --- | --- |
| `qwen35-author.jinja` | [Qwen/Qwen3.5-9B](https://huggingface.co/Qwen/Qwen3.5-9B/blob/c202236235762e1c871ad0ccb60c8ee5ba337b9a/chat_template.jinja), `c202236235762e1c871ad0ccb60c8ee5ba337b9a` | `a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715` |
| `qwen35-gguf.jinja` | Decoded `tokenizer.chat_template` from [Unsloth Q4_K_M GGUF](https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/tree/3885219b6810b007914f3a7950a8d1b469d598a5), `3885219b6810b007914f3a7950a8d1b469d598a5` | `7f0e529032c25183bcd66c7f238da2d377f43be754a94e2725a58c4e16d2ed67` |
| `gemma4.jinja` | [google/gemma-4-12B-it](https://huggingface.co/google/gemma-4-12B-it/blob/707f0a3b8a3c7ad586ed01e27eafbad8a27dd0f7/chat_template.jinja), `707f0a3b8a3c7ad586ed01e27eafbad8a27dd0f7` | `ae53464bf3be25802b3a5b37def7fd89667067d7577049b3b2d74c4d8de4c6d4` |

The Gemma source equals the template embedded in ggml-org's Q4_0 GGUF at
`a29b2a6b584a5bdcb672ccdcda99ea9faeacc51a`. Qwen's converter template differs
from its author's source, including its default thinking mode; both are kept
separately. Source contents and upstream comments are preserved verbatim.
Attribution: Qwen/Alibaba, Unsloth and Google respectively. The source model
repositories declare Apache-2.0; a copy of that license is included here and
attribution is also installed in THIRD-PARTY-NOTICES.

`render-fixtures.py` uses Jinja2 3.1.6's ImmutableSandboxedEnvironment to render
72 combinations: three sources, six prompts, generation opener on/off and
ordinary/schema mode. Ordinary mode leaves `enable_thinking` unspecified;
schema mode sets it to false. Template hashes and output hashes are recorded
in `single-user-turn.json`. The Rust tests compare exact UTF-8 bytes, without
requiring Python, models or downloads in ordinary CI.

Maintainer-only reference verification, using an existing Jinja2 3.1.6 environment:

```sh
python rebirth/src/rust/rebirth-llm/tests/fixtures/modern-chat/render-fixtures.py
```

`--write` creates these new references directly from the pinned Jinja sources;
changing an established oracle requires the project's golden-update approval.
Jinja2 is not a package/runtime dependency. These are text-format references,
not numerical model goldens or proof that a GGUF loads. Gemma's BOS is explicit;
Qwen's format has none. Both retain the shared special-token parsing and
batch-decoding path. Actual tokenizer/model/backend behavior requires separate
installed-model evidence.
