// Included in lib.rs so extendr registers the internal wrappers together.
// Every R value and registry lives on the main thread. Only owned native data
// crosses into AsyncJob; neither external pointers nor R callbacks do.
use rebirth_llm::{
    AsyncCompletion, AsyncFixtureMode, AsyncJob, AsyncRequest, ExecutionPermit, NativeGuard,
    ProgressSnapshot, StreamEvent, ASYNC_MAX_ARGUMENT_BYTES, ASYNC_MAX_PROMPTS,
    ASYNC_MAX_PROMPT_BYTES, ASYNC_MAX_TOKENS,
};
use std::cell::Cell;
use std::hash::{BuildHasher, Hasher};
use std::rc::{Rc, Weak};

struct HandleState {
    model: RefCell<Option<LoadedModel>>,
    closed: Cell<bool>,
    fixture: Cell<Option<FixtureConfig>>,
}
#[derive(Clone, Copy)]
struct FixtureConfig {
    mode: AsyncFixtureMode,
    steps: u32,
    delay_ms: u64,
}
struct LlmHandle {
    state: Rc<HandleState>,
}
struct ActiveJob {
    owner: Weak<HandleState>,
    id: String,
    job: AsyncJob,
    completion: Option<AsyncCompletion>,
    streaming: bool,
    live: bool,
    live_pending: Option<(u64, usize, usize)>,
    discarded: bool,
    seed: u64,
}
thread_local! {
    static HANDLES: RefCell<Vec<Weak<HandleState>>> = const { RefCell::new(Vec::new()) };
    static DEFERRED: RefCell<Vec<LoadedModel>> = const { RefCell::new(Vec::new()) };
    static ACTIVE_JOB: RefCell<Option<ActiveJob>> = const { RefCell::new(None) };
}

impl LlmHandle {
    fn register(model: Option<LoadedModel>, closed: bool, fixture: Option<FixtureConfig>) -> Self {
        let state = Rc::new(HandleState {
            model: RefCell::new(model),
            closed: Cell::new(closed),
            fixture: Cell::new(fixture),
        });
        HANDLES.with(|handles| {
            let mut handles = handles.borrow_mut();
            handles.retain(|handle| handle.strong_count() > 0);
            handles.push(Rc::downgrade(&state));
        });
        Self { state }
    }
    fn new(model: LoadedModel) -> Self {
        Self::register(Some(model), false, None)
    }
    fn empty() -> Self {
        Self::register(None, true, None)
    }
    fn is_closed(&self) -> bool {
        self.state.closed.get()
    }
    fn close(&self) -> bool {
        if self.state.closed.replace(true) {
            return false;
        }
        ACTIVE_JOB.with(|slot| {
            if let Some(active) = slot.borrow_mut().as_mut() {
                if owns(active, &self.state) {
                    if active.streaming || active.live {
                        active.discarded = true;
                        active.job.discard_stream();
                    } else {
                        active.job.cancel();
                    }
                }
            }
        });
        if let Some(model) = self.state.model.borrow_mut().take() {
            retire(model);
        }
        true
    }
    fn run<F, T>(&self, f: F) -> Result<T, RebirthError>
    where
        F: FnOnce(&LoadedModel) -> Result<T, RebirthError>,
    {
        if self.is_closed() {
            return Err(RebirthError::Closed);
        }
        let _native = native_guard("model operation")?;
        let borrow = self.state.model.borrow();
        let model = borrow.as_ref().ok_or_else(|| RebirthError::Internal {
            context: "open test handle has no inference model".into(),
        })?;
        f(model)
    }
}
impl Drop for LlmHandle {
    fn drop(&mut self) {
        self.close();
    }
}
fn owns(active: &ActiveJob, state: &Rc<HandleState>) -> bool {
    active
        .owner
        .upgrade()
        .is_some_and(|owner| Rc::ptr_eq(&owner, state))
}

