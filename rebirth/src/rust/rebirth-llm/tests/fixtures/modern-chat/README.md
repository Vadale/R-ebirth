# Modern single-user chat references (D-054)

The five source templates are immutable inputs, not a generic Jinja runtime.

| File | Upstream source and revision | SHA-256 |
| --- | --- | --- |
| `qwen35-author.jinja` | [Qwen/Qwen3.5-9B](https://huggingface.co/Qwen/Qwen3.5-9B/blob/c202236235762e1c871ad0ccb60c8ee5ba337b9a/chat_template.jinja), `c202236235762e1c871ad0ccb60c8ee5ba337b9a` | `a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715` |
| `qwen35-gguf.jinja` | Decoded `tokenizer.chat_template` from [Unsloth Q4_K_M GGUF](https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/tree/3885219b6810b007914f3a7950a8d1b469d598a5), `3885219b6810b007914f3a7950a8d1b469d598a5` | `7f0e529032c25183bcd66c7f238da2d377f43be754a94e2725a58c4e16d2ed67` |
| `gemma4.jinja` | [google/gemma-4-12B-it](https://huggingface.co/google/gemma-4-12B-it/blob/707f0a3b8a3c7ad586ed01e27eafbad8a27dd0f7/chat_template.jinja), `707f0a3b8a3c7ad586ed01e27eafbad8a27dd0f7` | `ae53464bf3be25802b3a5b37def7fd89667067d7577049b3b2d74c4d8de4c6d4` |
| `qwen38-gguf.jinja` | Decoded `tokenizer.chat_template` from [Unsloth UD-IQ3_XXS GGUF](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/tree/4ca720788d1e01f1bff70c033e0d0028fd02e502), `4ca720788d1e01f1bff70c033e0d0028fd02e502` | `12827f24b742ea4e80cdc12dbcf9622227056b9f797252a3149263d4f9aaadce` |

The Gemma source equals the template embedded in ggml-org's Q4_0 GGUF at
`a29b2a6b584a5bdcb672ccdcda99ea9faeacc51a`. Qwen's converter template differs
from its author's source, including its default thinking mode; both are kept
separately. Source contents and upstream comments are preserved verbatim.
Attribution: Qwen/Alibaba, Unsloth and Google. The source model
repositories declare Apache-2.0; a copy of that license is included here and
attribution is also installed in THIRD-PARTY-NOTICES.

`render-fixtures.py` uses Jinja2 3.1.6's ImmutableSandboxedEnvironment to render
the existing 72 combinations plus 24 separate Qwen3.8 cases: six prompts,
generation opener on/off and ordinary/schema mode. Ordinary mode leaves `enable_thinking` unspecified;
schema mode sets it to false. Template hashes and output hashes are recorded
in `single-user-turn.json` and `qwen38-single-user-turn.json`. The original
72 reference bytes are unchanged. Qwen3.8 ordinary mode includes the source
`xhigh` reasoning system turn even without an assistant opener; non-thinking
mode omits that system turn entirely. The Rust tests compare exact UTF-8 bytes
without requiring Python, models or downloads in ordinary CI.

Maintainer-only reference verification, using an existing Jinja2 3.1.6 environment:

```sh
python rebirth/src/rust/rebirth-llm/tests/fixtures/modern-chat/render-fixtures.py
python rebirth/src/rust/rebirth-llm/tests/fixtures/modern-chat/render-fixtures.py --qwen38
```

`--write` creates these new references directly from the pinned Jinja sources;
changing an established oracle requires the project's golden-update approval.
Jinja2 is not a package/runtime dependency. These are text-format references,
not numerical model goldens or proof that a GGUF loads. Gemma's BOS is explicit;
Qwen's format has none. Both retain the shared special-token parsing and
batch-decoding path. Actual tokenizer/model/backend behavior requires separate
installed-model evidence.


The separate `qwen35-moe-gguf.jinja` source is decoded from the
[Unsloth Qwen3.5-35B-A3B UD-Q2_K_XL GGUF](https://huggingface.co/unsloth/Qwen3.5-35B-A3B-GGUF/tree/bc014a17be43adabd7066b7a86075ff935c6a4e2).
Its SHA-256 is `e60df41481b6ad20571cda7e2e1290cfee25670f1b50973f74576c9354c66336`.
Its ordinary single-user default enables thinking, whereas the dense Qwen3.5
converter source above disables it. Both explicitly disable thinking for schema
output. `render-fixtures.py --qwen35-moe` verifies 24 additional cases stored in
`qwen35-moe-single-user-turn.json`; previous reference bytes remain unchanged.
Full template recognition and a `qwen35moe` name do not certify a particular
quantized model's installation, resource fit, throughput or numerical quality.
