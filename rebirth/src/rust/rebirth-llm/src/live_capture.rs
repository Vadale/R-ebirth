//! Stable, context-owned live capture. Eval callbacks execute synchronously on
//! the decoding thread; owned buffers cross to the existing async worker only.
use crate::error::RebirthError;
use crate::ffi;
use crate::live_state::{trace_error, LiveEstimate, LiveRequest, LiveTrace};
use crate::trace::{parse_tensor_name, tensor_f32_rows, CaptureRow, Component};
use std::ffi::{c_void, CStr};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, MutexGuard, PoisonError};
#[cfg(test)]
const LIVE_CAPTURE_BYTES: usize = crate::LIVE_TRANSPORT_BYTES as usize;

#[derive(Default)]
pub(crate) struct LiveDispatcher {
    enabled: AtomicBool,
    capturing: AtomicBool,
    state: Mutex<Option<Capture>>,
}
struct Capture {
    names: Vec<(&'static str, Component)>,
    targets: Vec<CaptureRow>,
    seen: Vec<bool>,
    mlp_seen: Vec<bool>,
    source_pos: u32,
    source_token: i32,
    prompt_count: usize,
    state_id: usize,
    width: usize,
    decode_rows: usize,
    marker_rows: usize,
    final_microbatch: bool,
    pending: Option<usize>,
    copies: usize,
    copied_bytes: usize,
    callback_thread: Option<std::thread::ThreadId>,
    error: Option<RebirthError>,
    token_piece: Option<String>,
    sink: Option<CaptureSink>,
    #[cfg_attr(not(feature = "spill"), allow(dead_code))]
    request: Option<LiveRequest>,
    #[cfg_attr(not(feature = "spill"), allow(dead_code))]
    estimate: Option<LiveEstimate>,
    #[cfg_attr(not(feature = "spill"), allow(dead_code))]
    spill_written: u64,
    finished: bool,
    #[cfg(feature = "spill")]
    cancel: std::sync::Arc<crate::live_spill::LiveCancel>,
}
enum CaptureSink {
    Memory(Vec<CaptureRow>),
    #[cfg(feature = "spill")]
    Spill(Box<crate::live_spill::LiveSpillSink>),
}
#[cfg_attr(not(test), allow(dead_code))]
pub(crate) struct LiveSnapshot {
    pub state_id: usize,
    pub token_id: i32,
    pub context_pos: u32,
    pub source_pos: u32,
    pub source_token: i32,
    pub prompt_count: usize,
    pub rows: Vec<CaptureRow>,
    pub trace: Option<LiveTrace>,
    pub copies: usize,
    pub copied_bytes: usize,
    pub allocated_bytes: usize,
}
pub(crate) type LiveObserver<'a> = dyn FnMut(LiveSnapshot, &[f32]) -> Result<(), RebirthError> + 'a;
fn internal(context: &str) -> RebirthError {
    RebirthError::Internal {
        context: context.into(),
    }
}

pub(crate) fn capture_allocation_bytes(
    width: usize,
    row_capacity: usize,
    names_capacity: usize,
    seen_capacity: usize,
    mlp_capacity: usize,
) -> Option<usize> {
    std::mem::size_of::<LiveDispatcher>()
        .checked_add(std::mem::size_of::<LiveSnapshot>())?
        .checked_add(width.checked_mul(4)?.checked_mul(row_capacity)?)?
        .checked_add(row_capacity.checked_mul(std::mem::size_of::<CaptureRow>() * 2)?)?
        .checked_add(names_capacity.checked_mul(std::mem::size_of::<(&str, Component)>())?)?
        .checked_add(seen_capacity)?
        .checked_add(mlp_capacity)
}
impl LiveDispatcher {
    fn lock(&self) -> MutexGuard<'_, Option<Capture>> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }
    pub(crate) fn install(&mut self, params: &mut ffi::llama_context_params) {
        params.cb_eval = live_trampoline as *mut c_void;
        params.cb_eval_user_data = (self as *mut Self).cast();
    }
    pub(crate) fn begin_decode(
        &self,
        start: i32,
        tokens: &[i32],
        model: &crate::LoadedModel,
    ) -> Result<(), RebirthError> {
        if !self.enabled.load(Ordering::Relaxed) {
            return Ok(());
        }
        let mut guard = self.lock();
        if let Some(state) = guard.as_mut() {
            let capture =
                !state.finished && start as usize + tokens.len() - 1 == state.source_pos as usize;
            if capture {
                crate::async_job::checkpoint()?;
                state.seen.fill(false);
                state.mlp_seen.fill(false);
                state.decode_rows = tokens.len();
                state.marker_rows = 0;
                state.final_microbatch = false;
                state.pending = None;
                state.source_token = tokens[tokens.len() - 1];
                state.callback_thread = Some(std::thread::current().id());
                state.token_piece = if model.has_tokenizer() {
                    Some(model.live_token_piece(state.source_token)?)
                } else {
                    None
                };
                if state.token_piece.as_ref().is_some_and(|s| s.contains('\0')) {
                    return Err(trace_error(
                        "A live token display piece contains an embedded NUL.",
                    ));
                }
                #[cfg(feature = "spill")]
                if let (Some(request), Some(estimate)) = (&state.request, &state.estimate) {
                    if estimate.spilled {
                        state.sink = Some(CaptureSink::Spill(Box::new(
                            crate::live_spill::LiveSpillSink::new(
                                request,
                                estimate,
                                state.state_id,
                                state.prompt_count,
                                state.source_pos,
                                state.spill_written,
                                state.cancel.clone(),
                            )?,
                        )));
                    } else {
                        state.sink =
                            Some(CaptureSink::Memory(Vec::with_capacity(state.targets.len())));
                    }
                } else {
                    state.sink = Some(CaptureSink::Memory(Vec::with_capacity(state.targets.len())));
                }
                #[cfg(not(feature = "spill"))]
                {
                    state.sink = Some(CaptureSink::Memory(Vec::with_capacity(state.targets.len())));
                }
            }
            self.capturing
                .store(capture && !state.targets.is_empty(), Ordering::Release);
        }
        Ok(())
    }
    pub(crate) fn end_decode(&self) -> Result<(), RebirthError> {
        if !self.capturing.swap(false, Ordering::AcqRel) {
            return Ok(());
        }
        let mut guard = self.lock();
        let state = guard
            .as_mut()
            .ok_or_else(|| internal("missing active capture"))?;
        if let Some(error) = state.error.take() {
            return Err(error);
        }
        if state.marker_rows != state.decode_rows
            || state.pending.is_some()
            || state.seen.iter().any(|v| !v)
        {
            return Err(trace_error("The live graph did not emit exactly one final-microbatch vector for every selected tap."));
        }
        Ok(())
    }
    pub(crate) fn snapshot(
        &self,
        state_id: usize,
        token: i32,
        context_pos: u32,
    ) -> Result<LiveSnapshot, RebirthError> {
        // Moving the sink out releases the callback mutex before joining/writing.
        let (sink, mut snapshot) = {
            let mut guard = self.lock();
            let state = guard
                .as_mut()
                .ok_or_else(|| internal("missing live session"))?;
            if state.source_pos.checked_add(1) != Some(context_pos) || state.state_id != state_id {
                return Err(internal("live source/state correlation mismatch"));
            }
            let allocated_bytes = capture_allocation_bytes(
                state.width,
                state.targets.capacity(),
                state.names.capacity(),
                state.seen.capacity(),
                state.mlp_seen.capacity(),
            )
            .ok_or_else(|| internal("live allocation overflow"))?;
            (
                state
                    .sink
                    .take()
                    .ok_or_else(|| internal("live capture sink missing"))?,
                LiveSnapshot {
                    state_id,
                    token_id: token,
                    context_pos,
                    source_pos: state.source_pos,
                    source_token: state.source_token,
                    prompt_count: state.prompt_count,
                    rows: Vec::new(),
                    trace: None,
                    copies: state.copies,
                    copied_bytes: state.copied_bytes,
                    allocated_bytes,
                },
            )
        };
        match sink {
            CaptureSink::Memory(rows) => snapshot.rows = rows,
            #[cfg(feature = "spill")]
            CaptureSink::Spill(sink) => {
                let report = (*sink).finish()?;
                self.lock()
                    .as_mut()
                    .ok_or_else(|| internal("live session lost"))?
                    .spill_written += report.serialized_bytes;
                snapshot.trace = Some(LiveTrace::Spilled(Box::new(report)));
            }
        }
        Ok(snapshot)
    }
    pub(crate) fn advance(&self, context_pos: u32, finished: bool) -> Result<(), RebirthError> {
        let mut guard = self.lock();
        let state = guard
            .as_mut()
            .ok_or_else(|| internal("missing live session"))?;
        state.source_pos = context_pos;
        state.state_id += 1;
        state.finished = finished;
        Ok(())
    }
    fn on_node(&self, tensor: *mut ffi::ggml_tensor, ask: bool) -> Result<bool, RebirthError> {
        if !self.capturing.load(Ordering::Acquire) {
            return Ok(!ask);
        }
        let mut guard = self.lock();
        let Some(state) = guard.as_mut() else {
            return Ok(!ask);
        };
        if state.error.is_some() {
            return Ok(false);
        }
        if state.callback_thread != Some(std::thread::current().id()) {
            return Err(internal("eval callback ran outside the decode thread"));
        }
        // SAFETY: scheduler owns the live tensor/name until this callback returns.
        let name_ptr = unsafe { ffi::ggml_get_name(tensor) };
        if name_ptr.is_null() {
            return Ok(!ask);
        }
        let Ok(name) = (unsafe { CStr::from_ptr(name_ptr) }).to_str() else {
            return Ok(!ask);
        };
        if ask && name == "attn_norm-0" {
            if state.pending.is_some() {
                return Err(internal("new microbatch before pending live copy"));
            }
            let rows = tensor_f32_rows(tensor, state.width)?;
            state.marker_rows = state
                .marker_rows
                .checked_add(rows)
                .filter(|&n| n <= state.decode_rows)
                .ok_or_else(|| trace_error("Live microbatch row marker exceeds decode length."))?;
            state.final_microbatch = state.marker_rows == state.decode_rows;
            state.mlp_seen.fill(false);
            return Ok(false);
        }
        let Some((base, layer)) = parse_tensor_name(name) else {
            return Ok(!ask);
        };
        let Some((_, component)) = state.names.iter().find(|(n, _)| *n == base) else {
            return Ok(!ask);
        };
        let Some(index) = state
            .targets
            .iter()
            .position(|r| r.layer == layer && r.component == *component)
        else {
            return Ok(!ask);
        };
        if !state.final_microbatch {
            return Ok(!ask);
        }
        if ask {
            if *component == Component::MlpOut && state.mlp_seen[index] {
                return Ok(false);
            }
            if state.seen[index] || state.pending.is_some() {
                return Err(trace_error(
                    "Duplicate live activation tap in final microbatch.",
                ));
            }
            if *component == Component::MlpOut {
                state.mlp_seen[index] = true;
            }
            state.pending = Some(index);
            return Ok(true);
        }
        if state.pending.take() != Some(index) {
            return Err(internal("live ready callback does not match requested tap"));
        }
        let rows = tensor_f32_rows(tensor, state.width)?;
        if rows > state.decode_rows {
            return Err(trace_error("Live activation row count exceeds decode."));
        }
        crate::async_job::checkpoint()?;
        let bytes = state.width * 4;
        let mut values = vec![0.0_f32; state.width];
        // SAFETY: checked contiguous F32 shape; only final row is read after
        // backend synchronization. No earlier microbatch values are copied.
        unsafe {
            ffi::ggml_backend_tensor_get(
                tensor,
                values.as_mut_ptr().cast(),
                (rows - 1) * bytes,
                bytes,
            );
        }
        let target = &state.targets[index];
        let row = CaptureRow {
            prompt_id: 0,
            token_pos: state.source_pos,
            layer: target.layer,
            component: target.component,
            token: state.token_piece.clone(),
            values,
        };
        match state
            .sink
            .as_mut()
            .ok_or_else(|| internal("live sink missing during capture"))?
        {
            CaptureSink::Memory(rows) => rows.push(row),
            #[cfg(feature = "spill")]
            CaptureSink::Spill(writer) => writer.push(row)?,
        }
        state.seen[index] = true;
        state.copies += 1;
        state.copied_bytes += bytes;
        Ok(true)
    }
    fn activate_inner<'a>(
        &'a self,
        model: &crate::LoadedModel,
        prompt_count: usize,
        layers: &[u32],
        components: &[Component],
        request: Option<LiveRequest>,
        estimate: Option<LiveEstimate>,
    ) -> Result<LiveSession<'a>, RebirthError> {
        if prompt_count == 0
            || components.is_empty()
            || components
                .iter()
                .enumerate()
                .any(|(i, c)| components[..i].contains(c))
            || layers
                .iter()
                .enumerate()
                .any(|(i, &l)| l >= model.num_layers() as u32 || layers[..i].contains(&l))
        {
            return Err(trace_error("Invalid live capture selection."));
        }
        let width =
            usize::try_from(model.hidden_size()).map_err(|_| internal("invalid hidden width"))?;
        if width == 0
            || (!layers.is_empty()
                && width
                    .checked_mul(4)
                    .is_none_or(|n| n > crate::LIVE_VECTOR_BYTES as usize))
        {
            return Err(trace_error("Live activation vector exceeds 1 MiB."));
        }
        let mut names = Vec::with_capacity(components.len());
        for &component in components.iter().filter(|_| !layers.is_empty()) {
            let name = crate::trace::component_name(&model.architecture(), component)
                .ok_or_else(|| trace_error("Requested live component is unsupported."))?;
            names.push((name, component));
        }
        let count = layers
            .len()
            .checked_mul(components.len())
            .ok_or_else(|| internal("capture size overflow"))?;
        let mut targets = Vec::with_capacity(count);
        for &layer in layers {
            for &component in components {
                targets.push(CaptureRow {
                    prompt_id: 0,
                    token_pos: 0,
                    layer,
                    component,
                    token: None,
                    values: Vec::new(),
                });
            }
        }
        let mut guard = self.lock();
        if guard.is_some() {
            return Err(internal("live capture already active"));
        }
        *guard = Some(Capture {
            names,
            targets,
            seen: vec![false; count],
            mlp_seen: vec![false; count],
            source_pos: (prompt_count - 1) as u32,
            source_token: 0,
            prompt_count,
            state_id: 1,
            width,
            decode_rows: 0,
            marker_rows: 0,
            final_microbatch: false,
            pending: None,
            copies: 0,
            copied_bytes: 0,
            callback_thread: None,
            error: None,
            token_piece: None,
            sink: None,
            request,
            estimate,
            spill_written: 0,
            finished: false,
            #[cfg(feature = "spill")]
            cancel: crate::async_job::live_cancel().unwrap_or_default(),
        });
        self.enabled.store(true, Ordering::Release);
        Ok(LiveSession(self))
    }
    #[cfg(test)]
    fn activate<'a>(
        &'a self,
        model: &crate::LoadedModel,
        prompt_count: usize,
        layers: &[u32],
        components: &[Component],
    ) -> Result<LiveSession<'a>, RebirthError> {
        self.activate_inner(model, prompt_count, layers, components, None, None)
    }
}
extern "C" fn live_trampoline(t: *mut ffi::ggml_tensor, ask: bool, user: *mut c_void) -> bool {
    if user.is_null() {
        return !ask;
    }
    // SAFETY: boxed dispatcher outlives the context and its synchronous scheduler.
    let dispatcher = unsafe { &*user.cast::<LiveDispatcher>() };
    if !dispatcher.capturing.load(Ordering::Acquire) {
        return !ask;
    }
    let result =
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| dispatcher.on_node(t, ask)));
    match result {
        Ok(Ok(value)) => value,
        failure => {
            if let Some(state) = dispatcher.lock().as_mut() {
                state.error = Some(match failure {
                    Ok(Err(error)) => error,
                    _ => internal("panic inside live activation callback"),
                });
            }
            false
        }
    }
}
struct LiveSession<'a>(&'a LiveDispatcher);
impl Drop for LiveSession<'_> {
    fn drop(&mut self) {
        self.0.capturing.store(false, Ordering::Release);
        self.0.enabled.store(false, Ordering::Release);
        // Drop/join occurs on the generation worker after releasing callback lock.
        let state = self.0.lock().take();
        drop(state);
    }
}
impl crate::LoadedModel {
    #[cfg(test)]
    fn generate_observed(
        &self,
        prompt: &[i32],
        params: &crate::GenerateParams,
        layers: &[u32],
        components: &[Component],
        observer: &mut LiveObserver<'_>,
    ) -> Result<crate::Generation, RebirthError> {
        let _native = crate::NativeGuard::try_acquire("live feasibility generation")?;
        self.validate_ids(prompt)?;
        let _session = self
            .live_capture()
            .activate(self, prompt.len(), layers, components)?;
        self.generate_inner(prompt, params, Some(observer))
    }
    pub(crate) fn generate_live_tokens(
        &self,
        prompt: &[i32],
        params: &crate::GenerateParams,
        request: &LiveRequest,
    ) -> Result<crate::Generation, RebirthError> {
        let estimate = request.preflight(&self.metadata(), params.max_tokens)?;
        let _session = self.live_capture().activate_inner(
            self,
            prompt.len(),
            &request.layers,
            &request.components,
            Some(request.clone()),
            Some(estimate),
        )?;
        self.generate_inner(
            prompt,
            params,
            Some(&mut |snapshot, logits| {
                let picks = crate::top_k_logits(logits, request.top);
                let mut summary = Vec::with_capacity(picks.len());
                for (id, logit, prob) in picks {
                    let token = if self.has_tokenizer() {
                        self.live_token_piece(id as i32)?
                    } else {
                        String::new()
                    };
                    if token.contains('\0') {
                        return Err(trace_error("A live logit token contains an embedded NUL."));
                    }
                    summary.push(crate::TokenLogit {
                        token_id: id as i32,
                        token,
                        logit,
                        prob,
                    });
                }
                let trace = snapshot.trace.unwrap_or(LiveTrace::Memory(snapshot.rows));
                crate::async_job::publish_live(crate::LiveState {
                    job_id: 0,
                    state_id: snapshot.state_id,
                    token_id: snapshot.token_id,
                    context_pos: snapshot.context_pos,
                    source_pos: snapshot.source_pos,
                    prompt_token_count: snapshot.prompt_count,
                    elapsed: 0.0,
                    logits: summary,
                    trace,
                })
            }),
        )
    }
    pub(crate) fn generate_live_prompt(
        &self,
        prompt: &str,
        chat: bool,
        params: &crate::GenerateParams,
        request: &LiveRequest,
    ) -> Result<crate::Generation, RebirthError> {
        let (text, add, parse) = self.resolve_prompt_text(prompt, chat)?;
        let tokens = self.tokenize(&text, add, parse)?;
        self.generate_live_tokens(&tokens, params, request)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::load_for_live_feasibility;
    use crate::{BackendKind, GenerateParams, LoadRequest};
    use std::path::PathBuf;
    use std::time::{Duration, Instant};

    fn root() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../..")
    }

