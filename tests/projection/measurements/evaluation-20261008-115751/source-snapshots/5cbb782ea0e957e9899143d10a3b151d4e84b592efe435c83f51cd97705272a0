/* D046: metadata-only first pass, bounded scalar-reboxing value pass.
 * Neither phase evaluates promises or invokes active bindings.
 * This is called only on R's main thread with protected R objects. */
#include <Rinternals.h>
#include <stdint.h>
#include <string.h>

struct relm_r_state_facts {
    uint64_t hash_slots;
    uint64_t bindings;
    uint64_t c_finalizer_bytes;
};
struct relm_r_state_frame {
    SEXP env, expected, hash, chain, symbol, value, ptr_symbol, closed_symbol;
    const char *name;
    R_xlen_t slots, slot;
    unsigned seen, count;
};
size_t relm_r_state_frame_size(void) { return sizeof(struct relm_r_state_frame) + 4 * sizeof(void *); }

static int inspect_chain(struct relm_r_state_frame *f) {
    for (; f->chain != R_NilValue; f->chain = CDR(f->chain)) {
        if (TYPEOF(f->chain) != LISTSXP || ATTRIB(f->chain) != R_NilValue || ++f->count > 2) return 0;
        f->symbol = TAG(f->chain);
        if (TYPEOF(f->symbol) != SYMSXP || R_BindingIsActive(f->symbol, f->env)) return 0;
        f->name = CHAR(PRINTNAME(f->symbol));
        if (strcmp(f->name, "ptr") == 0) {
            if (f->seen & 1u) return 0;
            f->ptr_symbol = f->symbol; f->seen |= 1u;
        } else if (strcmp(f->name, "closed") == 0) {
            if (f->seen & 2u) return 0;
            f->closed_symbol = f->symbol; f->seen |= 2u;
        } else return 0;
    }
    return 1;
}
int relm_r_state_inspect(SEXP env, SEXP expected, struct relm_r_state_facts *out) {
    struct relm_r_state_frame f = {0};
    if (!out || TYPEOF(env) != ENVSXP || ATTRIB(env) != R_NilValue
        || ENCLOS(env) != R_EmptyEnv || TYPEOF(expected) != EXTPTRSXP
        || ATTRIB(expected) != R_NilValue) return 0;
    f.env = env; f.expected = expected; f.hash = HASHTAB(env);
    if (f.hash == R_NilValue) {
        f.chain = FRAME(env);
        if (!inspect_chain(&f)) return 0;
    } else {
        if (TYPEOF(f.hash) != VECSXP || ALTREP(f.hash) || FRAME(env) != R_NilValue) return 0;
        f.slots = XLENGTH(f.hash);
        if (f.slots < 0 || (uint64_t) f.slots >= UINT64_C(9007199254740992)) return 0;
        for (f.slot = 0; f.slot < f.slots; ++f.slot) {
            f.chain = VECTOR_ELT(f.hash, f.slot);
            if (!inspect_chain(&f)) return 0;
        }
    }
    if (f.count != 2 || f.seen != 3u) return 0;
    /* All names/active-binding checks finish BEFORE either value lookup.
     * R4.5.1 envir.c findVarInFrame3 -> BINDING_VALUE returns an unforced
     * promise; it only expands an immediate scalar binding. memory.c's
     * R_expand_binding_value can create at most one scalar per lookup. R's
     * caller keeps env/expected protected; any expanded value is stored back
     * into that protected environment. The R workspace charges 2 * 56 bytes.
     * CAR cannot be used directly: it errors on immediate binding cells. */
    f.value = Rf_findVarInFrame3(f.env, f.ptr_symbol, FALSE);
    if (TYPEOF(f.value) == PROMSXP || f.value != f.expected) return 0;
    f.value = Rf_findVarInFrame3(f.env, f.closed_symbol, FALSE);
    if (TYPEOF(f.value) == PROMSXP || TYPEOF(f.value) != LGLSXP || ALTREP(f.value)
        || XLENGTH(f.value) != 1 || ATTRIB(f.value) != R_NilValue
        || (LOGICAL(f.value)[0] != 0 && LOGICAL(f.value)[0] != 1)) return 0;
    out->hash_slots = (uint64_t) f.slots;
    out->bindings = f.count;
    out->c_finalizer_bytes = sizeof(R_CFinalizer_t);
    return 1;
}

/* Constructor-only shell: finish every allocating R operation while its address
 * is NULL. Rust installs its Any box only after the handle-only response exists.
 * This uses installed official APIs, never a SEXPREC or extendr layout. */
extern void relm_projection_drop_any(void *address);
struct relm_projection_shell_frame { SEXP tag, shell; void *address; };
size_t relm_r_projection_shell_frame_size(void) {
    return sizeof(struct relm_projection_shell_frame) + sizeof(SEXP);
}
static void relm_projection_shell_finalizer(SEXP shell) {
    void *address = R_ExternalPtrAddr(shell);
    R_ClearExternalPtr(shell);
    R_SetExternalPtrTag(shell, R_NilValue);
    if (address) relm_projection_drop_any(address);
}
SEXP relm_r_projection_shell(SEXP tag) {
    SEXP shell = PROTECT(R_MakeExternalPtr(NULL, tag, R_NilValue));
    R_RegisterCFinalizerEx(shell, relm_projection_shell_finalizer, TRUE);
    UNPROTECT(1);
    return shell;
}
void relm_r_projection_shell_install(SEXP shell, void *address) {
    R_SetExternalPtrAddr(shell, address);
}
