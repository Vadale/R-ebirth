# tests/demos/make-abstracts-sample.R
#
# Regenerates the SYNTHETIC abstracts sample shipped in
# rebirth/inst/extdata/abstracts-sample.csv (Demo B, WP7).
#
# WHY SYNTHETIC: the shipped sample must be small (<= 5 MB), offline, reproducible
# and license-clean. Real scientific abstracts carry author copyright and cannot
# be redistributed in-repo, so the shipped sample is generated here from topic-
# specific word banks (CC0 / this project's own text). It has genuine topical
# structure -- an LLM embedder maps each topic to a distinct region -- so Demo B's
# embed -> UMAP -> HDBSCAN -> name -> map pipeline runs end-to-end offline. For the
# REAL corpus (~5,000 arXiv abstracts) use tests/demos/fetch-abstracts.R.
#
# Deterministic: a fixed seed => byte-identical CSV. Run from the repo root:
#   Rscript tests/demos/make-abstracts-sample.R

.topics <- list(
  deep_learning = list(
    label = "Deep learning",
    subject = c("deep neural networks", "transformer architectures", "convolutional models",
                "self-supervised representation learning", "graph neural networks",
                "generative diffusion models", "recurrent sequence models", "attention mechanisms"),
    method = c("stochastic gradient descent", "contrastive pre-training", "knowledge distillation",
               "mixed-precision training", "curriculum learning", "adversarial fine-tuning",
               "parameter-efficient adapters", "data augmentation"),
    object = c("classification accuracy", "sample efficiency", "generalization gap",
               "training throughput", "representation quality", "calibration error"),
    finding = c("outperforms strong baselines on standard benchmarks",
                "reduces the number of labelled examples required",
                "improves robustness to distribution shift",
                "learns transferable features across tasks",
                "narrows the gap to fully supervised models"),
    application = c("image recognition", "recommendation systems", "speech processing",
                    "autonomous perception", "tabular prediction")
  ),
  cosmology = list(
    label = "Cosmology and astrophysics",
    subject = c("the cosmic microwave background", "large-scale structure formation",
                "type Ia supernovae", "dark matter halos", "galaxy clustering",
                "gravitational lensing", "baryon acoustic oscillations", "the expansion history"),
    method = c("N-body simulations", "Bayesian parameter inference", "spectroscopic surveys",
               "weak-lensing tomography", "Markov chain Monte Carlo sampling",
               "cross-correlation analysis", "photometric redshift estimation"),
    object = c("the Hubble constant", "the matter power spectrum", "the dark energy equation of state",
               "cluster mass functions", "primordial non-Gaussianity", "the growth rate of structure"),
    finding = c("is consistent with the LambdaCDM concordance model",
                "reveals a mild tension with local measurements",
                "tightens constraints on cosmological parameters",
                "favours a nearly scale-invariant spectrum",
                "constrains the sum of neutrino masses"),
    application = c("next-generation redshift surveys", "cosmological forecasting",
                    "tests of general relativity", "dark-sector physics")
  ),
  genomics = list(
    label = "Genomics and molecular biology",
    subject = c("gene regulatory networks", "single-cell transcriptomes", "chromatin accessibility",
                "protein-coding variants", "CRISPR perturbation screens", "RNA splicing patterns",
                "epigenetic modifications", "the tumour microenvironment"),
    method = c("high-throughput sequencing", "differential expression analysis",
               "genome-wide association mapping", "mass spectrometry", "lineage tracing",
               "spatial transcriptomics", "variant calling pipelines"),
    object = c("cell-type identity", "regulatory element activity", "mutational burden",
               "allele-specific expression", "pathway enrichment", "clonal architecture"),
    finding = c("identifies previously uncharacterized cell states",
                "links regulatory variants to disease risk",
                "resolves heterogeneity within tumour samples",
                "uncovers coordinated transcriptional programmes",
                "implicates specific pathways in progression"),
    application = c("precision oncology", "developmental biology", "immunotherapy design",
                    "rare-disease diagnosis")
  ),
  climate = list(
    label = "Climate and atmospheric science",
    subject = c("the global carbon cycle", "atmospheric aerosols", "ocean heat uptake",
                "regional precipitation extremes", "Arctic sea-ice decline", "the monsoon system",
                "land-surface feedbacks", "greenhouse-gas forcing"),
    method = c("coupled climate model ensembles", "satellite remote sensing",
               "reanalysis data assimilation", "paleoclimate proxy reconstruction",
               "downscaling techniques", "detection-and-attribution analysis"),
    object = c("surface temperature trends", "climate sensitivity", "sea-level rise",
               "the hydrological cycle", "radiative forcing", "extreme-event frequency"),
    finding = c("indicates an accelerating warming trend",
                "attributes recent extremes to anthropogenic forcing",
                "reduces uncertainty in projected sea-level rise",
                "reveals strong regional heterogeneity",
                "highlights nonlinear feedback processes"),
    application = c("climate adaptation planning", "flood-risk assessment",
                    "carbon-budget accounting", "seasonal forecasting")
  ),
  condensed_matter = list(
    label = "Condensed matter and quantum materials",
    subject = c("topological insulators", "high-temperature superconductors",
                "two-dimensional materials", "quantum spin liquids", "correlated electron systems",
                "moire superlattices", "magnetic skyrmions", "the fractional quantum Hall effect"),
    method = c("angle-resolved photoemission spectroscopy", "density functional theory",
               "scanning tunnelling microscopy", "quantum Monte Carlo", "transport measurements",
               "the tensor-network renormalization group", "neutron scattering"),
    object = c("the electronic band structure", "the superconducting gap", "spin correlations",
               "the phase diagram", "quasiparticle interference", "the Berry curvature"),
    finding = c("reveals an unconventional pairing symmetry",
                "hosts robust topologically protected edge states",
                "exhibits emergent fractionalized excitations",
                "displays a tunable metal-insulator transition",
                "supports a nontrivial band topology"),
    application = c("quantum computing platforms", "low-power electronics",
                    "spintronic devices", "energy-efficient materials")
  ),
  epidemiology = list(
    label = "Epidemiology and public health",
    subject = c("infectious-disease transmission", "vaccine effectiveness", "health inequalities",
                "the burden of chronic disease", "antimicrobial resistance", "maternal health outcomes",
                "mental-health service use", "population screening programmes"),
    method = c("compartmental transmission models", "cohort studies", "difference-in-differences designs",
               "propensity-score matching", "Bayesian hierarchical models", "survival analysis",
               "instrumental-variable estimation"),
    object = c("the basic reproduction number", "incidence rates", "case-fatality ratios",
               "healthcare utilization", "the cost-effectiveness ratio", "years of life lost"),
    finding = c("estimates substantial averted mortality from intervention",
                "reveals persistent socioeconomic disparities",
                "supports the cost-effectiveness of early screening",
                "quantifies the impact of policy changes on outcomes",
                "identifies groups at elevated risk"),
    application = c("health-policy evaluation", "outbreak response", "resource allocation",
                    "equity-focused screening")
  ),
  cryptography = list(
    label = "Cryptography and security",
    subject = c("post-quantum key exchange", "zero-knowledge proof systems", "homomorphic encryption",
                "secure multiparty computation", "lattice-based signatures", "side-channel attacks",
                "authenticated encryption", "blockchain consensus protocols"),
    method = c("reductions to hard lattice problems", "the random-oracle model",
               "formal protocol verification", "constant-time implementation",
               "differential power analysis", "provable-security proofs"),
    object = c("the security parameter", "ciphertext expansion", "proof size",
               "the soundness error", "key-exchange latency", "the attack surface"),
    finding = c("achieves provable security under standard assumptions",
                "resists known quantum and classical attacks",
                "reduces communication overhead substantially",
                "closes a previously overlooked side channel",
                "improves the efficiency of the verifier"),
    application = c("secure messaging", "privacy-preserving analytics",
                    "digital identity", "financial infrastructure")
  ),
  number_theory = list(
    label = "Number theory and combinatorics",
    subject = c("elliptic curves over number fields", "the distribution of prime numbers",
                "modular forms", "L-functions", "additive combinatorics", "Diophantine equations",
                "random matrix analogies", "sieve methods"),
    method = c("the circle method", "algebraic geometry techniques", "analytic estimates",
               "spectral methods", "Galois representations", "probabilistic combinatorics",
               "the large sieve"),
    object = c("rational points", "the rank of the group", "prime gaps",
               "special L-values", "additive energy", "class numbers"),
    finding = c("establishes an asymptotic formula under mild hypotheses",
                "proves a conjecture in a wide range of cases",
                "improves the best known bound",
                "reveals an unexpected connection to modular forms",
                "resolves a special case of a long-standing problem"),
    application = c("computational number theory", "cryptographic hardness",
                    "coding theory", "arithmetic statistics")
  )
)

