# WP10 stable text decoder

Status: implemented on `codex/token-streaming`; execution results belong in the
WP10 implementation/validation record. This note is a proof and test inventory,
not a claim that the integrated native suite has run.

## Authority and source pin

Ordinary final text remains `LoadedModel::decode_tokens(ids, false, false)`,
which calls whole-vector `llama_detokenize` and Rust's lossy UTF-8 conversion.
The existing snapshot stop check still precedes streaming publication. Structured
final text remains `Constraint::complete`: raw `special=false` token bytes,
independent schema validation, then strict UTF-8. Sampling and context checks
keep their previous order.

The reviewed implementation is vendored llama.cpp b10828,
`3ad1ba7336986d98592d3e28cafd1a406715351f`, in
`rebirth/src/llama.cpp/src/llama-vocab.cpp`. The native test compares the exact
current detokenizer body with
`rebirth/src/rust/rebirth-llm/tests/fixtures/stream/b10828-detokenize.txt`.
That fixture's SHA256 is
`3f29e80d292ab8892ecba6ee6df74755f25ac397a8d87e81cc3f2f6fcf05606a`.
A vendor change fails this gate and requires revalidating the correspondence
below; merely changing the pin is not a validation. No vendor source is edited.

The relm-owned bridge reads the live vocabulary's `add_space_prefix` and
`clean_spaces` switches. Each ordinary token uses the same native
`llama_token_to_piece(..., special=false)` call as detokenization. `lstrip=1`
is used only for the first token if `add_space_prefix` is set. An empty first
piece still consumes that flag, exactly as the pinned whole-vector loop does.
The `remove_special=false` authority never skips a first/last token itself;
special-token suppression happens inside the shared token-piece function.

## Exact bounded cleanup

The implementation uses three separate left-to-right rewrite transducers.
These are the actual transformations in the pinned passes:

| Pass | Input pattern | Output | Maximum retained proper prefix |
|---|---|---|---|
| 1 | space followed by `?`, `!`, `.`, or `,` | punctuation | 1 byte |
| 2 | space, apostrophe, space | apostrophe | 2 bytes |
| 3 | space followed by `'s`, `'m`, `'re`, or `'ve` | contraction without initial space | 3 bytes |

Native `'t`, `'d` and `'ll` branches deliberately do nothing, so they are not
rewrite patterns. The original in-place loops retain the previous **input**
character for their predicates: output writes never advance ahead of the scan.
After a deletion the next iteration's previous-input position is still intact.
Pass 2 explicitly consumes its following space, writes NUL there, and advances
past it; this prevents that consumed space from participating in the next match.
It is exactly the non-overlapping consumption used by the second transducer.
Output is never rescanned by the same pass. It is scanned once by the next pass.

For each pass, maintain the following invariant after every input byte:

1. Forwarded output equals completed non-overlapping rewrites of the consumed
   input, in the original order.
2. Pending bytes are empty or a proper prefix of at least one of that pass's
   finite patterns.
3. No forwarded byte can belong to a match completed by any future input.

Appending one byte preserves the invariant: a complete pattern is replaced;
a proper prefix remains pending; otherwise the first pending byte cannot begin
any pattern and is forwarded, repeating on the rest. These alternatives are
exhaustive. Pattern lengths bound pending input at 1, 2 and 3 bytes. At EOF,
unmatched pending bytes are literal output. Applying the induction to each pass
in order proves the composed forwarded output is an immutable prefix of the
native cleanup for **every** future byte suffix, not only the next token.
Empty pieces do nothing. The composition retains at most six bytes across its
stages; it does not guess a six-byte suffix of an already-cleaned snapshot.
One incoming byte can release at most those six bytes plus itself, fitting the
fixed eight-byte forwarding buffer.

## UTF-8, stops and terminal authority

Only irrevocable cleaned bytes reach incremental UTF-8 conversion. When Rust's
UTF-8 parser reports a definite invalid subsequence (`error_len=Some`), lossy
conversion emits the same single U+FFFD as the existing authority. When it
reports an incomplete suffix (`error_len=None`), at most three bytes remain
pending. A future byte can change only this incomplete suffix. Structured
streaming skips cleanup and rejects a definite invalid subsequence instead of
replacing it. Embedded NUL rejects with `relm_error_stream(reason="encoding")`.

