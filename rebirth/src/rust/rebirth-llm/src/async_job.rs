//! R-free, single-slot asynchronous generation. No R object, callback or RNG
//! enters this module. Ownership returns with the reserved permit on collection.

use crate::{
    CompiledSchema, ExecutionPermit, GenerateParams, Generation, LoadedModel, RebirthError,
};
use std::cell::{Cell, RefCell};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

// Twin-pinned by the R admission tests; these are async-only D-037 limits.
pub const ASYNC_MAX_PROMPTS: usize = 128;
pub const ASYNC_MAX_PROMPT_BYTES: usize = 1024 * 1024;
pub const ASYNC_MAX_ARGUMENT_BYTES: usize = 16 * 1024 * 1024;
pub const ASYNC_MAX_TOKENS: usize = 8192;
pub const ASYNC_MAX_OUTPUT_BYTES: usize = 8 * 1024 * 1024;
// Independently bounded descriptors prevent empty strings from bypassing the
// copied-text limit. Conservative across the supported 64-bit R/Rust targets.
pub const ASYNC_MAX_DESCRIPTOR_BYTES: usize = 16 * 1024 * 1024;
pub const ASYNC_STRING_DESCRIPTOR_BYTES: usize = 64;
pub const ASYNC_IMAGE_ROW_BYTES: usize = 32;
// Names used by the FFI pre-copy estimator; pin aliases to the same constants.
pub const ASYNC_MAX_STORAGE_BYTES: usize = ASYNC_MAX_DESCRIPTOR_BYTES;
pub const ASYNC_STRING_OVERHEAD: usize = ASYNC_STRING_DESCRIPTOR_BYTES;
pub const ASYNC_IMAGE_ROW_OVERHEAD: usize = ASYNC_IMAGE_ROW_BYTES;

