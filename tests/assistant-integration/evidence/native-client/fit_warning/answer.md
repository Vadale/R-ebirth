The exact requested model was run once with `glm.control(maxit = 1)`. No alternative iteration budget or replacement model was fitted.

The fit returned:

- Warning: `glm.fit: algorithm did not converge`
- `converged = FALSE`
- Iterations: `1`
- Analytic sample: 25 observations, with 12 zeros and 13 ones

The resulting nominal Wald quantities were:

| Term | Coefficient | Nominal 95% interval |
|---|---:|---:|
| Intercept | 0.0973 | −0.8080 to 1.0025 |
| x | 1.1673 | 0.6652 to 1.6695 |

These intervals should **not** be reported as trustworthy confidence intervals. They use the curvature after a single, explicitly nonconverged IRLS iteration. Moreover, the data are completely separated: every outcome 0 has `x ≤ −0.25`, while every outcome 1 has `x ≥ 0`. Thus the ordinary finite logistic-regression MLE is not supported; the apparently finite coefficient, standard error, p-value, and interval are artifacts of stopping early rather than valid inference. They are retained as diagnostics and marked `withheld`.

Artifacts:

- [Executable analysis code](/private/tmp/relm-i1/native-client-02/fit_warning/analysis.R)
- [Fit status and actual warning](/private/tmp/relm-i1/native-client-02/fit_warning/analysis-output/fit-status.csv)
- [Captured conditions](/private/tmp/relm-i1/native-client-02/fit_warning/analysis-output/conditions.csv)
- [Coefficients and withheld intervals](/private/tmp/relm-i1/native-client-02/fit_warning/analysis-output/estimates.csv)
- [Diagnostics](/private/tmp/relm-i1/native-client-02/fit_warning/analysis-output/diagnostics.csv)
- [Analysis summary](/private/tmp/relm-i1/native-client-02/fit_warning/analysis-output/summary.md)
- [R session information](/private/tmp/relm-i1/native-client-02/fit_warning/analysis-output/session-info.txt)