At construction, the stream records `max(stop byte lengths) - 1`, with zero for
an empty collection or only empty strings. After each unchanged full-snapshot
stop check finds no stop, it withholds that many bytes of valid text, rounded
backward to a UTF-8 character boundary. Any newly completed stop crossing the
current boundary must begin within its own byte length minus one, so this
conservative maximum protects every stop. The immutable cleanup prefix may end
before the current full snapshot; applying the same suffix rule at that earlier
boundary is also conservative. A stop caused by a **provisional** U+FFFD is still
recognized by the ordinary snapshot before publication; streaming does not
change its timing.

The bound is computed once by reading string lengths. Each later publication
uses subtraction and at most three UTF-8 continuation-byte checks, independent
of text length, stop length, matching prefixes or number of stops. It allocates
no matcher table. This replaces suffix-by-suffix matching, which could require
quadratic work on legal long near-matches. A long stop may delay text until
termination if the generated output is shorter than the holdback; token events
continue normally. Empty stops impose no delay. The ordinary full-snapshot
`first_stop` authority and its cancellation checkpoints remain unchanged.

At successful termination, the unchanged authoritative final text must start
with all already-published text byte-for-byte. Otherwise the stream rejects with
`reason="invariant"`. The remainder of that authority is the final delta,
including any terminal lossy replacement or pending cleanup/stop suffix. The
decoder never silently repairs a previously published prefix. It can publish
ordinary text during generation, as the pre-terminal fixture asserts.

## Storage and event order

Opt-out generation allocates no `TextStream`, reads no decoder flags and extracts
no extra token piece. Opt-in keeps one prefix `String`, with exact reserve calls
and length/capacity bounded by the current prompt's remaining async output
budget (at most 8 MiB). That string includes the withheld stop suffix and the
already-sent bytes needed by the terminal assertion. Stop strings are inspected
at construction and are neither retained nor cloned; one `usize` stores the
holdback. Three cleanup stages and UTF-8 carry fixed state under 1 KiB.

An ordinary current token piece has an exact capacity at most the same 8 MiB
limit. It is freed before the next sampling step. Existing authoritative snapshot
replacement can temporarily retain old text, its native byte buffer and the new
lossy string; the existing stop path can clone one snapshot. These lifetimes,
the additional prefix and current piece, and the much smaller structured bytes
fit the transport's conservative decoder allowance of eight 8 MiB buffers.
This allowance is distinct from final result/input budgets, queue descriptors,
queued/drained payload, one producer chunk, R materialization and CSV buffers.
It is not a process RSS or model/backend allocation guarantee.

A sampled non-EOG token is appended to `Generation.tokens` before its token
event. The event precedes every text delta made publishable by that token.
Stop-suffix and context-full sampled tokens therefore remain in the stream.
Successful final text is emitted before the owner emits `prompt_end`; structured
generation emits that end only after independent validation and prompt-budget
accounting. Native failures never produce a successful end for their prompt.

## Download-free checks

`text_stream::tests` runs in the ordinary native PR job. It writes a tiny
vocabulary-only GGUF into a temporary file, loads the actual native vocabulary,
and calls the actual pinned `llama_detokenize`; no inference weights are needed.

- All 960,800 words of length at most seven over seven interacting byte classes
  compare transducer output and every emitted prefix with the actual decoder.
  Equivalent concrete punctuation/contraction bytes have separate fixtures.
- Adversarial runs cover repeated spaces/apostrophes, every transformed and
  deliberately unchanged contraction, both leading-space settings, special and
  user-defined tokens, empty pieces inserted at every token boundary, and zero
  text.
- Every non-NUL byte pair and targeted longer sequences compare incremental
  UTF-8 prefixes with Rust's existing lossy conversion. Native fixtures include
  split Unicode and malformed/incomplete sequences.
- Overlapping stops, multibyte stops, removed cleanup spaces and provisional
  U+FFFD stops assert final equality and the exact token at which stopping occurs.
- An 8 MiB all-`a` prefix against `a^(4 MiB) + b + a^(4 MiB)` exercises the
  former quadratic near-match case at the real output limit. Separate fixtures
  check UTF-8 rounding and empty-stop behavior without timing-based thresholds.
- Structured raw spacing, encoding/invariant conditions, fixed-state size,
  allocation capacity bounds and text publication before finish are explicit
  assertions. Transport fixtures separately check actual sampled-token parity
  and context exhaustion on the in-repo synthetic model.
