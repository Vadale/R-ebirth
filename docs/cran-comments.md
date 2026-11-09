# Submission comments — relm 0.6.3 draft

**Not submitted. Final artifact and check results pending.** This corrective
update follows CRAN 0.6.2, published on November 2. The current correction
deadline is November 20.

## Reported installation failure

Fedora Clang23/libc++23 reports undeclared standard functions in the bundled
engine. An owned patch includes `<cstdlib>` directly in the graph, memory-map
and vocabulary sources and qualifies the standard C++ calls. This removes
reliance on transitive standard-library headers. The pinned engine revision,
algorithms, allocation strategy, dependency locks, compiler flags, numerical
contracts, public APIs, steering and tracing remain unchanged.

## Changes since CRAN 0.6.2

The package change is the standard-header portability fix described in NEWS.
Separate application/CI setup changes permit the new patch version and bound
downloads of the same frozen service dependency versions. They do not add an R
package dependency or weaken package tests.

## Candidate evidence to complete before submission

- Exact final production source archive, SHA256 and source mapping: pending.
- Complete ordinary Windows/macOS/Linux release/oldrel/devel checks and the
  production non-shared-R route: pending current candidate.
- Full R-devel Clang23/libc++23 package check, GCC sanitizer/LTO, full noLD R and
  available Windows/macOS pre-submission builders: pending final archive.
- Errors, warnings, notes, scoped skips and reverse-dependency disposition:
  record from the final candidate and current official results.

The local complete libc++23 CPU engine build and header regression are supporting
evidence, not a full CRAN Fedora package check. No exact CRAN-farm equivalence,
new model evaluation or acceptance guarantee is claimed.
