# Checks that change interpretation

Select checks relevant to the design, rather than running every test on every
analysis. A successful function call is computational success, not validation.

- **Unit/dependence:** repeated observations, families, sites, matched pairs and
  spatial/time structure determine standard errors and resampling units. A large
  row count does not compensate for few independent clusters.
- **Data support:** document exclusions and denominators; flag empty groups,
  insufficient events, near-zero variance, aliased coefficients, extreme weights,
  separation and unsupported extrapolation before reporting model precision.
- **Missingness:** quantify by variables/groups and report the resulting analytic
  sample. Choose complete cases, imputation or a joint model for justified
  reasons; sensitivity to plausible missingness matters more than a mechanical
  significance test of MCAR.
- **Model adequacy:** examine the relevant residuals, link/function form,
  heteroscedasticity, overdispersion, influence and calibration. Do not choose
  inference solely by a preliminary normality-test p-value. Robust/clustered
  standard errors address their stated variance problem, not omitted confounding.
- **Complex fits:** retain optimizer/convergence and singular-fit warnings. For
  MCMC inspect R-hat, effective sample sizes, divergences and posterior predictive
  checks; use method-specific published criteria. For Cox models assess PH and
  functional form; use alternatives if required by the estimand/design.
- **Multiplicity/selection:** define families/contrasts, distinguish prespecified
  from exploratory analyses, and use justified FWER/FDR adjustments. Model,
  subgroup or threshold selection on the reported test set invalidates ordinary
  held-out claims. Label conditional versus selection-aware intervals.
- **Uncertainty:** report interval type, level, method and scale. Back-transform
  both estimate and endpoints where appropriate. Do not call a credible interval
  a confidence interval; do not read a p-value as probability a hypothesis is true.
  A wide interval is not evidence of equivalence. Define an equivalence margin
  and appropriate design/test before an equivalence claim.
- **Causality:** state identification assumptions and why the design might support
  them. Adjustment alone does not identify an effect; significance and predictive
  importance do not establish mechanism.
- **Reproducibility:** preserve scripts, configuration, seeds, package versions,
  contrast choices, data identities and execution status. Seeds alone do not
  guarantee cross-platform or cross-version bitwise identity. Do not redistribute
  confidential data merely to make a public reproduction archive.

When a diagnostic invalidates an inference, mark the affected result withheld
or exploratory and explain the consequence. Do not silently suppress warnings,
substitute a model, or keep fitting until the requested conclusion appears.

Use diagnostic status `pass` only for a stated criterion supported by evidence.
A fit returning successfully or a non-significant lack-of-fit test does not prove
an assumption. Use `assumed` or `not_assessed` for unverified assumptions, and
retain the diagnostic result separately from that interpretation.