    fn request(path: PathBuf, backend: BackendKind, context_length: u32) -> LoadRequest {
        LoadRequest {
            path,
            context_length,
            gpu_layers: None,
            backend,
            mmap: true,
            projector: None,
        }
    }

    fn params() -> GenerateParams {
        GenerateParams {
            max_tokens: 4,
            temperature: 0.0,
            top_p: 1.0,
            seed: 42,
            stop: vec![],
        }
    }

    /// Download-free cargo-test CI: dormant/active/dormant reuse and ownership
    /// moving to another decode thread. Callback selection must survive caches.
    #[test]
    fn same_context_toggle_and_worker_move_preserve_generation() {
        let model = load_for_live_feasibility(
            request(
                root().join("tests/llm-golden/synthetic/synthetic-llama-2l.gguf"),
                BackendKind::Cpu,
                768,
            ),
            Some(4),
            Some(2),
            true,
        )
        .unwrap();
        let prompt = vec![1, 7, 13, 22, 5, 31, 44];
        let baseline = model.generate(&prompt, &params()).unwrap();
        let (model, observed) = std::thread::spawn(move || {
            let mut seen = 0;
            let observed = model
                .generate_observed(
                    &prompt,
                    &params(),
                    &[0, 1],
                    &[Component::Residual, Component::AttnOut, Component::MlpOut],
                    &mut |snapshot, logits| {
                        seen += 1;
                        assert_eq!(snapshot.state_id, seen);
                        assert_eq!(snapshot.source_pos as usize, prompt.len() + seen - 2);
                        assert_eq!(snapshot.context_pos as usize, prompt.len() + seen - 1);
                        assert_eq!(snapshot.prompt_count, prompt.len());
                        assert_eq!(snapshot.rows.len(), 6);
                        assert_eq!(logits.len(), 48);
                        if seen == 1 {
                            assert_eq!(snapshot.source_token, *prompt.last().unwrap());
                        }
                        assert!(snapshot
                            .rows
                            .iter()
                            .all(|r| r.token_pos == snapshot.source_pos));
                        Ok(())
                    },
                )
                .unwrap();
            assert_eq!(seen, observed.tokens.len());
            assert!(model.live_capture().lock().is_none());
            (model, observed)
        })
        .join()
        .unwrap();
        assert_eq!(observed, baseline);
        assert_eq!(
            model
                .generate(&[1, 7, 13, 22, 5, 31, 44], &params())
                .unwrap(),
            baseline
        );
    }

