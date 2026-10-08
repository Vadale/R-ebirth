//! F6b coefficient-only commands. Original directions are immutable job input;
//! only the worker touches the generation context or its applied revision.
use crate::{LoadedModel, ModelMetadata, RebirthError};
use std::sync::Arc;

#[derive(Debug, Clone)]
pub struct LiveSteer {
    /// Original intervention-list index, engine-native0-based (gaps allowed).
    pub intervention: u32,
    pub layer: u32,
    pub coef: f64,
    pub direction: Arc<[f64]>,
}
impl LiveSteer {
    /// Two owned request descriptor arrays share each immutable Arc slice.
    pub fn descriptor_bytes() -> usize {
        2 * std::mem::size_of::<Self>() + 2 * std::mem::size_of::<usize>()
    }
}
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LiveCoefficient {
    pub intervention: u32,
    pub coef: f64,
}
pub type LiveReply = Vec<LiveCoefficient>;
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LiveSteeringRow {
    pub intervention: u32,
    pub layer: u32,
    pub coef: f64,
}

pub(crate) fn reply_error(reason: impl Into<String>) -> RebirthError {
    RebirthError::Argument {
        argument: "on_state_reply".into(),
        reason: reason.into(),
    }
}
fn initial_error(reason: impl Into<String>) -> RebirthError {
    RebirthError::Argument {
        argument: "on_state".into(),
        reason: reason.into(),
    }
}
fn finite_coef(value: f64) -> bool {
    value.is_finite() && value.abs() <= f32::MAX as f64
}
pub(crate) fn validate_entries(
    entries: &[LiveSteer],
    metadata: &ModelMetadata,
) -> Result<(), RebirthError> {
    for (i, entry) in entries.iter().enumerate() {
        if entry.intervention >= i32::MAX as u32
            || entry.layer == 0
            || entry.layer >= metadata.layers as u32
            || entry.direction.len() != metadata.hidden_size as usize
            || !finite_coef(entry.coef)
            || entry.direction.iter().any(|v| !v.is_finite())
            || (i > 0 && entries[i - 1].intervention >= entry.intervention)
        {
            return Err(initial_error("Live steering requires ordered original steer indices, valid steerable layers, finite f32 coefficients and finite original directions of the model width."));
        }
    }
    Ok(())
}

/// Only the original steering adapter is retained. Existing ablation adapters
/// remain installed and are neither rebuilt nor modified by F6b commands.
pub(crate) struct SteeringBaseline {
    pub(crate) values: Vec<f32>,
    pub(crate) range: (i32, i32),
}
pub(crate) fn apply_buffer(
    model: &LoadedModel,
    values: &[f32],
    range: (i32, i32),
) -> Result<(), RebirthError> {
    crate::intervene::apply_steering_buffer(
        model.ctx_ptr(),
        model.hidden_size() as usize,
        values,
        range,
    )
}

pub(crate) struct LiveSteering<'a> {
    model: &'a LoadedModel,
    entries: &'a [LiveSteer],
    current: Vec<f64>,
    candidate: Vec<f64>,
    buffer: Vec<f32>,
    scaled: Vec<f32>,
    range: (i32, i32),
    pub(crate) revision: usize,
    pub(crate) applied_after: usize,
    pub(crate) effective_source: u32,
    dirty: bool,
}
pub(crate) fn session_bytes() -> usize {
    std::mem::size_of::<LiveSteering<'static>>()
}

