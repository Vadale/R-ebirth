//! Bounded, R-free F6a request and one-state payload. Admission reads metadata
//! only; no tokenizer, context or R object is touched by `preflight`.
use crate::{CaptureRow, Component, ModelMetadata, RebirthError, TokenLogit};

pub const LIVE_MAX_STATES: usize = 1024;
pub const LIVE_MATERIALIZED_BYTES: u64 = 32 * 1024 * 1024;
pub const LIVE_VECTOR_BYTES: u64 = 1024 * 1024;
pub const LIVE_TRANSPORT_BYTES: u64 = 8 * 1024 * 1024;
pub const LIVE_SPILL_BYTES: u64 = 2 * 1024 * 1024 * 1024;
pub const LIVE_BATCH_ROWS: usize = 4096;
pub const LIVE_BATCH_BYTES: u64 = 1024 * 1024;
pub const LIVE_VECTOR_HEADER_BYTES: u64 = 48;
pub const LIVE_ALLOCATION_ALIGNMENT: u64 = 8;

#[derive(Debug, Clone)]
pub struct LiveRequest {
    pub layers: Vec<u32>,
    pub components: Vec<Component>,
    pub top: usize,
    pub budget_bytes: u64,
    pub r_fixed_bytes: u64,
    pub spill: bool,
    pub spill_dir: String,
    pub trace_id: String,
    pub model: String,
    pub spec_key: String,
    pub steering: Vec<crate::LiveSteer>,
}

#[derive(Debug, Clone)]
pub struct LiveEstimate {
    pub steering_probe_bytes: u64,
    pub steering_probe_fixed_bytes: u64,
    pub steering_bytes: u64,
    pub steering_descriptor_bytes: u64,
    pub native_fixed_bytes: u64,
    pub ffi_intern_bytes: u64,
    pub schema_frame_bytes: u64,
    pub record_frame_bytes: u64,
    pub arrow_metadata_workspace_bytes: u64,
    pub arrow_body_bytes: u64,
    pub r_payload_bytes: u64,
    pub r_assembly_bytes: u64,
    pub native_logits_bytes: u64,
    pub capture_writer_bytes: u64,
    pub wp10_peak_bytes: u64,
    #[cfg_attr(not(feature = "spill"), allow(dead_code))]
    pub(crate) capture_control_bytes: u64,
    pub materialized_bytes: u64,
    pub logits_bytes: u64,
    pub native_capture_bytes: u64,
    pub transient_bytes: u64,
    pub spill_bytes: u64,
    pub batch_bytes: u64,
    pub spilled: bool,
    pub n_values: u64,
    pub n_vectors: usize,
    pub hidden_size: usize,
    pub max_piece_bytes: u64,
}

#[derive(Debug)]
pub enum LiveTrace {
    Memory(Vec<CaptureRow>),
    #[cfg(feature = "spill")]
    Spilled(Box<LiveSpillReport>),
}

#[cfg(feature = "spill")]
#[derive(Debug)]
pub struct LiveSpillReport {
    pub report: crate::SpillReport,
    pub spec_key: String,
    pub batch_bytes: u64,
    pub serialized_bytes: u64,
    pub(crate) owned: Option<crate::live_spill::OwnedLiveFile>,
}

#[derive(Debug)]
pub struct LiveState {
    pub job_id: u64,
    pub state_id: usize,
    pub token_id: i32,
    pub context_pos: u32,
    pub source_pos: u32,
    pub prompt_token_count: usize,
    pub elapsed: f64,
    pub steering_revision: usize,
    pub applied_after_state: usize,
    pub effective_source_pos: u32,
    pub steering: Vec<crate::LiveSteeringRow>,
    pub logits: Vec<TokenLogit>,
    pub trace: LiveTrace,
}

