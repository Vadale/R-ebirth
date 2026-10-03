# Public steering-update measurements

Fresh F6b installation; sixteen actual 128-state runs (one warm-up pair and
three balanced measured pairs per requested CPU/Metal backend), 2,048 delivered
states. Worker coefficient/revision/source audits, unchanged metadata, seeded
reset and delivered-object bounds pass. Receipts independently replayed without
another model call. CPU median callback-exit-to-next-state interval is 11ms for
unchanged and changing coefficients; Metal-handle medians are 19ms and 22ms.
Intervals include validation, acknowledgement, adapter update, decode, publication
and R polling. They are not isolated setter cost or a newly invented performance
gate. The backend names identify requested handles; this run does not independently
re-prove actual GPU offload (earlier F6a feasibility keeps its original provenance).
