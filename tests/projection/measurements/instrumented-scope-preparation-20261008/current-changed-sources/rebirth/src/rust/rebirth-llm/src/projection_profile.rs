//! Compiled D046 admission only. This module has no plan/context constructor.
//! The public generation dispatcher cannot arm a projection until the R/native
//! combined ledger has been independently accepted.
use crate::{projection_layout as owner, InterventionSpec, LoadedModel, RebirthError};
use std::mem::{align_of, size_of};

pub const PROJECTION_PROFILE_VERSION: u64 = 2;
pub const PROJECTION_PROFILE_FIELDS: usize = 27;
pub const PROJECTION_INPUT_FIELDS: usize = 15;
pub const PROJECTION_ESTIMATE_FIELDS: usize = 14;
const MAX_BYTES: u64 = 512 * 1024 * 1024;
// No interpolated user string, architecture or filename enters this grammar.
// Scalar status/width fields have explicit decimal bounds. Fixed formatting
// frame and exact String copy have separate charges.
const ERROR_MESSAGE: &str =
    "Projection admission refused: invalid shape, capacity, ownership, arithmetic, or budget.";
const BUDGET_MESSAGE: &str = "Projection owners and working copies exceed max_bytes. Reduce projection sites or increase max_bytes.";
// Full grammar: static context-allocation refusal and the two existing adapter
// setter errors. Signed i32 uses at most 11 decimal bytes, usize at most 20.
const ABLATE_ERROR_BYTES: usize =
    "The engine rejected the ablation mask (intervention setter returned ".len()
        + 11
        + "); its width must equal the model's hidden size (".len()
        + 20
        + ").".len();
const STEER_ERROR_BYTES: usize = "The engine rejected the steering adapter (setter status ".len()
    + 11
    + ", hidden width ".len()
    + 20
    + ").".len();