// Check type before extendr's Any downcast: a foreign EXTPTR may point at an
// unrelated C allocation, so attempting a Rust Any downcast first is unsafe.
fn checked_handle(ptr: &Robj) -> Result<&ExternalPtr<LlmHandle>, RebirthError> {
    if !ptr.check_external_ptr_type::<LlmHandle>() {
        return Err(RebirthError::Closed);
    }
    <&ExternalPtr<LlmHandle>>::try_from(ptr).map_err(|_| RebirthError::Closed)
}
fn drain_deferred() {
    DEFERRED.with(|items| items.borrow_mut().clear());
}
fn native_guard(operation: &str) -> Result<NativeGuard, RebirthError> {
    let guard = NativeGuard::try_acquire(operation)?;
    drain_deferred();
    Ok(guard)
}
fn retire(model: LoadedModel) {
    if let Ok(_native) = native_guard("close") {
        drop(model);
    } else {
        DEFERRED.with(|items| items.borrow_mut().push(model));
    }
}
fn async_ok() -> Robj {
    list!(ok = true).into()
}
fn async_argument(argument: &str, reason: &str) -> RebirthError {
    RebirthError::Argument {
        argument: argument.into(),
        reason: reason.into(),
    }
}

// R's file_test("-f") also accepts devices on supported R versions. Use the
// OS metadata type, without opening or writing the caller-owned stream file.
#[extendr]
fn rebirth_stream_regular_file(path: Robj) -> Robj {
    resolve(catch_unwind(AssertUnwindSafe(|| {
        if path.len() != 1 {
            return Err(async_argument("on_token", "expected one file path"));
        }
        let path = path
            .as_str()
            .filter(|value| !value.is_na() && !value.is_empty())
            .ok_or_else(|| async_argument("on_token", "expected a non-missing file path"))?;
        let regular = std::fs::metadata(path).is_ok_and(|metadata| metadata.is_file());
        Ok(list!(ok = true, regular = regular).into())
    })))
}

#[extendr]
fn rebirth_async_ready(ptr: Robj) -> Robj {
    resolve(catch_unwind(AssertUnwindSafe(|| {
        let handle = checked_handle(&ptr)?;
        if handle.is_closed() {
            return Err(RebirthError::Closed);
        }
        let _native = native_guard("llm_generate")?;
        Ok(async_ok())
    })))
}

// Input byte/count checks precede Vec<String> construction even for internal
// direct calls. The public R layer additionally budgets names and R overhead.
fn inspect_strings(value: &Robj, name: &str, total: &mut usize) -> Result<(), RebirthError> {
    let iter = value
        .as_str_iter()
        .ok_or_else(|| async_argument(name, "expected character input"))?;
    for text in iter {
        if text.is_na() {
            return Err(async_argument(name, "missing text is not accepted"));
        }
        if name == "prompt" && text.len() > ASYNC_MAX_PROMPT_BYTES {
            return Err(async_argument(name, "async prompt exceeds 1 MiB"));
        }
        *total = total
            .checked_add(text.len())
            .ok_or_else(|| async_argument(name, "input size overflow"))?;
        if *total > ASYNC_MAX_ARGUMENT_BYTES {
            return Err(async_argument(name, "async copied text exceeds 16 MiB"));
        }
    }
    Ok(())
}
fn owned_strings(value: &Robj) -> Vec<String> {
    value
        .as_str_iter()
        .expect("validated character input")
        .map(str::to_owned)
        .collect()
}
fn job_nonce() -> String {
    // Fresh keyed hashers obtain per-instance random seeds without touching R's
    // RNG or introducing a dependency. Tokens are session-local, not credentials.
    let a = std::collections::hash_map::RandomState::new()
        .build_hasher()
        .finish();
    let b = std::collections::hash_map::RandomState::new()
        .build_hasher()
        .finish();
    format!("{a:016x}{b:016x}")
}

