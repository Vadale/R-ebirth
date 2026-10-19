#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>
#include <stdlib.h>
static SEXP probe(SEXP x) { return x; }
static SEXP wrappers(SEXP symbols, SEXP module) {
  if (!Rf_asLogical(symbols)) Rf_error("symbols required");
  if (getenv("RELM_INVALID_WRAPPER_FIXTURE")) return Rf_mkString("invalid <- function(");
  return Rf_mkString("rebirth_probe <- function(x) .Call(wrap__rebirth_probe, x)\n");
}
static const R_CallMethodDef entries[] = {
  {"wrap__make_relm_wrappers", (DL_FUNC) &wrappers, 2},
  {"wrap__rebirth_probe", (DL_FUNC) &probe, 1},
  {NULL, NULL, 0}
};
void R_init_relm(DllInfo *dll) { R_registerRoutines(dll, NULL, entries, NULL, NULL); R_useDynamicSymbols(dll, FALSE); }
