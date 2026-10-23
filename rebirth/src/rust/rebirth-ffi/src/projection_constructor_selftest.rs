use super::*;
fn config(budget: u64, mode: &str) -> Robj {
    let mut direction = vec![0.; 32];
    direction[1] = 1.;
    list!(
        mode = mode,
        layer = if mode == "inherit" { 0. } else { 2. },
        component = "mlp_out",
        coef = if mode == "inherit" { 0. } else { 1. },
        direction = if mode == "inherit" {
            Vec::<f64>::new()
        } else {
            direction
        },
        steer_entries = 0.,
        ablate_entries = 0.,
        existing_direction_estimate = 0.,
        r_projection_fixed_bytes = 4096.,
        r_adapter_bytes = 0.,
        max_bytes = budget as f64
    )
    .into()
}
pub(super) fn run(path: &str) -> Result<(), RebirthError> {
    // R allocation/finalizer controls have no model/context and run outside
    // native borrows. The actual C finalizer releases exactly one Any owner.
    let (empty_state, empty_output) = projection_empty_payload()?;
    assert_eq!(Rc::strong_count(&empty_state), 2);
    drop(empty_output);
    eval_string("invisible(gc())").expect("R-hosted shell collection");
    assert_eq!(Rc::strong_count(&empty_state), 1);
    assert!(empty_state.closed.get() && empty_state.model.borrow().is_none());
    let tag = Robj::from(std::any::type_name::<LlmHandle>());
    // SAFETY: same protected official empty-shell allocator; null finalizer
    // is intentional and must never attempt Box::from_raw(NULL).
    let null_shell = unsafe { Robj::from_sexp(relm_r_projection_shell(tag.get().cast()).cast()) };
    drop(null_shell);
    eval_string("invisible(gc())").expect("R-hosted null shell collection");
    let source = ExternalPtr::new(LlmHandle::new(rebirth_llm::load(LoadRequest {
        path: PathBuf::from(path),
        context_length: 768,
        gpu_layers: Some(0),
        backend: BackendKind::Cpu,
        mmap: true,
        projector: None,
        threads: None,
    })?));
    let ptr: Robj = source.clone().into();
    let ints = Robj::from(Vec::<i32>::new());
    let doubles = Robj::from(Vec::<f64>::new());
    let arrays = [&ints, &doubles, &ints, &ints, &doubles];
    let before = source.run(|m| m.prompt_last_logits(&[1, 7, 13], 48))?;
    let mut cfg = config(64 * 1024 * 1024, "new_site");
    let preflight = rebirth_projection_preflight(ptr.clone(), cfg.clone());
    let preflight = preflight.as_list().unwrap();
    assert_eq!(preflight.elt(0).unwrap().as_bool(), Some(true));
    let terms = projection_field(&preflight, "terms")?.as_list().unwrap();
    let exact = projection_uint(&projection_field(&terms, "total_bytes")?)?;
    let old = HANDLES.with(|v| (v.borrow().len(), v.borrow().capacity()));
    assert!(
        projection_construct_boundary(&ptr, &config(exact - 1, "new_site"), arrays, false).is_err()
    );
    assert_eq!(
        HANDLES.with(|v| (v.borrow().len(), v.borrow().capacity())),
        old
    );
    // Mirrors the asynchronous loan boundary: an open source with its
    // model owned by a worker must not derive a context from stale metadata.
    let loan = source.state.model.borrow_mut().take();
    assert!(projection_construct_boundary(&ptr, &cfg, arrays, false).is_err());
    *source.state.model.borrow_mut() = loan;
    // A refused post-construction transfer destroys the candidate context,
    // leaves registry/source unchanged, and never opens its preallocated shell.
    assert!(projection_construct_boundary(&ptr, &cfg, arrays, true).is_err());
    assert_eq!(
        HANDLES.with(|v| (v.borrow().len(), v.borrow().capacity())),
        old
    );
    assert_eq!(
        source.run(|m| m.prompt_last_logits(&[1, 7, 13], 48))?,
        before
    );
    cfg = config(exact, "new_site");
    let result = projection_construct_boundary(&ptr, &cfg, arrays, false)?;
    let result = result.as_list().unwrap();
    assert_eq!(result.len(), 2);
    assert_eq!(result.names().unwrap().collect::<Vec<_>>(), ["ok", "ptr"]);
    let candidate_ptr = projection_field(&result, "ptr")?;
    let candidate = checked_handle(&candidate_ptr)?;
    assert!(!candidate.is_closed());
    assert_eq!(HANDLES.with(|v| v.borrow().capacity()), old.1 + 1);
    let projected = candidate.run(|m| m.prompt_last_logits(&[1, 7, 13], 48))?;
    assert!(projected
        .iter()
        .zip(&before)
        .any(|(a, b)| a.to_bits() != b.to_bits()));
    assert!(projection_construct_boundary(&candidate_ptr, &cfg, arrays, false).is_err());
    assert!(candidate
        .run(|m| m.derive_with_interventions(&InterventionSpec::new(32, 3)))
        .is_err());
    let inherited = projection_construct_boundary(
        &candidate_ptr,
        &config(64 * 1024 * 1024, "inherit"),
        arrays,
        false,
    )?;
    let inherited_ptr = projection_field(&inherited.as_list().unwrap(), "ptr")?;
    let inherited = checked_handle(&inherited_ptr)?;
    assert_eq!(
        inherited.run(|m| m.prompt_last_logits(&[1, 7, 13], 48))?,
        projected
    );
    assert!(candidate.close());
    assert_eq!(
        inherited.run(|m| m.prompt_last_logits(&[1, 7, 13], 48))?,
        projected
    );
    assert!(projection_construct_boundary(&candidate_ptr, &cfg, arrays, false).is_err());
    assert!(inherited.close());
    assert_eq!(
        source.run(|m| m.prompt_last_logits(&[1, 7, 13], 48))?,
        before
    );
    assert!(source.close());
    // Fresh compiled profile and actual inputs/terms for the independent R
    // twin; output rows are bounded schema arrays, not constructor metadata.
    let profile = ProjectionAllocationProfile::compiled(projection_native_profile()?);
    for (s, a) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
        let input = rebirth_llm::ProjectionAdmission {
            mode: ProjectionAdmissionMode::NewSite,
            hidden_size: 32,
            layers: 3,
            previous_sites: 1,
            steer_entries: s,
            ablate_entries: a,
            source_baseline_values: 0,
            metadata_bytes: 0,
            metadata_scratch_bytes: 0,
            backend: 0,
            existing_direction_estimate: 0,
            r_projection_fixed_bytes: 4096,
            r_adapter_bytes: 0,
            max_bytes: 64 * 1024 * 1024,
        };
        let e = profile.estimate(&input)?;
        let mut exact = input;
        exact.max_bytes = e.total_bytes;
        assert_eq!(profile.estimate(&exact)?.fields(), e.fields());
        exact.max_bytes -= 1;
        assert!(profile.estimate(&exact).is_err());
        fn fields<const N: usize>(v: [(&str, u64); N]) -> String {
            v.into_iter()
                .map(|(k, x)| format!("\"{k}\":{x}"))
                .collect::<Vec<_>>()
                .join(",")
        }
        println!("F6E_PROJECTION_CONSTRUCTOR_TWIN {{\"case\":\"s{s}a{a}\",\"profile\":{{{}}},\"inputs\":{{{}}},\"terms\":{{{}}}}}",fields(profile.fields()),fields(input.fields()),fields(e.fields()));
    }
    println!("F6E_PROJECTION_CONSTRUCTOR_TEST {{\"test\":\"projection_constructor_rhost_transfer\",\"status\":\"passed\",\"expected_cases\":18,\"executed_cases\":18,\"expected_rejections\":10,\"rejected_cases\":10,\"expected_values\":0,\"compared_values\":0,\"max_abs_error\":0,\"model_loads\":1,\"twin_cases\":4}}");
    Ok(())
}
