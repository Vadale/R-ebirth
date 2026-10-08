# Pruning-path numerical failure — cause not yet established

This resume is FAILED. Format/clippy/no-spill compile passed. The full forward
case passed15 cases/34748 values with max absolute error0.004728402942419052;
2944 same-input-row comparisons have zero measured difference. Receipts and
stage log hashes were independently checked. Preserve that exact source scope.

The next microbatch/pruning/reuse test failed with native0.547000527381897 vs
reference0.5585253461344721 (difference0.011524818752575161, bound0.01). The
reference value uniquely identifies long_prefill position514 vocabulary1.
The earlier full forward passed this reference under513-prefill+1incremental
execution. The extra pruning branch calls prompt_last_logits on all514tokens
with512+2 batching and last-only outputs. The observed difference is concrete;
its cause is not yet established. Do not declare benign kernel drift, a product
fix, or a fixture error without controlled evidence. Keep tolerance/reference
and long/pruned gate unchanged. Prepare one bounded diagnostic comparison of
schedule/output policy/projection before any corrective runtime change.

No tests8–9, CPU/Metal benchmark or held-out experiment executed in this attempt.
