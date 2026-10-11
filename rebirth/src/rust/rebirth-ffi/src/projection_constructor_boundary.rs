extern "C" {
    fn relm_r_projection_shell_frame_size() -> usize;
    fn relm_r_projection_shell(tag: *mut std::ffi::c_void) -> *mut std::ffi::c_void;
    fn relm_r_projection_shell_install(
        shell: *mut std::ffi::c_void,
        address: *mut std::ffi::c_void,
    );
}
// Exactly extendr's documented Box<Box<dyn Any>> pointee contract, with a
// null-safe installed-header finalizer. No R calls or pointer-layout inspection.
#[no_mangle]
extern "C" fn relm_projection_drop_any(address: *mut std::ffi::c_void) {
    if !address.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| {
            // SAFETY: installed once from Box::into_raw below, cleared by C
            // before this callback, hence dropped at most once.
            unsafe {
                drop(Box::from_raw(address.cast::<Box<dyn Any>>()));
            }
        }));
    }
}
fn projection_empty_payload() -> Result<(Rc<HandleState>, Robj), RebirthError> {
    let tag = Robj::from(std::any::type_name::<LlmHandle>());
    // SAFETY: R main thread; tag remains protected; returned shell is immediately
    // protected by Robj. Its null address owns no Rust/native resource yet.
    let shell = unsafe { Robj::from_sexp(relm_r_projection_shell(tag.get().cast()).cast()) };
    let output = List::from_names_and_values(["ok", "ptr"], [Robj::from(true), shell.clone()])
        .map_err(|_| projection_argument())?;
    // R pointer/tag/finalizer/list are complete. Remaining ownership allocations
    // are Rust only, and the official address setter cannot allocate or evaluate.
    let state = Rc::new(HandleState {
        model: RefCell::new(None),
        closed: Cell::new(true),
        fixture: Cell::new(None),
    });
    let handle = LlmHandle {
        state: state.clone(),
    };
    let boxed: Box<dyn Any> = Box::new(handle);
    let boxed = Box::new(boxed);
    // SAFETY: shell uses the matching null-safe finalizer; transfer exactly once.
    unsafe {
        relm_r_projection_shell_install(shell.get().cast(), Box::into_raw(boxed).cast());
    }
    Ok((state, output.into()))
}
// Bounded product constructor; the registered bridge preserves this transaction.
fn projection_construct_boundary(
    ptr: &Robj,
    config: &Robj,
    values: [&Robj; 5],
    refuse_transfer: bool,
) -> Result<Robj, RebirthError> {
    let list = config.as_list().ok_or_else(projection_argument)?;
    let s = projection_scalars(&list)?;
    let direction = projection_field(&list, "direction")?;
    if direction.is_altrep() || values.iter().any(|v| v.is_altrep()) {
        return Err(projection_argument());
    }
    let arrays = rebirth_llm::ProjectionResidualArrays {
        steer_layers: values[0]
            .as_integer_slice()
            .ok_or_else(projection_argument)?,
        steer_vectors: values[1].as_real_slice().ok_or_else(projection_argument)?,
        ablate_layers: values[2]
            .as_integer_slice()
            .ok_or_else(projection_argument)?,
        ablate_neurons: values[3]
            .as_integer_slice()
            .ok_or_else(projection_argument)?,
        ablate_values: values[4].as_real_slice().ok_or_else(projection_argument)?,
    };
    let command = ProjectionCommand {
        mode: s.mode,
        layer: s.layer,
        component: s.component,
        coef: s.coef,
        direction: direction.as_real_slice().ok_or_else(projection_argument)?,
        steer_entries: s.steer_entries,
        ablate_entries: s.ablate_entries,
        existing_direction_estimate: s.existing_direction_estimate,
        r_projection_fixed_bytes: s.r_projection_fixed_bytes,
        r_adapter_bytes: s.r_adapter_bytes,
        max_bytes: s.max_bytes,
    };
    let source = checked_handle(ptr)?;
    // All R allocations precede the model borrow/registry transaction. This
    // empty, closed shell owns no native context if an R allocation unwinds.
    let (target, output) = projection_empty_payload()?;
    projection_same_source(source, ptr)?;
    // No R call from here until all native borrows/guards have been released.
    let _guard = native_guard("projection constructor transaction")?;
    if source.state.closed.get() {
        return Err(projection_argument());
    }
    let held = source
        .state
        .model
        .try_borrow()
        .map_err(|_| projection_argument())?;
    let model = held.as_ref().ok_or_else(projection_argument)?;
    let profile = projection_native_profile()?;
    // The constructor validates these borrowed arrays against its authoritative
    // H/D and complete budget before copying any of the five residual arrays.
    HANDLES.with(|registry| {
        let mut registry = registry
            .try_borrow_mut()
            .map_err(|_| projection_argument())?;
        let capacity = registry.capacity();
        if projection_registry_charge(capacity)? != profile.registry_bytes
            || !registry
                .iter()
                .any(|w| w.as_ptr() == Rc::as_ptr(&source.state))
        {
            return Err(projection_argument());
        }
        let (derived, _receipt) = model.projection_construct(&command, arrays, profile)?;
        // Only the private harness can inject a postconstruction refusal. The
        // normal bridge always forwards false; product builds omit that branch.
        #[cfg(feature = "projection-private")]
        let admitted_capacity = if refuse_transfer {
            capacity.checked_add(1).ok_or_else(projection_argument)?
        } else {
            capacity
        };
        #[cfg(not(feature = "projection-private"))]
        let admitted_capacity = {
            let _ = refuse_transfer;
            capacity
        };
        projection_reserve_registration(
            &mut registry,
            &source.state,
            &target,
            admitted_capacity,
            profile.registry_bytes,
        )?;
        *target.model.borrow_mut() = Some(derived);
        target.closed.set(false);
        Ok(())
    })?;
    Ok(output)
}

#[cfg(feature = "selftest")]
#[extendr]
fn rebirth_selftest_projection_constructor(path: &str) -> Robj {
    projection_resolve(catch_unwind(AssertUnwindSafe(|| {
        #[cfg(not(feature = "projection-private"))]
        {
            let _ = path;
            Err(projection_argument())
        }
        #[cfg(feature = "projection-private")]
        {
            projection_constructor_selftest::run(path)?;
            Ok(list!(ok = true).into())
        }
    })))
}
#[cfg(feature = "projection-private")]
#[path = "projection_constructor_selftest.rs"]
mod projection_constructor_selftest;
