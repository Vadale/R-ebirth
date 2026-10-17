# WP13 final bounded benchmark — frozen before execution

Three configurations only, in fixed order: CPU baseline; installed CUDA baseline;
CUDA with the private live polling interval changed from 5ms to 1ms. This last
candidate addresses the measured 104 versus 231 token/s live/ordinary diagnostic
and the actual per-state acknowledgement followed by a 5ms R timer. It changes
only an R timer in this isolated experiment; no new API, precision, kernel, driver,
cache configuration or runtime ownership policy. The candidate is not yet product
code or accepted. No fourth configuration or retuning will follow these results.

Each configuration runs in a fresh R process against the exact accepted production
DLL 8bf2d82f337262386b54ed89ab77f18da15b3a0dd0e819b1ce1435fa535b24a5.
Use the same pinned Qwen Q8_0 ca59ca7f..., context512, full CUDA offload (or CPU0),
mmapTRUE, raw exact new repair-cafe prompt in benchmark.R, 128 tokens, temperature0,
top_p.95, seed8002, no stop/images/schema. Save one actual tokenizer result per
configuration. Same saved CUDA-workflow MLP direction, layer12/coef1, no retraining.
Transfer of this recorded vector to the same CPU model is for cost measurement;
it does not establish cross-backend numerical identity or efficacy.

Per configuration: one cold-process load and one derived owner, then exactly four
iterations (iteration0 warmup, 1..3 measured). Each iteration performs plain sync,
plain async/token stream, filtered residual+MLP trace (last position/layer12),
projected async stream, and original live async stream (MLP12/top5/spillFALSE).
No deletion, retries, outlier trimming, prompt selection, extra warmups or sleeps.
Total planned3loads/3tokenizations/3derives/12traces/48generations, including warmup.
CPU and original CUDA live timer5ms; candidate1ms. Ordinary async timer50ms unchanged.
No nested loop changes; later::run_now(.01) is identical in all configurations.

Record every result/error, text, sampled token IDs and nine-column event data,
live states, R callback arrivals, wall/native event timings and process CPU time.
Same-configuration repetitions and plain/live text+IDs are verified from retained
raw data; backend differences are reported rather than forced equal. Source and
installed byte inventories before/after. Save actual placement/warnings and
owner cleanup; no silence of the known tokenizer warning. Cold-process load is
not a cold filesystem-cache claim (model was previously read).

Record global NVIDIA telemetry200ms and process RSS/HWM/CPU/threads100ms. GPU
memory includes desktop baseline. Native first-token time includes queue, prompt
processing and sampling; input_tokens/TTFT is an inclusive prompt rate, never
pure prefill/kernel throughput. Decode rate=(tokens-1)/(last-first token elapsed).
Plain sync reports wall/token rate only; no fabricated native TTFT. Compare
median and full min/max of all three measured samples; retain warmup separately.
Projection generations may follow different histories; timing is application
cost, not a pure-operator microbenchmark. GPU clocks/thermal/order confounding
remain explicit; no generalized or globally maximum performance claim.

Adopt the 1ms CUDA-only live timer only if all correctness/output/cleanup checks
pass, median live wall time improves at least5%, and median live process CPU time
is at most1.5x the CUDA baseline. Otherwise retain 5ms and the slower outcome.
Record raw measurements before this rule is applied. CPU/Metal timer unchanged.
No repeated benchmarks after selecting the already measured setting.
