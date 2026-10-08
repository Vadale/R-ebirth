# F6e instrumented run 37773468792: partial acceptance, original failure retained

Exact source: e2081b43ebc7108c7bdc7b96fc2203b679d222a7.
ASan/UBSan executed both selected tests (23 cases, 11 refusals, 291 comparison
values). Separate baseline Memcheck executed the default constructor test
(13 cases, 9 refusals, 288 values), with no XML errors or applied suppressions.
These passed scopes were independently recovered from raw source bindings,
commands, compiler/object/runtime evidence and exact named execution receipts.

The remaining Memcheck worker did not execute. Valgrind rejected its XML output
argument before loading the test binary: the portable test label contains
`%3A`, which Valgrind parses as its output-name format syntax. Standard output
is empty and no XML exists. This is a harness argument failure, not a successful
worker execution or a Memcheck defect finding. The complete job remains failed.

Correct only percent escaping in the XML filename argument, exercise a literal
percent-containing output name in the next real runtime control, and execute
only the missing/affected scope. Preserve the passed original scopes; do not
repeat both old sanitizer tests or the passed Memcheck constructor. Product
review fixes have separate current-source tests and cannot inherit this run as
if they were present at e2081b4.

Raw text evidence is retained compressed. Compiled probe binaries/objects remain
local with explicit path/hash inventory; no compiled binary is committed. The
owner inspector's initial Arrow crate-name assumption is retained separately
and corrected against the pinned source/raw archive records. No native/model
execution was repeated by owner verification. No R/SEXP, GPU, universal UB, new
golden accuracy or later-source execution is claimed.