#[extendr]
#[allow(clippy::too_many_arguments)]
fn rebirth_async_submit(
    ptr: Robj,
    prompts: Robj,
    chat: bool,
    max_tokens: i32,
    temperature: f64,
    top_p: f64,
    seed: f64,
    stop: Robj,
    images_flat: Robj,
    images_lens: Robj,
    image_max_bytes: f64,
    schema: Robj,
    stream: bool,
) -> Robj {
    async_submit(
        ptr,
        prompts,
        chat,
        max_tokens,
        temperature,
        top_p,
        seed,
        stop,
        images_flat,
        images_lens,
        image_max_bytes,
        schema,
        stream,
        ().into(),
    )
}

#[extendr]
#[allow(clippy::too_many_arguments)]
fn rebirth_live_submit(
    ptr: Robj,
    prompts: Robj,
    chat: bool,
    max_tokens: i32,
    temperature: f64,
    top_p: f64,
    seed: f64,
    stop: Robj,
    images_flat: Robj,
    images_lens: Robj,
    image_max_bytes: f64,
    schema: Robj,
    stream: bool,
    live: Robj,
) -> Robj {
    async_submit(
        ptr,
        prompts,
        chat,
        max_tokens,
        temperature,
        top_p,
        seed,
        stop,
        images_flat,
        images_lens,
        image_max_bytes,
        schema,
        stream,
        live,
    )
}