pub struct AsyncRequest {
    pub prompts: Vec<String>,
    pub chat: bool,
    pub params: GenerateParams,
    pub schema: Option<CompiledSchema>,
    pub images: Option<Vec<Vec<String>>>,
    pub image_max_bytes: u64,
    // Numeric synthetic fixtures use the production worker/control path without
    // claiming tokenizer coverage. This seam does not exist in shipped builds.
    #[cfg(test)]
    numeric_prompts: Option<Vec<Vec<i32>>>,
}
impl AsyncRequest {
    pub fn validate(&self) -> Result<(), RebirthError> {
        let invalid = |argument: &str, reason: &str| RebirthError::Argument {
            argument: argument.into(),
            reason: reason.into(),
        };
        if self.prompts.is_empty() || self.prompts.len() > ASYNC_MAX_PROMPTS {
            return Err(invalid("prompt", "async requires 1..128 prompts"));
        }
        if self
            .prompts
            .iter()
            .any(|p| p.len() > ASYNC_MAX_PROMPT_BYTES)
        {
            return Err(invalid("prompt", "async prompt exceeds 1 MiB"));
        }
        if self.params.max_tokens > ASYNC_MAX_TOKENS {
            return Err(invalid("max_tokens", "async token bound exceeds 8192"));
        }
        if let Some(images) = &self.images {
            if images.len() != self.prompts.len() {
                return Err(invalid("images", "image lists must align with prompts"));
            }
            if self.schema.is_some() {
                return Err(invalid(
                    "images",
                    "structured output does not accept images",
                ));
            }
        }
        let mut strings = self
            .prompts
            .iter()
            .chain(&self.params.stop)
            .chain(self.images.iter().flatten().flatten());
        let bytes = strings.try_fold(0usize, |sum, text| sum.checked_add(text.len()));
        if bytes.is_none_or(|bytes| bytes > ASYNC_MAX_ARGUMENT_BYTES) {
            return Err(invalid("prompt", "async copied text exceeds 16 MiB"));
        }
        let string_count = self
            .prompts
            .len()
            .checked_add(self.params.stop.len())
            .and_then(|n| n.checked_add(usize::from(self.schema.is_some())))
            .and_then(|n| {
                self.images
                    .iter()
                    .flatten()
                    .try_fold(n, |n, paths| n.checked_add(paths.len()))
            });
        let descriptors = string_count
            .and_then(|n| n.checked_mul(ASYNC_STRING_DESCRIPTOR_BYTES))
            .and_then(|n| {
                n.checked_add(
                    self.images.as_ref().map_or(0, |rows| rows.len()) * ASYNC_IMAGE_ROW_BYTES,
                )
            });
        if descriptors.is_none_or(|bytes| bytes > ASYNC_MAX_DESCRIPTOR_BYTES) {
            return Err(invalid("prompt", "async_input_storage"));
        }
        // The FFI checks names and the raw schema before copying; CompiledSchema
        // independently limits raw schema and compiled grammar allocations.
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProgressSnapshot {
    pub prompt_id: usize,
    pub prompts_completed: usize,
    pub prompts_total: usize,
    pub generated_tokens: usize,
    pub max_tokens: usize,
    pub phase: &'static str,
}
struct State {
    progress: ProgressSnapshot,
    terminal: bool,
    cancellation_accepted: bool,
    committed_output: usize,
}
struct Control {
    cancel: AtomicBool,
    seed: u64,
    state: Mutex<State>,
    #[cfg(test)]
    test_pause: Mutex<Option<TestPause>>,
}
impl Control {
    fn new(request: &AsyncRequest) -> Self {
        Self {
            #[cfg(test)]
            test_pause: Mutex::new(TEST_PAUSE.with(|slot| slot.borrow_mut().take())),
            cancel: AtomicBool::new(false),
            seed: request.params.seed,
            state: Mutex::new(State {
                progress: ProgressSnapshot {
                    prompt_id: 1,
                    prompts_completed: 0,
                    prompts_total: request.prompts.len(),
                    generated_tokens: 0,
                    max_tokens: request.params.max_tokens,
                    phase: "prefill",
                },
                terminal: false,
                cancellation_accepted: false,
                committed_output: 0,
            }),
        }
    }
    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }
    fn cancelled(&self, state: &State) -> RebirthError {
        RebirthError::Cancelled {
            reason: "requested".into(),
            seed: self.seed,
            prompt_id: state.progress.prompt_id,
            generated_tokens: state.progress.generated_tokens,
        }
    }
    fn checkpoint(&self) -> Result<(), RebirthError> {
        if self.cancel.load(Ordering::Acquire) {
            return Err(self.cancelled(&self.lock()));
        }
        Ok(())
    }
    fn publish(&self, result: &mut Result<Vec<Generation>, RebirthError>, panicked: bool) {
        let mut state = self.lock();
        if state.cancellation_accepted && !panicked {
            *result = Err(self.cancelled(&state));
        }
        if result.is_ok() {
            state.progress.prompts_completed = state.progress.prompts_total;
            state.progress.prompt_id = state.progress.prompts_total;
            state.progress.phase = "complete";
        }
        // cancel and terminal publication arbitrate under the same short lock.
        state.terminal = true;
    }
}
#[cfg(test)]
#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum TestStage {
    PrefillChunk,
    SampledToken,
    PromptBoundary,
    BeforeVisionIngest,
    AfterVisionIngest,
}
#[cfg(test)]
struct TestPause {
    stage: TestStage,
    entered: std::sync::mpsc::Sender<()>,
    resume: std::sync::mpsc::Receiver<()>,
}
#[cfg(test)]
thread_local! { static TEST_PAUSE: RefCell<Option<TestPause>> = const { RefCell::new(None) }; }
#[cfg(test)]
pub(crate) fn test_checkpoint(stage: TestStage) {
    with_control(|control| {
        if let Some(control) = control {
            let pause = {
                let mut pause = control.test_pause.lock().unwrap();
                if pause.as_ref().is_some_and(|pause| pause.stage == stage) {
                    pause.take()
                } else {
                    None
                }
            };
            if let Some(pause) = pause {
                pause.entered.send(()).expect("checkpoint observer");
                pause.resume.recv().expect("checkpoint resume");
            }
        }
    });
}
thread_local! {
    static CONTROL: RefCell<Option<Arc<Control>>> = const { RefCell::new(None) };
    static CAUGHT_WORKER: Cell<bool> = const { Cell::new(false) };
}
type PanicHook = Box<dyn Fn(&std::panic::PanicHookInfo<'_>) + Send + Sync + 'static>;
static PREVIOUS_PANIC_HOOK: Mutex<Option<PanicHook>> = Mutex::new(None);
fn install_panic_filter() {
    let mut previous = PREVIOUS_PANIC_HOOK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    if previous.is_none() {
        *previous = Some(std::panic::take_hook());
        std::panic::set_hook(Box::new(|info| {
            if !CAUGHT_WORKER.try_with(Cell::get).unwrap_or(false) {
                let previous = PREVIOUS_PANIC_HOOK
                    .lock()
                    .unwrap_or_else(|e| e.into_inner());
                if let Some(previous) = previous.as_ref() {
                    previous(info);
                }
            }
        }));
    }
}
/// Call after joining all jobs and before DLL unload. Restore the actual prior
/// hook, not a delegating closure whose code would itself reside in this DLL.
pub fn restore_async_panic_hook() {
    let previous = PREVIOUS_PANIC_HOOK
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .take();
    if let Some(previous) = previous {
        std::panic::set_hook(previous);
    }
}
fn with_control<T>(f: impl FnOnce(Option<&Control>) -> T) -> T {
    CONTROL.with(|slot| f(slot.borrow().as_deref()))
}
/// Shared text/vision ingest and sampler checkpoints are no-ops synchronously.
pub(crate) fn checkpoint() -> Result<(), RebirthError> {
    with_control(|control| control.map_or(Ok(()), Control::checkpoint))
}
pub(crate) fn prompt_started(prompt_id: usize) -> Result<(), RebirthError> {
    #[cfg(test)]
    if prompt_id > 1 {
        test_checkpoint(TestStage::PromptBoundary);
    }
    with_control(|control| {
        if let Some(control) = control {
            control.checkpoint()?;
            let mut state = control.lock();
            state.progress.prompt_id = prompt_id;
            state.progress.generated_tokens = 0;
            state.progress.phase = "prefill";
        }
        Ok(())
    })
}
pub(crate) fn sampled(generated_tokens: usize) -> Result<(), RebirthError> {
    with_control(|control| {
        if let Some(control) = control {
            let mut state = control.lock();
            // The token was already sampled, even if cancellation raced with
            // selection. Publish its count before constructing a cancellation.
            state.progress.generated_tokens = generated_tokens;
            state.progress.phase = "generate";
        }
    });
    #[cfg(test)]
    test_checkpoint(TestStage::SampledToken);
    checkpoint()
}
pub(crate) fn prompt_completed(bytes: usize) -> Result<(), RebirthError> {
    with_control(|control| {
        if let Some(control) = control {
            control.checkpoint()?;
            let mut state = control.lock();
            if bytes > ASYNC_MAX_OUTPUT_BYTES - state.committed_output {
                return Err(output_budget_error(
                    state.committed_output.saturating_add(bytes),
                ));
            }
            state.committed_output += bytes;
            state.progress.prompts_completed += 1;
        }
        Ok(())
    })
}
pub(crate) fn output_remaining() -> Option<usize> {
    with_control(|control| control.map(|c| ASYNC_MAX_OUTPUT_BYTES - c.lock().committed_output))
}
pub(crate) fn output_budget_error(estimate: usize) -> RebirthError {
    RebirthError::Oom {
        estimate_bytes: estimate as u64,
        budget_bytes: ASYNC_MAX_OUTPUT_BYTES as u64,
        suggestion: "Reduce max_tokens or the number of prompts for asynchronous generation."
            .into(),
    }
}

/// Completion retains reservation until the FFI restores or destroys ownership.
/// Dropping an uncollected completion also tears down under its own permit.
pub struct AsyncCompletion {
    pub model: Option<LoadedModel>,
    pub result: Result<Vec<Generation>, RebirthError>,
    pub permit: ExecutionPermit,
    pub panicked: bool,
}
impl Drop for AsyncCompletion {
    fn drop(&mut self) {
        if self.model.is_some() {
            let _bound = self.permit.enter();
            self.model.take();
        }
    }
}
pub struct AsyncStartFailure {
    pub model: Option<LoadedModel>,
    pub permit: ExecutionPermit,
    pub error: RebirthError,
}
impl Drop for AsyncStartFailure {
    fn drop(&mut self) {
        if self.model.is_some() {
            let _bound = self.permit.enter();
            self.model.take();
        }
    }
}

/// Private FFI test seam: synthetic scheduler behavior, never text inference.
#[derive(Debug, Clone, Copy)]
pub enum AsyncFixtureMode {
    StartError,
    Success,
    Error,
    Panic,
}
struct Fixture {
    mode: AsyncFixtureMode,
    steps: u32,
    delay_ms: u64,
}

pub struct AsyncJob {
    control: Arc<Control>,
    worker: Option<JoinHandle<AsyncCompletion>>,
}
impl AsyncJob {
    pub fn start(
        model: LoadedModel,
        request: AsyncRequest,
        permit: ExecutionPermit,
    ) -> Result<Self, AsyncStartFailure> {
        Self::spawn(Some(model), request, permit, None)
    }
    pub fn start_fixture(
        request: AsyncRequest,
        permit: ExecutionPermit,
        mode: AsyncFixtureMode,
        steps: u32,
        delay_ms: u64,
    ) -> Result<Self, AsyncStartFailure> {
        Self::spawn(
            None,
            request,
            permit,
            Some(Fixture {
                mode,
                steps,
                delay_ms,
            }),
        )
    }
    fn spawn(
        model: Option<LoadedModel>,
        request: AsyncRequest,
        permit: ExecutionPermit,
        fixture: Option<Fixture>,
    ) -> Result<Self, AsyncStartFailure> {
        if let Err(error) = request.validate() {
            return Err(AsyncStartFailure {
                model,
                permit,
                error,
            });
        }
        if fixture
            .as_ref()
            .is_some_and(|fixture| matches!(fixture.mode, AsyncFixtureMode::StartError))
        {
            // Deterministic stand-in for OS thread startup rejection; ownership
            // returns through the exact production failure object.
            return Err(AsyncStartFailure {
                model,
                permit,
                error: RebirthError::Generation {
                    reason: "async_start".into(),
                },
            });
        }
        install_panic_filter();
        let control = Arc::new(Control::new(&request));
        let worker_control = control.clone();
        // std::thread drops its closure on OS startup failure. Retain payload in
        // this one slot so that failure returns model + reservation intact.
        let payload = Arc::new(Mutex::new(Some((model, request, permit, fixture))));
        let worker_payload = payload.clone();
        match thread::Builder::new()
            .name("relm-generation".into())
            .spawn(move || {
                let (mut model, request, mut permit, fixture) = worker_payload
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .take()
                    .expect("owned worker payload");
                let bound = permit.enter();
                CAUGHT_WORKER.with(|flag| flag.set(true));
                CONTROL.with(|slot| *slot.borrow_mut() = Some(worker_control.clone()));
                let outcome = catch_unwind(AssertUnwindSafe(|| {
                    checkpoint()?;
                    let result = if let Some(fixture) = fixture {
                        run_fixture(&request, fixture)
                    } else {
                        run_request(model.as_ref().expect("worker model"), &request)
                    };
                    // Ordinary failures and cancellation reset the same context;
                    // grammar/sampler objects are local and already dropped.
                    if let Some(model) = &model {
                        model.clear_memory();
                    }
                    result
                }));
                let panicked = outcome.is_err();
                let mut result = match outcome {
                    Ok(result) => result,
                    Err(_) => {
                        // Never reuse potentially poisoned context state. Destruct
                        // while bound, in context -> projector -> model -> backend order.
                        model.take();
                        Err(RebirthError::Internal {
                            context: "asynchronous worker panicked".into(),
                        })
                    }
                };
                worker_control.publish(&mut result, panicked);
                CONTROL.with(|slot| slot.borrow_mut().take());
                CAUGHT_WORKER.with(|flag| flag.set(false));
                drop(bound);
                AsyncCompletion {
                    model,
                    result,
                    permit,
                    panicked,
                }
            }) {
            Ok(worker) => Ok(Self {
                control,
                worker: Some(worker),
            }),
            Err(_) => {
                let (model, _, permit, _) = payload
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .take()
                    .expect("startup failure retains payload");
                Err(AsyncStartFailure {
                    model,
                    permit,
                    error: RebirthError::Generation {
                        reason: "async_start".into(),
                    },
                })
            }
        }
    }
    pub fn cancel(&self) -> bool {
        let mut state = self.control.lock();
        if state.terminal || state.cancellation_accepted {
            return false;
        }
        state.cancellation_accepted = true;
        self.control.cancel.store(true, Ordering::Release);
        true
    }
    pub fn is_running(&self) -> bool {
        self.worker
            .as_ref()
            .is_some_and(|worker| !worker.is_finished())
    }
    /// Nonblocking state collection; contention means retry at the next timer.
    pub fn snapshot(&self) -> Option<ProgressSnapshot> {
        self.control
            .state
            .try_lock()
            .ok()
            .map(|state| state.progress.clone())
    }
    pub fn try_collect(&mut self) -> Option<AsyncCompletion> {
        if !self.worker.as_ref()?.is_finished() {
            return None;
        }
        Some(
            self.worker
                .take()
                .unwrap()
                .join()
                .expect("worker catch boundary"),
        )
    }
    /// Controlled unload/shutdown is the only blocking collection path.
    pub fn shutdown(&mut self) -> Option<AsyncCompletion> {
        self.cancel();
        self.worker
            .take()
            .map(|worker| worker.join().expect("worker catch boundary"))
    }
}
impl Drop for AsyncJob {
    fn drop(&mut self) {
        // No detached native code may outlive the library. The FFI keeps jobs
        // rooted until try_collect, so interactive GC does not enter this join.
        drop(self.shutdown());
    }
}
fn run_request(
    model: &LoadedModel,
    request: &AsyncRequest,
) -> Result<Vec<Generation>, RebirthError> {
    #[cfg(test)]
    if let Some(prompts) = &request.numeric_prompts {
        let mut output = Vec::with_capacity(prompts.len());
        for (i, tokens) in prompts.iter().enumerate() {
            prompt_started(i + 1)?;
            let generated = model.generate(tokens, &request.params)?;
            prompt_completed(generated.text.len())?;
            output.push(generated);
        }
        return Ok(output);
    }
    if let Some(schema) = &request.schema {
        return model.generate_prompts_structured(
            &request.prompts,
            request.chat,
            &request.params,
            schema,
        );
    }
    let mut output = Vec::with_capacity(request.prompts.len());
    for (i, prompt) in request.prompts.iter().enumerate() {
        prompt_started(i + 1)?;
        let generation = if let Some(images) = &request.images {
            model.generate_prompt_with_images(
                prompt,
                request.chat,
                &images[i],
                request.image_max_bytes,
                &request.params,
            )?
        } else {
            model.generate_prompt(prompt, request.chat, &request.params)?
        };
        prompt_completed(generation.text.len())?;
        output.push(generation);
    }
    Ok(output)
}
fn run_fixture(request: &AsyncRequest, fixture: Fixture) -> Result<Vec<Generation>, RebirthError> {
    for i in 0..fixture.steps {
        checkpoint()?;
        if fixture.delay_ms > 0 {
            thread::sleep(Duration::from_millis(fixture.delay_ms));
        }
        sampled((i as usize + 1).min(request.params.max_tokens))?;
    }
    match fixture.mode {
        AsyncFixtureMode::StartError => unreachable!("startup failure never enters worker"),
        AsyncFixtureMode::Success => Ok(request
            .prompts
            .iter()
            .map(|_| Generation {
                tokens: vec![],
                text: "fixture".into(),
                stop_reason: crate::StopReason::MaxTokens,
                seed: request.params.seed,
            })
            .collect()),
        AsyncFixtureMode::Error => Err(RebirthError::Generation {
            reason: "async_fixture".into(),
        }),
        AsyncFixtureMode::Panic => panic!("controlled asynchronous fixture panic"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn request() -> AsyncRequest {
        AsyncRequest {
            prompts: vec!["fixture".into()],
            chat: false,
            params: GenerateParams {
                max_tokens: 8192,
                temperature: 0.0,
                top_p: 1.0,
                seed: 42,
                stop: vec![],
            },
            schema: None,
            images: None,
            image_max_bytes: 1,
            numeric_prompts: None,
        }
    }
    fn fixture(mode: AsyncFixtureMode, steps: u32, delay: u64) -> AsyncJob {
        AsyncJob::start_fixture(
            request(),
            ExecutionPermit::try_acquire("fixture").unwrap(),
            mode,
            steps,
            delay,
        )
        .unwrap_or_else(|_| panic!("fixture startup"))
    }
    // Rust PR job, debug/release. All scheduler proofs precede model execution.
    #[test]
    fn async_cancel_busy_and_shutdown_return_ownership() {
        let mut job = fixture(AsyncFixtureMode::Success, 100, 1);
        assert!(ExecutionPermit::try_acquire("second job").is_err());
        assert!(job.cancel());
        assert!(!job.cancel());
        let mut completed = job.shutdown().unwrap();
        assert!(matches!(
            completed.result,
            Err(RebirthError::Cancelled { seed: 42, .. })
        ));
        assert!(ExecutionPermit::try_acquire("uncollected reservation").is_err());
        {
            let _bound = completed.permit.enter();
            crate::domain::assert_current();
        }
        drop(completed);
        assert!(ExecutionPermit::try_acquire("reusable domain").is_ok());
    }
    #[test]
    fn async_terminal_cancel_is_false_and_progress_is_coalesced() {
        let mut job = fixture(AsyncFixtureMode::Success, 100_000, 0);
        // Joining in this R-free test proves terminal-before-cancel ordering;
        // production only joins after is_finished or on controlled shutdown.
        let completed = job.worker.take().unwrap().join().unwrap();
        assert!(!job.cancel());
        let state = job.control.lock();
        assert!(state.terminal);
        assert_eq!(state.progress.phase, "complete");
        assert_eq!(state.progress.prompts_completed, 1);
        assert!(completed.result.is_ok());
        drop(state);
        drop(completed);
    }
    #[test]
    fn async_worker_panic_and_error_release_the_domain() {
        for mode in [AsyncFixtureMode::Panic, AsyncFixtureMode::Error] {
            let mut job = fixture(mode, 0, 0);
            let completed = job.worker.take().unwrap().join().unwrap();
            assert_eq!(completed.panicked, matches!(mode, AsyncFixtureMode::Panic));
            assert_eq!(
                completed.result.as_ref().unwrap_err().class(),
                if completed.panicked {
                    "relm_error_internal"
                } else {
                    "relm_error_generation"
                }
            );
            drop(completed);
        }
    }
    #[test]
    fn async_admission_bounds_and_utf8_bytes() {
        let mut req = request();
        req.prompts[0] = "é".repeat(ASYNC_MAX_PROMPT_BYTES / 2);
        assert!(req.validate().is_ok());
        req.prompts[0].push('x');
        assert!(matches!(req.validate(), Err(RebirthError::Argument { .. })));
        req = request();
        req.params.max_tokens = ASYNC_MAX_TOKENS + 1;
        assert!(req.validate().is_err());
        req = request();
        req.prompts = vec![String::new(); ASYNC_MAX_PROMPTS + 1];
        assert!(req.validate().is_err());
    }
    #[test]
    fn async_cancel_after_computation_before_publication_wins() {
        let control = Arc::new(Control::new(&request()));
        let job = AsyncJob {
            control: control.clone(),
            worker: None,
        };
        let mut computed_success = Ok(Vec::new());
        assert!(job.cancel());
        control.publish(&mut computed_success, false);
        assert!(matches!(
            computed_success,
            Err(RebirthError::Cancelled { .. })
        ));
        assert!(!job.cancel());
    }
    #[test]
    fn async_start_failure_returns_reservation() {
        let failure = match AsyncJob::start_fixture(
            request(),
            ExecutionPermit::try_acquire("startup fixture").unwrap(),
            AsyncFixtureMode::StartError,
            0,
            0,
        ) {
            Ok(_) => panic!("fixture must reject startup"),
            Err(failure) => failure,
        };
        assert_eq!(
            failure.error,
            RebirthError::Generation {
                reason: "async_start".into()
            }
        );
        assert!(ExecutionPermit::try_acquire("retained failure").is_err());
        drop(failure);
        assert!(ExecutionPermit::try_acquire("after failure").is_ok());
    }
    #[test]
    fn async_empty_strings_cannot_bypass_retained_descriptor_budget() {
        let mut req = request();
        req.params.stop =
            vec![String::new(); ASYNC_MAX_DESCRIPTOR_BYTES / ASYNC_STRING_DESCRIPTOR_BYTES];
        assert!(
            matches!(req.validate(), Err(RebirthError::Argument { reason, .. }) if reason == "async_input_storage")
        );
        req.params.stop.pop();
        assert!(req.validate().is_ok());
    }
    #[test]
    fn async_output_budget_accounts_for_prior_prompts() {
        let control = Arc::new(Control::new(&request()));
        CONTROL.with(|slot| *slot.borrow_mut() = Some(control));
        prompt_completed(ASYNC_MAX_OUTPUT_BYTES).unwrap();
        assert_eq!(output_remaining(), Some(0));
        assert!(matches!(prompt_completed(1), Err(RebirthError::Oom { .. })));
        CONTROL.with(|slot| slot.borrow_mut().take());
    }
    #[test]
    fn async_limits_are_twin_pinned_to_r_admission() {
        let source = include_str!("../../../../R/async.R");
        for (name, value) in [
            ("max_prompts", ASYNC_MAX_PROMPTS),
            ("max_prompt_bytes", ASYNC_MAX_PROMPT_BYTES),
            ("max_input_bytes", ASYNC_MAX_ARGUMENT_BYTES),
            ("max_tokens", ASYNC_MAX_TOKENS),
            ("max_output_bytes", ASYNC_MAX_OUTPUT_BYTES),
            ("max_descriptor_bytes", ASYNC_MAX_DESCRIPTOR_BYTES),
            ("string_descriptor_bytes", ASYNC_STRING_DESCRIPTOR_BYTES),
            ("image_row_bytes", ASYNC_IMAGE_ROW_BYTES),
        ] {
            assert!(
                source
                    .lines()
                    .any(|line| line == format!("relm_async_{name} <- {value}")),
                "R/native async bound differs: {name}"
            );
        }
    }
    // Rust PR job after R-free ownership fixtures; synthetic GGUF, no download.
    #[test]
    fn async_synthetic_failure_returns_original_context_and_shared_parent() {
        let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../../../tests/llm-golden/synthetic/synthetic-llama-2l.gguf");
        let parent = crate::load_with_batch(
            crate::LoadRequest {
                path,
                context_length: 64,
                gpu_layers: None,
                backend: crate::BackendKind::Cpu,
                mmap: true,
                projector: None,
            },
            Some(1),
        )
        .unwrap();
        let metadata = parent.metadata();
        let spec =
            crate::InterventionSpec::new(metadata.hidden_size as usize, metadata.layers as usize);
        let derived = parent.derive_with_interventions(&spec).unwrap();
        let mut req = request();
        req.params.max_tokens = 16;
        req.params.temperature = 0.8;
        let params = req.params.clone();
        let expected = derived.generate(&[1, 7], &params).unwrap();
        let mut job = AsyncJob::start(
            derived,
            req,
            ExecutionPermit::try_acquire("async error").unwrap(),
        )
        .unwrap_or_else(|_| panic!("worker starts"));
        assert!(matches!(
            parent.generate(&[1, 7], &params),
            Err(RebirthError::Busy { .. })
        ));
        // Test-only direct join; production polls is_finished or cancels/joins
        // at controlled shutdown. This preserves the actual tokenizer error.
        let mut completed = job.worker.take().unwrap().join().unwrap();
        assert!(matches!(
            completed.result,
            Err(RebirthError::Tokenize { .. })
        ));
        let derived;
        {
            let _bound = completed.permit.enter();
            derived = completed.model.take().unwrap();
            assert_eq!(derived.generate(&[1, 7], &params).unwrap(), expected);
            assert_eq!(parent.metadata(), metadata);
        }
        drop(completed);
        assert_eq!(parent.generate(&[1, 7], &params).unwrap(), expected);
        drop(derived);
    }
    // Rust PR job, debug/release, actual synthetic native decode. Latches force
    // cancellation after a prefill chunk, after sampling, and between prompts;
    // no wall-clock race, polling loop, or fabricated inference progress.
    #[test]
    fn async_cancel_real_prefill_sample_and_prompt_boundaries_recover() {
        use std::sync::mpsc;
        for stage in [
            TestStage::PrefillChunk,
            TestStage::SampledToken,
            TestStage::PromptBoundary,
        ] {
            let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../../../../tests/llm-golden/synthetic/synthetic-llama-2l.gguf");
            let model = crate::load_with_batch(
                crate::LoadRequest {
                    path,
                    context_length: 64,
                    gpu_layers: None,
                    backend: crate::BackendKind::Cpu,
                    mmap: true,
                    projector: None,
                },
                Some(1),
            )
            .unwrap();
            let mut request = request();
            request.params.max_tokens = 2;
            request.params.temperature = 0.8;
            request.prompts.push("second numeric prompt".into());
            request.numeric_prompts = Some(vec![vec![1, 7, 3], vec![1, 7, 3]]);
            let params = request.params.clone();
            let expected = model.generate(&[1, 7, 3], &params).unwrap();
            let (entered, observed) = mpsc::channel();
            let (resume, resumed) = mpsc::channel();
            TEST_PAUSE.with(|slot| {
                *slot.borrow_mut() = Some(TestPause {
                    stage,
                    entered,
                    resume: resumed,
                })
            });
            let mut job = AsyncJob::start(
                model,
                request,
                ExecutionPermit::try_acquire("cancel checkpoint").unwrap(),
            )
            .unwrap_or_else(|_| panic!("worker starts"));
            observed
                .recv_timeout(Duration::from_secs(5))
                .expect("actual native checkpoint");
            let before = job.snapshot().unwrap();
            let accepted = job.cancel();
            resume.send(()).unwrap();
            let mut completed = job.worker.take().unwrap().join().unwrap();
            assert!(accepted);
            let expected_count = match stage {
                TestStage::PrefillChunk => 0,
                TestStage::SampledToken => 1,
                TestStage::PromptBoundary => 2,
                _ => unreachable!("text cancellation stage"),
            };
            assert_eq!(before.generated_tokens, expected_count);
            assert_eq!(
                before.prompts_completed,
                usize::from(stage == TestStage::PromptBoundary)
            );
            assert!(
                matches!(completed.result, Err(RebirthError::Cancelled { seed: 42, prompt_id: 1, generated_tokens, .. }) if generated_tokens == expected_count)
            );
            {
                let _bound = completed.permit.enter();
                assert_eq!(
                    completed
                        .model
                        .as_ref()
                        .unwrap()
                        .generate(&[1, 7, 3], &params)
                        .unwrap(),
                    expected
                );
            }
            // Drop also tests release of a cancelled actual context under its
            // returned permit. The next iteration must admit a fresh model.
            drop(completed);
        }
    }
    // [MODEL] Cached local + vision nightly only. The latches bracket the
    // existing synchronous helper (image encoding AND multimodal prefill), not
    // an encoder-interior interrupt. No reference/golden regeneration needed.
    #[test]
    fn async_vlm_cancel_and_drop_at_native_boundaries() {
        use std::sync::mpsc;
        let model_path = std::env::var("RELM_TEST_MODEL_VLM").ok();
        let projector_path = std::env::var("RELM_TEST_MMPROJ_VLM").ok();
        if model_path.is_none() && projector_path.is_none() {
            assert_ne!(
                std::env::var("RELM_REQUIRE_ASYNC_VLM").as_deref(),
                Ok("1"),
                "required async VLM gate has no cached model/projector configuration"
            );
            eprintln!(
                "SKIP async_vlm_cancel_and_drop_at_native_boundaries: cached VLM/projector unset"
            );
            return;
        }
        // Once either path is configured, a missing/invalid partner is a
        // failure. Required acceptance also checks the success marker below.
        let model_path =
            std::path::PathBuf::from(model_path.expect("RELM_TEST_MODEL_VLM is required"));
        let projector_path =
            std::path::PathBuf::from(projector_path.expect("RELM_TEST_MMPROJ_VLM is required"));
        assert!(model_path.is_file(), "cached VLM path must exist");
        assert!(projector_path.is_file(), "cached projector path must exist");
        let image = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../../../tests/vision/red-square.png");
        assert!(image.is_file(), "committed vision fixture must exist");
        let images = vec![image.to_str().unwrap().to_string()];
        let parent = crate::load(crate::LoadRequest {
            path: model_path,
            context_length: 2048,
            gpu_layers: None,
            backend: crate::BackendKind::Cpu,
            mmap: true,
            projector: Some(projector_path),
        })
        .expect("cached VLM/projector load");
        let metadata = parent.metadata();
        let spec =
            crate::InterventionSpec::new(metadata.hidden_size as usize, metadata.layers as usize);
        let params = GenerateParams {
            max_tokens: 8,
            temperature: 0.0,
            top_p: 0.95,
            seed: 11,
            stop: vec![],
        };
        let prompt = "What color is the square?";
        let image_max_bytes = 64 * 1024 * 1024;
        let expected = parent
            .generate_prompt_with_images(prompt, true, &images, image_max_bytes, &params)
            .expect("same-build vision baseline");
        assert!(
            !expected.tokens.is_empty(),
            "fixture must reach a sampled text token"
        );
        let mut cases = 0;
        for stage in [
            TestStage::BeforeVisionIngest,
            TestStage::AfterVisionIngest,
            TestStage::SampledToken,
        ] {
            for close_native_owner in [false, true] {
                // One shared model/projector load; only the normal derived
                // generation context is allocated for each ownership case.
                let model = parent.derive_with_interventions(&spec).unwrap();
                let request = AsyncRequest {
                    prompts: vec![prompt.into()],
                    chat: true,
                    params: params.clone(),
                    schema: None,
                    images: Some(vec![images.clone()]),
                    image_max_bytes,
                    numeric_prompts: None,
                };
                let (entered, observed) = mpsc::channel();
                let (resume, resumed) = mpsc::channel();
                TEST_PAUSE.with(|slot| {
                    *slot.borrow_mut() = Some(TestPause {
                        stage,
                        entered,
                        resume: resumed,
                    })
                });
                let mut job = AsyncJob::start(
                    model,
                    request,
                    ExecutionPermit::try_acquire("vision boundary").unwrap(),
                )
                .unwrap_or_else(|_| panic!("vision worker starts"));
                // Test watchdog only: production cancellation has no promised
                // deadline while the synchronous native helper is executing.
                observed
                    .recv_timeout(Duration::from_secs(180))
                    .expect("actual VLM boundary reached");
                let snapshot = job.snapshot();
                let shared_access = parent.generate_prompt_with_images(
                    prompt,
                    true,
                    &images,
                    image_max_bytes,
                    &params,
                );
                let accepted = job.cancel();
                let repeated = job.cancel();
                resume.send(()).unwrap();
                let mut completed = job.worker.take().unwrap().join().unwrap();
                assert!(
                    accepted,
                    "cancellation must be accepted at the held boundary"
                );
                assert!(!repeated, "cancellation is accepted exactly once");
                assert!(matches!(shared_access, Err(RebirthError::Busy { .. })));
                let count = usize::from(stage == TestStage::SampledToken);
                let snapshot = snapshot.unwrap();
                assert_eq!(snapshot.generated_tokens, count);
                assert_eq!(snapshot.prompts_completed, 0);
                assert_eq!(
                    snapshot.phase,
                    if count == 0 { "prefill" } else { "generate" }
                );
                assert!(matches!(completed.result, Err(RebirthError::Cancelled {
                    seed: 11, prompt_id: 1, generated_tokens, ..
                }) if generated_tokens == count));
                assert!(!completed.panicked);
                if close_native_owner {
                    // Native close/GC lifecycle: return ownership, then free the
                    // existing context under its retained permit. R closed-flag
                    // behavior is covered separately by the public-API R tests.
                    drop(completed);
                } else {
                    let returned;
                    {
                        let _bound = completed.permit.enter();
                        returned = completed.model.take().expect("cancelled context returns");
                    }
                    drop(completed);
                    assert_eq!(
                        returned
                            .generate_prompt_with_images(
                                prompt,
                                true,
                                &images,
                                image_max_bytes,
                                &params
                            )
                            .expect("cancelled vision handle remains reusable"),
                        expected
                    );
                    drop(returned);
                }
                assert_eq!(
                    parent
                        .generate_prompt_with_images(
                            prompt,
                            true,
                            &images,
                            image_max_bytes,
                            &params
                        )
                        .expect("shared projector survives sibling cancellation/drop"),
                    expected
                );
                cases += 1;
            }
        }
        assert_eq!(cases, 6);
        println!("ASYNC_VLM_BOUNDARIES_PASSED");
    }
}
