// D046 allocation/profile boundary only. There is deliberately no derive entry.
use rebirth_llm::{
    ProjectionAdmissionMode, ProjectionAllocationProfile, ProjectionCommand, ProjectionFfiProfile,
    PROJECTION_ESTIMATE_FIELDS, PROJECTION_INPUT_FIELDS, PROJECTION_PROFILE_FIELDS,
};

const PROJECTION_CONFIG_NAMES: [&str; 11] = [
    "mode",
    "layer",
    "component",
    "coef",
    "direction",
    "steer_entries",
    "ablate_entries",
    "existing_direction_estimate",
    "r_projection_fixed_bytes",
    "r_adapter_bytes",
    "max_bytes",
];
#[derive(Clone, Copy)]
struct ProjectionScalars {
    mode: ProjectionAdmissionMode,
    layer: u32,
    component: Component,
    coef: f64,
    steer_entries: u64,
    ablate_entries: u64,
    existing_direction_estimate: u64,
    r_projection_fixed_bytes: u64,
    r_adapter_bytes: u64,
    max_bytes: u64,
}
fn projection_argument() -> RebirthError {
    RebirthError::Intervention {
        reason: "Invalid projection admission configuration.".into(),
    }
}
fn projection_field(list: &List, name: &str) -> Result<Robj, RebirthError> {
    list.iter()
        .find(|(k, _)| *k == name)
        .map(|(_, v)| v)
        .ok_or_else(projection_argument)
}
fn projection_uint(value: &Robj) -> Result<u64, RebirthError> {
    let x = value.as_real().ok_or_else(projection_argument)?;
    if value.len() != 1 || !x.is_finite() || x < 0. || x.fract() != 0. || x >= 9007199254740992. {
        return Err(projection_argument());
    }
    Ok(x as u64)
}
fn projection_scalars(list: &List) -> Result<ProjectionScalars, RebirthError> {
    if list.len() != PROJECTION_CONFIG_NAMES.len()
        || PROJECTION_CONFIG_NAMES
            .iter()
            .any(|key| list.iter().filter(|(k, _)| k == key).count() != 1)
    {
        return Err(projection_argument());
    }
    let mode = projection_field(list, "mode")?;
    let mode = match mode.as_str().filter(|_| mode.len() == 1) {
        Some("new_site") => ProjectionAdmissionMode::NewSite,
        Some("inherit") => ProjectionAdmissionMode::Inherit,
        _ => return Err(projection_argument()),
    };
    let layer = projection_uint(&projection_field(list, "layer")?)?;
    let layer = if mode == ProjectionAdmissionMode::NewSite {
        u32::try_from(layer.checked_sub(1).ok_or_else(projection_argument)?)
            .map_err(|_| projection_argument())?
    } else if layer == 0 {
        0
    } else {
        return Err(projection_argument());
    };
    let component = projection_field(list, "component")?;
    let component = match component.as_str().filter(|_| component.len() == 1) {
        Some("mlp_out") => Component::MlpOut,
        Some("attn_out") => Component::AttnOut,
        _ => return Err(projection_argument()),
    };
    let coef = projection_field(list, "coef")?;
    let coefficient = coef
        .as_real()
        .filter(|x| coef.len() == 1 && x.is_finite() && x.abs() <= f32::MAX as f64)
        .ok_or_else(projection_argument)?;
    if mode == ProjectionAdmissionMode::Inherit
        && (coefficient != 0. || component != Component::MlpOut)
    {
        return Err(projection_argument());
    }
    Ok(ProjectionScalars {
        mode,
        layer,
        component,
        coef: coefficient,
        steer_entries: projection_uint(&projection_field(list, "steer_entries")?)?,
        ablate_entries: projection_uint(&projection_field(list, "ablate_entries")?)?,
        existing_direction_estimate: projection_uint(&projection_field(
            list,
            "existing_direction_estimate",
        )?)?,
        r_projection_fixed_bytes: projection_uint(&projection_field(
            list,
            "r_projection_fixed_bytes",
        )?)?,
        r_adapter_bytes: projection_uint(&projection_field(list, "r_adapter_bytes")?)?,
        max_bytes: projection_uint(&projection_field(list, "max_bytes")?)?,
    })
}
fn projection_registry_charge(capacity: usize) -> Result<u64, RebirthError> {
    let cap = capacity as u64;
    let candidate = cap.checked_add(1).ok_or_else(projection_argument)?;
    let bytes = cap
        .checked_add(candidate)
        .and_then(|n| n.checked_mul(std::mem::size_of::<Weak<HandleState>>() as u64))
        .and_then(|n| n.checked_add(std::mem::size_of::<Vec<Weak<HandleState>>>() as u64))
        .ok_or_else(projection_argument)?;
    if bytes > 512 * 1024 * 1024 {
        return Err(projection_argument());
    }
    Ok(bytes)
}
fn projection_constructor_command_bytes() -> u64 {
    use std::mem::size_of;
    (size_of::<ProjectionScalars>()
        + size_of::<ProjectionCommand<'static>>()
        + size_of::<List>()
        + 3 * size_of::<Robj>()
        // Actual construction retains five borrowed argument owners and the
        // borrowed slice descriptor alongside the five owned native copies.
        + size_of::<[&Robj;5]>()
        + size_of::<rebirth_llm::ProjectionResidualArrays<'static>>()
        + size_of::<Rc<HandleState>>()
        + size_of::<std::cell::Ref<'static,Option<LoadedModel>>>()
        + size_of::<std::cell::RefMut<'static,Vec<Weak<HandleState>>>>()
        + size_of::<NativeGuard>()
        + 2 * size_of::<Robj>()
        + size_of::<Box<dyn Any>>()
        + size_of::<Box<Box<dyn Any>>>()) as u64
        + unsafe { relm_r_projection_shell_frame_size() } as u64
}
fn projection_native_profile() -> Result<ProjectionFfiProfile, RebirthError> {
    use std::mem::size_of;
    // The five existing residual arrays own their Vec headers independently of
    // InterventionSpec. The sixth command (direction) is a borrowed R slice.
    let adapter_fixed_bytes = (3 * size_of::<Vec<i32>>() + 2 * size_of::<Vec<f64>>()) as u64;
    // Rc allocation includes two counters + aligned HandleState. LoadedModel is
    // inline and already in model_owner_bytes; remove exactly that inline value,
    // not the Option/RefCell/control padding surrounding it.
    let rc_header = (2 * size_of::<usize>()).div_ceil(std::mem::align_of::<HandleState>())
        * std::mem::align_of::<HandleState>();
    let handles = 2
        * (rc_header + size_of::<HandleState>() - size_of::<LoadedModel>()
            + size_of::<LlmHandle>()
            + size_of::<Box<dyn Any>>()
            + size_of::<ExternalPtr<LlmHandle>>());
    let registry_bytes = HANDLES.with(|h| projection_registry_charge(h.borrow().capacity()))?;
    let command_bytes = projection_constructor_command_bytes() + projection_bridge_frame_bytes();
    // No from_pairs/Vec in the new response. Arrays and borrowed iterators are
    // bounded by the exact schema counts; all R lists/CHARSXPs belong to R's
    // measured response/config skeleton, not an unspecified native reserve.
    let response_bytes =
        ((PROJECTION_PROFILE_FIELDS + PROJECTION_INPUT_FIELDS + PROJECTION_ESTIMATE_FIELDS)
            * size_of::<(&str, u64)>()
            + 5 * size_of::<Robj>()
            + 5 * size_of::<&str>()
            + 4 * size_of::<List>()
            + size_of::<std::slice::Iter<'static, (&'static str, u64)>>()) as u64;
    Ok(ProjectionFfiProfile {
        fixed_bytes: handles as u64,
        command_bytes,
        response_bytes: response_bytes
            .max(projection_state_workspace_bytes())
            .max(projection_error_response_bytes()),
        adapter_fixed_bytes,
        registry_bytes,
        handle_tag_bytes: std::any::type_name::<LlmHandle>().len() as u64,
    })
}
fn projection_error_response_bytes() -> u64 {
    use std::mem::size_of;
    // Sum both error field/outer arrays and their independently moved iterator
    // descriptors; no reliance on stack-slot reuse. R vector/name allocation
    // is charged by the measured R failure prototype. No Vec or String here.
    (size_of::<std::thread::Result<Result<Robj, RebirthError>>>()
        + size_of::<[Robj; 2]>()
        + size_of::<[Robj; 4]>()
        + size_of::<[&str; 2]>()
        + size_of::<[&str; 4]>()
        + size_of::<std::array::IntoIter<Robj, 2>>()
        + size_of::<std::array::IntoIter<Robj, 4>>()
        + size_of::<std::array::IntoIter<&str, 2>>()
        + size_of::<std::array::IntoIter<&str, 4>>()
        + 4 * size_of::<List>()
        + size_of::<(&str, &str)>()
        + 2 * size_of::<&u64>()) as u64
}
fn projection_numeric_list<const N: usize>(fields: [(&str, u64); N]) -> Result<Robj, RebirthError> {
    List::from_names_and_values(
        fields.iter().map(|(k, _)| *k),
        fields.iter().map(|(_, v)| Robj::from(*v as f64)),
    )
    .map(Into::into)
    .map_err(|_| projection_argument())
}
// Avoid error.to_string()/format! geometric copies in this new path. The native
// error's one exact owned reason is borrowed into the R condition. Panic output
// is a fixed message, not an unbounded second copy of its payload.
fn projection_resolve(result: std::thread::Result<Result<Robj, RebirthError>>) -> Robj {
    match result {
        Ok(Ok(value)) => value,
        outcome => {
            let (class, message) = match &outcome {
                Ok(Err(RebirthError::Intervention { reason })) => {
                    ("relm_error_intervention", reason.as_str())
                }
                Ok(Err(RebirthError::Oom { suggestion, .. })) => {
                    ("relm_error_oom", suggestion.as_str())
                }
                Ok(Err(e)) => (
                    e.class(),
                    "Projection admission could not access the model.",
                ),
                Err(_) => (
                    "relm_error_internal",
                    "Projection admission failed internally.",
                ),
                Ok(Ok(_)) => unreachable!(),
            };
            let fields = match &outcome {
                Ok(Err(RebirthError::Oom {
                    estimate_bytes,
                    budget_bytes,
                    ..
                })) => List::from_names_and_values(
                    ["estimate_bytes", "budget_bytes"],
                    [
                        Robj::from(*estimate_bytes as f64),
                        Robj::from(*budget_bytes as f64),
                    ],
                ),
                _ => List::from_names_and_values(["reason"], [Robj::from(message)]),
            }
            .expect("fixed projection error fields");
            List::from_names_and_values(
                ["ok", "class", "message", "fields"],
                [
                    Robj::from(false),
                    Robj::from(class),
                    Robj::from(message),
                    fields.into(),
                ],
            )
            .expect("fixed projection error response")
            .into()
        }
    }
}
#[extendr]
fn rebirth_projection_allocation_profile() -> Robj {
    projection_resolve(catch_unwind(AssertUnwindSafe(|| {
        projection_numeric_list(
            ProjectionAllocationProfile::compiled(projection_native_profile()?).fields(),
        )
    })))
}
#[extendr]
fn rebirth_projection_preflight(ptr: Robj, config: Robj) -> Robj {
    projection_resolve(catch_unwind(AssertUnwindSafe(|| {
        let list = config.as_list().ok_or_else(projection_argument)?;
        let s = projection_scalars(&list)?;
        let direction = projection_field(&list, "direction")?;
        if direction.is_altrep() {
            return Err(projection_argument());
        }
        let direction = direction.as_real_slice().ok_or_else(projection_argument)?;
        let command = ProjectionCommand {
            mode: s.mode,
            layer: s.layer,
            component: s.component,
            coef: s.coef,
            direction,
            steer_entries: s.steer_entries,
            ablate_entries: s.ablate_entries,
            existing_direction_estimate: s.existing_direction_estimate,
            r_projection_fixed_bytes: s.r_projection_fixed_bytes,
            r_adapter_bytes: s.r_adapter_bytes,
            max_bytes: s.max_bytes,
        };
        let handle = checked_handle(&ptr)?;
        let (profile, inputs, terms) = handle
            .run(|model| model.projection_preflight(&command, projection_native_profile()?))?;
        List::from_names_and_values(
            ["ok", "armed", "profile", "inputs", "terms"],
            [
                Robj::from(true),
                Robj::from(false),
                projection_numeric_list(profile.fields())?,
                projection_numeric_list(inputs.fields())?,
                projection_numeric_list(terms.fields())?,
            ],
        )
        .map(Into::into)
        .map_err(|_| projection_argument())
    })))
}
// Internal model-free fixture, invoked only by the owner-controlled Rscript
// harness. R owns initialization and executes this on its main thread; no
// embedded initializer or additional dependency is needed. Never in NAMESPACE.
#[cfg(feature = "selftest")]
#[extendr]
fn rebirth_selftest_projection_ledger() -> Robj {
    projection_resolve(catch_unwind(AssertUnwindSafe(|| {
        projection_boundary_selftest::projection_profile_ffi_descriptors_and_schema_are_exact();
        Ok(list!(ok = true).into())
    })))
}
#[cfg(feature = "selftest")]
#[path = "projection_boundary_selftest.rs"]
mod projection_boundary_selftest;