#[allow(clippy::too_many_arguments)]
fn async_submit(
    ptr: Robj,
    prompts: Robj,
    chat: bool,
    max_tokens: i32,
    temperature: f64,
    top_p: f64,
    seed: f64,
    stop: Robj,
    images_flat: Robj,
    images_lens: Robj,
    image_max_bytes: f64,
    schema: Robj,
    stream: bool,
    live: Robj,
) -> Robj {
    resolve(catch_unwind(AssertUnwindSafe(|| {
        let handle = checked_handle(&ptr)?;
        if handle.is_closed() {
            return Err(RebirthError::Closed);
        }
        if prompts.len() == 0 || prompts.len() > ASYNC_MAX_PROMPTS {
            return Err(async_argument("prompt", "async requires 1..128 prompts"));
        }
        if max_tokens < 1 || max_tokens as usize > ASYNC_MAX_TOKENS {
            return Err(async_argument(
                "max_tokens",
                "async requires 1..8192 tokens",
            ));
        }
        if !temperature.is_finite() || temperature < 0.0 || temperature > f32::MAX as f64 {
            return Err(async_argument(
                "temperature",
                "expected finite nonnegative float32 temperature",
            ));
        }
        if !top_p.is_finite() || top_p <= 0.0 || top_p > 1.0 {
            return Err(async_argument("top_p", "expected top_p in (0, 1]"));
        }
        if !seed.is_finite() || seed < 0.0 || seed.fract() != 0.0 || seed >= 18446744073709551616.0
        {
            return Err(async_argument(
                "seed",
                "expected whole-number seed in [0, 2^64)",
            ));
        }
        let schema_text = if schema.is_null() {
            None
        } else {
            Some(
                schema
                    .as_str()
                    .filter(|text| !text.is_na())
                    .ok_or_else(|| {
                        async_argument("schema", "expected one nonmissing string or NULL")
                    })?,
            )
        };
        let mut total = schema_text.map_or(0, str::len);
        inspect_strings(&prompts, "prompt", &mut total)?;
        inspect_strings(&stop, "stop", &mut total)?;
        inspect_strings(&images_flat, "images", &mut total)?;
        let live_strings = inspect_live_strings(&live, &mut total)?;
        let images_lens = images_lens
            .as_integer_slice()
            .ok_or_else(|| async_argument("images", "expected integer image counts"))?;
        if images_lens.len() != prompts.len() {
            return Err(async_argument(
                "images",
                "image lists must align with prompts",
            ));
        }
        let descriptors = prompts
            .len()
            .checked_add(stop.len())
            .and_then(|n| n.checked_add(live_strings))
            .and_then(|n| n.checked_add(images_flat.len()))
            .and_then(|n| n.checked_add(usize::from(schema_text.is_some())))
            .and_then(|n| n.checked_mul(rebirth_llm::ASYNC_STRING_OVERHEAD))
            .and_then(|n| n.checked_add(images_lens.len() * rebirth_llm::ASYNC_IMAGE_ROW_OVERHEAD));
        if descriptors.is_none_or(|n| n > rebirth_llm::ASYNC_MAX_STORAGE_BYTES) {
            return Err(async_argument("prompt", "async_input_storage"));
        }
        let compiled = schema_text.map(CompiledSchema::compile).transpose()?;
        let image_sets = split_image_sets(owned_strings(&images_flat), images_lens, prompts.len())?;
        let live = if live.is_null() {
            None
        } else {
            handle.run(|model| parse_live_request(&live, &model.metadata(), max_tokens as usize))?
        };
        let is_live = live.is_some();
        let request = AsyncRequest {
            prompts: owned_strings(&prompts),
            chat,
            params: GenerateParams {
                max_tokens: max_tokens as usize,
                temperature: temperature as f32,
                top_p: top_p as f32,
                seed: seed as u64,
                stop: owned_strings(&stop),
            },
            schema: compiled,
            images: if image_sets.iter().all(Vec::is_empty) {
                None
            } else {
                Some(image_sets)
            },
            image_max_bytes: checked_image_max_bytes(image_max_bytes)?,
            stream,
            live,
        };
        request.validate()?;
        let id = job_nonce();
        let permit = ExecutionPermit::try_acquire("llm_generate")?;
        let result = if let Some(config) = handle.state.fixture.get() {
            AsyncJob::start_fixture(request, permit, config.mode, config.steps, config.delay_ms)
        } else {
            let model = handle
                .state
                .model
                .borrow_mut()
                .take()
                .ok_or(RebirthError::Closed)?;
            AsyncJob::start(model, request, permit)
        };
        match result {
            Ok(job) => {
                ACTIVE_JOB.with(|slot| {
                    debug_assert!(slot.borrow().is_none());
                    *slot.borrow_mut() = Some(ActiveJob {
                        owner: Rc::downgrade(&handle.state),
                        id: id.clone(),
                        job,
                        completion: None,
                        streaming: stream,
                        live: is_live,
                        live_pending: None,
                        discarded: false,
                        seed: seed as u64,
                    });
                });
                Ok(list!(ok = true, job_id = id).into())
            }
            Err(mut failure) => {
                // A startup error returns the exact same model and reservation.
                let _bound = failure.permit.enter();
                *handle.state.model.borrow_mut() = failure.model.take();
                drain_deferred();
                Err(failure.error.clone())
            }
        }
    })))
}

fn progress_payload(snapshot: Option<ProgressSnapshot>) -> Robj {
    match snapshot {
        None => ().into(),
        Some(p) => list!(
            prompt_id = p.prompt_id as i32,
            prompts_completed = p.prompts_completed as i32,
            prompts_total = p.prompts_total as i32,
            generated_tokens = p.generated_tokens as i32,
            max_tokens = p.max_tokens as i32,
            phase = p.phase
        )
        .into(),
    }
}

