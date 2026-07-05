#!/usr/bin/env python3
"""Write the committed synthetic 2-layer llama GGUF.

Produces ``synthetic-llama-2l.gguf`` next to this script: a tiny, valid,
download-free ``llama``-architecture model with F32 weights, deterministically
seeded from ``synthetic_model.CONFIG``. llama.cpp b9726 loads it and
``rebirth::llm()`` reports its dimensions.

The tokenizer is ``no_vocab`` (LLAMA_VOCAB_TYPE_NONE): the model carries no real
tokenizer because the goldens are computed on raw token ids. ``vocab_size`` is
still published so llama.cpp sizes the embedding/output tensors and reports the
tiny vocabulary in summary().

Usage (from the pinned golden venv, see ../requirements.txt):

    python build_synthetic.py

Regeneration is governed solely by the ``golden-update`` skill; never hand-edit
the produced GGUF.
"""

from __future__ import annotations

import os
import shutil

import gguf

from synthetic_model import (
    CONFIG,
    build_weights,
    canonical_gguf_path,
    head_dim,
    package_fixture_path,
)

# general.file_type == 0 is ALL_F32 in llama_ftype at b9726 (mirrored by the
# ftype_name() table in rebirth-llm/src/engine.rs -> reported as "F32").
GGML_FTYPE_ALL_F32 = 0


def main() -> None:
    out_path = canonical_gguf_path()
    arch = str(CONFIG["arch"])

    writer = gguf.GGUFWriter(out_path, arch)

    # --- identification ---
    writer.add_name(str(CONFIG["name"]))
    writer.add_file_type(GGML_FTYPE_ALL_F32)

    # --- llama hyper-parameters (the keys llama.cpp b9726 reads for LLM_ARCH_LLAMA) ---
    writer.add_context_length(int(CONFIG["n_ctx_train"]))
    writer.add_embedding_length(int(CONFIG["n_embd"]))
    writer.add_block_count(int(CONFIG["n_layer"]))
    writer.add_feed_forward_length(int(CONFIG["n_ff"]))
    writer.add_head_count(int(CONFIG["n_head"]))
    writer.add_head_count_kv(int(CONFIG["n_head_kv"]))
    writer.add_key_length(head_dim())
    writer.add_value_length(head_dim())
    writer.add_rope_dimension_count(head_dim())
    writer.add_rope_freq_base(float(CONFIG["rope_freq_base"]))
    writer.add_layer_norm_rms_eps(float(CONFIG["rms_eps"]))
    writer.add_vocab_size(int(CONFIG["n_vocab"]))

    # --- tokenizer: none; goldens use raw token ids ---
    writer.add_tokenizer_model("no_vocab")

    # --- weights (F32, canonical (out, in) layout) ---
    for name, tensor in build_weights().items():
        writer.add_tensor(name, tensor)

    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_tensors_to_file()
    writer.close()

    size = os.path.getsize(out_path)
    print(f"wrote {out_path} ({size} bytes, {size / 1024:.1f} KiB)")
    if size > 2 * 1024 * 1024:
        raise SystemExit(f"GGUF exceeds the 2 MB budget: {size} bytes")

    # Ship a byte-identical copy as the R package test fixture so the testthat
    # load test can reach the model from inside the R CMD check tarball (the
    # repo-root copy lives outside the package). reference_forward.py --check
    # enforces the two stay identical.
    fixture = package_fixture_path()
    os.makedirs(os.path.dirname(fixture), exist_ok=True)
    shutil.copyfile(out_path, fixture)
    print(f"copied to package fixture {fixture}")


if __name__ == "__main__":
    main()
