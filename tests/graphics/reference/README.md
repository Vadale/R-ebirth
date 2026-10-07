# Independent F6c figure data

These hand-calculated values are reference data for the R presentation layer,
not new native-model goldens. The four reference/intervention coordinates have
exact binary-representable differences 0.5, -1, 1 and 0. Prefix-divergence tests
must withhold every difference instead of reusing this table. Test fixtures
separately fix the sampled IDs and worker audit; no model run is inferred.

Ordinary R CI runs test-graphics-*.R. The later cached-model composition and
rendered-image inspection are separate acceptance gates.