// Conversion happens after releasing every native mutex and registry borrow.
fn stream_payload(rows: Vec<StreamEvent>) -> Result<Robj, RebirthError> {
    if rows.is_empty() {
        return Ok(().into());
    }
    let count = rows.len() as i32;
    let mut result: Robj = list!(
        event_id = rows.iter().map(|r| r.event_id).collect::<Vec<_>>(),
        event = rows.iter().map(|r| r.event).collect::<Vec<_>>(),
        prompt_id = rows.iter().map(|r| r.prompt_id).collect::<Vec<_>>(),
        token_pos = rows
            .iter()
            .map(|r| r.token_pos.unwrap_or(i32::MIN))
            .collect::<Vec<_>>(),
        token_id = rows
            .iter()
            .map(|r| r.token_id.unwrap_or(i32::MIN))
            .collect::<Vec<_>>(),
        text = rows.iter().map(|r| r.text.as_ref()).collect::<Vec<_>>(),
        elapsed = rows.iter().map(|r| r.elapsed).collect::<Vec<_>>(),
        finish_reason = rows.iter().map(|r| r.finish_reason).collect::<Vec<_>>(),
        validated = rows
            .iter()
            .map(|r| r.validated.map(Rbool::from).unwrap_or_else(Rbool::na))
            .collect::<Vec<_>>()
    )
    .into();
    let representation_error = |_| RebirthError::Stream {
        reason: "invariant".into(),
        prompt_id: rows.first().map(|r| r.prompt_id as usize),
        event_id: rows.first().map(|r| r.event_id as usize),
    };
    result
        .set_attrib("class", "data.frame")
        .map_err(representation_error)?;
    result
        .set_attrib("row.names", vec![i32::MIN, -count])
        .map_err(representation_error)?;
    Ok(result)
}
fn active_for<'a>(
    slot: &'a mut Option<ActiveJob>,
    handle: &LlmHandle,
    job_id: &str,
) -> Result<&'a mut ActiveJob, RebirthError> {
    let active = slot
        .as_mut()
        .ok_or_else(|| async_argument("job_id", "no active job"))?;
    if active.id != job_id || !owns(active, &handle.state) {
        return Err(async_argument(
            "job_id",
            "job does not belong to this handle",
        ));
    }
    Ok(active)
}
fn finish_active(
    mut active: ActiveJob,
    handle: &LlmHandle,
    snapshot: Option<ProgressSnapshot>,
) -> Robj {
    let mut completion = active.completion.take().expect("collected completion");
    {
        let _bound = completion.permit.enter();
        if completion.panicked || completion.model_invalidated {
            handle.state.closed.set(true);
        }
        if handle.is_closed() {
            completion.model.take();
        } else {
            *handle.state.model.borrow_mut() = completion.model.take();
        }
        drain_deferred();
    }
    let mut outcome = std::mem::replace(&mut completion.result, Ok(Vec::new()));
    if (active.streaming || active.live) && handle.is_closed() && outcome.is_ok() {
        outcome = Err(RebirthError::Cancelled {
            reason: "stream_closed".into(),
            seed: active.seed,
            prompt_id: snapshot.as_ref().map_or(1, |p| p.prompt_id),
            generated_tokens: snapshot.as_ref().map_or(0, |p| p.generated_tokens),
        });
    }
    drop(completion); // release reservation before final progress/settlement
    let (state, text, error): (&str, Robj, Robj) = match outcome {
        Ok(output) => (
            "completed",
            output
                .into_iter()
                .map(|g| g.text)
                .collect::<Vec<_>>()
                .into(),
            ().into(),
        ),
        Err(error) => (
            if matches!(error, RebirthError::Cancelled { .. }) {
                "cancelled"
            } else {
                "failed"
            },
            ().into(),
            error_payload(error),
        ),
    };
    list!(
        ok = true,
        state = state,
        progress = progress_payload(snapshot),
        text = text,
        error = error,
        closed = handle.is_closed(),
        batch = (),
        delivery_ready = false
    )
    .into()
}

