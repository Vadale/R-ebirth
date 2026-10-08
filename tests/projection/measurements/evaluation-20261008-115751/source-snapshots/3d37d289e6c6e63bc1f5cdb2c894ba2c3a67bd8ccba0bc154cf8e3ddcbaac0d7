//! D046 bounded projection runtime, shared by production and private gates.
use crate::projection_layout::*;
use crate::{ffi, Component, InterventionSpec, LoadedModel, RebirthError};
use std::ffi::CStr;
use std::mem::size_of;
use std::sync::atomic::Ordering;
use std::sync::{Arc, MutexGuard};

const MAX_SITES: usize = 32;
#[cfg(test)]
const MAX_WIDTH: usize = 65_536;
const ERROR_TEXT_BYTES: usize =
    "projection residual specification dimensions differ from model".len();
#[cfg(test)]
fn oom(bytes: usize) -> RebirthError {
    RebirthError::Oom {
        estimate_bytes: bytes as u64,
        budget_bytes: 64 * 1024 * 1024,
        suggestion: "Use fewer projection sites or a smaller model.".into(),
    }
}
fn error(reason: &'static str) -> RebirthError {
    debug_assert!(reason.len() <= ERROR_TEXT_BYTES);
    RebirthError::Intervention {
        reason: reason.into(),
    }
}

impl Site {
    fn code(&self) -> u32 {
        u32::from(self.component == Component::AttnOut)
    }
}

// Test-only independent fixture observation, separately byte capped. Never used
// by the probe/benchmark or product admission. No unbounded activation map.

fn exact_f32(h: usize) -> Result<Box<[f32]>, RebirthError> {
    let mut v = Vec::new();
    v.try_reserve_exact(h)
        .map_err(|_| error("projection row allocation failed"))?;
    if v.capacity() != h {
        return Err(error("projection row capacity differs from admission"));
    }
    v.resize(h, 0.0);
    Ok(v.into_boxed_slice())
}
#[cfg(test)]
fn validate_site(site: &Site, h: usize, depth: usize, arch: &str) -> Result<(), RebirthError> {
    if !(1..=MAX_WIDTH).contains(&h)
        || site.direction.len() != h
        || site.layer as usize >= depth
        || !site.coef.is_finite()
        || site.coef.abs() > f32::MAX as f64
    {
        return Err(error("invalid projection shape, layer or coefficient"));
    }
    if !matches!(
        (arch, site.component),
        ("llama", Component::MlpOut | Component::AttnOut) | ("qwen2", Component::MlpOut)
    ) {
        return Err(error("unsupported projection architecture/component"));
    }
    let mut norm = 0.0;
    for &v in site.direction.iter() {
        if !v.is_finite() {
            return Err(error("nonfinite projection direction"));
        }
        norm += v * v;
    }
    if !norm.is_finite() || (norm.sqrt() - 1.0).abs() > 1e-12 {
        return Err(error("projection direction must be unit length"));
    }
    Ok(())
}