/// Match the original R operation order exactly: multiply in f64, convert each
/// entry to f32, then sum entries in their original order using f32 arithmetic.
fn rebuild(
    entries: &[LiveSteer],
    coefficients: &[f64],
    width: usize,
    output: &mut [f32],
    scaled: &mut [f32],
) -> Result<(), RebirthError> {
    output.fill(0.0);
    for (entry, &coefficient) in entries.iter().zip(coefficients) {
        if !finite_coef(coefficient) {
            return Err(reply_error(
                "Coefficient is not finite and representable as f32.",
            ));
        }
        for (value, &direction) in scaled.iter_mut().zip(entry.direction.iter()) {
            let product = coefficient * direction;
            *value = product as f32;
            if !product.is_finite() || !value.is_finite() {
                return Err(reply_error("A scaled direction overflows f32."));
            }
        }
        let offset = entry.layer as usize * width;
        for (sum, &value) in output[offset..offset + width].iter_mut().zip(scaled.iter()) {
            *sum += value;
            if !sum.is_finite() {
                return Err(reply_error("The summed steering buffer overflows f32."));
            }
        }
    }
    Ok(())
}
impl<'a> LiveSteering<'a> {
    pub(crate) fn prepare(
        model: &'a LoadedModel,
        entries: &'a [LiveSteer],
    ) -> Result<Self, RebirthError> {
        let width = model.hidden_size() as usize;
        let mut state = Self {
            model,
            entries,
            current: entries.iter().map(|e| e.coef).collect(),
            candidate: vec![0.0; entries.len()],
            buffer: Vec::new(),
            scaled: Vec::new(),
            range: (-1, -1),
            revision: 0,
            applied_after: 0,
            effective_source: 0,
            dirty: false,
        };
        if entries.is_empty() {
            if model.steering_baseline.is_some() {
                return Err(initial_error(
                    "A steered handle requires its complete original steering metadata.",
                ));
            }
            return Ok(state);
        }
        let baseline = model.steering_baseline.as_ref().ok_or_else(|| {
            initial_error("The handle has no authoritative original steering adapter.")
        })?;
        state.range = (
            entries.iter().map(|e| e.layer as i32).min().unwrap(),
            entries.iter().map(|e| e.layer as i32).max().unwrap(),
        );
        state.buffer = vec![0.0; width * model.num_layers() as usize];
        state.scaled = vec![0.0; width];
        rebuild(
            entries,
            &state.current,
            width,
            &mut state.buffer,
            &mut state.scaled,
        )
        .map_err(|e| initial_error(format!("Invalid original steering specification: {e}")))?;
        if state.range != baseline.range
            || state.buffer.len() != baseline.values.len()
            || state
                .buffer
                .iter()
                .zip(&baseline.values)
                .any(|(a, b)| a.to_bits() != b.to_bits())
        {
            return Err(initial_error("Original directions and coefficients do not reproduce this handle's applied steering adapter."));
        }
        // A zero-coefficient derivation may never have probed its layer. Prove
        // every requested nonzero direction's layer before this job's prefill.
        let mut layers = Vec::with_capacity(entries.len());
        for entry in entries {
            if entry.direction.iter().any(|&v| v != 0.0) && !layers.contains(&entry.layer) {
                layers.push(entry.layer);
            }
        }
        model.verify_steering_layers(&layers)?;
        Ok(state)
    }
    pub(crate) fn audit(&self) -> Vec<LiveSteeringRow> {
        self.entries
            .iter()
            .zip(&self.current)
            .map(|(entry, &coef)| LiveSteeringRow {
                intervention: entry.intervention,
                layer: entry.layer,
                coef,
            })
            .collect()
    }
    pub(crate) fn apply_reply(
        &mut self,
        reply: LiveReply,
        state_id: usize,
        effective_source: u32,
    ) -> Result<(), RebirthError> {
        crate::async_job::checkpoint()?;
        if reply.is_empty() {
            return Ok(());
        }
        if reply.len() > self.entries.len() {
            return Err(reply_error(
                "The reply has more rows than the original steering entries.",
            ));
        }
        self.candidate.copy_from_slice(&self.current);
        for (i, update) in reply.iter().enumerate() {
            if !finite_coef(update.coef)
                || reply[..i]
                    .iter()
                    .any(|old| old.intervention == update.intervention)
            {
                return Err(reply_error("Reply indices must be unique and coefficients finite and representable as f32."));
            }
            let index = self
                .entries
                .binary_search_by_key(&update.intervention, |entry| entry.intervention)
                .map_err(|_| {
                    reply_error("Reply index does not name an original steering entry.")
                })?;
            self.candidate[index] = update.coef;
        }
        if self.candidate == self.current {
            return Ok(());
        }
        rebuild(
            self.entries,
            &self.candidate,
            self.model.hidden_size() as usize,
            &mut self.buffer,
            &mut self.scaled,
        )?;
        let next = self
            .revision
            .checked_add(1)
            .ok_or_else(|| reply_error("Steering revision overflow."))?;
        // Mark dirty before the setter: even a failed partially applied setter
        // must be followed by restoration before the context can be returned.
        crate::async_job::apply_live_command(|| {
            self.dirty = true;
            #[cfg(test)]
            if crate::async_job::live_steering_fault() == 2 {
                return Err(RebirthError::Intervention {
                    reason: "injected live setter failure".into(),
                });
            }
            apply_buffer(self.model, &self.buffer, self.range)?;
            #[cfg(test)]
            assert_ne!(
                crate::async_job::live_steering_fault(),
                3,
                "injected panic after live setter"
            );
            std::mem::swap(&mut self.current, &mut self.candidate);
            self.revision = next;
            self.applied_after = state_id;
            self.effective_source = effective_source;
            Ok(())
        })
    }
    pub(crate) fn restore(&mut self) -> Result<(), RebirthError> {
        if !self.dirty {
            return Ok(());
        }
        self.dirty = false;
        #[cfg(test)]
        if crate::async_job::live_steering_fault() == 1 {
            self.model.steering_restore_failed.set(true);
            return Err(RebirthError::Intervention {
                reason: "injected original adapter restoration failure".into(),
            });
        }
        let result = self
            .model
            .steering_baseline
            .as_ref()
            .ok_or_else(|| RebirthError::Internal {
                context: "live steering baseline lost".into(),
            })
            .and_then(|original| apply_buffer(self.model, &original.values, original.range));
        if result.is_err() {
            self.model.steering_restore_failed.set(true);
        }
        result
    }
}
impl Drop for LiveSteering<'_> {
    fn drop(&mut self) {
        let _ = self.restore();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn f6b_rebuild_preserves_original_order_and_f64_products() {
        let entries: Vec<_> = [16_777_216.0, 1.0, -16_777_216.0]
            .into_iter()
            .enumerate()
            .map(|(i, direction)| LiveSteer {
                intervention: (i * 2) as u32,
                layer: 1,
                coef: 1.0,
                direction: Arc::from([direction]),
            })
            .collect();
        let mut output = [0.0; 3];
        rebuild(&entries, &[1.0; 3], 1, &mut output, &mut [0.0]).unwrap();
        assert_eq!(
            output,
            [0.0, 0.0, 0.0],
            "f32 original-order sum, never f64 summed then cast"
        );
        let entry = LiveSteer {
            intervention: 0,
            layer: 1,
            coef: 0.0,
            direction: Arc::from([1.000_000_06]),
        };
        rebuild(&[entry], &[1.000_000_06], 1, &mut output, &mut [0.0]).unwrap();
        assert_eq!(output[1], (1.000_000_06_f64 * 1.000_000_06_f64) as f32);
        assert_ne!(
            output[1],
            (1.000_000_06_f64 as f32) * (1.000_000_06_f64 as f32)
        );
    }

    #[test]
    fn f6b_rebuild_rejects_scalar_product_and_sum_overflow() {
        let entry = LiveSteer {
            intervention: 0,
            layer: 1,
            coef: 0.0,
            direction: Arc::from([1.0]),
        };
        let next = f64::from_bits((f32::MAX as f64).to_bits() + 1);
        assert!(
            (next as f32).is_finite(),
            "boundary fixture rounds back to MAX"
        );
        for coef in [f64::NAN, f64::INFINITY, next, -next] {
            assert!(rebuild(
                std::slice::from_ref(&entry),
                &[coef],
                1,
                &mut [0.0; 2],
                &mut [0.0]
            )
            .is_err());
        }
        let mut large = entry.clone();
        large.direction = Arc::from([2.0]);
        assert!(rebuild(&[large], &[f32::MAX as f64], 1, &mut [0.0; 2], &mut [0.0]).is_err());
        assert!(rebuild(
            &[entry.clone(), entry],
            &[f32::MAX as f64; 2],
            1,
            &mut [0.0; 2],
            &mut [0.0]
        )
        .is_err());
    }
}