#[extendr]
fn rebirth_async_poll(ptr: Robj, job_id: &str) -> Robj {
    resolve(catch_unwind(AssertUnwindSafe(|| {
        let handle = checked_handle(&ptr)?;
        let (finished, snapshot, rows, delivery_ready, native_complete, live_state) = ACTIVE_JOB
            .with(|slot| {
                let mut slot = slot.borrow_mut();
                let active = active_for(&mut slot, handle, job_id)?;
                if active.completion.is_none() {
                    active.completion = active.job.try_collect();
                }
                let snapshot = active.job.snapshot();
                let native_complete = active.completion.is_some();
                if native_complete
                    && (!active.streaming
                        || active.discarded
                        || active
                            .completion
                            .as_ref()
                            .is_some_and(|done| done.result.is_err()))
                {
                    active.job.discard_stream();
                    return Ok::<_, RebirthError>((
                        slot.take(),
                        snapshot,
                        Vec::new(),
                        false,
                        true,
                        None,
                    ));
                }
                let (rows, empty) = if active.streaming {
                    active
                        .job
                        .drain_stream()
                        .unwrap_or_else(|| (Vec::new(), false))
                } else {
                    (Vec::new(), true)
                };
                // Earlier token rows are converted/delivered before this state in R.
                // Neither registry borrow nor native locks survive conversion/callback.
                let live_state = if empty
                    && active.live
                    && active.live_pending.is_none()
                    && !active.discarded
                    && !handle.is_closed()
                {
                    active.job.drain_state().flatten()
                } else {
                    None
                };
                if let Some(state) = live_state.as_ref() {
                    active.live_pending =
                        Some((state.job_id, state.state_id, state.steering.len()));
                }
                Ok((
                    None,
                    snapshot,
                    rows,
                    native_complete && empty,
                    native_complete,
                    live_state,
                ))
            })?;
        if let Some(active) = finished {
            return Ok(finish_active(active, handle, snapshot));
        }
        Ok(list!(
            ok = true,
            state = if native_complete {
                "draining"
            } else {
                "running"
            },
            progress = progress_payload(snapshot),
            closed = handle.is_closed(),
            batch = stream_payload(rows)?,
            live_state = live_state
                .map(live_state_payload)
                .transpose()?
                .unwrap_or_else(|| ().into()),
            delivery_ready = delivery_ready
        )
        .into())
    })))
}

#[extendr]
fn rebirth_async_ack(ptr: Robj, job_id: &str) -> Robj {
    resolve(catch_unwind(AssertUnwindSafe(|| {
        let handle = checked_handle(&ptr)?;
        let (active, snapshot) = ACTIVE_JOB.with(|slot| {
            let mut slot = slot.borrow_mut();
            let active = active_for(&mut slot, handle, job_id)?;
            if !active.streaming || active.completion.is_none() || !active.job.stream_empty() {
                return Err(async_argument(
                    "job_id",
                    "stream delivery is not ready for acknowledgement",
                ));
            }
            let snapshot = active.job.snapshot();
            Ok((slot.take().expect("validated active job"), snapshot))
        })?;
        Ok(finish_active(active, handle, snapshot))
    })))
}

#[extendr]
fn rebirth_async_discard(ptr: Robj, job_id: &str) -> Robj {
    resolve(catch_unwind(AssertUnwindSafe(|| {
        let handle = checked_handle(&ptr)?;
        ACTIVE_JOB.with(|slot| {
            let mut slot = slot.borrow_mut();
            let active = active_for(&mut slot, handle, job_id)?;
            active.discarded = true;
            active.job.discard_stream();
            Ok::<_, RebirthError>(())
        })?;
        Ok(async_ok())
    })))
}

#[extendr]
fn rebirth_async_cancel(ptr: Robj) -> Robj {
    resolve(catch_unwind(AssertUnwindSafe(|| {
        let handle = checked_handle(&ptr)?;
        if handle.is_closed() {
            return Err(RebirthError::Closed);
        }
        let cancelled = ACTIVE_JOB.with(|slot| {
            slot.borrow()
                .as_ref()
                .is_some_and(|active| owns(active, &handle.state) && active.job.cancel())
        });
        Ok(list!(ok = true, cancelled = cancelled).into())
    })))
}

