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
    assert!(projection_reserve_registration(&mut registry, &a, &b, capacity + 1, bytes).is_err());
    assert!(projection_reserve_registration(&mut registry, &a, &b, capacity, bytes - 1).is_err());
    assert!(projection_reserve_registration(&mut registry, &absent, &b, capacity, bytes).is_err());
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
        projection_reserve_registration(&mut registry, &a, &a, new_capacity, new_bytes).is_err()
    );
    assert!(
        projection_reserve_registration(&mut registry, &a, &b, new_capacity, new_bytes).is_err()
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
        (
            "compiled_assignment",
            "local({f<-compiler::cmpfun(function(e){e$closed<-FALSE;e}); f(param.1)})",
        ),
    ] {
        let ptr: Robj = ExternalPtr::new(LlmHandle::empty()).into();
        let created = rebirth_model_state(ptr.clone());
        let state = eval_string_with_params(code, &[&ptr, &created]).unwrap();
        let facts = rebirth_projection_state_facts(state, ptr)
            .as_list()
            .unwrap();
        assert_eq!(facts.len(), 3);
        assert_eq!(facts.elt(0).unwrap().as_real(), Some(0.));
        assert_eq!(facts.elt(1).unwrap().as_real(), Some(2.));
        assert_eq!(
            facts.elt(2).unwrap().as_real(),
            Some(std::mem::size_of::<unsafe extern "C" fn(extendr_api::SEXP)>() as f64)
        );
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
    assert!(
        projection_native_profile().unwrap().response_bytes >= projection_state_workspace_bytes()
    );
    marker("projection_transfer_r_state_facts", 16, 12);
}
