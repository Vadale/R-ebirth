#include "/Users/alessandrovadala/DOCUDESK/R-ebirth/rebirth/src/rust/rebirth-ffi/native/projection_state.c"
void relm_projection_drop_any(void *address) { (void) address; }
SEXP state_create(SEXP ptr) { return relm_r_state_create(ptr); }
SEXP state_facts(SEXP env, SEXP ptr) {
    struct relm_r_state_facts facts = {0};
    if (!relm_r_state_inspect(env,ptr,&facts)) return R_NilValue;
    SEXP answer=PROTECT(Rf_allocVector(REALSXP,3));
    REAL(answer)[0]=facts.hash_slots; REAL(answer)[1]=facts.bindings; REAL(answer)[2]=facts.c_finalizer_bytes;
    UNPROTECT(1);return answer;
}
SEXP state_key(SEXP ptr) { return R_WeakRefKey(R_ExternalPtrProtected(ptr)); }
SEXP state_size(SEXP ignored) { (void) ignored; return Rf_ScalarReal(relm_r_state_frame_size()); }

SEXP fresh_pointer(void) { return R_MakeExternalPtr(NULL,R_NilValue,R_NilValue); }