#[extendr]
fn rebirth_async_shutdown() -> Robj {
    resolve(catch_unwind(AssertUnwindSafe(|| {
        let active = ACTIVE_JOB.with(|slot| slot.borrow_mut().take());
        if let Some(mut active) = active {
            active.job.discard_stream();
            if let Some(mut completion) = active.completion.take().or_else(|| active.job.shutdown())
            {
                let _bound = completion.permit.enter();
                completion.model.take();
                close_all_handles();
                drain_deferred();
            }
        } else {
            let _native = native_guard("shutdown")?;
            close_all_handles();
        }
        rebirth_llm::restore_async_panic_hook();
        Ok(async_ok())
    })))
}
fn close_all_handles() {
    HANDLES.with(|handles| {
        for weak in handles.borrow_mut().drain(..) {
            if let Some(state) = weak.upgrade() {
                state.closed.set(true);
                state.model.borrow_mut().take();
            }
        }
    });
}

// Internal scheduler seams; no model download and no inference-quality claim.
#[extendr]
fn rebirth_async_test_handle() -> Robj {
    let handle = LlmHandle::register(
        None,
        false,
        Some(FixtureConfig {
            mode: AsyncFixtureMode::Success,
            steps: 20,
            delay_ms: 5,
        }),
    );
    ok_payload(
        ExternalPtr::new(handle).into(),
        ModelMetadata {
            architecture: "async-fixture".into(),
            parameters: 0,
            quantization: "none".into(),
            layers: 1,
            hidden_size: 1,
            context_length: 2048,
            context_train: 2048,
            backend: "cpu".into(),
            size_bytes: 0,
            vocab_size: 1,
            max_token_piece_bytes: 1,
            description: "R-free scheduler fixture; not an inference model".into(),
            gpu_layers: 0,
            mmap: false,
        },
    )
}
#[extendr]
fn rebirth_async_test_config(ptr: Robj, mode: &str, steps: i32, delay_ms: i32) -> Robj {
    resolve(catch_unwind(AssertUnwindSafe(|| {
        let handle = checked_handle(&ptr)?;
        if handle.is_closed() {
            return Err(RebirthError::Closed);
        }
        let _native = native_guard("fixture configuration")?;
        if handle.state.fixture.get().is_none() {
            return Err(async_argument("ptr", "not a fixture"));
        }
        let mode = match mode {
            "success" => AsyncFixtureMode::Success,
            "error" => AsyncFixtureMode::Error,
            "panic" => AsyncFixtureMode::Panic,
            "start_error" => AsyncFixtureMode::StartError,
            "stream_text" => AsyncFixtureMode::StreamText,
            "stream_encoding" => AsyncFixtureMode::StreamEncoding,
            _ => return Err(async_argument("mode", "unknown fixture mode")),
        };
        if !(1..=100_000).contains(&steps)
            || delay_ms < 0
            || i64::from(steps) * i64::from(delay_ms) > 5000
        {
            return Err(async_argument(
                "steps",
                "fixture bound is 100000 updates and 5000 ms total delay",
            ));
        }
        handle.state.fixture.set(Some(FixtureConfig {
            mode,
            steps: steps as u32,
            delay_ms: delay_ms as u64,
        }));
        Ok(async_ok())
    })))
}

#[extendr]
fn rebirth_async_test_stats() -> Robj {
    let (active_jobs, worker_threads, terminal_slots) = ACTIVE_JOB.with(|slot| {
        let slot = slot.borrow();
        match slot.as_ref() {
            None => (0i32, 0i32, 0i32),
            Some(active) => (
                1,
                i32::from(active.job.is_running()),
                i32::from(!active.job.is_running()),
            ),
        }
    });
    let deferred_handles = DEFERRED.with(|items| items.borrow().len() as i32);
    list!(
        ok = true,
        active_jobs = active_jobs,
        worker_threads = worker_threads,
        deferred_handles = deferred_handles,
        snapshot_slots = active_jobs,
        terminal_slots = terminal_slots,
        queued_jobs = 0i32
    )
    .into()
}
