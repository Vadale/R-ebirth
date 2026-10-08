/* D046: bounded state provenance and an unforced two-value query.
 * The factory uses only public R allocation/weak-reference/environment APIs.
 * A protected weak reference proves that this exact state was created unhashed
 * with two fixed names. Locking names prevents hash growth or added bindings;
 * values remain mutable for close(). The weak key preserves existing GC timing.
 * All calls run on R's main thread with protected R objects. */
#include <Rinternals.h>
#include <Rversion.h>
#include <stdint.h>

#if R_VERSION < R_Version(4, 5, 0)
#define RELM_HAS_ATTRIBUTES(x) (ATTRIB(x) != R_NilValue)
#define RELM_PARENT_ENV(x) ENCLOS(x)
#else
#define RELM_HAS_ATTRIBUTES(x) ANY_ATTRIB(x)
#define RELM_PARENT_ENV(x) R_ParentEnv(x)
#endif

struct relm_r_state_facts {
    uint64_t hash_slots;
    uint64_t bindings;
    uint64_t c_finalizer_bytes;
};
/* Keep the original conservative frame charge. The new factory and query use
 * fewer rooted pointers than this envelope; no platform-specific SEXPREC layout.
 */
struct relm_r_state_frame {
    SEXP env, expected, proof, reserved, symbol, value, ptr_symbol, closed_symbol;
    const char *reserved_name;
    R_xlen_t reserved_slots, reserved_slot;
    unsigned reserved_seen, reserved_count;
};
size_t relm_r_state_frame_size(void) { return sizeof(struct relm_r_state_frame) + 4 * sizeof(void *); }

SEXP relm_r_state_create(SEXP ptr) {
    if (TYPEOF(ptr) != EXTPTRSXP || RELM_HAS_ATTRIBUTES(ptr)
        || R_ExternalPtrProtected(ptr) != R_NilValue) return R_NilValue;
    SEXP env = PROTECT(R_NewEnv(R_EmptyEnv, FALSE, 0));
    Rf_defineVar(Rf_install("ptr"), ptr, env);
    SEXP closed = PROTECT(Rf_ScalarLogical(FALSE));
    Rf_defineVar(Rf_install("closed"), closed, env);
    R_LockEnvironment(env, FALSE);
    SEXP proof = PROTECT(R_MakeWeakRef(env, R_NilValue, R_NilValue, FALSE));
    R_SetExternalPtrProtected(ptr, proof);
    UNPROTECT(3);
    return env;
}

static SEXP relm_state_unforced_value(SEXP env, SEXP symbol) {
#if R_VERSION >= R_Version(4, 6, 0)
    /* R_getVar would force a promise or run an active binding. Inspect the
     * public binding type first; even an already forced promise is refused. */
    if (R_GetBindingType(symbol, env) != R_BindingTypeValue) return R_UnboundValue;
    return R_getVar(symbol, env, FALSE);
#else
    /* R <= 4.5 has no public binding-type query. Its declared legacy accessor
     * returns promises unforced and can rebox at most one immediate scalar.
     * This branch is not compiled or linked against R 4.6. */
    if (R_BindingIsActive(symbol, env)) return R_UnboundValue;
    return Rf_findVarInFrame3(env, symbol, FALSE);
#endif
}

int relm_r_state_inspect(SEXP env, SEXP expected, struct relm_r_state_facts *out) {
    struct relm_r_state_frame f = {0};
    if (!out || TYPEOF(env) != ENVSXP || RELM_HAS_ATTRIBUTES(env)
        || RELM_PARENT_ENV(env) != R_EmptyEnv || !R_EnvironmentIsLocked(env)
        || TYPEOF(expected) != EXTPTRSXP || RELM_HAS_ATTRIBUTES(expected)) return 0;
    f.env = env; f.expected = expected; f.proof = R_ExternalPtrProtected(expected);
    if (TYPEOF(f.proof) != WEAKREFSXP || R_WeakRefKey(f.proof) != env
        || R_WeakRefValue(f.proof) != R_NilValue) return 0;
    f.ptr_symbol = Rf_install("ptr"); f.closed_symbol = Rf_install("closed");
    /* Provenance establishes the exact two names without enumerating an
     * untrusted environment or allocating a hash-table-sized profile. */
    f.value = relm_state_unforced_value(f.env, f.ptr_symbol);
    if (TYPEOF(f.value) == PROMSXP || f.value != f.expected) return 0;
    f.value = relm_state_unforced_value(f.env, f.closed_symbol);
    if (TYPEOF(f.value) == PROMSXP || TYPEOF(f.value) != LGLSXP || ALTREP(f.value)
        || XLENGTH(f.value) != 1 || RELM_HAS_ATTRIBUTES(f.value)
        || (LOGICAL(f.value)[0] != 0 && LOGICAL(f.value)[0] != 1)) return 0;
    out->hash_slots = 0;
    out->bindings = 2;
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
