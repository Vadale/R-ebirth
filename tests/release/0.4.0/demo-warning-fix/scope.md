# Demo warning correction

The original RStudio job remains accepted with its30 recorded warnings. This correction does not rerun that job or change its receipts.

The probe explicitly chooses the same deviance metric that installed glmnet already selects when observations per fold are below10. A new model-free40-row fixture verifies identical lambda grid/selection, CV summaries, prevalidated predictions and coefficients against the old warning-producing call. A100-row policy check retains AUC when the fallback does not apply. No tolerance or fold assignment changes.

The plot draws collapsed intervals as ticks. Redrawing the retained DemoA result emits no warnings, returns the exact unchanged result and preserves all24 data points and interval limits. The resulting PNG was visually inspected. No model, captured activation or consumed evaluation was executed again.

The single warning in the focused log belongs to the deliberately retained original glmnet call. The corrected call and plot emitted zero warnings. Linker, toolchain and vendored-source warnings are outside this narrow correction.