    /// Download-free cargo-test CI: observer errors detach state before reuse.
    #[test]
    fn observer_failure_detaches_capture() {
        let model = crate::load(request(
            root().join("tests/llm-golden/synthetic/synthetic-llama-2l.gguf"),
            BackendKind::Cpu,
            512,
        ))
        .unwrap();
        let baseline = model.generate(&[1, 7], &params()).unwrap();
        let result = model.generate_observed(
            &[1, 7],
            &params(),
            &[1],
            &[Component::Residual],
            &mut |_, _| Err(internal("injected observer failure")),
        );
        assert!(result.is_err());
        assert!(model.live_capture().lock().is_none());
        assert_eq!(model.generate(&[1, 7], &params()).unwrap(), baseline);
    }

    /// Download-free cargo-test CI: selection refusal and context-full last
    /// sample preserve the valid preceding source and do not invent a decode.
    #[test]
    fn capture_filters_and_context_full_boundary() {
        let model = crate::load(request(
            root().join("tests/llm-golden/synthetic/synthetic-llama-2l.gguf"),
            BackendKind::Cpu,
            32,
        ))
        .unwrap();
        let prompt = vec![1; model.metadata().context_length as usize];
        let baseline = model.generate(&prompt, &params()).unwrap();
        let mut seen = 0;
        let observed = model
            .generate_observed(
                &prompt,
                &params(),
                &[1],
                &[Component::MlpOut],
                &mut |state, _| {
                    seen += 1;
                    assert_eq!(state.context_pos as usize, prompt.len());
                    assert_eq!(state.source_pos as usize, prompt.len() - 1);
                    assert_eq!(state.rows.len(), 1);
                    assert_eq!(state.rows[0].layer, 1);
                    assert_eq!(state.rows[0].component, Component::MlpOut);
                    Ok(())
                },
            )
            .unwrap();
        assert_eq!(seen, 1);
        assert_eq!(observed, baseline);
        assert_eq!(observed.stop_reason, crate::StopReason::ContextFull);
        for layers in [vec![2], vec![1, 1]] {
            assert!(model
                .generate_observed(
                    &[1, 7],
                    &params(),
                    &layers,
                    &[Component::Residual],
                    &mut |_, _| panic!("invalid selection must not deliver")
                )
                .is_err());
        }
        let mut zero_rows = 0;
        model
            .generate_observed(
                &[1, 7],
                &params(),
                &[],
                &[Component::Residual],
                &mut |state, _| {
                    assert!(state.rows.is_empty());
                    zero_rows += 1;
                    Ok(())
                },
            )
            .unwrap();
        assert_eq!(zero_rows, params().max_tokens);
    }