# Each template consumes the banks in one grammatical order: subject (noun),
# method (noun), object (noun), finding (3rd-person verb phrase), application
# (noun). Keeping the roles fixed guarantees every assembled sentence is
# well-formed regardless of which topic fills it.
.templates <- list(
  function(t, p) sprintf(
    "We study %s using %s. We measure %s and show that our approach %s. These results have implications for %s.",
    p(t$subject), p(t$method), p(t$object), p(t$finding), p(t$application)
  ),
  function(t, p) sprintf(
    "This paper investigates %s. Building on %s, we quantify %s and find that the method %s. Our findings inform %s.",
    p(t$subject), p(t$method), p(t$object), p(t$finding), p(t$application)
  ),
  function(t, p) sprintf(
    "We present a framework for studying %s based on %s. Focusing on %s, we demonstrate that it %s, with applications to %s.",
    p(t$subject), p(t$method), p(t$object), p(t$finding), p(t$application)
  ),
  function(t, p) sprintf(
    "Understanding %s remains challenging. Using %s, we analyse %s and observe that the model %s, motivating further work in %s.",
    p(t$subject), p(t$method), p(t$object), p(t$finding), p(t$application)
  ),
  function(t, p) sprintf(
    "We revisit %s through the lens of %s. Studying %s, we show that the approach %s, which is relevant for %s.",
    p(t$subject), p(t$method), p(t$object), p(t$finding), p(t$application)
  ),
  function(t, p) sprintf(
    "Motivated by open questions in %s, we apply %s to characterize %s. The results show that our method %s, advancing %s.",
    p(t$subject), p(t$method), p(t$object), p(t$finding), p(t$application)
  )
)

