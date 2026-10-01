# Choose methods by design and estimand

The ecosystem is open-ended. These are candidate starting points, not guarantees
of suitability or availability. Check installed help and maintained upstream
vignettes for the selected method/version; read only the relevant domain.

| Question/design | R starting points | Decision that must precede fitting |
|---|---|---|
| Describe distributions, groups and missingness | base R, `stats`, `graphics` | Units, denominators, weights, grouping and missing-data policy |
| Compare independent or paired groups | `stats::t.test`, `wilcox.test`, `lm` | Pairing/dependence, target mean or distribution, appropriate variance assumption; rank tests do not generally test medians |
| Continuous, binary or count outcome | `stats::lm`, `glm`; `MASS`, `sandwich`, `lmtest` if needed | Link, exposure/offset, nonlinearity, separation, overdispersion and dependence; coefficient scale versus marginal effect |
| Repeated observations/multilevel data | `nlme`, `lme4`, `glmmTMB`, `geepack` | Cluster hierarchy, random-effects structure, within-unit correlation and subject-specific versus population-average estimand |
| Nonlinear relationships/smooths | `mgcv` | Smoothing selection, support/extrapolation, concurvity and effective complexity |
| Time to event | `survival`; `cmprsk` where justified | Event coding, censoring, delayed entry, competing risks, time-varying covariates and proportional hazards |
| Survey/population inference | `survey`, `srvyr` when an existing workflow uses it | Weights, strata, PSUs, finite-population corrections and design-based variance; weights alone are insufficient |
| Intervention/observational causality | design-specific tools: `MatchIt`, `WeightIt`, `fixest`, `did` | Identification, overlap, confounding, treatment timing and target effect; no automatic causal claim from regression |
| Missing-data inference | `mice`, model-specific alternatives | Missingness mechanism, compatibility, auxiliary variables and pooling; never mean-impute by default |
| Time series/forecasting | `stats`, `forecast`, `fable` | Frequency, availability time, rolling validation, seasonality, stationarity and forecast horizon |
| Bayesian hierarchical inference | `brms`, `rstanarm`, `cmdstanr` | Priors, likelihood, identifiability, MCMC diagnostics, posterior/predictive checks and compute budget |
| Meta-analysis | `metafor`, `meta` | Effect scale, sampling variance, dependent effects, heterogeneity and bias/sensitivity |
| Prediction/high dimensions | `glmnet`, `ranger`, `tidymodels` if useful | Leakage-free splits, fold-local preprocessing/tuning, calibration, uncertainty and external validation |
| Omics/biological data | Bioconductor: `limma`, `edgeR`, `DESeq2`, domain workflows | Count scale, library preparation, replication, batch/confounding, normalization and multiplicity |
| Spatial, psychometric, compositional or other specialized work | Relevant CRAN Task View and method authors' vignettes | Domain-specific dependence, measurement assumptions and data support |

Use this route for unfamiliar methods:

1. Find the relevant [CRAN Task View](https://cran.r-project.org/web/views/)
   or [Bioconductor workflow](https://bioconductor.org/help/workflows/).
2. Compare the specific method requirements with the study design. Read the
   original package documentation and its diagnostic/interpretation guidance.
3. Check availability/version and dependency cost. Reuse an installed suitable
   package; request/perform only authorized project-scoped installation.
4. Run the primary method plus targeted diagnostic/sensitivity checks. Report
   unsupported assumptions, identification limits or insufficient data directly.

A package being on CRAN/Bioconductor does not validate an arbitrary analysis.
An unlisted package is permitted when it better answers the actual question.
R package licenses and system requirements remain their authors' own.