pub(crate) fn invalid(reason: &str) -> RebirthError {
    RebirthError::Argument {
        argument: "on_state".into(),
        reason: reason.into(),
    }
}
pub(crate) fn trace_error(reason: impl Into<String>) -> RebirthError {
    RebirthError::Trace {
        reason: reason.into(),
    }
}
pub(crate) fn overflow() -> RebirthError {
    invalid("live size arithmetic overflow")
}
pub(crate) fn add(a: u64, b: u64) -> Result<u64, RebirthError> {
    a.checked_add(b).ok_or_else(overflow)
}
pub(crate) fn mul(a: u64, b: u64) -> Result<u64, RebirthError> {
    a.checked_mul(b).ok_or_else(overflow)
}
pub(crate) fn sum(values: &[u64]) -> Result<u64, RebirthError> {
    values.iter().try_fold(0, |total, &value| add(total, value))
}
/// R's small-vector allocation pools on the supported 64-bit allocation profile.
pub fn live_r_vector_bytes(bytes: u64) -> Result<u64, RebirthError> {
    let pooled = [0, 8, 16, 32, 48, 64, 128]
        .into_iter()
        .find(|&n| n >= bytes)
        .map(Ok)
        .unwrap_or_else(|| add(bytes, 7).map(|n| n / 8 * 8))?;
    add(LIVE_VECTOR_HEADER_BYTES, pooled)
}
fn grow(bytes: u64) -> Result<u64, RebirthError> {
    Ok(live_r_vector_bytes(bytes)? - LIVE_VECTOR_HEADER_BYTES)
}
fn chars(bytes: u64) -> Result<u64, RebirthError> {
    live_r_vector_bytes(add(bytes, 1)?)
}

impl LiveRequest {
    pub fn preflight(
        &self,
        metadata: &ModelMetadata,
        max_tokens: usize,
    ) -> Result<LiveEstimate, RebirthError> {
        let direction_values = self
            .steering
            .iter()
            .try_fold(0_u64, |n, entry| add(n, entry.direction.len() as u64))?;
        let estimate = self.preflight_with_steering_shape(
            metadata,
            max_tokens,
            self.steering.len(),
            direction_values,
        )?;
        crate::live_steering::validate_entries(&self.steering, metadata)?;
        Ok(estimate)
    }

