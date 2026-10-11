// Unarmed D046 transfer helpers; no constructor or projection activation entry.
#[repr(C)]
#[derive(Default)]
struct ProjectionStateFacts {
    hash_slots: u64,
    bindings: u64,
    c_finalizer_bytes: u64,
}
extern "C" {
    // C receives opaque R object pointers and uses the installed R headers.
    // Rust never inspects extendr's non-exhaustive SEXPREC pointee layout.
    fn relm_r_state_inspect(
        state: *mut std::ffi::c_void,
        ptr: *mut std::ffi::c_void,
        out: *mut ProjectionStateFacts,
    ) -> i32;
    fn relm_r_state_frame_size() -> usize;
    fn relm_r_state_create(ptr: *mut std::ffi::c_void) -> *mut std::ffi::c_void;
}
fn projection_state_workspace_bytes() -> u64 {
    use std::mem::size_of;
    // The C frame getter includes both accessor arguments and chain-helper
    // arguments. This complete query path never overlaps the profile response.
    (unsafe { relm_r_state_frame_size() as u64 })
        + (size_of::<ProjectionStateFacts>()
            + 2 * size_of::<Robj>()
            + size_of::<List>()
            + size_of::<[(&str, u64); 3]>()
            + size_of::<std::slice::Iter<'static, (&'static str, u64)>>()) as u64
}
#[extendr]
fn rebirth_model_state(ptr: Robj) -> Robj {
    projection_resolve(catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: this boundary is on R's main thread, ptr is rooted by Robj,
        // and C returns the new environment without an intervening R allocation.
        // Robj immediately protects it (the weak proof itself is not a root).
        let state = unsafe { Robj::from_sexp(relm_r_state_create(ptr.get().cast()).cast()) };
        if !state.is_environment() {
            return Err(projection_argument());
        }
        Ok(state)
    })))
}
#[extendr]
fn rebirth_projection_state_facts(state: Robj, ptr: Robj) -> Robj {
    projection_resolve(catch_unwind(AssertUnwindSafe(|| {
        checked_handle(&ptr)?;
        let mut facts = ProjectionStateFacts::default();
        // SAFETY: the .Call runs on R's main thread; both Robj arguments keep
        // their SEXPs alive. The installed-header accessor rejects active bindings
        // before lookups and never forces promises. Official R lookup may
        // rebox at most two scalar bindings (112 R bytes charged separately);
        // expanded values remain rooted by the protected source environment.
        let ok = unsafe { relm_r_state_inspect(state.get().cast(), ptr.get().cast(), &mut facts) };
        if ok != 1 {
            return Err(projection_argument());
        }
        projection_numeric_list([
            ("hash_slots", facts.hash_slots),
            ("bindings", facts.bindings),
            ("c_finalizer_bytes", facts.c_finalizer_bytes),
        ])
    })))
}
fn projection_same_source<'a>(
    expected: &LlmHandle,
    ptr: &'a Robj,
) -> Result<&'a ExternalPtr<LlmHandle>, RebirthError> {
    let current = checked_handle(ptr)?;
    if expected.is_closed() || current.is_closed() || !Rc::ptr_eq(&expected.state, &current.state) {
        return Err(projection_argument());
    }
    Ok(current)
}
fn projection_reserve_registration<T>(
    registry: &mut Vec<Weak<T>>,
    source: &Rc<T>,
    candidate: &Rc<T>,
    admitted_capacity: usize,
    admitted_bytes: u64,
) -> Result<(), RebirthError> {
    // This runs without R calls while the original source model borrow remains
    // held. A changed registry is refused; the old vector stays byte-for-byte
    // owned until every check, exact reservation and candidate insertion passes.
    if registry.capacity() != admitted_capacity
        || projection_registry_charge(registry.capacity())? != admitted_bytes
        || !registry.iter().any(|w| w.as_ptr() == Rc::as_ptr(source))
        || Rc::ptr_eq(source, candidate)
        || registry.iter().any(|w| w.as_ptr() == Rc::as_ptr(candidate))
    {
        return Err(projection_argument());
    }
    // Expired weak owners do not require replacement slots. Live entries plus
    // the candidate fit the already admitted old-capacity-plus-one bound.
    let capacity = registry
        .iter()
        .filter(|w| w.strong_count() > 0)
        .count()
        .checked_add(1)
        .ok_or_else(projection_argument)?;
    let mut replacement = Vec::new();
    replacement
        .try_reserve_exact(capacity)
        .map_err(|_| projection_argument())?;
    if replacement.capacity() != capacity {
        return Err(projection_argument());
    }
    replacement.extend(registry.iter().filter(|w| w.strong_count() > 0).cloned());
    replacement.push(Rc::downgrade(candidate));
    if replacement.capacity() != capacity {
        return Err(projection_argument());
    }
    *registry = replacement;
    Ok(())
}
#[cfg(feature = "selftest")]
fn projection_handle_only(ptr: ExternalPtr<LlmHandle>) -> Robj {
    // No LoadedModel::metadata() or cloned path/display fields in this result.
    list!(ok = true, ptr = Robj::from(ptr)).into()
}
#[cfg(feature = "selftest")]
struct ProjectionResidualInput<'a> {
    steer_layers: &'a [i32],
    steer_vectors: &'a [f64],
    ablate_layers: &'a [i32],
    ablate_neurons: &'a [i32],
    ablate_values: &'a [f64],
}
#[cfg(feature = "selftest")]
impl ProjectionResidualInput<'_> {
    fn validate(
        &self,
        width: usize,
        depth: usize,
        mut cached: impl FnMut(u32, bool) -> bool,
    ) -> Result<(), RebirthError> {
        let layer = |one: i32, steering: bool| -> Result<u32, RebirthError> {
            let zero = one
                .checked_sub(1)
                .filter(|x| *x >= i32::from(steering))
                .ok_or_else(projection_argument)?;
            if zero as usize >= depth {
                return Err(projection_argument());
            }
            Ok(zero as u32)
        };
        if width == 0
            || depth == 0
            || width.checked_mul(self.steer_layers.len()) != Some(self.steer_vectors.len())
            || self.ablate_layers.len() != self.ablate_neurons.len()
            || self.ablate_layers.len() != self.ablate_values.len()
        {
            return Err(projection_argument());
        }
        for (i, &one) in self.steer_layers.iter().enumerate() {
            let layer = layer(one, true)?;
            let row = &self.steer_vectors[i * width..(i + 1) * width];
            if row
                .iter()
                .any(|v| !v.is_finite() || v.abs() > f32::MAX as f64)
            {
                return Err(projection_argument());
            }
            if row.iter().any(|&v| v as f32 != 0.) && !cached(layer, true) {
                return Err(projection_argument());
            }
        }
        for ((&one, &neuron), &value) in self
            .ablate_layers
            .iter()
            .zip(self.ablate_neurons)
            .zip(self.ablate_values)
        {
            let layer = layer(one, false)?;
            if neuron < 1
                || neuron as usize > width
                || !value.is_finite()
                || value.abs() > f32::MAX as f64
                || !cached(layer, false)
            {
                return Err(projection_argument());
            }
        }
        Ok(())
    }
}

#[cfg(feature = "selftest")]
#[extendr]
fn rebirth_selftest_projection_transfer() -> Robj {
    projection_resolve(catch_unwind(AssertUnwindSafe(|| {
        projection_transfer_selftest::run();
        Ok(list!(ok = true).into())
    })))
}
#[cfg(feature = "selftest")]
#[path = "projection_transfer_selftest.rs"]
mod projection_transfer_selftest;

#[cfg(test)]
#[path = "projection_review_registry_tests.rs"]
mod projection_review_registry_tests;
