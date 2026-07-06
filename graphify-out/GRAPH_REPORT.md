# Graph Report - .  (2026-07-06)

## Corpus Check
- Large corpus: 386 files · ~986,705 words. Semantic extraction will be expensive (many Claude tokens). Consider running on a subfolder.

## Summary
- 252 nodes · 536 edges · 13 communities (12 shown, 1 thin omitted)
- Extraction: 97% EXTRACTED · 3% INFERRED · 0% AMBIGUOUS · INFERRED: 14 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Errors, Chat Templates & Sampling|Errors, Chat Templates & Sampling]]
- [[_COMMUNITY_Backend & Context Lifecycle|Backend & Context Lifecycle]]
- [[_COMMUNITY_R Boundary (extendr)|R Boundary (extendr)]]
- [[_COMMUNITY_Numpy Correctness Oracle|Numpy Correctness Oracle]]
- [[_COMMUNITY_Model Handle & llama.cpp FFI Types|Model Handle & llama.cpp FFI Types]]
- [[_COMMUNITY_Generation Golden Test|Generation Golden Test]]
- [[_COMMUNITY_Batch Decode Plumbing|Batch Decode Plumbing]]
- [[_COMMUNITY_Backend Capabilities|Backend Capabilities]]
- [[_COMMUNITY_Logit Oracle Test|Logit Oracle Test]]
- [[_COMMUNITY_Build Pipeline|Build Pipeline]]
- [[_COMMUNITY_extendr Doc Binary|extendr Doc Binary]]
- [[_COMMUNITY_Error Display|Error Display]]

## God Nodes (most connected - your core abstractions)
1. `RebirthError` - 29 edges
2. `LoadedModel` - 16 edges
3. `Model` - 15 edges
4. `load()` - 14 edges
5. `check_goldens()` - 12 edges
6. `LoadedModel` - 11 edges
7. `build_weights()` - 11 edges
8. `Context` - 10 edges
9. `apply_template()` - 10 edges
10. `forward()` - 10 edges

## Surprising Connections (you probably didn't know these)
- `load_synthetic()` --calls--> `load()`  [INFERRED]
  rebirth/src/rust/rebirth-llm/tests/synthetic_generate.rs → rebirth/src/rust/rebirth-llm/src/engine.rs
- `engine_logits_match_numpy_oracle_within_tolerance()` --calls--> `load()`  [INFERRED]
  rebirth/src/rust/rebirth-llm/tests/synthetic_logits.rs → rebirth/src/rust/rebirth-llm/src/engine.rs
- `ok_payload()` --references--> `ModelMetadata`  [EXTRACTED]
  rebirth/src/rust/rebirth-ffi/src/lib.rs → rebirth/src/rust/rebirth-llm/src/engine.rs
- `error_fields()` --references--> `RebirthError`  [EXTRACTED]
  rebirth/src/rust/rebirth-ffi/src/lib.rs → rebirth/src/rust/rebirth-llm/src/error.rs
- `error_payload()` --references--> `RebirthError`  [EXTRACTED]
  rebirth/src/rust/rebirth-ffi/src/lib.rs → rebirth/src/rust/rebirth-llm/src/error.rs

## Import Cycles
- None detected.

## Communities (13 total, 1 thin omitted)

### Community 0 - "Errors, Chat Templates & Sampling"
Cohesion: 0.11
Nodes (25): Display, Into, RebirthError, Error, String, apply_template(), apply_template_formats_chatml(), apply_template_rejects_an_unsupported_template() (+17 more)

### Community 1 - "Backend & Context Lifecycle"
Cohesion: 0.08
Nodes (32): Arc, Clone, MutexGuard, NonNull, available_backends(), Backend, BackendKind, Context (+24 more)

### Community 2 - "R Boundary (extendr)"
Cohesion: 0.12
Nodes (31): Any, F, error_fields(), error_payload(), from_engine_token(), LlmHandle, ok_payload(), panic_payload() (+23 more)

### Community 3 - "Numpy Correctness Oracle"
Cohesion: 0.13
Nodes (33): main(), check_goldens(), compute_logits(), _files_equal(), forward(), gguf_weights_match_source(), greedy_continuation(), greedy_tokens() (+25 more)

### Community 4 - "Model Handle & llama.cpp FFI Types"
Cohesion: 0.17
Nodes (10): LoadedModel, llama_chat_message, llama_context, llama_context_params, llama_model, llama_model_params, llama_vocab, c_char (+2 more)

### Community 5 - "Generation Golden Test"
Cohesion: 0.35
Nodes (11): greedy_generation_matches_numpy_golden(), greedy_golden_csv(), load_synthetic(), max_tokens_zero_yields_an_empty_generation(), read_greedy_golden(), repo_root(), LoadedModel, PathBuf (+3 more)

### Community 6 - "Batch Decode Plumbing"
Cohesion: 0.18
Nodes (9): FnMut, llama_pos, llama_seq_id, llama_token, llama_batch, Batch, Drop, T (+1 more)

### Community 7 - "Backend Capabilities"
Cohesion: 0.33
Nodes (8): backend_free(), backend_init(), backend_initializes_and_reports_system_info(), max_devices(), String, supports_mlock(), supports_mmap(), system_info()

### Community 8 - "Logit Oracle Test"
Cohesion: 0.40
Nodes (7): engine_logits_match_numpy_oracle_within_tolerance(), golden_logits_csv(), read_golden_csv(), repo_root(), PathBuf, Vec, synthetic_gguf()

### Community 9 - "Build Pipeline"
Cohesion: 0.46
Nodes (7): Path, emit_link_flags(), find_file(), main(), profile_target_dir(), Option, PathBuf

### Community 10 - "extendr Doc Binary"
Cohesion: 0.40
Nodes (4): main(), Box, Error, Result

## Knowledge Gaps
- **1 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `RebirthError` connect `Errors, Chat Templates & Sampling` to `Backend & Context Lifecycle`, `R Boundary (extendr)`, `Error Display`?**
  _High betweenness centrality (0.340) - this node is a cross-community bridge._
- **Why does `load()` connect `Backend & Context Lifecycle` to `Errors, Chat Templates & Sampling`, `Logit Oracle Test`, `Model Handle & llama.cpp FFI Types`, `Generation Golden Test`?**
  _High betweenness centrality (0.170) - this node is a cross-community bridge._
- **Why does `load_synthetic()` connect `Generation Golden Test` to `Backend & Context Lifecycle`?**
  _High betweenness centrality (0.067) - this node is a cross-community bridge._
- **What connects `NORM-mode RoPE, matching ggml rotate_pairs(scale=1) + rope_cache_init.      x: (`, `Return logits of shape (seq_len, n_vocab), float64.`, `Autoregressive greedy decode: forward -> argmax -> append -> repeat.      Return` to the rest of the system?**
  _8 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Errors, Chat Templates & Sampling` be split into smaller, more focused modules?**
  _Cohesion score 0.11450980392156863 - nodes in this community are weakly interconnected._
- **Should `Backend & Context Lifecycle` be split into smaller, more focused modules?**
  _Cohesion score 0.07591836734693877 - nodes in this community are weakly interconnected._
- **Should `R Boundary (extendr)` be split into smaller, more focused modules?**
  _Cohesion score 0.11711711711711711 - nodes in this community are weakly interconnected._