const DECODE_ERROR_BYTES: usize = "llama_decode returned ".len() + 11;
const CONTEXT_ERROR_BYTES: usize = "Could not create a context for the intervened model. There may not be enough memory; free other loaded models first, or reduce context_length.".len();
const fn max(a: usize, b: usize) -> usize {
    if a > b {
        a
    } else {
        b
    }
}
const ERROR_BYTES: usize = max(
    max(
        max(ERROR_MESSAGE.len(), BUDGET_MESSAGE.len()),
        ABLATE_ERROR_BYTES,
    ),
    max(
        max(STEER_ERROR_BYTES, CONTEXT_ERROR_BYTES),
        DECODE_ERROR_BYTES,
    ),
);
struct ErrorFrame {
    bytes: [u8; ERROR_BYTES],
    len: usize,
}
impl std::fmt::Write for ErrorFrame {
    fn write_str(&mut self, text: &str) -> std::fmt::Result {
        let end = self.len.checked_add(text.len()).ok_or(std::fmt::Error)?;
        let dst = self.bytes.get_mut(self.len..end).ok_or(std::fmt::Error)?;
        dst.copy_from_slice(text.as_bytes());
        self.len = end;
        Ok(())
    }
}
pub(crate) fn bounded_error_reason(args: std::fmt::Arguments<'_>) -> String {
    use std::fmt::Write;
    let mut frame = ErrorFrame {
        bytes: [0; ERROR_BYTES],
        len: 0,
    };
    if frame.write_fmt(args).is_err() {
        frame.len = ERROR_MESSAGE.len();
        frame.bytes[..frame.len].copy_from_slice(ERROR_MESSAGE.as_bytes());
    }
    String::from_utf8(frame.bytes[..frame.len].to_vec()).expect("UTF-8 projection error")
}
pub(crate) fn bounded_intervention_error(args: std::fmt::Arguments<'_>) -> RebirthError {
    RebirthError::Intervention {
        reason: bounded_error_reason(args),
    }
}
pub(crate) fn admission_error() -> RebirthError {
    bounded_intervention_error(format_args!("{ERROR_MESSAGE}"))
}
fn add(a: u64, b: u64) -> Result<u64, RebirthError> {
    a.checked_add(b).ok_or_else(admission_error)
}
fn mul(a: u64, b: u64) -> Result<u64, RebirthError> {
    a.checked_mul(b).ok_or_else(admission_error)
}
fn sum(v: &[u64]) -> Result<u64, RebirthError> {
    v.iter().try_fold(0, |a, &b| add(a, b))
}
fn arc_header<T>() -> u64 {
    let h = 2 * size_of::<usize>();
    let a = align_of::<T>();
    h.div_ceil(a) as u64 * a as u64
}
fn arc_value<T>() -> u64 {
    let h = arc_header::<T>() + size_of::<T>() as u64;
    let a = align_of::<T>().max(align_of::<usize>()) as u64;
    h.div_ceil(a) * a
}
fn r_growth(n: u64) -> Result<u64, RebirthError> {
    Ok(match n {
        0 => 0,
        1..=8 => 8,
        9..=16 => 16,
        17..=32 => 32,
        33..=48 => 48,
        49..=64 => 64,
        65..=128 => 128,
        _ => add(n, 7)? / 8 * 8,
    })
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProjectionAdmissionMode {
    Inherit,
    NewSite,
}
#[derive(Clone, Copy, Debug)]
pub struct ProjectionAdmission {
    pub mode: ProjectionAdmissionMode,
    pub hidden_size: u64,
    pub layers: u64,
    pub previous_sites: u64,
    pub steer_entries: u64,
    pub ablate_entries: u64,
    pub source_baseline_values: u64,
    pub metadata_bytes: u64,
    pub metadata_scratch_bytes: u64,
    pub backend: u64,
    pub existing_direction_estimate: u64,
    pub r_projection_fixed_bytes: u64,
    pub r_adapter_bytes: u64,
    pub max_bytes: u64,
}
impl ProjectionAdmission {
    /// Rechecked after exact reservations and before adapter ownership transfer.
    /// Order: five FFI arrays, spec steer/mask/add, conversion row, candidate
    /// baseline. No oversized Vec is hidden by a logical-length estimate.
    pub fn validate_adapter_capacities(&self, capacities: [usize; 10]) -> Result<(), RebirthError> {
        let h = self.hidden_size;
        let hd = mul(h, self.layers)?;
        let steer = if self.steer_entries > 0 { hd } else { 0 };
        let ablate = if self.ablate_entries > 0 { hd } else { 0 };
        let expected = [
            self.steer_entries,
            mul(h, self.steer_entries)?,
            self.ablate_entries,
            self.ablate_entries,
            self.ablate_entries,
            steer,
            ablate,
            ablate,
            if steer > 0 { h } else { 0 },
            steer,
        ];
        if capacities
            .iter()
            .zip(expected)
            .any(|(&actual, wanted)| actual as u64 != wanted)
        {
            return Err(admission_error());
        }
        Ok(())
    }
    pub fn fields(&self) -> [(&'static str, u64); PROJECTION_INPUT_FIELDS] {
        [
            (
                "mode",
                u64::from(self.mode == ProjectionAdmissionMode::NewSite),
            ),
            ("hidden_size", self.hidden_size),
            ("layers", self.layers),
            ("previous_sites", self.previous_sites),
            ("steer_entries", self.steer_entries),
            ("ablate_entries", self.ablate_entries),
            ("source_baseline_values", self.source_baseline_values),
            ("metadata_bytes", self.metadata_bytes),
            ("metadata_scratch_bytes", self.metadata_scratch_bytes),
            (
                "existing_direction_estimate",
                self.existing_direction_estimate,
            ),
            ("r_projection_fixed_bytes", self.r_projection_fixed_bytes),
            ("r_adapter_bytes", self.r_adapter_bytes),
            ("max_bytes", self.max_bytes),
            ("backend", self.backend),
            ("production_armed", 1),
        ]
    }
}
/// Compiled by rebirth-ffi, never read from an R-supplied number.
#[derive(Clone, Copy, Debug, Default)]
pub struct ProjectionFfiProfile {
    pub fixed_bytes: u64,
    pub command_bytes: u64,
    pub response_bytes: u64,
    pub adapter_fixed_bytes: u64,
    pub registry_bytes: u64,
    pub handle_tag_bytes: u64,
}
#[derive(Clone, Copy, Debug, Default)]
pub struct ProjectionEstimate {
    pub direction_bytes: u64,
    pub plan_bytes: u64,
    pub context_bytes: u64,
    pub frame_bytes: u64,
    pub probe_bytes: u64,
    pub projection_bytes: u64,
    pub residual_probe_bytes: u64,
    pub adapter_data_bytes: u64,
    pub adapter_fixed_bytes: u64,
    pub metadata_bytes: u64,
    pub r_projection_bytes: u64,
    pub r_adapter_bytes: u64,
    pub existing_direction_estimate: u64,
    pub total_bytes: u64,
}
impl ProjectionEstimate {
    pub fn fields(&self) -> [(&'static str, u64); PROJECTION_ESTIMATE_FIELDS] {
        [
            ("direction_bytes", self.direction_bytes),
            ("plan_bytes", self.plan_bytes),
            ("context_bytes", self.context_bytes),
            ("frame_bytes", self.frame_bytes),
            ("probe_bytes", self.probe_bytes),
            ("projection_bytes", self.projection_bytes),
            ("residual_probe_bytes", self.residual_probe_bytes),
            ("adapter_data_bytes", self.adapter_data_bytes),
            ("adapter_fixed_bytes", self.adapter_fixed_bytes),
            ("metadata_bytes", self.metadata_bytes),
            ("r_projection_bytes", self.r_projection_bytes),
            ("r_adapter_bytes", self.r_adapter_bytes),
            (
                "existing_direction_estimate",
                self.existing_direction_estimate,
            ),
            ("total_bytes", self.total_bytes),
        ]
    }
}
#[derive(Clone, Copy, Debug)]
pub struct ProjectionAllocationProfile {
    pub version: u64,
    pub direction_arc_header_bytes: u64,
    pub plan_arc_bytes: u64,
    pub site_bytes: u64,
    pub runtime_bytes: u64,
    pub probe_state_bytes: u64,
    pub model_owner_bytes: u64,
    pub derive_frame_bytes: u64,
    pub callback_frame_bytes: u64,
    pub probe_frame_bytes: u64,
    pub residual_probe_fixed_bytes: u64,
    pub ffi_fixed_bytes: u64,
    pub adapter_fixed_bytes: u64,
    pub error_format_bytes: u64,
    pub metadata_owner_bytes: u64,
    pub slot_bytes: u64,
    pub proof_bytes: u64,
    pub projection_info_bytes: u64,
    pub cpp_access_frame_bytes: u64,
    pub cpp_name_frame_bytes: u64,
    pub ffi_command_bytes: u64,
    pub ffi_response_bytes: u64,
    pub ffi_registry_bytes: u64,
    pub ffi_handle_tag_bytes: u64,
    pub layout_checksum: u64,
    pub max_sites: u64,
    pub max_width: u64,
}
impl ProjectionAllocationProfile {
    pub fn compiled(ffi: ProjectionFfiProfile) -> Self {
        // C++ getters return compile-time POD/stack sizes; they do not initialize
        // a backend, inspect a tensor, or allocate memory.
        let cpp_access = unsafe { crate::ffi::relm_projection_access_frame_size() } as u64;
        let cpp_name = unsafe { crate::ffi::relm_projection_name_frame_size() } as u64;
        Self {
            version: PROJECTION_PROFILE_VERSION,
            direction_arc_header_bytes: arc_header::<f64>(),
            plan_arc_bytes: arc_value::<owner::Plan>(),
            site_bytes: size_of::<owner::Site>() as u64,
            runtime_bytes: size_of::<owner::Runtime>() as u64,
            probe_state_bytes: size_of::<owner::Probe>() as u64,
            model_owner_bytes: (size_of::<LoadedModel>()
                + size_of::<crate::live_capture::LiveDispatcher>())
                as u64,
            // Actual simultaneous descriptors: request, profile, result, pending
            // entry Vec, two Arc handles, cloned site, error owner and ASCII frame.
            derive_frame_bytes: (size_of::<ProjectionAdmission>()
                + size_of::<Self>()
                + size_of::<ProjectionEstimate>()
                + size_of::<ProjectionConstructionReceipt>()
                + 2 * size_of::<ProjectionResidualArrays<'static>>()
                // Runtime value can coexist with its boxed destination during
                // installation; no optimizer-dependent stack elision assumed.
                + 2 * size_of::<owner::Runtime>()
                + size_of::<std::sync::Arc<[f64]>>()
                + size_of::<Vec<owner::Site>>()
                + 2 * size_of::<std::sync::Arc<owner::Plan>>()
                + size_of::<owner::Site>()
                + size_of::<RebirthError>()
                + size_of::<ErrorFrame>()
                + size_of::<std::fmt::Arguments<'static>>()
                + size_of::<[u8; 7]>()
                + size_of::<crate::NativeGuard>()
                + size_of::<std::sync::MutexGuard<'static, Option<Box<owner::Runtime>>>>())
                as u64
                + ffi.command_bytes,
            callback_frame_bytes: (2 * size_of::<crate::ffi::ProjectionInfo>()
                + size_of::<owner::ArithmeticFrame>()
                + size_of::<std::sync::MutexGuard<'static, Option<Box<owner::Runtime>>>>())
                as u64
                + cpp_access
                + cpp_name,
            probe_frame_bytes: (size_of::<owner::Site>()
                + size_of::<crate::generate::Batch>()
                + 4 * size_of::<i32>()
                + 2 * size_of::<*mut i32>()
                + size_of::<i8>()
                + size_of::<std::sync::Arc<[f64]>>()
                + size_of::<Box<owner::Probe>>()) as u64,
            residual_probe_fixed_bytes: crate::probe::projection_residual_probe_fixed_bytes()
                as u64,
            ffi_fixed_bytes: ffi.fixed_bytes + ffi.response_bytes + ffi.registry_bytes,
            // Baseline's Vec descriptor is inline in LoadedModel. Spec owns its
            // three Vec descriptors; only the independent conversion Vec is added.
            adapter_fixed_bytes: (size_of::<InterventionSpec>() + size_of::<Vec<f32>>()) as u64
                + ffi.adapter_fixed_bytes,
            error_format_bytes: ERROR_BYTES as u64,
            metadata_owner_bytes: 0,
            slot_bytes: size_of::<owner::Slot>() as u64,
            proof_bytes: size_of::<owner::Proof>() as u64,
            projection_info_bytes: size_of::<crate::ffi::ProjectionInfo>() as u64,
            cpp_access_frame_bytes: cpp_access,
            cpp_name_frame_bytes: cpp_name,
            ffi_command_bytes: ffi.command_bytes,
            ffi_response_bytes: ffi.response_bytes,
            ffi_registry_bytes: ffi.registry_bytes,
            ffi_handle_tag_bytes: ffi.handle_tag_bytes,
            layout_checksum: owner::layout_checksum() & ((1 << 52) - 1),
            max_sites: 32,
            max_width: 65536,
        }
    }
    pub fn fields(&self) -> [(&'static str, u64); PROJECTION_PROFILE_FIELDS] {
        [
            ("version", self.version),
            (
                "direction_arc_header_bytes",
                self.direction_arc_header_bytes,
            ),
            ("plan_arc_bytes", self.plan_arc_bytes),
            ("site_bytes", self.site_bytes),
            ("runtime_bytes", self.runtime_bytes),
            ("probe_state_bytes", self.probe_state_bytes),
            ("model_owner_bytes", self.model_owner_bytes),
            ("derive_frame_bytes", self.derive_frame_bytes),
            ("callback_frame_bytes", self.callback_frame_bytes),
            ("probe_frame_bytes", self.probe_frame_bytes),
            (
                "residual_probe_fixed_bytes",
                self.residual_probe_fixed_bytes,
            ),
            ("ffi_fixed_bytes", self.ffi_fixed_bytes),
            ("adapter_fixed_bytes", self.adapter_fixed_bytes),
            ("error_format_bytes", self.error_format_bytes),
            ("metadata_owner_bytes", self.metadata_owner_bytes),
            ("slot_bytes", self.slot_bytes),
            ("proof_bytes", self.proof_bytes),
            ("projection_info_bytes", self.projection_info_bytes),
            ("cpp_access_frame_bytes", self.cpp_access_frame_bytes),
            ("cpp_name_frame_bytes", self.cpp_name_frame_bytes),
            ("ffi_command_bytes", self.ffi_command_bytes),
            ("ffi_response_bytes", self.ffi_response_bytes),
            ("ffi_registry_bytes", self.ffi_registry_bytes),
            ("ffi_handle_tag_bytes", self.ffi_handle_tag_bytes),
            ("layout_checksum", self.layout_checksum),
            ("max_sites", self.max_sites),
            ("max_width", self.max_width),
        ]
    }
    pub fn estimate(&self, i: &ProjectionAdmission) -> Result<ProjectionEstimate, RebirthError> {
        let h = i.hidden_size;
        let d = i.layers;
        let p0 = i.previous_sites;
        if h == 0
            || h > self.max_width
            || d == 0
            || d > i32::MAX as u64
            || p0 > self.max_sites
            || i.max_bytes == 0
            || i.max_bytes > MAX_BYTES
            || (i.mode == ProjectionAdmissionMode::NewSite && p0 == self.max_sites)
        {
            return Err(admission_error());
        }
        let new = u64::from(i.mode == ProjectionAdmissionMode::NewSite);
        let p = add(p0, new)?;
        let mut e = ProjectionEstimate::default();
        if p > 0 {
            let plans = if new == 1 { 1 + u64::from(p0 > 0) } else { 1 };
            let contexts = if new == 1 { 1 + u64::from(p0 > 0) } else { 2 };
            let entries = if new == 1 { add(p0, p)? } else { p };
            e.direction_bytes = mul(p, add(mul(8, h)?, self.direction_arc_header_bytes)?)?;
            e.plan_bytes = add(
                mul(plans, self.plan_arc_bytes)?,
                mul(entries, self.site_bytes)?,
            )?;
            e.context_bytes = add(
                mul(contexts, add(mul(4, h)?, self.runtime_bytes)?)?,
                mul(2, self.model_owner_bytes)?,
            )?;
            e.frame_bytes = sum(&[
                self.derive_frame_bytes,
                self.callback_frame_bytes,
                self.ffi_fixed_bytes,
                self.error_format_bytes,
            ])?;
            e.probe_bytes = sum(&[
                mul(20, h)?,
                self.direction_arc_header_bytes,
                self.plan_arc_bytes,
                self.site_bytes,
                self.runtime_bytes,
                self.probe_state_bytes,
                self.model_owner_bytes,
                self.probe_frame_bytes,
            ])?;
            e.projection_bytes = sum(&[
                e.direction_bytes,
                e.plan_bytes,
                e.context_bytes,
                e.frame_bytes,
                e.probe_bytes,
            ])?;
            e.r_projection_bytes = add(
                i.r_projection_fixed_bytes,
                mul(add(p0, mul(2, new)?)?, r_growth(mul(8, h)?)?)?,
            )?;
        }
        let s = i.steer_entries;
        let a = i.ablate_entries;
        let is = u64::from(s > 0);
        let ia = u64::from(a > 0);
        e.residual_probe_bytes = if s > 0 || a > 0 {
            sum(&[
                mul(mul(8, h)?, d)?,
                mul(4, h)?,
                self.residual_probe_fixed_bytes,
            ])?
        } else {
            0
        };
        e.adapter_data_bytes = sum(&[
            mul(4, i.source_baseline_values)?,
            mul(mul(mul(4, h)?, d)?, 2 * is + 2 * ia)?,
            mul(mul(4, h)?, is)?,
            mul(mul(8, h)?, s)?,
            mul(4, s)?,
            mul(16, a)?,
        ])?;
        e.adapter_fixed_bytes = self.adapter_fixed_bytes;
        e.metadata_bytes = sum(&[
            i.metadata_bytes,
            i.metadata_scratch_bytes,
            self.metadata_owner_bytes,
        ])?;
        e.r_adapter_bytes = i.r_adapter_bytes;
        e.existing_direction_estimate = i.existing_direction_estimate;
        e.total_bytes = sum(&[
            e.projection_bytes,
            e.residual_probe_bytes,
            e.adapter_data_bytes,
            e.adapter_fixed_bytes,
            e.metadata_bytes,
            e.r_projection_bytes,
            e.r_adapter_bytes,
            e.existing_direction_estimate,
        ])?;
        if usize::try_from(e.total_bytes).is_err() {
            return Err(admission_error());
        }
        if e.total_bytes > i.max_bytes {
            return Err(RebirthError::Oom {
                estimate_bytes: e.total_bytes,
                budget_bytes: i.max_bytes,
                suggestion: bounded_error_reason(format_args!("{BUDGET_MESSAGE}")),
            });
        }
        Ok(e)
    }
}
/// Borrowed command. Production exposes validation/admission only, never derive.
pub struct ProjectionCommand<'a> {
    pub mode: ProjectionAdmissionMode,
    pub layer: u32,
    pub component: crate::Component,
    pub coef: f64,
    pub direction: &'a [f64],
    pub steer_entries: u64,
    pub ablate_entries: u64,
    pub existing_direction_estimate: u64,
    pub r_projection_fixed_bytes: u64,
    pub r_adapter_bytes: u64,
    pub max_bytes: u64,
}
impl LoadedModel {
    pub fn projection_preflight(
        &self,
        c: &ProjectionCommand<'_>,
        ffi: ProjectionFfiProfile,
    ) -> Result<
        (
            ProjectionAllocationProfile,
            ProjectionAdmission,
            ProjectionEstimate,
        ),
        RebirthError,
    > {
        let _native = crate::NativeGuard::try_acquire("projection admission")?;
        let h = self.hidden_size().max(0) as u64;
        let d = self.num_layers().max(0) as u64;
        if !(1..=65536).contains(&h) || d == 0 {
            return Err(admission_error());
        }
        let (supported, backend) = self.projection_model_facts(c.component);
        if c.mode == ProjectionAdmissionMode::NewSite && !supported {
            return Err(admission_error());
        }
        let slot = &self.live_capture().projection;
        let held = slot
            .runtime
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if slot.poisoned.load(std::sync::atomic::Ordering::Acquire) {
            return Err(admission_error());
        }
        let previous = held.as_ref().map_or(0, |r| r.plan.sites.len() as u64);
        if let Some(r) = held.as_ref() {
            if r.plan.width as u64 != h || r.plan.depth as u64 != d || r.row.len() as u64 != h {
                return Err(admission_error());
            }
            for site in &r.plan.sites {
                if site.direction.len() as u64 != h {
                    return Err(admission_error());
                }
            }
        }
        if c.mode == ProjectionAdmissionMode::NewSite {
            if c.direction.len() as u64 != h
                || c.layer as u64 >= d
                || !matches!(
                    c.component,
                    crate::Component::MlpOut | crate::Component::AttnOut
                )
                || !c.coef.is_finite()
                || c.coef.abs() > f32::MAX as f64
            {
                return Err(admission_error());
            }
            let norm = c
                .direction
                .iter()
                .try_fold(
                    0.,
                    |n, &x| if x.is_finite() { Some(n + x * x) } else { None },
                )
                .ok_or_else(admission_error)?;
            if !norm.is_finite() || (norm.sqrt() - 1.).abs() > 1e-12 {
                return Err(admission_error());
            }
            if held.as_ref().is_some_and(|r| {
                r.plan
                    .sites
                    .iter()
                    .any(|s| s.layer == c.layer && s.component == c.component)
            }) {
                return Err(admission_error());
            }
        } else if !c.direction.is_empty() {
            return Err(admission_error());
        }
        let profile = ProjectionAllocationProfile::compiled(ffi);
        let inputs = ProjectionAdmission {
            mode: c.mode,
            hidden_size: h,
            layers: d,
            previous_sites: previous,
            steer_entries: c.steer_entries,
            ablate_entries: c.ablate_entries,
            source_baseline_values: self
                .steering_baseline
                .as_ref()
                .map_or(0, |b| b.values.capacity() as u64),
            metadata_bytes: 0,
            metadata_scratch_bytes: 0,
            backend,
            existing_direction_estimate: c.existing_direction_estimate,
            r_projection_fixed_bytes: c.r_projection_fixed_bytes,
            r_adapter_bytes: c.r_adapter_bytes,
            max_bytes: c.max_bytes,
        };
        if inputs.source_baseline_values > 0 && inputs.steer_entries == 0 {
            return Err(admission_error());
        }
        // Reject count/overflow/budget before any metadata or direction allocation.
        let estimate = profile.estimate(&inputs)?;
        Ok((profile, inputs, estimate))
    }
}
impl LoadedModel {
    /// Unarmed transfer gate. The caller must hold the original handle's model
    /// borrow throughout validation, construction and registry transfer. Native
    /// dimensions, current plan and source baseline capacity are reread here;
    /// an R preflight receipt is never an authority for these values.
    ///
    /// Supplied residual arrays remain a validated accumulated specification,
    /// not authenticated history. All used capabilities must already be cached:
    /// no additional probe allocation or decode is hidden inside admission.
    pub fn projection_validate_transfer(
        &self,
        command: &ProjectionCommand<'_>,
        residual: &InterventionSpec,
        ffi: ProjectionFfiProfile,
    ) -> Result<
        (
            ProjectionAllocationProfile,
            ProjectionAdmission,
            ProjectionEstimate,
        ),
        RebirthError,
    > {
        let admitted = self.projection_validate_source(command, ffi)?;
        residual.projection_validate_residual(
            admitted.1.hidden_size as usize,
            admitted.1.layers as usize,
            command.steer_entries,
            command.ablate_entries,
        )?;
        self.projection_validate_cached_residual(residual)?;
        Ok(admitted)
    }
    pub(crate) fn projection_validate_source(
        &self,
        command: &ProjectionCommand<'_>,
        ffi: ProjectionFfiProfile,
    ) -> Result<
        (
            ProjectionAllocationProfile,
            ProjectionAdmission,
            ProjectionEstimate,
        ),
        RebirthError,
    > {
        if self.steering_restore_failed.get()
            || self.vision_ptr().is_some()
            || self.live_capture().projection_capture_active()
        {
            return Err(admission_error());
        }
        let admitted = self.projection_preflight(command, ffi)?;
        if command.mode == ProjectionAdmissionMode::Inherit && admitted.1.previous_sites == 0 {
            return Err(admission_error());
        }
        let h = admitted.1.hidden_size as usize;
        let d = admitted.1.layers as usize;
        let dense = h.checked_mul(d).ok_or_else(admission_error)?;
        if self.steering_baseline.as_ref().is_some_and(|b| {
            b.values.len() != dense
                || b.values.capacity() != dense
                || b.range.0 < 1
                || b.range.1 < b.range.0
                || b.range.1 as usize >= d
                || b.values.iter().any(|v| !v.is_finite())
        }) {
            return Err(admission_error());
        }
        {
            let held = self
                .live_capture()
                .projection
                .runtime
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if held.as_ref().is_some_and(|r| {
                r.plan
                    .sites
                    .iter()
                    .enumerate()
                    .any(|(i, _)| !r.proofs[i].proven)
            }) {
                return Err(admission_error());
            }
        }
        Ok(admitted)
    }
}

/// Borrowed accumulated R-native (one-based) residual arrays. No ownership copy.
#[derive(Clone, Copy)]
pub struct ProjectionResidualArrays<'a> {
    pub steer_layers: &'a [i32],
    pub steer_vectors: &'a [f64],
    pub ablate_layers: &'a [i32],
    pub ablate_neurons: &'a [i32],
    pub ablate_values: &'a [f64],
}
impl ProjectionResidualArrays<'_> {
    pub fn empty() -> Self {
        Self {
            steer_layers: &[],
            steer_vectors: &[],
            ablate_layers: &[],
            ablate_neurons: &[],
            ablate_values: &[],
        }
    }
    pub fn validate(&self, h: usize, d: usize, s: u64, a: u64) -> Result<(), RebirthError> {
        if h == 0
            || d == 0
            || self.steer_layers.len() as u64 != s
            || self.ablate_layers.len() as u64 != a
            || h.checked_mul(self.steer_layers.len()) != Some(self.steer_vectors.len())
            || self.ablate_layers.len() != self.ablate_neurons.len()
            || self.ablate_layers.len() != self.ablate_values.len()
        {
            return Err(admission_error());
        }
        for &layer in self.steer_layers {
            if layer < 2 || layer as usize > d {
                return Err(admission_error());
            }
        }
        for &value in self.steer_vectors.iter().chain(self.ablate_values) {
            if !value.is_finite() || value.abs() > f32::MAX as f64 {
                return Err(admission_error());
            }
        }
        for (&layer, &neuron) in self.ablate_layers.iter().zip(self.ablate_neurons) {
            if layer < 1 || layer as usize > d || neuron < 1 || neuron as usize > h {
                return Err(admission_error());
            }
        }
        Ok(())
    }
}
#[derive(Default, Debug)]
pub struct ProjectionConstructionReceipt {
    pub adapter_capacities: [usize; 10],
    pub projection_probe_decodes: usize,
    pub residual_probe_decodes: usize,
}

#[cfg(test)]
#[path = "projection_profile_tests.rs"]
mod tests;
