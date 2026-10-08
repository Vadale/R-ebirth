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
fn projection_handle_only(ptr: ExternalPtr<LlmHandle>) -> Robj {
    // No LoadedModel::metadata() or cloned path/display fields in this result.
    list!(ok = true, ptr = Robj::from(ptr)).into()
}
struct ProjectionResidualInput<'a> {
    steer_layers: &'a [i32],
    steer_vectors: &'a [f64],
    ablate_layers: &'a [i32],
    ablate_neurons: &'a [i32],
    ablate_values: &'a [f64],
}
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

#[extendr]
fn rebirth_selftest_projection_transfer() -> Robj {
    projection_resolve(catch_unwind(AssertUnwindSafe(|| {
        projection_transfer_selftest::run();
        Ok(list!(ok = true).into())
    })))
}
mod projection_transfer_selftest {
    use super::*;
    fn marker(test: &str, cases: usize, rejected: usize) {
        println!("F6E_PROJECTION_TRANSFER_TEST {{\"test\":\"{test}\",\"status\":\"passed\",\"expected_cases\":{cases},\"executed_cases\":{cases},\"expected_rejections\":{rejected},\"rejected_cases\":{rejected}}}");
    }
    pub(super) fn run() {
        source_registry_payload();
        borrowed_residual();
        state_facts();
    }
    fn source_registry_payload() {
        let source = ExternalPtr::new(LlmHandle::register(None, false, None));
        let same: Robj = source.clone().into();
        assert!(projection_same_source(&source, &same).is_ok());
        let other: Robj = ExternalPtr::new(LlmHandle::register(None, false, None)).into();
        assert!(projection_same_source(&source, &other).is_err());
        assert!(projection_same_source(&source, &Robj::from("foreign")).is_err());
        source.state.closed.set(true);
        assert!(projection_same_source(&source, &same).is_err());
        source.state.closed.set(false);
        // A shape/identity fixture cannot masquerade as an actual native model.
        assert!(source.run(|_| Ok(())).is_err());
        let a = Rc::new(1u8);
        let b = Rc::new(2u8);
        let absent = Rc::new(3u8);
        let mut registry = Vec::with_capacity(2);
        registry.push(Rc::downgrade(&a));
        let capacity = registry.capacity();
        let bytes = projection_registry_charge(capacity).unwrap();
        assert!(
            projection_reserve_registration(&mut registry, &a, &b, capacity + 1, bytes).is_err()
        );
        assert!(
            projection_reserve_registration(&mut registry, &a, &b, capacity, bytes - 1).is_err()
        );
        assert!(
            projection_reserve_registration(&mut registry, &absent, &b, capacity, bytes).is_err()
        );
        assert_eq!(registry.len(), 1);
        assert_eq!(registry.capacity(), capacity);
        assert_eq!(registry[0].as_ptr(), Rc::as_ptr(&a));
        projection_reserve_registration(&mut registry, &a, &b, capacity, bytes).unwrap();
        assert_eq!(registry.len(), 2);
        assert_eq!(registry.capacity(), registry.len());
        assert_eq!(registry[0].as_ptr(), Rc::as_ptr(&a));
        assert_eq!(registry[1].as_ptr(), Rc::as_ptr(&b));
        let new_capacity = registry.capacity();
        let new_bytes = projection_registry_charge(new_capacity).unwrap();
        assert!(
            projection_reserve_registration(&mut registry, &a, &a, new_capacity, new_bytes)
                .is_err()
        );
        assert!(
            projection_reserve_registration(&mut registry, &a, &b, new_capacity, new_bytes)
                .is_err()
        );
        let stale_capacity = new_capacity + 1;
        assert!(projection_reserve_registration(
            &mut registry,
            &a,
            &absent,
            stale_capacity,
            projection_registry_charge(stale_capacity).unwrap(),
        )
        .is_err());
        drop(b);
        let capacity = registry.capacity();
        projection_reserve_registration(
            &mut registry,
            &a,
            &absent,
            capacity,
            projection_registry_charge(capacity).unwrap(),
        )
        .unwrap();
        assert_eq!(registry.len(), 2);
        assert_eq!(registry.capacity(), registry.len());
        let output = projection_handle_only(ExternalPtr::new(LlmHandle::empty()));
        let list = output.as_list().unwrap();
        assert_eq!(list.names().unwrap().collect::<Vec<_>>(), vec!["ok", "ptr"]);
        assert_eq!(list.elt(0).unwrap().as_bool(), Some(true));
        assert!(checked_handle(&list.elt(1).unwrap()).unwrap().is_closed());
        marker("projection_transfer_source_registry_and_payload", 14, 10);
    }
    fn borrowed_residual() {
        let mut input = ProjectionResidualInput {
            steer_layers: &[2],
            steer_vectors: &[1., -1.],
            ablate_layers: &[1],
            ablate_neurons: &[2],
            ablate_values: &[0.25],
        };
        assert!(input.validate(2, 3, |_, _| true).is_ok());
        assert!(input.validate(2, 3, |_, _| false).is_err());
        assert!(input.validate(3, 3, |_, _| true).is_err());
        input.steer_layers = &[1];
        assert!(input.validate(2, 3, |_, _| true).is_err());
        input.steer_layers = &[4];
        assert!(input.validate(2, 3, |_, _| true).is_err());
        input.steer_layers = &[2];
        input.steer_vectors = &[f64::INFINITY, 0.];
        assert!(input.validate(2, 3, |_, _| true).is_err());
        input.steer_vectors = &[f32::MAX as f64 * 2., 0.];
        assert!(input.validate(2, 3, |_, _| true).is_err());
        input.steer_vectors = &[0., 0.];
        assert!(input.validate(2, 3, |_, steer| !steer).is_ok());
        input.ablate_neurons = &[3];
        assert!(input.validate(2, 3, |_, _| true).is_err());
        input.ablate_neurons = &[2];
        input.ablate_values = &[f64::NAN];
        assert!(input.validate(2, 3, |_, _| true).is_err());
        input.ablate_values = &[];
        assert!(input.validate(2, 3, |_, _| true).is_err());
        assert!(
            std::mem::size_of::<ProjectionResidualInput<'_>>()
                <= 3 * std::mem::size_of::<Vec<i32>>() + 2 * std::mem::size_of::<Vec<f64>>()
        );
        marker("projection_transfer_borrowed_residual_inputs", 12, 9);
    }
    fn state_facts() {
        for (name, code) in [
            ("factory_open", "param.1"),
            ("factory_closed", "local({param.1$closed<-TRUE; param.1})"),
            ("compiled_assignment", "local({f<-compiler::cmpfun(function(e){e$closed<-FALSE;e}); f(param.1)})"),
        ] {
            let ptr: Robj = ExternalPtr::new(LlmHandle::empty()).into();
            let created = rebirth_model_state(ptr.clone());
            let state = eval_string_with_params(code, &[&ptr, &created]).unwrap();
            let facts = rebirth_projection_state_facts(state, ptr).as_list().unwrap();
            assert_eq!(facts.len(), 3);
            assert_eq!(facts.elt(0).unwrap().as_real(), Some(0.));
            assert_eq!(facts.elt(1).unwrap().as_real(), Some(2.));
            assert_eq!(facts.elt(2).unwrap().as_real(), Some(std::mem::size_of::<unsafe extern "C" fn(extendr_api::SEXP)>() as f64));
            println!("F6E_PROJECTION_STATE_FACTS {{\"fixture\":\"{name}\",\"hash_slots\":0,\"bindings\":2,\"c_finalizer_bytes\":{},\"query_workspace_bytes\":{},\"ffi_response_bytes\":{}}}",facts.elt(2).unwrap().as_real().unwrap(),projection_state_workspace_bytes(),projection_native_profile().unwrap().response_bytes);
        }
        for code in [
            "local({e<-param.1; parent.env(e)<-globalenv(); e})",
            "local({e<-param.1; attr(e,'x')<-1L; e})",
            "local({e<-new.env(hash=FALSE,parent=emptyenv()); e$ptr<-param.0; e$closed<-FALSE; e$x<-1L; e})",
            "local({e<-new.env(hash=FALSE,parent=emptyenv()); e$ptr<-param.0; e})",
            "local({e<-param.1; e$closed<-NA; e})",
            "local({e<-param.1; e$closed<-0L; e})",
            "local({e<-param.1; e$closed<-structure(FALSE,x=1L); e})",
            "local({e<-param.1; delayedAssign('closed',stop('PROMISE EVALUATED'),assign.env=e); e})",
            "local({e<-new.env(hash=TRUE,parent=emptyenv()); e$closed<-FALSE; makeActiveBinding('ptr',function()stop('ACTIVE EVALUATED'),e); e})",
            "local({e<-new.env(hash=TRUE,size=29L,parent=emptyenv()); e$ptr<-param.0; e$closed<-FALSE; lockEnvironment(e); e})",
            "local({e<-param.1; delayedAssign('ptr',stop('POINTER PROMISE EVALUATED'),assign.env=e); e})",
            "local({e<-new.env(hash=FALSE,parent=emptyenv()); e$ptr<-param.0; e$closed<-FALSE; lockEnvironment(e); e})",
        ] {
            let ptr: Robj = ExternalPtr::new(LlmHandle::empty()).into();
            let created = rebirth_model_state(ptr.clone());
            let state = eval_string_with_params(code, &[&ptr, &created]).unwrap();
            let result = rebirth_projection_state_facts(state,ptr).as_list().unwrap();
            assert_eq!(result.elt(0).unwrap().as_bool(),Some(false));
        }
        assert!(projection_native_profile().unwrap().response_bytes >= projection_state_workspace_bytes());
        marker("projection_transfer_r_state_facts", 16, 12);
    }

}

#[cfg(test)]
#[path = "projection_review_registry_tests.rs"]
mod projection_review_registry_tests;