fn project(row: &mut [f32], direction: &[f64], coef: f64) -> Result<f64, &'static str> {
    if row.len() != direction.len() || !coef.is_finite() || coef.abs() > f32::MAX as f64 {
        return Err("invalid projection row/coefficient");
    }
    if coef == 0.0 {
        return Ok(0.0);
    }
    let mut work = ArithmeticFrame {
        dot: 0.0,
        value: 0.0,
    };
    for (&h, &v) in row.iter().zip(direction) {
        if !h.is_finite() || !v.is_finite() {
            return Err("nonfinite projection operand");
        }
        work.dot += v * f64::from(h);
    }
    if !work.dot.is_finite() {
        return Err("nonfinite projection dot");
    }
    for (h, &v) in row.iter_mut().zip(direction) {
        work.value = f64::from(*h) - (coef * v) * work.dot;
        let value = work.value;
        if !value.is_finite() || value.abs() > f32::MAX as f64 {
            return Err("projection result outside finite f32 range");
        }
        *h = value as f32;
    }
    Ok(work.dot)
}
impl Runtime {
    fn new(plan: Arc<Plan>) -> Result<Self, RebirthError> {
        Ok(Self {
            row: exact_f32(plan.width)?,
            plan,
            proofs: [Proof::default(); MAX_SITES],
            seen: [false; MAX_SITES],
            ready: [false; MAX_SITES],
            source: 0,
            count: 0,
            marker: 0,
            micro_rows: 0,
            last_only: true,
            owner: None,
            failure: None,
            diagnostic: (0, 0, 0),
            fault: Fault::None,
            stats: Stats::default(),
            probe: None,
            audit: None,
        })
    }
    fn check_microbatch(&self) -> Result<(), &'static str> {
        for (i, site) in self.plan.sites.iter().enumerate() {
            if self.probe.is_none() && !self.proofs[i].proven {
                return Err("projection capability was not proved");
            }

            let zero_pruned = self.last_only
                && site.component == Component::MlpOut
                && site.layer as usize + 1 == self.plan.depth
                && self.marker < self.count;
            if !zero_pruned && !self.seen[i] {
                return Err("missing projection producer");
            }
            if !zero_pruned
                && (site.coef != 0.0 || self.probe.is_some() || self.audit.is_some())
                && !self.ready[i]
            {
                return Err("missing projection ready callback");
            }
        }
        Ok(())
    }
    fn record(
        &mut self,
        position: usize,
        layer: u32,
        component: Component,
        before: bool,
    ) -> Result<(), &'static str> {
        if let Some(audit) = self.audit.as_mut() {
            if audit.positions.contains(&position) {
                let added = size_of::<Observation>() + 4 * self.row.len();
                if audit
                    .bytes
                    .checked_add(added)
                    .is_none_or(|n| n > 8 * 1024 * 1024)
                    || audit.rows.len() == 128
                {
                    return Err("private fixture observer exceeded its separate bound");
                }
                audit.bytes += added;
                audit.rows.push(Observation {
                    position,
                    layer,
                    component,
                    before,
                    values: self.row.clone(),
                });
            }
        }
        Ok(())
    }
    fn node(&mut self, t: *mut ffi::ggml_tensor, ask: bool) -> Result<bool, &'static str> {
        if self.owner != Some(std::thread::current().id()) {
            return Err("projection callback changed decode thread");
        }
        if self.failure.is_some() {
            return Ok(false);
        }
        // SAFETY: callback tensor and name are live for this synchronous call only.
        let name = unsafe { CStr::from_ptr(ffi::ggml_get_name(t)) }
            .to_str()
            .map_err(|_| "invalid graph tensor name")?;
        let Some((base, layer)) = crate::parse_tensor_name(name) else {
            return Ok(!ask);
        };
        if ask && base == "attn_norm" && layer == 0 {
            if self.marker > 0 {
                self.check_microbatch()?;
            }
            // SAFETY: metadata-only public accessor on the live graph node.
            let rows = unsafe { ffi::ggml_nrows(t) };
            if rows <= 0 {
                return Err("invalid projection microbatch marker");
            }
            self.micro_rows = rows as usize;
            self.marker = self
                .marker
                .checked_add(self.micro_rows)
                .ok_or("projection marker overflow")?;
            if self.marker > self.count {
                return Err("projection marker exceeds decode rows");
            }
            self.seen.fill(false);
            self.ready.fill(false);
            return Ok(false);
        }
        let component = match base {
            "ffn_out" => Some(Component::MlpOut),
            "attn_out" => Some(Component::AttnOut),
            "l_out" => Some(Component::Residual),
            _ => None,
        };
        let index = self
            .plan
            .sites
            .iter()
            .position(|s| s.layer == layer && Some(s.component) == component);
        let consumer = self.probe.as_ref().is_some_and(|p| {
            p.layer == layer
                && base
                    == if p.component == Component::MlpOut {
                        "l_out"
                    } else {
                        "ffn_inp"
                    }
        });
        let observing = self.audit.is_some() && component.is_some();
        if index.is_none() && !consumer && !observing {
            return Ok(!ask);
        }
        let mut info = ffi::ProjectionInfo::default();
        if let Some(i) = index {
            // SAFETY: C++ uses pinned headers; output is an owned repr(C) POD.
            let status = unsafe {
                ffi::relm_projection_classify(
                    t,
                    layer,
                    self.plan.sites[i].code(),
                    self.plan.width,
                    !ask,
                    &mut info,
                )
            };
            if status == 1 {
                return Ok(!ask);
            }
            // Retain only fixed owned metadata from the first nonempty ready
            // producer, before any tensor access. Emit after decode, never here.
            if !ask && info.bytes > 0 && self.proofs[i].buffer.is_none() {
                self.proofs[i].buffer = Some(info);
            }
            if status != 0 {
                self.diagnostic = (layer, self.plan.sites[i].code(), status);
                return Err("unsupported projection producer/layout/alias/buffer");
            }
            if info.bytes
                != info
                    .rows
                    .checked_mul((self.plan.width * 4) as u64)
                    .ok_or("projection extent overflow")?
                || (!ask && info.rows > 0 && !matches!(info.access, 1 | 2))
            {
                return Err("projection descriptor disagrees with row extent/buffer");
            }
            if ask {
                if self.seen[i] {
                    return Err("duplicate projection producer");
                }
                self.seen[i] = true;
                if self.proofs[i].wrappers.is_some_and(|w| w != info.wrappers) {
                    return Err("projection producer changed during graph reuse");
                }
                self.proofs[i].wrappers = Some(info.wrappers);
                if info.rows == 0 {
                    self.ready[i] = true;
                }
                if self.fault == Fault::Missing {
                    return Ok(false);
                }
            }
        } else if component == Some(Component::MlpOut) {
            // Exclude Llama's residual duplicate from private observation too.
            let status = unsafe {
                ffi::relm_projection_classify(t, layer, 0, self.plan.width, !ask, &mut info)
            };
            if status == 1 {
                return Ok(!ask);
            }
            if status != 0 {
                return Err("unsupported observed MLP producer");
            }
        }
        if ask {
            let needed = consumer
                || observing
                || self.probe.is_some()
                || index.is_some_and(|i| self.plan.sites[i].coef != 0.0);
            if needed {
                self.stats.barriers = self
                    .stats
                    .barriers
                    .checked_add(1)
                    .ok_or("projection counter overflow")?;
            }
            return Ok(needed);
        }
        if let Some(i) = index {
            self.ready[i] = true;
        }
        if consumer {
            let p = self.probe.as_ref().unwrap();
            let code = u32::from(p.component == Component::AttnOut);
            if unsafe { ffi::relm_projection_consumer(t, layer, code, self.plan.width) } != 0 {
                return Err("projection probe consumer relationship failed");
            }
        }
        let rows = unsafe { ffi::ggml_nrows(t) };
        if rows < 0 || rows as usize > self.micro_rows {
            return Err("invalid projection row count");
        }
        if rows == 0 {
            return Ok(true);
        }
        let h = self.plan.width;
        for row_index in 0..rows as usize {
            if self.fault == Fault::Cancel || crate::async_job::checkpoint().is_err() {
                return Err("projection cancelled during decode");
            }
            if self.fault == Fault::Panic {
                panic!("private projection fault");
            }
            let pos = self.source + self.marker - self.micro_rows
                + if rows as usize == self.micro_rows {
                    row_index
                } else {
                    self.micro_rows - 1
                };
            if unsafe { ffi::relm_projection_row(t, h, row_index, self.row.as_mut_ptr(), false) }
                != 0
            {
                return Err("projection row read failed");
            }
            if self.row.iter().any(|v| !v.is_finite()) {
                return Err("nonfinite projection/probe row");
            }
            self.stats.read_bytes = self
                .stats
                .read_bytes
                .checked_add((4 * h) as u64)
                .ok_or("projection counter overflow")?;
            if let Some(i) = index {
                if let Some(p) = self.probe.as_mut() {
                    // Reuse the existing producer storage for this decode's
                    // actual pre-row. The baseline removal is retained as one
                    // scalar for the independent downstream comparison.
                    p.producer.copy_from_slice(&self.row);
                    p.producer_seen = true;
                }
                self.record(pos, layer, self.plan.sites[i].component, true)?;
                let site = &self.plan.sites[i];
                let active = site.coef != 0.0;
                let before_norm = self
                    .row
                    .iter()
                    .map(|&x| f64::from(x).powi(2))
                    .sum::<f64>()
                    .sqrt();
                let dot = project(&mut self.row, &site.direction, site.coef)?;
                if let Some(audit) = self.audit.as_mut() {
                    if audit.witnesses.len() == 2048 {
                        return Err("private witness capacity exceeded");
                    }
                    audit.witnesses.push(Witness {
                        position: pos,
                        layer,
                        component: site.component,
                        dot,
                        write: active,
                        before_norm,
                        after_norm: self
                            .row
                            .iter()
                            .map(|&x| f64::from(x).powi(2))
                            .sum::<f64>()
                            .sqrt(),
                    });
                }
                if active && !matches!(self.fault, Fault::NoWrite | Fault::WrongSite) {
                    if unsafe {
                        ffi::relm_projection_row(t, h, row_index, self.row.as_mut_ptr(), true)
                    } != 0
                    {
                        return Err("projection row write failed");
                    }
                    self.stats.write_bytes = self
                        .stats
                        .write_bytes
                        .checked_add((4 * h) as u64)
                        .ok_or("projection counter overflow")?;
                }
                // A readback proof observes actual storage, not our host buffer.
                if active && (self.probe.is_some() || self.audit.is_some()) {
                    if unsafe {
                        ffi::relm_projection_row(t, h, row_index, self.row.as_mut_ptr(), false)
                    } != 0
                    {
                        return Err("projection readback failed");
                    }
                    self.stats.read_bytes = self
                        .stats
                        .read_bytes
                        .checked_add((4 * h) as u64)
                        .ok_or("projection counter overflow")?;
                    if let Some(p) = self
                        .probe
                        .as_ref()
                        .filter(|_| self.fault != Fault::WrongSite)
                    {
                        for (j, &value) in self.row.iter().enumerate() {
                            let expected = if j == p.neuron {
                                0.0
                            } else {
                                f64::from(p.producer[j])
                            };
                            let delta = (f64::from(value) - expected).abs();
                            if !delta.is_finite() || delta > 2e-6 * (1.0 + expected.abs()) {
                                return Err("projection producer readback failed");
                            }
                        }
                    }
                }
                self.stats.rows = self
                    .stats
                    .rows
                    .checked_add(1)
                    .ok_or("projection counter overflow")?;
                if self.fault == Fault::AfterRow {
                    return Err("injected projection failure after row");
                }
            }
            if consumer {
                if self.fault == Fault::WrongSite {
                    self.row[self.probe.as_ref().unwrap().neuron] = 0.0;
                    if unsafe {
                        ffi::relm_projection_row(t, h, row_index, self.row.as_mut_ptr(), true)
                    } != 0
                    {
                        return Err("wrong-site fault write failed");
                    }
                }
                let p = self.probe.as_mut().unwrap();
                if p.edited {
                    for (j, &value) in self.row.iter().enumerate() {
                        let expected = p.consumer[j] as f64
                            - if j == p.neuron {
                                f64::from(p.baseline_signal)
                            } else {
                                0.0
                            };
                        if (f64::from(value) - expected).abs() > 0.01 {
                            return Err("projection downstream capability probe failed");
                        }
                    }
                    if (self.row[p.neuron] - p.consumer[p.neuron]).abs() <= 0.01 {
                        return Err("projection downstream no-op");
                    }
                } else {
                    p.consumer.copy_from_slice(&self.row);
                }
                p.consumer_seen = true;
            }
            if let Some(c) = component {
                self.record(pos, layer, c, false)?;
            }
        }
        Ok(true)
    }
}
impl Slot {
    fn lock(&self) -> MutexGuard<'_, Option<Box<Runtime>>> {
        self.runtime.lock().unwrap_or_else(|e| e.into_inner())
    }
    pub(crate) fn enabled(&self) -> bool {
        self.active.load(Ordering::Acquire)
    }
    #[cfg(test)]
    pub(crate) fn time_decode(&self, prefill: bool, seconds: f64) {
        let mut t = self.timings.lock().unwrap();
        if prefill {
            t.0 += seconds
        } else {
            t.1 += seconds
        }
    }
    #[cfg(test)]
    pub(crate) fn timings(&self) -> (f64, f64) {
        *self.timings.lock().unwrap()
    }
    #[cfg(test)]
    pub(crate) fn clear_timings(&self) {
        *self.timings.lock().unwrap() = (0.0, 0.0);
    }
    pub(crate) fn failed(&self) -> bool {
        self.poisoned.load(Ordering::Acquire)
    }
    fn install(&self, runtime: Runtime) {
        *self.lock() = Some(Box::new(runtime));
        self.active.store(true, Ordering::Release);
    }
    pub(crate) fn begin(
        &self,
        start: i32,
        count: usize,
        last_only: bool,
    ) -> Result<(), RebirthError> {
        if self.failed() {
            return Err(error("projected context is invalidated"));
        }
        if let Some(r) = self.lock().as_mut() {
            r.owner = Some(std::thread::current().id());
            r.source = start as usize;
            r.count = count;
            r.marker = 0;
            r.micro_rows = 0;
            r.last_only = last_only;
            r.seen.fill(false);
            r.ready.fill(false);
        }
        Ok(())
    }
    pub(crate) fn node(&self, t: *mut ffi::ggml_tensor, ask: bool) -> bool {
        if !self.enabled() {
            return !ask;
        }
        let mut lock = self.lock();
        let Some(r) = lock.as_mut() else { return !ask };
        match r.node(t, ask) {
            Ok(v) => v,
            Err(e) => {
                r.failure = Some(e);
                self.poisoned.store(true, Ordering::Release);
                false
            }
        }
    }
    pub(crate) fn panic(&self) {
        if let Some(r) = self.lock().as_mut() {
            r.failure = Some("panic inside projection callback");
        }
        self.poisoned.store(true, Ordering::Release);
    }
    pub(crate) fn end(&self) -> Result<(), RebirthError> {
        if let Some(r) = self.lock().as_mut() {
            if r.failure.is_none() {
                r.failure = if r.marker != r.count {
                    Some("projection microbatch count mismatch")
                } else {
                    r.check_microbatch().err()
                };
            }
            #[cfg(any(test, feature = "projection-private"))]
            let phase = r.probe.as_ref().map_or("projected", |probe| {
                if probe.edited {
                    "probe_edited"
                } else {
                    "probe_baseline"
                }
            });
            #[cfg(any(test, feature = "projection-private"))]
            for (i, proof) in r.proofs.iter_mut().enumerate().take(r.plan.sites.len()) {
                if let Some(info) = proof.buffer.as_ref().filter(|_| !proof.buffer_reported) {
                    let b = &info.buffer;
                    let site = &r.plan.sites[i];
                    // Fixed arrays render as JSON byte arrays without allocating
                    // Strings or a JSON tree; no tensor pointers escape decode.
                    println!(
                        r#"F6E_PROJECTION_BUFFER {{"schema":1,"phase":"{}","width":{},"depth":{},"layer_native":{},"component_code":{},"kind":{},"is_host":{},"usage":{},"device_type":{},"flags":{},"device_index":{},"type_name_bytes":{:?},"device_name_bytes":{:?},"registry_name_bytes":{:?},"rows":{},"bytes":{},"dtype_f32":true,"view_offset":0,"data_nonnull":{},"contiguous":{},"no_staging_supported":{},"decode_failed":{}}}"#,
                        phase,
                        r.plan.width,
                        r.plan.depth,
                        site.layer,
                        site.code(),
                        b.kind,
                        b.is_host,
                        b.usage,
                        b.device_type,
                        b.flags,
                        b.device_index,
                        b.type_name,
                        b.device_name,
                        b.registry_name,
                        info.rows,
                        info.bytes,
                        b.flags & 64 != 0,
                        b.flags & 128 != 0,
                        matches!(b.kind, 1 | 2),
                        r.failure.is_some()
                    );
                    proof.buffer_reported = true;
                }
            }
            if let Some(e) = r.failure {
                #[cfg(any(test, feature = "projection-private"))]
                eprintln!("F6E_PROJECTION_FAILURE site={}:{} native_status={} marker={} rows={} reason={}", r.diagnostic.0,r.diagnostic.1,r.diagnostic.2,r.marker,r.count,e);
                self.poisoned.store(true, Ordering::Release);
                return Err(error(e));
            }
        }
        Ok(())
    }
    #[cfg(test)]
    pub(crate) fn inherit(&self, other: &Self) -> Result<(), RebirthError> {
        if let Some(r) = other.lock().as_ref() {
            let mut inherited = Runtime::new(r.plan.clone())?;
            inherited.proofs = r.proofs;
            for proof in &mut inherited.proofs {
                proof.buffer = None;
                proof.buffer_reported = false;
            }
            self.install(inherited);
        }
        Ok(())
    }
}
impl LoadedModel {
    pub(crate) fn projection(&self) -> &Slot {
        &self.live_capture().projection
    }
    #[cfg(test)]
    fn projection_raw(&self, sites: Vec<Site>) -> Result<LoadedModel, RebirthError> {
        let h = self.hidden_size() as usize;
        let depth = self.num_layers() as usize;
        if sites.is_empty() || sites.len() > MAX_SITES {
            return Err(error("projection site count outside 1..32"));
        }
        let arch = if self.projection_model_facts(Component::AttnOut).0 {
            "llama"
        } else if self.projection_model_facts(Component::MlpOut).0 {
            "qwen2"
        } else {
            "unsupported"
        };
        for (i, s) in sites.iter().enumerate() {
            validate_site(s, h, depth, arch)?;
            if sites[..i]
                .iter()
                .any(|a| a.layer == s.layer && a.component == s.component)
            {
                return Err(error("duplicate projection site"));
            }
        }
        if sites.capacity() != sites.len() {
            return Err(error("projection site capacity differs from admission"));
        }
        let admitted = estimate(h, sites.len() - 1)?;
        if admitted.total > 64 * 1024 * 1024 {
            return Err(oom(admitted.total));
        }
        let derived = self.clone_with_fresh_context()?;
        let plan = Arc::new(Plan {
            width: h,
            depth,
            sites: sites.into_boxed_slice(),
        });
        derived.projection().install(Runtime::new(plan)?);
        Ok(derived)
    }
    #[cfg(test)]
    pub(crate) fn derive_projection(
        &self,
        sites: Vec<Site>,
        residual: &InterventionSpec,
        fault: Fault,
    ) -> Result<LoadedModel, RebirthError> {
        let _native = crate::NativeGuard::try_acquire("private projection derivation")?;
        let previous = self.projection().lock().as_ref().map(|r| r.plan.clone());
        let sites = if let Some(old) = previous {
            if old.sites.len() + sites.len() > MAX_SITES {
                return Err(error("projection site count outside 1..32"));
            }
            let mut full = Vec::with_capacity(old.sites.len() + sites.len());
            full.extend(old.sites.iter().cloned());
            full.extend(sites);
            full
        } else {
            sites
        };
        if sites.is_empty() || sites.len() > MAX_SITES {
            return Err(error("projection site count outside 1..32"));
        }
        if residual.n_embd != self.hidden_size() as usize
            || residual.n_layer != self.num_layers() as usize
        {
            return Err(error(
                "projection residual specification dimensions differ from model",
            ));
        }
        let adapter_bytes = residual
            .projection_allocation_bytes()
            .ok_or_else(|| error("projection adapter admission overflow"))?
            .checked_add(
                self.steering_baseline
                    .as_ref()
                    .map_or(0, |b| b.values.capacity() * size_of::<f32>()),
            )
            .ok_or_else(|| error("projection adapter admission overflow"))?;
        let estimate = estimate(self.hidden_size() as usize, sites.len() - 1)?;
        if estimate
            .total
            .checked_add(adapter_bytes)
            .is_none_or(|n| n > 64 * 1024 * 1024)
        {
            return Err(oom(estimate.total.saturating_add(adapter_bytes)));
        }
        let mut derived = self.projection_raw(sites)?;
        let count = derived
            .projection()
            .lock()
            .as_ref()
            .unwrap()
            .plan
            .sites
            .len();
        for i in 0..count {
            let site = derived.projection().lock().as_ref().unwrap().plan.sites[i].clone();
            self.prove_projection(&site, fault)?;
            derived.projection().lock().as_mut().unwrap().proofs[i].proven = true;
        }
        residual.projection_apply(&mut derived)?;
        Ok(derived)
    }
    #[cfg(test)]
    pub(crate) fn inherit_projection(&self, source: &LoadedModel) -> Result<(), RebirthError> {
        self.projection().inherit(source.projection())?;
        let plan = self.projection().lock().as_ref().map(|r| r.plan.clone());
        if let Some(plan) = plan {
            for site in plan.sites.iter() {
                source.prove_projection(site, Fault::None)?;
            }
        }
        Ok(())
    }
    fn prove_projection(&self, site: &Site, fault: Fault) -> Result<(), RebirthError> {
        let h = self.hidden_size() as usize;
        let mut axis = Arc::<[f64]>::new_uninit_slice(h);
        for (j, value) in Arc::get_mut(&mut axis).unwrap().iter_mut().enumerate() {
            value.write(if j == 0 { 1.0 } else { 0.0 });
        }
        // SAFETY: every element in the unique Arc slice was initialized above.
        let axis = unsafe { axis.assume_init() };
        let mut probe_site = Site {
            layer: site.layer,
            component: site.component,
            coef: 0.0,
            direction: axis,
        };
        let base = self.projection_probe_context(probe_site.clone())?;
        base.projection().lock().as_mut().unwrap().probe = Some(Box::new(Probe {
            layer: site.layer,
            component: site.component,
            producer: exact_f32(h)?,
            consumer: exact_f32(h)?,
            producer_seen: false,
            consumer_seen: false,
            edited: false,
            neuron: 0,
            baseline_signal: 0.0,
        }));
        base.decode_projection_tokens(&[0], 0, true)?;
        let mut baseline = base
            .projection()
            .lock()
            .as_mut()
            .unwrap()
            .probe
            .take()
            .unwrap();
        if !baseline.producer_seen || !baseline.consumer_seen {
            return Err(error("projection baseline probe incomplete"));
        }
        drop(base);
        let k = (0..h)
            .max_by(|&a, &b| {
                baseline.producer[a]
                    .abs()
                    .total_cmp(&baseline.producer[b].abs())
                    .then_with(|| b.cmp(&a))
            })
            .unwrap();
        let signal = baseline.producer[k];
        if !signal.is_finite() || signal.abs() <= 0.02 {
            return Err(error("projection probe has insufficient causal signal"));
        }
        Arc::make_mut(&mut probe_site.direction).fill(0.0);
        Arc::make_mut(&mut probe_site.direction)[k] = 1.0;
        probe_site.coef = 1.0;
        let shifted = self.projection_probe_context(probe_site)?;
        shifted.projection().lock().as_mut().unwrap().fault = fault;
        baseline.edited = true;
        baseline.neuron = k;
        baseline.baseline_signal = signal;
        baseline.producer_seen = false;
        baseline.consumer_seen = false;
        shifted.projection().lock().as_mut().unwrap().probe = Some(baseline);
        shifted.decode_projection_tokens(&[0], 0, true)?;
        let edited = shifted
            .projection()
            .lock()
            .as_mut()
            .unwrap()
            .probe
            .take()
            .unwrap();
        if !edited.producer_seen || !edited.consumer_seen {
            return Err(error("projection edited probe incomplete"));
        }
        Ok(())
    }
    #[cfg(test)]
    pub(crate) fn projection_audit(&self, positions: &[usize]) {
        assert!(positions.len() <= 128, "private fixture position bound");
        self.projection().lock().as_mut().unwrap().audit = Some(Box::new(Audit {
            positions: positions.into(),
            rows: Vec::with_capacity(128),
            witnesses: Vec::with_capacity(2048),
            bytes: size_of::<Audit>()
                + std::mem::size_of_val(positions)
                + 128 * size_of::<Observation>()
                + 2048 * size_of::<Witness>(),
        }));
    }
    #[cfg(test)]
    pub(crate) fn projection_take_audit(&self) -> (Vec<Observation>, Vec<Witness>) {
        let audit = self
            .projection()
            .lock()
            .as_mut()
            .unwrap()
            .audit
            .take()
            .unwrap();
        (audit.rows, audit.witnesses)
    }
    #[cfg(test)]
    pub(crate) fn projection_stats(&self) -> Stats {
        self.projection()
            .lock()
            .as_ref()
            .map_or(Stats::default(), |r| r.stats)
    }
    #[cfg(test)]
    pub(crate) fn projection_reset_stats(&self) {
        if let Some(r) = self.projection().lock().as_mut() {
            r.stats = Stats::default();
        }
    }
    #[cfg(test)]
    pub(crate) fn projection_fault(&self, fault: Fault) {
        self.projection().lock().as_mut().unwrap().fault = fault;
    }
}
#[cfg(test)]
#[derive(Debug)]
struct Estimate {
    direction_bytes: usize,
    plan_bytes: usize,
    runtime_bytes: usize,
    probe_bytes: usize,
    frame_bytes: usize,
    total: usize,
}
#[cfg(test)]
fn estimate(h: usize, p0: usize) -> Result<Estimate, RebirthError> {
    if !(1..=MAX_WIDTH).contains(&h) || p0 >= MAX_SITES {
        return Err(error("projection admission count/width"));
    }
    let p = p0 + 1;
    let owners = usize::from(p0 > 0) + 1;
    let arc = 2 * size_of::<usize>();
    let direction_bytes = p * (8 * h + arc);
    let plan_bytes = owners * (arc + size_of::<Plan>()) + (p0 + p) * size_of::<Site>();
    let runtime_bytes = owners * (4 * h + size_of::<Runtime>())
        + 2 * (size_of::<LoadedModel>() + size_of::<crate::live_capture::LiveDispatcher>());
    // Baseline vectors move into the edited probe. Only one context/runtime row
    // and canonical axis allocation coexist with these two vectors.
    let probe_bytes = 20 * h
        + 2 * arc
        + size_of::<Plan>()
        + 2 * size_of::<Site>()
        + size_of::<Runtime>()
        + size_of::<Probe>()
        + size_of::<LoadedModel>()
        + size_of::<crate::live_capture::LiveDispatcher>()
        + size_of::<crate::generate::Batch>()
        + 4 * size_of::<i32>()
        + 2 * size_of::<*mut i32>()
        + size_of::<i8>();
    let frame_bytes = size_of::<Estimate>()
        // Node metadata coexists with the consumer classifier metadata and the
        // bounded backend identity frame. Retained metadata lives in Runtime's
        // 32 Proof slots and is already charged by size_of::<Runtime>().
        + 2 * size_of::<ffi::ProjectionInfo>()
        + unsafe { ffi::relm_projection_access_frame_size() }
        + 2 * size_of::<Site>()
        + size_of::<RebirthError>()
        + ERROR_TEXT_BYTES
        + size_of::<ArithmeticFrame>()
        // SAFETY: header-only compiled size; no context/tensor access.
        + unsafe {ffi::relm_projection_name_frame_size()};
    let total = direction_bytes
        .checked_add(plan_bytes)
        .and_then(|v| v.checked_add(runtime_bytes))
        .and_then(|v| v.checked_add(probe_bytes))
        .and_then(|v| v.checked_add(frame_bytes))
        .ok_or_else(|| error("projection admission overflow"))?;
    Ok(Estimate {
        direction_bytes,
        plan_bytes,
        runtime_bytes,
        probe_bytes,
        frame_bytes,
        total,
    })
}
include!("projection_constructor.rs");

#[cfg(test)]
#[path = "projection_tests.rs"]
mod tests;