    /// Metadata-only sizing before the FFI copies original direction slices.
    /// The complete preflight rechecks actual entry lengths, order and values.
    pub fn preflight_with_steering_shape(
        &self,
        metadata: &ModelMetadata,
        max_tokens: usize,
        steer_count: usize,
        direction_values: u64,
    ) -> Result<LiveEstimate, RebirthError> {
        if max_tokens == 0
            || max_tokens > LIVE_MAX_STATES
            || self.top > 128
            || self.top > metadata.vocab_size.max(0) as usize
        {
            return Err(invalid(
                "live mode requires 1..1024 tokens and top in 0..min(128, vocabulary_size)",
            ));
        }
        if self.components.is_empty()
            || self
                .components
                .iter()
                .enumerate()
                .any(|(i, v)| self.components[..i].contains(v))
            || self
                .layers
                .iter()
                .enumerate()
                .any(|(i, &v)| v >= metadata.layers.max(0) as u32 || self.layers[..i].contains(&v))
            || (self.layers.is_empty() && self.top == 0)
        {
            return Err(invalid("live capture requires unique valid layers/components and at least logits or activations"));
        }
        for &component in &self.components {
            if !self.layers.is_empty()
                && crate::trace::component_name(&metadata.architecture, component).is_none()
            {
                return Err(trace_error(format!(
                    "The '{}' component is not observable for '{}'.",
                    component.as_str(),
                    metadata.architecture
                )));
            }
        }
        if self.budget_bytes == 0
            || self.budget_bytes > LIVE_MATERIALIZED_BYTES
            || self.r_fixed_bytes < LIVE_VECTOR_HEADER_BYTES
        {
            return Err(invalid(
                "invalid live materialization budget or empty-state allocation profile",
            ));
        }
        if self.trace_id.is_empty()
            || !self
                .trace_id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        {
            return Err(invalid("live trace_id must be a path-safe nonce"));
        }
        if self.spill && !std::path::Path::new(&self.spill_dir).is_absolute() {
            return Err(invalid("live spill_dir must be absolute"));
        }
        let h = u64::try_from(metadata.hidden_size)
            .map_err(|_| invalid("invalid model hidden width"))?;
        let vectors = self
            .layers
            .len()
            .checked_mul(self.components.len())
            .ok_or_else(overflow)?;
        let n = mul(h, vectors as u64)?;
        if h == 0
            || ((!self.layers.is_empty() || steer_count > 0) && mul(h, 4)? > LIVE_VECTOR_BYTES)
        {
            return Err(RebirthError::Oom {
                estimate_bytes: mul(h, 4)?,
                budget_bytes: LIVE_VECTOR_BYTES,
                suggestion: "Select a model whose activation vector fits the 1 MiB live limit."
                    .into(),
            });
        }
        let steer_count = steer_count as u64;
        if direction_values != mul(h, steer_count)? {
            return Err(invalid(
                "Live steering direction lengths do not match the model width and entry count.",
            ));
        }
        let descriptor_count = (self.steering.capacity() as u64).max(steer_count);
        let steering_descriptor_bytes = if steer_count == 0 {
            0
        } else {
            sum(&[
                mul(
                    descriptor_count,
                    crate::LiveSteer::descriptor_bytes() as u64,
                )?,
                crate::live_steering::session_bytes() as u64,
                std::mem::size_of::<Option<crate::live_steering::SteeringBaseline>>() as u64,
                3 * std::mem::size_of::<Vec<u8>>() as u64,
                std::mem::size_of::<usize>() as u64,
            ])?
        };
        let steering_transport_bytes = if steer_count == 0 {
            0
        } else {
            sum(&[
                mul(8, direction_values)?,
                mul(52, steer_count)?,
                steering_descriptor_bytes,
            ])?
        };
        let audit = if steer_count == 0 {
            0
        } else {
            sum(&[
                mul(2, grow(mul(4, steer_count)?)?)?,
                grow(mul(8, steer_count)?)?,
                8,
            ])?
        };
        let steering_bytes = if steer_count == 0 {
            0
        } else {
            sum(&[
                steering_transport_bytes,
                mul(8, mul(h, metadata.layers.max(0) as u64)?)?,
                mul(4, h)?,
                live_r_vector_bytes(mul(8, direction_values)?)?,
                mul(2, self.r_fixed_bytes)?,
                mul(2, grow(mul(4, steer_count)?)?)?,
                mul(2, grow(mul(8, steer_count)?)?)?,
                mul(3, live_r_vector_bytes(mul(4, steer_count)?)?)?,
                live_r_vector_bytes(mul(8, steer_count)?)?,
            ])?
        };
        let steering_probe_fixed_bytes = if steer_count == 0 {
            0
        } else {
            crate::probe::live_probe_fixed_bytes() as u64
        };
        let steering_probe_bytes = if steer_count == 0 {
            0
        } else {
            sum(&[
                mul(4, mul(h, metadata.layers.max(0) as u64)?)?,
                mul(4, h)?,
                mul(
                    metadata.layers.max(0) as u64,
                    std::mem::size_of::<bool>() as u64,
                )?,
                steering_probe_fixed_bytes,
            ])?
        };
        let b = metadata.max_token_piece_bytes;
        let k = self.top as u64;
        let c = self.components.len() as u64;
        let component_chars = self.components.iter().try_fold(0, |total, comp| {
            add(total, chars(comp.as_str().len() as u64)?)
        })?;
        let component_bytes = self
            .components
            .iter()
            .map(|comp| comp.as_str().len() as u64)
            .sum::<u64>();
        let logits = sum(&[
            mul(3, grow(mul(4, k)?)?)?,
            mul(3, grow(mul(8, k)?)?)?,
            mul(k, chars(b)?)?,
            if k > 0 { 8 } else { 0 },
        ])?;
        let trace_vectors = add(mul(4, grow(mul(4, n)?)?)?, mul(3, grow(mul(8, n)?)?)?)?;
        let trace = if n == 0 {
            0
        } else {
            sum(&[
                mul(44, n)?.max(trace_vectors),
                chars(b)?,
                component_chars,
                8,
            ])?
        };
        let logits_bytes = sum(&[self.r_fixed_bytes, logits, audit])?;
        let materialized_bytes = add(logits_bytes, trace)?;
        let strings = sum(&[
            self.spill_dir.capacity() as u64,
            self.trace_id.capacity() as u64,
            self.model.capacity() as u64,
            self.spec_key.capacity() as u64,
        ])?;
        let selector_bytes = add(
            mul(self.layers.capacity() as u64, 4)?,
            mul(
                self.components.capacity() as u64,
                std::mem::size_of::<Component>() as u64,
            )?,
        )?;
        // AsyncRequest and active capture each retain one owned request. Fixed
        // object sizes are compiled, not guessed from a per-row multiplier.
        let mut native_fixed_bytes = sum(&[
            crate::async_job::live_control_bytes() as u64,
            mul(2, std::mem::size_of::<LiveRequest>() as u64)?,
            mul(2, add(strings, selector_bytes)?)?,
            std::mem::size_of::<LiveEstimate>() as u64,
            std::mem::size_of::<LiveState>() as u64,
        ])?;
        let capture_selectors = crate::live_capture::capture_allocation_bytes(
            0,
            vectors,
            self.components.len(),
            vectors,
            vectors,
        )
        .ok_or_else(overflow)? as u64;
        let capture_memory = sum(&[
            mul(n, 4)?,
            capture_selectors,
            mul(add(vectors as u64, 1)?, b)?,
        ])?;
        if add(steering_transport_bytes, native_fixed_bytes)? > LIVE_TRANSPORT_BYTES
            && steer_count > 0
        {
            return Err(RebirthError::Oom {
                estimate_bytes: add(steering_transport_bytes, native_fixed_bytes)?,
                budget_bytes: LIVE_TRANSPORT_BYTES,
                suggestion:
                    "Reduce the number of original steering entries to fit live owned transport."
                        .into(),
            });
        }
        let native_capture_bytes =
            sum(&[capture_memory, native_fixed_bytes, steering_transport_bytes])?;
        let spilled = vectors > 0
            && (materialized_bytes > self.budget_bytes
                || native_capture_bytes > LIVE_TRANSPORT_BYTES);
        if logits_bytes > self.budget_bytes || (spilled && !self.spill) {
            return Err(RebirthError::Oom {
                estimate_bytes: materialized_bytes,
                budget_bytes: self.budget_bytes,
                suggestion: "Narrow layers/components/top, raise the live budget, or enable spill."
                    .into(),
            });
        }
        #[cfg(not(feature = "spill"))]
        if spilled {
            return Err(trace_error("This native build has no live spill writer."));
        }
        #[cfg(feature = "spill")]
        let arrow = if spilled {
            crate::live_spill::arrow_bounds(self, h as usize, b)?
        } else {
            crate::live_spill::ArrowBounds::default()
        };
        #[cfg(feature = "spill")]
        let (
            schema_frame_bytes,
            record_frame_bytes,
            batch_bytes,
            arrow_body_bytes,
            spill_bytes,
            arrow_metadata_workspace_bytes,
            arrow_fixed,
        ) = (
            arrow.schema_frame,
            arrow.record_frame,
            arrow.batch_bytes,
            arrow.body_bytes,
            mul(arrow.per_file, max_tokens as u64)?,
            arrow.workspace,
            arrow.fixed,
        );
        #[cfg(not(feature = "spill"))]
        let (
            schema_frame_bytes,
            record_frame_bytes,
            batch_bytes,
            arrow_body_bytes,
            spill_bytes,
            arrow_metadata_workspace_bytes,
            arrow_fixed,
        ) = (0, 0, 0, 0, 0, 0, 0);
        if spill_bytes > LIVE_SPILL_BYTES {
            return Err(RebirthError::Oom { estimate_bytes: spill_bytes, budget_bytes: LIVE_SPILL_BYTES, suggestion: "Narrow live capture filters or reduce max_tokens to fit the full-call spill bound.".into() });
        }
        if spilled {
            // Report, exclusive file guard and open/lease path copies. The
            // maximum spec is also stored in the schema (in arrow_fixed).
            let path = sum(&[
                self.spill_dir.len() as u64,
                1,
                self.trace_id.len() as u64,
                1,
                4,
                6,
            ])?;
            let spec = self
                .state_spec(
                    LIVE_MAX_STATES,
                    i32::MAX as usize,
                    i32::MAX as u32 - 1,
                    batch_bytes,
                )
                .len() as u64;
            native_fixed_bytes = sum(&[
                native_fixed_bytes,
                arrow_fixed,
                mul(4, path)?,
                mul(2, spec)?,
                self.trace_id.len() as u64 + 5,
                selector_bytes,
                4,
            ])?;
        }
        let capture_control_bytes = sum(&[
            capture_selectors,
            native_fixed_bytes,
            b,
            steering_transport_bytes,
        ])?;
        let one_row = sum(&[mul(h, 4)?, b, std::mem::size_of::<CaptureRow>() as u64])?;
        // The queue descriptor reserve and all retained selectors/control are
        // inside the8MiB cap; producer and consumer rows are separate scratch.
        if spilled
            && sum(&[
                capture_control_bytes,
                64 * std::mem::size_of::<CaptureRow>() as u64,
                one_row,
            ])? > LIVE_TRANSPORT_BYTES
        {
            return Err(RebirthError::Oom {
                estimate_bytes: add(capture_control_bytes, one_row)?,
                budget_bytes: LIVE_TRANSPORT_BYTES,
                suggestion: "Narrow live selectors/metadata to fit the capture transport.".into(),
            });
        }
        let capture_writer_bytes = if spilled {
            sum(&[
                LIVE_TRANSPORT_BYTES,
                mul(2, one_row)?,
                mul(4, arrow_body_bytes)?,
                arrow_metadata_workspace_bytes,
            ])?
        } else {
            capture_memory
        };
        let (transport_n, transport_v) = if spilled { (0, 0) } else { (n, vectors as u64) };
        let r_payload_bytes = if spilled {
            logits_bytes
        } else {
            sum(&[
                logits_bytes,
                mul(4, grow(mul(4, transport_n)?)?)?,
                grow(mul(8, transport_n)?)?,
                mul(3, grow(mul(4, transport_v)?)?)?,
                grow(mul(8, c)?)?,
                grow(8)?,
                chars(b)?,
                component_chars,
            ])?
        };
        let r_assembly_bytes = if spilled {
            0
        } else {
            add(
                mul(2, live_r_vector_bytes(mul(4, n)?)?)?,
                mul(2, live_r_vector_bytes(mul(8, n)?)?)?,
            )?
        };
        // Existing trace_payload: one token and at most3 components. Both
        // HashMaps fit4 buckets; both level Vecs have capacity4, and keys borrow
        // existing labels. R list/workspace objects are in r_fixed_bytes.
        let ffi_intern_bytes = sum(&[
            20 * std::mem::size_of::<Vec<u8>>() as u64,
            2 * std::mem::size_of::<std::collections::HashMap<&str, i32>>() as u64,
            2 * (4 * (std::mem::size_of::<(Option<&str>, i32)>() + 1) + 16) as u64,
            8 * std::mem::size_of::<String>() as u64,
            14 * std::mem::size_of::<(&str, usize)>() as u64,
            b,
            component_bytes,
        ])?;
        let native_ffi = sum(&[
            mul(24, transport_n)?,
            mul(12, transport_v)?,
            mul(44, k)?,
            mul(16, steer_count)?,
            ffi_intern_bytes,
        ])?;
        let native_logits_bytes = sum(&[
            mul(metadata.vocab_size.max(0) as u64, 20)?,
            mul(
                k,
                add(
                    (crate::generate::top_rank_bytes()
                        + std::mem::size_of::<(usize, f32, f64)>()
                        + std::mem::size_of::<TokenLogit>()) as u64,
                    b,
                )?,
            )?,
            b / 3,
            b,
        ])?;
        // D-038's complete existing six-term peak; the live state can coexist
        // with token delivery/output so no non-overlap is assumed.
        let wp10_peak_bytes = (128 * 256 + 262144)
            + (128 + 16384)
            + (128 * 64 + 65536)
            + 8 * 8388608
            + (8192 + 1024 * 64 + 65536)
            + (8192 + 2048 * 64 + 12 * 65536);
        let r_mode = if spilled {
            logits_bytes
        } else {
            materialized_bytes
        };
        let transient_bytes = sum(&[
            mul(2, r_mode)?,
            r_payload_bytes,
            r_assembly_bytes,
            native_ffi,
            native_logits_bytes,
            capture_writer_bytes,
            native_fixed_bytes,
            wp10_peak_bytes,
            steering_bytes,
            steering_probe_bytes,
        ])?;
        Ok(LiveEstimate {
            steering_probe_bytes,
            steering_probe_fixed_bytes,
            steering_bytes,
            steering_descriptor_bytes,
            native_fixed_bytes,
            ffi_intern_bytes,
            schema_frame_bytes,
            record_frame_bytes,
            arrow_metadata_workspace_bytes,
            arrow_body_bytes,
            r_payload_bytes,
            r_assembly_bytes,
            native_logits_bytes,
            capture_writer_bytes,
            wp10_peak_bytes,
            capture_control_bytes,
            materialized_bytes,
            logits_bytes,
            native_capture_bytes,
            transient_bytes,
            spill_bytes,
            batch_bytes,
            spilled,
            n_values: n,
            n_vectors: vectors,
            hidden_size: h as usize,
            max_piece_bytes: b,
        })
    }