    fn csv(name: &str) -> Vec<Vec<String>> {
        std::fs::read_to_string(
            root()
                .join("tests/llm-golden/live-state/goldens")
                .join(name),
        )
        .unwrap()
        .lines()
        .skip(1)
        .filter(|line| !line.is_empty())
        .map(|line| line.split(',').map(str::to_owned).collect())
        .collect()
    }

    fn check_digest(path: &std::path::Path, expected: &str) {
        // Test-only system checksum tools already present on the Mac/Linux CI
        // runners. This checks artifact bytes, not paths or echoed metadata.
        let mut command = if cfg!(target_os = "macos") {
            let mut c = std::process::Command::new("shasum");
            c.args(["-a", "256"]);
            c
        } else {
            std::process::Command::new("sha256sum")
        };
        let output = command.arg(path).output().expect("system SHA256 tool");
        assert!(output.status.success(), "checksum {}", path.display());
        assert_eq!(
            String::from_utf8(output.stdout)
                .unwrap()
                .split_whitespace()
                .next()
                .unwrap(),
            expected,
            "artifact bytes {}",
            path.display()
        );
    }

    /// Download-free cargo-test CI. Independent full-prefix numpy reference,
    /// last-only output pruning, over-n_batch and over-n_ubatch first prefill,
    /// post-intervention residual and unmodified raw MLP semantics.
    #[test]
    fn source_rows_and_logits_match_independent_prefix_goldens() {
        let dir = root().join("tests/llm-golden/live-state/goldens");
        let manifest: serde_json::Value =
            serde_json::from_slice(&std::fs::read(dir.join("manifest.json")).unwrap()).unwrap();
        for (name, artifact) in manifest["artifacts"].as_object().unwrap() {
            check_digest(&dir.join(name), artifact["sha256"].as_str().unwrap());
        }
        for (path, digest) in manifest["provenance_sha256"].as_object().unwrap() {
            check_digest(&root().join(path), digest.as_str().unwrap());
        }
        let states = csv("states.csv");
        let activations = csv("activations.csv");
        let logits = csv("logits.csv");
        let mut maximum_activation_delta = 0.0_f64;
        let mut maximum_logit_delta = 0.0_f64;
        let mut compared_values = 0;
        for case in manifest["cases"].as_array().unwrap() {
            let name = case["name"].as_str().unwrap();
            let prompt: Vec<i32> = case["prompt_tokens_native"]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| v.as_i64().unwrap() as i32)
                .collect();
            let expected_tokens: Vec<i32> = case["generated_tokens_native"]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| v.as_i64().unwrap() as i32)
                .collect();
            // long_prefill covers both n_batch chunking and a final decode that
            // itself spans physical microbatches; both use only last-logit flags.
            let batch_sizes = if name == "long_prefill" {
                vec![512, 768]
            } else {
                vec![512]
            };
            for batch in batch_sizes {
                let base = load_for_live_feasibility(
                    request(
                        root().join("tests/llm-golden/synthetic/synthetic-llama-2l.gguf"),
                        BackendKind::Cpu,
                        768,
                    ),
                    Some(batch),
                    Some(64),
                    true,
                )
                .unwrap();
                let mut intervention = crate::InterventionSpec::new(32, 2);
                if let Some(layer) = case["steer_layer_native"].as_u64() {
                    let vector: Vec<f32> = case["steer_vector"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|v| v.as_f64().unwrap() as f32)
                        .collect();
                    intervention.add_steer(layer as usize, &vector);
                }
                for item in case["ablate_native"].as_array().unwrap() {
                    let neurons: Vec<usize> = item["neurons"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|v| v.as_u64().unwrap() as usize)
                        .collect();
                    intervention.add_ablation(
                        item["layer"].as_u64().unwrap() as usize,
                        &neurons,
                        item["value"].as_f64().unwrap() as f32,
                    );
                }
                let derived = if name != "baseline" && name != "long_prefill" {
                    Some(base.derive_with_interventions(&intervention).unwrap())
                } else {
                    None
                };
                let model = derived.as_ref().unwrap_or(&base);
                let parameters = GenerateParams {
                    max_tokens: expected_tokens.len(),
                    ..params()
                };
                let ordinary = model.generate(&prompt, &parameters).unwrap();
                let mut count = 0;
                let observed = model
                    .generate_observed(
                        &prompt,
                        &parameters,
                        &[0, 1],
                        &[Component::Residual, Component::AttnOut, Component::MlpOut],
                        &mut |snapshot, raw| {
                            count += 1;
                            let state = states
                                .iter()
                                .find(|row| {
                                    row[0] == name
                                        && row[1].parse::<usize>().unwrap() == snapshot.state_id
                                })
                                .unwrap();
                            assert_eq!(snapshot.state_id, count);
                            assert_eq!(snapshot.token_id + 1, state[3].parse::<i32>().unwrap());
                            assert_eq!(snapshot.context_pos + 1, state[4].parse::<u32>().unwrap());
                            assert_eq!(snapshot.source_pos + 1, state[5].parse::<u32>().unwrap());
                            assert_eq!(snapshot.source_token + 1, state[7].parse::<i32>().unwrap());
                            assert_eq!(snapshot.prompt_count, state[8].parse::<usize>().unwrap());
                            assert_eq!(snapshot.rows.len(), 6);
                            for row in &snapshot.rows {
                                assert_eq!(row.token_pos, snapshot.source_pos);
                                for (neuron, &value) in row.values.iter().enumerate() {
                                    let reference = activations
                                        .iter()
                                        .find(|v| {
                                            v[0] == name
                                                && v[1].parse::<usize>().unwrap() == count
                                                && v[2].parse::<u32>().unwrap() == row.layer + 1
                                                && v[3] == row.component.as_str()
                                                && v[4].parse::<usize>().unwrap() == neuron + 1
                                        })
                                        .unwrap()[5]
                                        .parse::<f64>()
                                        .unwrap();
                                    let delta = (f64::from(value) - reference).abs();
                                    maximum_activation_delta = maximum_activation_delta.max(delta);
                                    assert!(
                                        delta <= 1e-2,
                                        "{name}/{count}/{}/{}/{} activation delta {delta}",
                                        row.layer,
                                        row.component.as_str(),
                                        neuron
                                    );
                                    compared_values += 1;
                                }
                            }
                            let picks = crate::top_k_logits(raw, raw.len());
                            assert_eq!(picks.len(), 48);
                            for (rank, &(id, value, prob)) in picks.iter().enumerate() {
                                let row = logits
                                    .iter()
                                    .find(|v| {
                                        v[0] == name
                                            && v[1].parse::<usize>().unwrap() == count
                                            && v[2].parse::<usize>().unwrap() == id + 1
                                    })
                                    .unwrap();
                                let delta =
                                    (f64::from(value) - row[3].parse::<f64>().unwrap()).abs();
                                maximum_logit_delta = maximum_logit_delta.max(delta);
                                assert!(delta <= 1e-2, "{name}/{count}/{id} logit delta {delta}");
                                assert!((prob - row[4].parse::<f64>().unwrap()).abs() <= 1e-2);
                                if rank > 0 {
                                    let previous = picks[rank - 1];
                                    assert!(
                                        previous.1 > value
                                            || (previous.1 == value && previous.0 < id)
                                    );
                                }
                            }
                            assert!((picks.iter().map(|p| p.2).sum::<f64>() - 1.0).abs() < 1e-12);
                            Ok(())
                        },
                    )
                    .unwrap();
                assert_eq!(count, expected_tokens.len());
                assert_eq!(
                    observed.tokens, expected_tokens,
                    "independent autoregressive token path {name}"
                );
                assert_eq!(observed, ordinary, "same-context observer parity {name}");
                assert_eq!(model.generate(&prompt, &parameters).unwrap(), ordinary);
            }
        }
        assert_eq!(compared_values, 3840);
        println!("F6_GOLDEN activation_values={compared_values} max_activation_delta={maximum_activation_delta} max_logit_delta={maximum_logit_delta}");
    }

    static LOAD_LOG: Mutex<String> = Mutex::new(String::new());

    extern "C" fn feasibility_log(
        _level: std::os::raw::c_int,
        message: *const std::os::raw::c_char,
        _data: *mut c_void,
    ) {
        if message.is_null() {
            return;
        }
        let _ = std::panic::catch_unwind(|| {
            // SAFETY: llama lends a NUL-terminated message for this call.
            let message = unsafe { CStr::from_ptr(message) }.to_string_lossy();
            LOAD_LOG
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push_str(&message);
        });
    }

    struct LoadLog;
    impl Drop for LoadLog {
        fn drop(&mut self) {
            // SAFETY: restore static quiet callback; no borrowed logger storage.
            unsafe {
                ffi::llama_log_set(Some(crate::engine::quiet_log), std::ptr::null_mut());
            }
        }
    }

    fn start_load_log() -> LoadLog {
        LOAD_LOG
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clear();
        // SAFETY: static callback and global mutex live beyond both model loads;
        // this ignored test holds the process-wide NativeGuard exclusively.
        unsafe {
            ffi::llama_log_set(Some(feasibility_log), std::ptr::null_mut());
        }
        LoadLog
    }

    // b10828 names actual Metal devices/buffers MTL<n>, not "Metal".
    // Match a selected device to its own compute buffer, not an arbitrary GPU.
    fn selected_metal_compute(devices: &[String], compute: &[(String, f64)]) -> bool {
        devices.iter().any(|description| {
            let name = description.split_whitespace().next().unwrap_or("");
            let metal_name = name.strip_prefix("MTL").is_some_and(|suffix| {
                !suffix.is_empty() && suffix.bytes().all(|b| b.is_ascii_digit())
            });
            metal_name
                && compute
                    .iter()
                    .any(|(buffer, mib)| buffer == name && mib.is_finite() && *mib > 0.0)
        })
    }

    #[test]
    fn metal_receipt_matches_retained_pinned_device_name() {
        let log = std::fs::read_to_string(
            root().join("tests/live-state/fixtures/metal-backend-b10828.txt"),
        )
        .unwrap();
        let devices: Vec<_> = log
            .lines()
            .filter_map(|line| line.split_once(": using device ").map(|p| p.1.to_owned()))
            .collect();
        let compute: Vec<_> = log
            .lines()
            .filter_map(|line| {
                let (prefix, suffix) = line.split_once(" compute buffer size = ")?;
                Some((
                    prefix.split_once(':')?.1.trim().to_owned(),
                    suffix.split_whitespace().next()?.parse::<f64>().ok()?,
                ))
            })
            .collect();
        assert!(
            !devices.iter().any(|name| name.starts_with("Metal")),
            "retained receipt must reproduce the original parser rejection"
        );
        assert!(selected_metal_compute(&devices, &compute));
        for name in ["", "CPU", "CUDA0", "Metal", "MTL", "MTLfake", "MTL0spoof"] {
            assert!(!selected_metal_compute(
                &[name.into()],
                &[(name.into(), 1.0)]
            ));
        }
        assert!(!selected_metal_compute(
            &devices,
            &[("MTL1".into(), 300.25)]
        ));
        for size in [0.0, -1.0, f64::NAN, f64::INFINITY] {
            assert!(!selected_metal_compute(&devices, &[("MTL0".into(), size)]));
        }
        assert!(!selected_metal_compute(&[], &compute));
        assert!(!selected_metal_compute(&devices, &[]));
    }

    fn backend_receipt(model: &crate::LoadedModel, backend: BackendKind) -> serde_json::Value {
        let log = std::mem::take(&mut *LOAD_LOG.lock().unwrap_or_else(PoisonError::into_inner));
        let metadata = model.metadata();
        let offload: Vec<_> = log
            .lines()
            .filter_map(|line| {
                let suffix = line.split_once(": offloaded ")?.1;
                let counts = suffix.split_whitespace().next()?;
                let (actual, total) = counts.split_once('/')?;
                Some((actual.parse::<usize>().ok()?, total.parse::<usize>().ok()?))
            })
            .collect();
        let devices: Vec<_> = log
            .lines()
            .filter_map(|line| line.split_once(": using device ").map(|p| p.1.to_owned()))
            .collect();
        let compute: Vec<_> = log
            .lines()
            .filter_map(|line| {
                let (prefix, suffix) = line.split_once(" compute buffer size = ")?;
                let name = prefix.split_once(":")?.1.trim();
                let mib = suffix.split_whitespace().next()?.parse::<f64>().ok()?;
                Some((name.to_owned(), mib))
            })
            .collect();
        assert_eq!(metadata.backend, backend.as_str());
        assert!(
            !compute.is_empty(),
            "missing actual compute-buffer receipt: {log}"
        );
        match backend {
            BackendKind::Cpu => {
                assert_eq!(metadata.gpu_layers, 0);
                assert!(devices.is_empty(), "CPU selected a GPU: {devices:?}");
                assert!(
                    offload.iter().all(|p| p.0 == 0),
                    "CPU offloaded layers: {offload:?}"
                );
                assert!(
                    compute.iter().all(|(name, _)| name == "CPU"),
                    "CPU has non-CPU compute buffers: {compute:?}"
                );
            }
            BackendKind::Metal => {
                assert_eq!(
                    offload.len(),
                    1,
                    "missing/ambiguous layer offload receipt: {log}"
                );
                assert_eq!(
                    offload[0],
                    (
                        (metadata.layers + 1) as usize,
                        (metadata.layers + 1) as usize
                    ),
                    "not all layers were offloaded: {log}"
                );
                assert!(
                    selected_metal_compute(&devices, &compute),
                    "no selected Metal device with its own positive compute buffer: {log}"
                );
            }
            BackendKind::Cuda => panic!("F6a.0 acceptance is CPU/Metal only"),
        }
        serde_json::json!({"resolved_backend": metadata.backend,
            "gpu_layer_policy": metadata.gpu_layers,
            "offloaded_layers": offload, "selected_devices": devices,
            "compute_buffers_mib": compute, "native_load_log": log})
    }

    /// Download-free Rust CI: descriptors, vectors and bool arrays are counted by
    /// actual capacity, with explicit fixed storage and overflow refusal.
    #[test]
    fn allocation_formula_covers_tiny_and_wide_capture_capacities() {
        assert!(capture_allocation_bytes(usize::MAX, 1, 1, 1, 1).is_none());
        assert!(capture_allocation_bytes(32, usize::MAX, 1, 1, 1).is_none());
        for (width, rows, names) in [(32, 6, 3), (896, 1, 1), (896, 72, 3), (262144, 7, 1)] {
            let values: Vec<Vec<f32>> = (0..rows).map(|_| vec![0.0; width]).collect();
            let storage: Vec<CaptureRow> = Vec::with_capacity(rows);
            let selection: Vec<(&str, Component)> = Vec::with_capacity(names);
            let seen = vec![false; rows];
            let actual = values.iter().map(|v| v.capacity() * 4).sum::<usize>()
                + storage.capacity() * std::mem::size_of::<CaptureRow>() * 2
                + selection.capacity() * std::mem::size_of::<(&str, Component)>()
                + seen.capacity() * 2
                + std::mem::size_of::<LiveDispatcher>()
                + std::mem::size_of::<LiveSnapshot>();
            assert_eq!(
                capture_allocation_bytes(width, rows, names, rows, rows),
                Some(actual)
            );
        }
        assert!(capture_allocation_bytes(262144, 8, 1, 8, 8).unwrap() > LIVE_CAPTURE_BYTES);
        assert!(capture_allocation_bytes(32, 1, 1, 1, 1).unwrap() > 32 * 4);
    }

    /// [MODEL] Local cached-Qwen CPU/Metal F6a.0 go/no-go, explicitly invoked.
    /// No model download; one warmup per mode and three interleaved measurements.
    /// The callback-free comparator exists only in this acceptance harness.
    #[test]
    #[ignore = "F6a.0 local cached-model benchmark; set F6_MODEL, F6_BACKEND, F6_SOURCE, F6_MODEL_SHA256"]
    fn live_feasibility_model() {
        let executable = std::env::current_exe().unwrap();
        let build_profile = executable
            .parent()
            .and_then(|p| p.parent())
            .and_then(|p| p.file_name())
            .and_then(|p| p.to_str())
            .unwrap();
        assert_eq!(
            build_profile, "release",
            "F6a.0 performance requires cargo test --release, matching R Makevars"
        );
        if cfg!(debug_assertions) {
            panic!("debug assertions must be disabled for production-representative timing");
        }
        let _native = crate::NativeGuard::try_acquire("live feasibility benchmark").unwrap();
        let _ = crate::available_backends();
        let load_log = start_load_log();
        let path = PathBuf::from(std::env::var("F6_MODEL").expect("F6_MODEL"));
        let backend_name = std::env::var("F6_BACKEND").expect("F6_BACKEND");
        let backend = BackendKind::parse(&backend_name).unwrap();
        let source = std::env::var("F6_SOURCE").expect("F6_SOURCE exact source/diff digest");
        let model_digest =
            std::env::var("F6_MODEL_SHA256").expect("F6_MODEL_SHA256 verified externally");
        let control =
            load_for_live_feasibility(request(path.clone(), backend, 1024), None, None, false)
                .unwrap();
        let control_backend = backend_receipt(&control, backend);
        let observed = crate::load(request(path.clone(), backend, 1024)).unwrap();
        let observed_backend = backend_receipt(&observed, backend);
        drop(load_log);
        let system_info = crate::system_info();
        println!(
            "F6_BACKEND {}",
            serde_json::json!({"source": source, "requested_backend": backend_name,
            "build_profile": build_profile, "debug_assertions": cfg!(debug_assertions),
            "executable": executable, "system_info": system_info,
            "callback_free": control_backend, "hooked": observed_backend})
        );
        let prompt = "Write a detailed explanation of how photosynthesis works, including the role of light, water, carbon dioxide and chlorophyll. Use numbered steps and give examples.";
        // Exercise the same real chat-template tokenizer as ordinary generation.
        let (text, add_special, parse_special) =
            observed.resolve_prompt_text(prompt, true).unwrap();
        let ids = observed
            .tokenize(&text, add_special, parse_special)
            .unwrap();
        let parameters = GenerateParams {
            max_tokens: 128,
            temperature: 0.8,
            top_p: 0.95,
            seed: 42,
            stop: vec![],
        };
        let layer = (observed.num_layers() / 2) as u32;
        let mut reference = None;
        let mut elapsed = [vec![], vec![], vec![]];
        let mut token_count = 0;
        // Warmup is outside measured samples; rotation distributes order effects.
        for round in 0..4 {
            for offset in 0..3 {
                let mode = if round == 0 {
                    offset
                } else {
                    (offset + round - 1) % 3
                };
                let start = Instant::now();
                let mut callback_time = Duration::ZERO;
                let mut states = 0;
                let mut copies = 0;
                let mut copied_bytes = 0;
                let mut allocated_bytes = 0;
                let result = if mode == 2 {
                    observed
                        .generate_observed(
                            &ids,
                            &parameters,
                            &[layer],
                            &[Component::Residual],
                            &mut |state, logits| {
                                let cb_start = Instant::now();
                                std::hint::black_box(crate::top_k_logits(logits, 20));
                                std::hint::black_box(&state.rows);
                                states += 1;
                                copies = state.copies;
                                copied_bytes = state.copied_bytes;
                                allocated_bytes = state.allocated_bytes;
                                callback_time += cb_start.elapsed();
                                Ok(())
                            },
                        )
                        .unwrap()
                } else if mode == 1 {
                    observed.generate(&ids, &parameters).unwrap()
                } else {
                    control.generate(&ids, &parameters).unwrap()
                };
                let seconds = start.elapsed().as_secs_f64();
                if let Some(expected) = &reference {
                    assert_eq!(&result, expected, "same-build token/text parity");
                } else {
                    reference = Some(result.clone());
                }
                token_count = result.tokens.len();
                if mode == 2 {
                    assert_eq!(states, token_count);
                }
                let mode_name = ["callback_free", "dormant", "active_residual_top20"][mode];
                println!(
                    "F6_RECEIPT {}",
                    serde_json::json!({
                        "source": source, "model": path, "model_sha256": model_digest,
                        "backend": backend_name, "mode": mode_name, "round": round,
                    "build_profile": build_profile, "debug_assertions": cfg!(debug_assertions),
                    "resolved_backend": observed.metadata().backend,
                    "gpu_layer_policy": observed.metadata().gpu_layers,
                        "warmup": round == 0, "elapsed_seconds": seconds,
                        "tokens": token_count, "seed": 42, "prompt_tokens": ids.len(),
                        "layer_native": layer, "top": 20, "states": states,
                        "capture_copies": copies, "capture_bytes": copied_bytes,
                    "capture_allocated_bytes": allocated_bytes,
                        "callback_seconds": callback_time.as_secs_f64(),
                        "callback_wait_seconds": 0, "spill_seconds": 0,
                        "scope": "native observer; no R transport or acknowledgement"
                    })
                );
                if round > 0 {
                    elapsed[mode].push(seconds);
                }
            }
        }
        let medians: Vec<f64> = elapsed
            .iter_mut()
            .map(|samples| {
                samples.sort_by(f64::total_cmp);
                samples[1]
            })
            .collect();
        println!(
            "F6_GATE {}",
            serde_json::json!({"source": source, "backend": backend_name,
            "baseline_median": medians[0], "dormant_median": medians[1], "active_median": medians[2],
            "dormant_ratio": medians[1] / medians[0], "active_limit_seconds": 1.5 * medians[0] + 0.010 * token_count as f64,
            "dormant_pass": medians[1] <= 1.05 * medians[0],
            "active_pass": medians[2] <= 1.5 * medians[0] + 0.010 * token_count as f64})
        );
        assert!(
            medians[1] <= 1.05 * medians[0],
            "dormant callback exceeds the approved 5% overhead gate"
        );
        assert!(
            medians[2] <= 1.5 * medians[0] + 0.010 * token_count as f64,
            "active capture exceeds the approved overhead gate"
        );
    }
}
