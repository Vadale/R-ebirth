// Included in projection.rs. Bounded D046 production constructor.
use crate::projection_profile::{
    admission_error, ProjectionAdmissionMode, ProjectionCommand, ProjectionConstructionReceipt,
    ProjectionFfiProfile, ProjectionResidualArrays,
};

#[derive(Clone, Copy, PartialEq)]
enum ConstructionFault {
    None,
    #[cfg(test)]
    BeforeContext,
    #[cfg(test)]
    AfterProbe,
    #[cfg(test)]
    AfterAdapter,
    #[cfg(test)]
    NoWrite,
    #[cfg(test)]
    Cancel,
}
fn exact_copy<T: Copy>(values: &[T]) -> Result<Vec<T>, RebirthError> {
    let mut result = Vec::new();
    result
        .try_reserve_exact(values.len())
        .map_err(|_| admission_error())?;
    if result.capacity() != values.len() {
        return Err(admission_error());
    }
    result.extend_from_slice(values);
    Ok(result)
}
impl LoadedModel {
    /// Admitted projection construction shared by normal and private builds.
    /// The FFI retains its source borrow and registry transaction around it.
    #[doc(hidden)]
    pub fn projection_construct(
        &self,
        command: &ProjectionCommand<'_>,
        arrays: ProjectionResidualArrays<'_>,
        ffi: ProjectionFfiProfile,
    ) -> Result<(LoadedModel, ProjectionConstructionReceipt), RebirthError> {
        self.projection_construct_inner(command, arrays, ffi, ConstructionFault::None)
    }
    fn projection_construct_inner(
        &self,
        command: &ProjectionCommand<'_>,
        arrays: ProjectionResidualArrays<'_>,
        ffi: ProjectionFfiProfile,
        fault: ConstructionFault,
    ) -> Result<(LoadedModel, ProjectionConstructionReceipt), RebirthError> {
        let _native = crate::NativeGuard::try_acquire("projection constructor")?;
        let (_, admitted, _) = self.projection_validate_source(command, ffi)?;
        let h = admitted.hidden_size as usize;
        let d = admitted.layers as usize;
        arrays.validate(h, d, command.steer_entries, command.ablate_entries)?;
        // Exact five copies only after the authoritative complete budget passes.
        let layers = exact_copy(arrays.steer_layers)?;
        let vectors = exact_copy(arrays.steer_vectors)?;
        let ablate_layers = exact_copy(arrays.ablate_layers)?;
        let neurons = exact_copy(arrays.ablate_neurons)?;
        let values = exact_copy(arrays.ablate_values)?;
        let owned = ProjectionResidualArrays {
            steer_layers: &layers,
            steer_vectors: &vectors,
            ablate_layers: &ablate_layers,
            ablate_neurons: &neurons,
            ablate_values: &values,
        };
        let (residual, row_capacity) = InterventionSpec::projection_from_arrays(h, d, owned)?;
        let mut receipt = ProjectionConstructionReceipt::default();
        receipt.adapter_capacities[..5].copy_from_slice(&[
            layers.capacity(),
            vectors.capacity(),
            ablate_layers.capacity(),
            neurons.capacity(),
            values.capacity(),
        ]);
        receipt.adapter_capacities[5..8].copy_from_slice(&residual.projection_buffer_capacities());
        receipt.adapter_capacities[8] = row_capacity;
        // The source current context and its KV/adapters are never touched.
        receipt.residual_probe_decodes = self.projection_prove_residual(&residual)?;
        let old = self.projection().lock().as_ref().map(|r| r.plan.clone());
        let plan = if command.mode == ProjectionAdmissionMode::Inherit {
            old.clone().ok_or_else(admission_error)?
        } else {
            let mut sites = Vec::new();
            let count = admitted.previous_sites as usize + 1;
            sites
                .try_reserve_exact(count)
                .map_err(|_| admission_error())?;
            if sites.capacity() != count {
                return Err(admission_error());
            }
            if let Some(previous) = &old {
                sites.extend(previous.sites.iter().cloned());
            }
            // One f64 allocation, no intermediate Vec/second direction copy.
            let mut direction = Arc::<[f64]>::new_uninit_slice(h);
            for (dst, &value) in Arc::get_mut(&mut direction)
                .unwrap()
                .iter_mut()
                .zip(command.direction)
            {
                dst.write(value);
            }
            // SAFETY: validated h values initialize every element exactly once.
            let direction = unsafe { direction.assume_init() };
            sites.push(Site {
                layer: command.layer,
                component: command.component,
                coef: command.coef,
                direction,
            });
            Arc::new(Plan {
                width: h,
                depth: d,
                sites: sites.into_boxed_slice(),
            })
        };
        #[cfg(test)]
        if fault == ConstructionFault::BeforeContext {
            return Err(admission_error());
        }
        let mut candidate = self.clone_projection_context()?;
        candidate.projection().install(Runtime::new(plan.clone())?);
        for (index, site) in plan.sites.iter().enumerate() {
            let probe_fault = {
                #[cfg(test)]
                {
                    match fault {
                        ConstructionFault::NoWrite => Fault::NoWrite,
                        ConstructionFault::Cancel => Fault::Cancel,
                        _ => Fault::None,
                    }
                }
                #[cfg(not(test))]
                {
                    let _ = fault;
                    Fault::None
                }
            };
            self.prove_projection(site, probe_fault)?;
            receipt.projection_probe_decodes += 2;
            candidate.projection().lock().as_mut().unwrap().proofs[index].proven = true;
        }
        #[cfg(test)]
        if fault == ConstructionFault::AfterProbe {
            return Err(admission_error());
        }
        residual.projection_apply(&mut candidate)?;
        receipt.adapter_capacities[9] = candidate
            .steering_baseline
            .as_ref()
            .map_or(0, |b| b.values.capacity());
        admitted.validate_adapter_capacities(receipt.adapter_capacities)?;
        #[cfg(test)]
        if fault == ConstructionFault::AfterAdapter {
            return Err(admission_error());
        }
        Ok((candidate, receipt))
    }
    fn projection_probe_context(&self, site: Site) -> Result<LoadedModel, RebirthError> {
        let candidate = self.clone_projection_context()?;
        let plan = Arc::new(Plan {
            width: self.hidden_size() as usize,
            depth: self.num_layers() as usize,
            sites: Box::new([site]),
        });
        candidate.projection().install(Runtime::new(plan)?);
        Ok(candidate)
    }
}
#[cfg(test)]
#[path = "projection_constructor_tests.rs"]
mod constructor_tests;