    pub(crate) fn state_spec(
        &self,
        state_id: usize,
        prompt_count: usize,
        source_pos: u32,
        batch_bytes: u64,
    ) -> String {
        format!("{}|position_space=model_context|prompt_token_count={prompt_count}|state_id={state_id}|source_pos={}|live_batch_rows={LIVE_BATCH_ROWS}|live_batch_bytes={batch_bytes}", self.spec_key, source_pos + 1).into_boxed_str().into_string()
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    pub(crate) fn metadata() -> ModelMetadata {
        ModelMetadata {
            architecture: "llama".into(),
            parameters: 0,
            quantization: "F32".into(),
            layers: 2,
            hidden_size: 32,
            context_length: 768,
            context_train: 768,
            backend: "cpu".into(),
            size_bytes: 0,
            vocab_size: 48,
            max_token_piece_bytes: 0,
            description: "live bound fixture".into(),
            gpu_layers: 0,
            mmap: true,
        }
    }
    pub(crate) fn request() -> LiveRequest {
        LiveRequest {
            layers: vec![0, 1],
            components: vec![Component::Residual, Component::AttnOut, Component::MlpOut],
            top: 5,
            budget_bytes: LIVE_MATERIALIZED_BYTES,
            r_fixed_bytes: 8192,
            spill: false,
            spill_dir: std::env::temp_dir().to_string_lossy().into_owned(),
            trace_id: "live-bound-test".into(),
            model: "synthetic".into(),
            spec_key: "live-v1-test".into(),
            steering: vec![],
        }
    }
    #[test]
    fn live_pool_and_checked_bounds() {
        for (payload, total) in [
            (0, 48),
            (1, 56),
            (8, 56),
            (9, 64),
            (17, 80),
            (33, 96),
            (49, 112),
            (65, 176),
            (128, 176),
            (129, 184),
        ] {
            assert_eq!(live_r_vector_bytes(payload).unwrap(), total);
        }
        assert!(live_r_vector_bytes(u64::MAX).is_err());
        let req = request();
        let meta = metadata();
        let e = req.preflight(&meta, 4).unwrap();
        assert!(!e.spilled);
        assert_eq!(e.n_values, 192);
        assert!(e.materialized_bytes >= e.logits_bytes + 44 * 192);
        assert_eq!(e.wp10_peak_bytes, 68_558_976);
        assert_eq!(
            e.transient_bytes,
            2 * e.materialized_bytes
                + e.r_payload_bytes
                + e.r_assembly_bytes
                + 24 * e.n_values
                + 12 * e.n_vectors as u64
                + 44 * req.top as u64
                + e.ffi_intern_bytes
                + e.native_logits_bytes
                + e.capture_writer_bytes
                + e.native_fixed_bytes
                + e.wp10_peak_bytes
        );
        let mut bad = req.clone();
        bad.r_fixed_bytes = u64::MAX;
        assert!(bad.preflight(&meta, 4).is_err());
        let mut huge = meta.clone();
        huge.hidden_size = (LIVE_VECTOR_BYTES / 4 + 1) as i32;
        assert!(req.preflight(&huge, 4).is_err());
        assert!(req.preflight(&meta, LIVE_MAX_STATES + 1).is_err());
        let mut empty = req;
        empty.layers.clear();
        empty.top = 0;
        assert!(empty.preflight(&meta, 4).is_err());
        empty.top = 1;
        huge.architecture = "unknown".into();
        assert!(empty.preflight(&huge, 4).is_ok());
    }
    #[test]
    fn f6b_shape_preflight_matches_owned_request_and_full_memory_ledger() {
        let mut req = request();
        let mut meta = metadata();
        meta.layers = 3;
        let base = req.preflight(&meta, 4).unwrap();
        let shape = req.preflight_with_steering_shape(&meta, 4, 2, 64).unwrap();
        req.steering = vec![
            crate::LiveSteer {
                intervention: 0,
                layer: 1,
                coef: 1.0,
                direction: std::sync::Arc::from([1.0; 32]),
            },
            crate::LiveSteer {
                intervention: 3,
                layer: 2,
                coef: 0.0,
                direction: std::sync::Arc::from([0.5; 32]),
            },
        ];
        let owned = req.preflight(&meta, 4).unwrap();
        assert_eq!(shape.steering_bytes, owned.steering_bytes);
        assert_eq!(shape.steering_probe_bytes, owned.steering_probe_bytes);
        assert_eq!(
            owned.steering_probe_fixed_bytes,
            crate::probe::live_probe_fixed_bytes() as u64
        );
        assert_eq!(
            owned.steering_probe_bytes,
            4 * 32 * 3 + 4 * 32 + 3 + owned.steering_probe_fixed_bytes
        );
        assert_eq!(base.steering_probe_bytes, 0);
        assert_eq!(shape.native_capture_bytes, owned.native_capture_bytes);
        assert_eq!(shape.transient_bytes, owned.transient_bytes);
        let s = 2;
        let h = 32;
        let d = 3;
        let g = |n| live_r_vector_bytes(n).unwrap() - 48;
        let v = |n| live_r_vector_bytes(n).unwrap();
        assert_eq!(
            owned.steering_bytes,
            8 * h * s
                + 8 * h * d
                + 4 * h
                + 52 * s
                + owned.steering_descriptor_bytes
                + v(8 * h * s)
                + 2 * req.r_fixed_bytes
                + 2 * g(4 * s)
                + 2 * g(8 * s)
                + 3 * v(4 * s)
                + v(8 * s)
        );
        let audit = 2 * g(4 * s) + g(8 * s) + 8;
        assert_eq!(owned.materialized_bytes - base.materialized_bytes, audit);
        assert_eq!(owned.logits_bytes - base.logits_bytes, audit);
        assert_eq!(
            owned.transient_bytes - base.transient_bytes,
            3 * audit + 16 * s + owned.steering_bytes + owned.steering_probe_bytes
        );
        assert!(req.preflight_with_steering_shape(&meta, 4, 2, 63).is_err());
        assert!(req
            .preflight_with_steering_shape(&meta, 4, usize::MAX, u64::MAX)
            .is_err());
        // Borrowed sizing refuses the copies before any original-direction Arc is made.
        let count = (LIVE_TRANSPORT_BYTES / (8 * h)) as usize;
        assert!(req
            .preflight_with_steering_shape(&meta, 4, count, count as u64 * h)
            .is_err());
        req.steering[1].intervention = 0;
        assert!(req.preflight(&meta, 4).is_err());
    }

    #[cfg(feature = "spill")]
    #[test]
    fn live_spill_admission_uses_proxy_and_component_fragments() {
        let mut req = request();
        let mut meta = metadata();
        req.spill = true;
        req.top = 0;
        req.budget_bytes = req.r_fixed_bytes;
        meta.hidden_size = 1024;
        meta.max_token_piece_bytes = 3 * 20000;
        let e = req.preflight(&meta, 2).unwrap();
        assert!(e.spilled);
        assert_eq!(e.r_payload_bytes, e.logits_bytes);
        assert_eq!(e.r_assembly_bytes, 0);
        assert!(e.batch_bytes >= LIVE_BATCH_BYTES);
        assert!(e.spill_bytes > 2 * e.n_values * meta.max_token_piece_bytes);
        assert!(e.transient_bytes > e.wp10_peak_bytes + e.capture_writer_bytes);
        let mut narrow = req.clone();
        narrow.budget_bytes = req.r_fixed_bytes - 1;
        assert!(narrow.preflight(&meta, 2).is_err());
        assert!(req.preflight(&meta, 1024).is_err());
    }
}
