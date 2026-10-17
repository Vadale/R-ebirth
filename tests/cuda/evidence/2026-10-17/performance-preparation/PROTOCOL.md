# WP13 performance profiling — frozen before execution

One diagnostic pass on the accepted production CUDA DLL
8bf2d82f337262386b54ed89ab77f18da15b3a0dd0e819b1ce1435fa535b24a5.
Use cached Qwen2.5-0.5B Q8_0 ca59ca7f13d0e15a8cfa77bd17e65d24f6844b554a7b6c12e07a5f89ff76844e,
CUDA full offload, context512, max128, temperature0, top_p.95, seed8001,
raw text, no custom stops/images/schema. The exact new seed-library prompt is in
profile.R; actual prompt token IDs are saved from one tokenizer call, not inferred
from output text. Reject an input exceeding the fixed context/output budget.

Fixed order: one cold model load; prompt tokenization; plain async/token-stream
generation; one filtered last-position layer12 residual+MLP trace; one static MLP
projection constructor (coefficient1, exact saved direction from the new CUDA
workflow); projected generation; original live-observation generation. No warmups
or repetitions in this diagnostic pass. Count1load/1trace/3generation/1derive/
1tokenization; constructor internal probes remain separate. No other model,
reference/oracle regeneration, consumed holdouts or quality-based selection.

Record all returned text, errors, nine-column native token events, R callback
arrival times and selected live states. Native first-token time includes queue,
prompt processing and sampling; prompt_tokens / first-token time is an inclusive
rate, not a pure kernel measurement. Decode throughput uses actual event count
minus one divided by the interval between first and last native token events.
Wall time includes R delivery and settlement. Trace/derive/load measured separately.
Record global GPU telemetry at200ms and process RSS/HWM/CPU/threads at100ms while
this single R process runs. This is bounded performance instrumentation, not a
new job monitor. GPU memory/utilization includes the active desktop; retain baseline.
No claim of kernel-level attribution follows from this coarse profile.

A profile observation is not performance acceptance or a reason to rerun until
favourable. After inspection, freeze at most four justified timing configurations
with one warmup and three measured samples, fixed prompts/settings/model, retain
slower candidates and report medians/ranges, output differences and limitations.
Separate CPU versus CUDA, R transport, filtered capture, static projection and live
observation costs. No source modification/overclock/driver/vendor/kernel/new API
or package dependency is implied by the profiling pass itself.
