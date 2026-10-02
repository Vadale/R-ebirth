# Analysis result

The exact maxit = 1 logistic regression did not converge (converged = FALSE, iterations = 1) and emitted: glm.fit: algorithm did not converge.
Its nominal coefficient Wald intervals are retained in estimates.csv but marked withheld; they are not trustworthy for reporting because the likelihood optimization did not converge and the data show complete separation.

## Limitations

- No model with a larger iteration budget, alternative estimator, or profile-likelihood interval was fitted.
- The data contain only x and outcome, so observation independence and broader design assumptions cannot be verified.
- The computed Wald intervals use the incomplete fit's curvature and therefore do not have a defensible usual confidence-interval interpretation.

Captured warnings: 1
See estimates.csv, diagnostics.csv and conditions.csv for evidence.
