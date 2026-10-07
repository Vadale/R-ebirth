# Quarto did not start inside the restricted runtime

The launcher failed before executing the vignette: `sysctl ... Operation not permitted`, followed by `quarto script failed: unrecognized architecture`. No vignette expression, source build or package check ran. The exact unchanged document/check pipeline is resumed with ordinary local runtime permissions. No model, native build or accepted test is repeated.
