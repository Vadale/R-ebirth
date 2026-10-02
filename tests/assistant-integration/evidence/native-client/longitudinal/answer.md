## Result

The groups’ trajectories clearly differed. Scores rose by an estimated:

- **Comparison:** 0.44 points/visit (95% CI 0.26–0.62)
- **Programme:** 1.80 points/visit (95% CI 1.62–1.98)
- **Difference:** **1.36 points/visit** (95% CI 1.11–1.61; p < 0.001)

Over visits 0–4, this represents **5.44 additional points of change** in the programme group (95% CI 4.43–6.46).

The primary linear mixed model included correlated person-specific intercepts and slopes, appropriately accounting for repeated observations. The person-level sensitivity analysis—estimating one slope per participant and comparing the 60 independent slopes—gave virtually the same result: **1.36 points/visit** (95% CI 1.10–1.62).

Diagnostics were reassuring:

- Complete balanced data: 300 observations, 60 people, 30 per group
- No important evidence against a linear trajectory (categorical-time comparison p = 0.289)
- Residual shape and variance pattern were acceptable
- Adding residual AR(1) correlation produced the same estimate; estimated correlation was only 0.012
- Leave-one-person-out estimates ranged from 1.33 to 1.40 points/visit

Because groups are observational, these results describe an association between group and trajectory, not necessarily a causal programme effect.

Artifacts:

- [Labelled trajectory plot](/private/tmp/relm-i1/native-client-02/longitudinal/analysis-deliverables/trajectory_plot.png)
- [Estimates table](/private/tmp/relm-i1/native-client-02/longitudinal/analysis-deliverables/estimates.csv)
- [Diagnostics](/private/tmp/relm-i1/native-client-02/longitudinal/analysis-deliverables/diagnostics.csv)
- [Diagnostic plots](/private/tmp/relm-i1/native-client-02/longitudinal/analysis-deliverables/diagnostic_plots.png)
- [Reproducible R code](/private/tmp/relm-i1/native-client-02/longitudinal/analysis-deliverables/analysis.R)
- [Plain-language summary](/private/tmp/relm-i1/native-client-02/longitudinal/analysis-deliverables/summary.md)