make_abstracts_sample <- function(per_topic = 150L, seed = 20240707L) {
  set.seed(seed)
  pick <- function(v) v[sample.int(length(v), 1L)]
  draw_one <- function(t) {
    txt <- .templates[[sample.int(length(.templates), 1L)]](t, pick)
    if (runif(1) < 0.4) { # optional second sentence for length variety
      txt <- paste(txt, sprintf("We further discuss %s and its connection to %s.",
                                pick(t$object), pick(t$subject)))
    }
    txt
  }
  rows <- list()
  n <- 0L
  seen <- character(0)
  for (key in names(.topics)) {
    t <- .topics[[key]]
    for (i in seq_len(per_topic)) {
      txt <- draw_one(t)
      tries <- 0L
      while (txt %in% seen && tries < 50L) { # reject collisions: keep texts unique
        txt <- draw_one(t)
        tries <- tries + 1L
      }
      seen <- c(seen, txt)
      n <- n + 1L
      rows[[n]] <- data.frame(
        id = n, category = key, label = t$label, text = txt,
        stringsAsFactors = FALSE
      )
    }
  }
  df <- do.call(rbind, rows)
  df[sample.int(nrow(df)), ] # shuffle so the CSV is not topic-ordered
}

if (sys.nframe() == 0L) {
  out <- file.path("rebirth", "inst", "extdata", "abstracts-sample.csv")
  dir.create(dirname(out), recursive = TRUE, showWarnings = FALSE)
  df <- make_abstracts_sample()
  df$id <- seq_len(nrow(df)) # renumber after the shuffle
  utils::write.csv(df, out, row.names = FALSE)
  message(sprintf(
    "wrote %s: %d abstracts, %d topics, %.2f MB",
    out, nrow(df), length(unique(df$category)), file.info(out)$size / 1e6
  ))
}
