//! R-free, single-slot asynchronous generation. No R object, callback or RNG
//! enters this module. Ownership returns with the reserved permit on collection.

use crate::{
    CompiledSchema, ExecutionPermit, GenerateParams, Generation, LoadedModel, RebirthError,
};
use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

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

// D-038 transport bounds; twin-pinned by R delivery tests. Text uses Box<str>,
// so the charged payload equals its allocation instead of String spare capacity.
pub const STREAM_QUEUE_ROWS: usize = 256;
pub const STREAM_QUEUE_BYTES: usize = 256 * 1024;
pub const STREAM_CHUNK_BYTES: usize = 16 * 1024;
pub const STREAM_BATCH_ROWS: usize = 64;
pub const STREAM_BATCH_BYTES: usize = 64 * 1024;

#[derive(Debug)]
pub struct StreamEvent {
    pub event_id: i32,
    pub event: &'static str,
    pub prompt_id: i32,
    pub token_pos: Option<i32>,
    pub token_id: Option<i32>,
    pub text: Box<str>,
    pub elapsed: f64,
    pub finish_reason: &'static str,
    pub validated: Option<bool>,
}
struct StreamQueue {
    rows: VecDeque<StreamEvent>,
    bytes: usize,
    next_id: usize,
    discarded: bool,
}
impl StreamQueue {
    fn new() -> Self {
        Self {
            rows: VecDeque::with_capacity(STREAM_QUEUE_ROWS),
            bytes: 0,
            next_id: 1,
            discarded: false,
        }
    }
    fn discard(&mut self) {
        self.rows.clear();
        self.bytes = 0;
        self.discarded = true;
    }
}

pub struct AsyncRequest {
    pub prompts: Vec<String>,
    pub chat: bool,
    pub params: GenerateParams,
    pub schema: Option<CompiledSchema>,
    pub images: Option<Vec<Vec<String>>>,
    pub image_max_bytes: u64,
    pub stream: bool,
    pub live: Option<crate::LiveRequest>,
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
        if self.live.is_some()
            && (self.prompts.len() != 1
                || self.params.max_tokens > crate::LIVE_MAX_STATES
                || self.images.is_some()
                || self.schema.is_some())
        {
            return Err(invalid("on_state", "live observation requires one text prompt, no images/schema and at most 1024 tokens"));
        }
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
        if self.params.max_tokens == 0 || self.params.max_tokens > ASYNC_MAX_TOKENS {
            return Err(invalid("max_tokens", "async requires 1..8192 tokens"));
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
        let bytes = strings
            .try_fold(0usize, |sum, text| sum.checked_add(text.len()))
            .and_then(|n| {
                self.live.as_ref().map_or(Some(n), |live| {
                    [&live.spill_dir, &live.trace_id, &live.model, &live.spec_key]
                        .into_iter()
                        .try_fold(n, |n, text| n.checked_add(text.capacity()))
                })
            });
        if bytes.is_none_or(|bytes| bytes > ASYNC_MAX_ARGUMENT_BYTES) {
            return Err(invalid("prompt", "async copied text exceeds 16 MiB"));
        }
        let string_count = self
            .prompts
            .len()
            .checked_add(self.params.stop.len())
            .and_then(|n| n.checked_add(if self.live.is_some() { 4 } else { 0 }))
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
struct LiveSlot {
    pending: Option<crate::LiveState>,
    outstanding: Option<usize>,
    drained: bool,
    next_id: usize,
    discarded: bool,
    reply: Option<crate::LiveReply>,
    steer_count: usize,
}
impl LiveSlot {
    fn new(steer_count: usize) -> Self {
        Self {
            pending: None,
            outstanding: None,
            drained: false,
            next_id: 1,
            discarded: false,
            reply: None,
            steer_count,
        }
    }
}
struct State {
    progress: ProgressSnapshot,
    terminal: bool,
    cancellation_accepted: bool,
    committed_output: usize,
    stream: Option<StreamQueue>,
    live: Option<LiveSlot>,
}
static NEXT_JOB_ID: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
// Keep the checked atomic increment compatible with both the current stable
// compiler and the pinned sanitizer toolchain. MAX remains the exhausted marker.
fn allocate_job_id(counter: &std::sync::atomic::AtomicU64) -> u64 {
    let mut current = counter.load(Ordering::Relaxed);
    loop {
        let Some(next) = current.checked_add(1) else {
            return u64::MAX;
        };
        match counter.compare_exchange_weak(current, next, Ordering::Relaxed, Ordering::Relaxed) {
            Ok(previous) => return previous,
            Err(observed) => current = observed,
        }
    }
}
struct Control {
    id: u64,
    #[cfg(feature = "spill")]
    live_cancel: Arc<crate::live_spill::LiveCancel>,
    cancel: AtomicBool,
    seed: u64,
    state: Mutex<State>,
    space: Condvar,
    started: Instant,
    streaming: bool,
    structured: bool,
    #[cfg(test)]
    test_pause: Mutex<Option<TestPause>>,
    #[cfg(test)]
    queue_waiter: Mutex<Option<std::sync::mpsc::Sender<()>>>,
    #[cfg(test)]
    live_published: Mutex<Option<std::sync::mpsc::Sender<(u64, usize)>>>,
    #[cfg(test)]
    steering_fault: std::sync::atomic::AtomicU8,
}
/// Compiled object storage used by the live preflight ledger. Arc strong/weak
/// counters are explicit; StreamQueue payload capacity is in WP10's ledger.
/// The boxed startup failure is charged even though it cannot coexist with a
/// successfully running worker, preserving a conservative failure-path bound.
pub(crate) fn live_control_bytes() -> usize {
    let bytes = std::mem::size_of::<Control>()
        + std::mem::size_of::<AsyncJob>()
        + std::mem::size_of::<AsyncStartFailure>()
        + 2 * std::mem::size_of::<usize>();
    // Control::new owns this Arc even when the live state stays in memory.
    // Charge its heap pointee and strong/weak counters on both delivery paths.
    #[cfg(feature = "spill")]
    let bytes = bytes
        + std::mem::size_of::<crate::live_spill::LiveCancel>()
        + 2 * std::mem::size_of::<usize>();
    bytes
}
impl Control {
    fn new(request: &AsyncRequest) -> Self {
        Self {
            id: allocate_job_id(&NEXT_JOB_ID),
            #[cfg(feature = "spill")]
            live_cancel: Arc::new(crate::live_spill::LiveCancel::default()),
            #[cfg(test)]
            test_pause: Mutex::new(TEST_PAUSE.with(|slot| slot.borrow_mut().take())),
            #[cfg(test)]
            queue_waiter: Mutex::new(TEST_QUEUE_WAITER.with(|slot| slot.borrow_mut().take())),
            #[cfg(test)]
            live_published: Mutex::new(TEST_LIVE_PUBLISHED.with(|slot| slot.borrow_mut().take())),
            #[cfg(test)]
            steering_fault: std::sync::atomic::AtomicU8::new(0),
            cancel: AtomicBool::new(false),
            seed: request.params.seed,
            space: Condvar::new(),
            started: Instant::now(),
            streaming: request.stream,
            structured: request.schema.is_some(),
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
                stream: request.stream.then(StreamQueue::new),
                live: request
                    .live
                    .as_ref()
                    .map(|live| LiveSlot::new(live.steering.len())),
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
    fn stream_error(&self, reason: &str, state: &State) -> RebirthError {
        RebirthError::Stream {
            reason: reason.into(),
            prompt_id: Some(state.progress.prompt_id),
            event_id: state.stream.as_ref().map(|stream| stream.next_id),
        }
    }
    fn enqueue(
        &self,
        event: &'static str,
        token_pos: Option<i32>,
        token_id: Option<i32>,
        text: Box<str>,
        finish_reason: &'static str,
    ) -> Result<(), RebirthError> {
        let mut state = self.lock();
        let elapsed = self.started.elapsed().as_secs_f64();
        loop {
            if state.cancellation_accepted {
                return Err(self.cancelled(&state));
            }
            let Some(stream) = state.stream.as_ref() else {
                return Ok(());
            };
            if stream.discarded || state.terminal {
                return Err(self.cancelled(&state));
            }
            let fits = stream.rows.len() < STREAM_QUEUE_ROWS
                && stream
                    .bytes
                    .checked_add(text.len())
                    .is_some_and(|n| n <= STREAM_QUEUE_BYTES);
            if fits {
                break;
            }
            // Cancellation changes this predicate with the same mutex before
            // notifying: no notification can be lost between check and sleep.
            #[cfg(test)]
            if let Some(waiter) = self.queue_waiter.lock().unwrap().take() {
                waiter.send(()).expect("queue wait observer");
            }
            state = self.space.wait(state).unwrap_or_else(|e| e.into_inner());
        }
        let prompt_id = state.progress.prompt_id as i32;
        let stream = state.stream.as_mut().expect("enabled stream");
        let event_id = i32::try_from(stream.next_id).map_err(|_| RebirthError::Stream {
            reason: "invariant".into(),
            prompt_id: Some(prompt_id as usize),
            event_id: None,
        })?;
        stream.next_id = stream
            .next_id
            .checked_add(1)
            .ok_or_else(|| RebirthError::Stream {
                reason: "invariant".into(),
                prompt_id: Some(prompt_id as usize),
                event_id: None,
            })?;
        stream.bytes = stream
            .bytes
            .checked_add(text.len())
            .expect("checked queue size");
        stream.rows.push_back(StreamEvent {
            event_id,
            event,
            prompt_id,
            token_pos,
            token_id,
            text,
            elapsed,
            finish_reason,
            validated: self.structured.then_some(event == "prompt_end"),
        });
        Ok(())
    }
    fn publish_live(
        &self,
        mut payload: crate::LiveState,
    ) -> Result<crate::LiveReply, RebirthError> {
        let mut state = self.lock();
        if state.cancellation_accepted {
            return Err(self.cancelled(&state));
        }
        let live = state.live.as_mut().ok_or_else(|| RebirthError::Internal {
            context: "live state without live control".into(),
        })?;
        if live.discarded || live.outstanding.is_some() || payload.state_id != live.next_id {
            return Err(RebirthError::Internal {
                context: "live state protocol sequence violation".into(),
            });
        }
        payload.job_id = self.id;
        payload.elapsed = self.started.elapsed().as_secs_f64();
        live.outstanding = Some(payload.state_id);
        live.drained = false;
        live.next_id = live
            .next_id
            .checked_add(1)
            .ok_or_else(|| RebirthError::Internal {
                context: "live state sequence overflow".into(),
            })?;
        live.pending = Some(payload);
        // This test seam denotes publication, not a condition-variable wake.
        // It fires once with the exact identity, before entering the ack loop.
        #[cfg(test)]
        if let Some(observer) = self.live_published.lock().unwrap().as_ref() {
            observer
                .send((self.id, live.outstanding.unwrap()))
                .expect("live publication observer");
        }
        loop {
            if state.cancellation_accepted
                || state.terminal
                || state.live.as_ref().is_some_and(|live| live.discarded)
            {
                // Move cleanup outside the control mutex: poll/cancel never
                // waits for filesystem metadata/unlink on this worker.
                let error = self.cancelled(&state);
                let abandoned = state.live.as_mut().and_then(|live| live.pending.take());
                let reply = state.live.as_mut().and_then(|live| live.reply.take());
                drop(state);
                drop(abandoned);
                drop(reply);
                return Err(error);
            }
            if state
                .live
                .as_ref()
                .is_some_and(|live| live.outstanding.is_none())
            {
                return Ok(state
                    .live
                    .as_mut()
                    .and_then(|live| live.reply.take())
                    .unwrap_or_default());
            }
            #[cfg(test)]
            if let Some(waiter) = self.queue_waiter.lock().unwrap().take() {
                waiter.send(()).expect("live wait observer");
            }
            state = self.space.wait(state).unwrap_or_else(|e| e.into_inner());
        }
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
        // A failed native outcome never starts any more consumers. Terminal
        // publication, cancellation and the producer predicate share this lock.
        let mut abandoned = None;
        if result.is_err() {
            if let Some(live) = state.live.as_mut() {
                abandoned = live.pending.take();
                live.reply.take();
                live.discarded = true;
            }
            if let Some(stream) = state.stream.as_mut() {
                stream.discard();
            }
        }
        state.terminal = true;
        self.space.notify_all();
        drop(state);
        drop(abandoned);
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
thread_local! {
    static TEST_PAUSE: RefCell<Option<TestPause>> = const { RefCell::new(None) };
    static TEST_QUEUE_WAITER: RefCell<Option<std::sync::mpsc::Sender<()>>> = const { RefCell::new(None) };
    static TEST_LIVE_PUBLISHED: RefCell<Option<std::sync::mpsc::Sender<(u64, usize)>>> = const { RefCell::new(None) };
}
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
#[cfg(feature = "spill")]
pub(crate) fn catch_background<T>(f: impl FnOnce() -> T) -> std::thread::Result<T> {
    CAUGHT_WORKER.with(|flag| flag.set(true));
    let result = catch_unwind(AssertUnwindSafe(f));
    CAUGHT_WORKER.with(|flag| flag.set(false));
    result
}
fn with_control<T>(f: impl FnOnce(Option<&Control>) -> T) -> T {
    CONTROL.with(|slot| f(slot.borrow().as_deref()))
}
/// Shared text/vision ingest and sampler checkpoints are no-ops synchronously.
pub(crate) fn checkpoint() -> Result<(), RebirthError> {
    with_control(|control| control.map_or(Ok(()), Control::checkpoint))
}
pub(crate) fn publish_live(payload: crate::LiveState) -> Result<crate::LiveReply, RebirthError> {
    with_control(|control| {
        control
            .ok_or_else(|| RebirthError::Internal {
                context: "live generation requires the async worker".into(),
            })?
            .publish_live(payload)
    })
}
#[cfg(test)]
pub(crate) fn live_steering_fault() -> u8 {
    with_control(|control| {
        control.map_or(0, |control| control.steering_fault.load(Ordering::Acquire))
    })
}
/// Linearize a validated worker command with cancellation acceptance. No R
/// callback or decode runs under this mutex; only the synchronous adapter setter.
pub(crate) fn apply_live_command(
    apply: impl FnOnce() -> Result<(), RebirthError>,
) -> Result<(), RebirthError> {
    with_control(|control| {
        if let Some(control) = control {
            let state = control.lock();
            if state.cancellation_accepted || state.terminal {
                return Err(control.cancelled(&state));
            }
            apply()
        } else {
            apply()
        }
    })
}
#[cfg(feature = "spill")]
pub(crate) fn live_cancel() -> Option<Arc<crate::live_spill::LiveCancel>> {
    with_control(|control| control.map(|c| c.live_cancel.clone()))
}
pub(crate) fn streaming() -> bool {
    with_control(|control| control.is_some_and(|control| control.streaming))
}
pub(crate) fn stream_error(reason: &str) -> RebirthError {
    with_control(|control| match control {
        Some(control) => control.stream_error(reason, &control.lock()),
        None => RebirthError::Stream {
            reason: reason.into(),
            prompt_id: None,
            event_id: None,
        },
    })
}
pub(crate) fn stream_token(token_id: i32, token_pos: usize) -> Result<(), RebirthError> {
    with_control(|control| {
        let Some(control) = control.filter(|control| control.streaming) else {
            return Ok(());
        };
        let token_id = token_id
            .checked_add(1)
            .filter(|id| *id > 0)
            .ok_or_else(|| control.stream_error("invariant", &control.lock()))?;
        let token_pos = i32::try_from(token_pos)
            .ok()
            .filter(|pos| *pos > 0)
            .ok_or_else(|| control.stream_error("invariant", &control.lock()))?;
        control.enqueue("token", Some(token_pos), Some(token_id), "".into(), "")
    })
}
pub(crate) fn stream_text(text: &str) -> Result<(), RebirthError> {
    with_control(|control| {
        let Some(control) = control.filter(|control| control.streaming) else {
            return Ok(());
        };
        if text.contains('\0') {
            return Err(control.stream_error("encoding", &control.lock()));
        }
        let mut remaining = text;
        while !remaining.is_empty() {
            let mut end = remaining.len().min(STREAM_CHUNK_BYTES);
            while !remaining.is_char_boundary(end) {
                end -= 1;
            }
            // Allocate only this chunk: while blocked there is one pending box.
            control.enqueue("text", None, None, remaining[..end].into(), "")?;
            remaining = &remaining[end..];
        }
        Ok(())
    })
}
pub(crate) fn stream_prompt_end(finish_reason: &'static str) -> Result<(), RebirthError> {
    with_control(
        |control| match control.filter(|control| control.streaming) {
            Some(control) => control.enqueue("prompt_end", None, None, "".into(), finish_reason),
            None => Ok(()),
        },
    )
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
    pub model_invalidated: bool,
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
    StreamText,
    StreamEncoding,
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
    ) -> Result<Self, Box<AsyncStartFailure>> {
        Self::spawn(Some(model), request, permit, None)
    }
    pub fn start_fixture(
        request: AsyncRequest,
        permit: ExecutionPermit,
        mode: AsyncFixtureMode,
        steps: u32,
        delay_ms: u64,
    ) -> Result<Self, Box<AsyncStartFailure>> {
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
        mut permit: ExecutionPermit,
        fixture: Option<Fixture>,
    ) -> Result<Self, Box<AsyncStartFailure>> {
        if let Err(error) = request.validate() {
            return Err(Box::new(AsyncStartFailure {
                model,
                permit,
                error,
            }));
        }
        if fixture
            .as_ref()
            .is_some_and(|fixture| matches!(fixture.mode, AsyncFixtureMode::StartError))
        {
            // Deterministic stand-in for OS thread startup rejection; ownership
            // returns through the exact production failure object.
            return Err(Box::new(AsyncStartFailure {
                model,
                permit,
                error: RebirthError::Generation {
                    reason: "async_start".into(),
                },
            }));
        }
        if let (Some(model_ref), Some(live)) = (model.as_ref(), request.live.as_ref()) {
            let checked = {
                let _bound = permit.enter();
                live.preflight(&model_ref.metadata(), request.params.max_tokens)
            };
            if let Err(error) = checked {
                return Err(Box::new(AsyncStartFailure {
                    model,
                    permit,
                    error,
                }));
            }
        }
        install_panic_filter();
        let control = Arc::new(Control::new(&request));
        if control.id == u64::MAX {
            return Err(Box::new(AsyncStartFailure {
                model,
                permit,
                error: RebirthError::Internal {
                    context: "async job identity exhausted".into(),
                },
            }));
        }
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
                let model_invalidated=model.as_ref().is_some_and(|model|model.steering_restore_failed.get());
                if model_invalidated {
                    model.take();
                    result=Err(RebirthError::Intervention {reason:"Restoring the original steering adapter failed; the affected handle was closed.".into()});
                }
                worker_control.publish(&mut result, panicked || model_invalidated);
                CONTROL.with(|slot| slot.borrow_mut().take());
                CAUGHT_WORKER.with(|flag| flag.set(false));
                drop(bound);
                AsyncCompletion {
                    model,
                    result,
                    permit,
                    panicked,
                    model_invalidated,
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
                Err(Box::new(AsyncStartFailure {
                    model,
                    permit,
                    error: RebirthError::Generation {
                        reason: "async_start".into(),
                    },
                }))
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
        #[cfg(feature = "spill")]
        self.control.live_cancel.cancel();
        self.control.space.notify_all();
        true
    }
    /// Abandon undelivered rows and wake a producer before any terminal wait.
    /// Native terminal arbitration is unchanged: cancel remains false afterward.
    pub fn discard_stream(&self) {
        let mut state = self.control.lock();
        if let Some(stream) = state.stream.as_mut() {
            stream.discard();
        }
        if !state.terminal {
            state.cancellation_accepted = true;
            self.control.cancel.store(true, Ordering::Release);
            #[cfg(feature = "spill")]
            self.control.live_cancel.cancel();
        }
        if let Some(live) = state.live.as_mut() {
            live.discarded = true;
        }
        self.control.space.notify_all();
    }
    pub fn id(&self) -> u64 {
        self.control.id
    }
    pub fn has_live(&self) -> bool {
        self.control.lock().live.is_some()
    }
    /// Transfer at most one state only after older token events were drained.
    /// Outer None means contention; inner None means no deliverable state.
    pub fn drain_state(&self) -> Option<Option<crate::LiveState>> {
        let mut state = self.control.state.try_lock().ok()?;
        if state.cancellation_accepted
            || state.live.as_ref().is_some_and(|live| live.discarded)
            || state.stream.as_ref().is_some_and(|q| !q.rows.is_empty())
        {
            return Some(None);
        }
        let Some(live) = state.live.as_mut() else {
            return Some(None);
        };
        let payload = live.pending.take();
        if payload.is_some() {
            live.drained = true;
        }
        #[cfg(feature = "spill")]
        let mut payload = payload;
        #[cfg(feature = "spill")]
        if let Some(payload) = payload.as_mut() {
            if let crate::LiveTrace::Spilled(report) = &mut payload.trace {
                report.delivered();
            }
        }
        Some(payload)
    }
    pub fn ack_state(&self, job_id: u64, state_id: usize) -> Result<(), RebirthError> {
        self.ack_state_with_reply(job_id, state_id, Vec::new())
    }
    pub fn ack_state_with_reply(
        &self,
        job_id: u64,
        state_id: usize,
        reply: crate::LiveReply,
    ) -> Result<(), RebirthError> {
        let mut state = self.control.lock();
        let cancelled = state.cancellation_accepted;
        let live = state.live.as_mut().ok_or_else(|| RebirthError::Internal {
            context: "state acknowledgement on non-live job".into(),
        })?;
        if job_id != self.control.id || !live.drained || live.outstanding != Some(state_id) {
            return Err(RebirthError::Internal {
                context: "stale, duplicate or wrong-job state acknowledgement".into(),
            });
        }
        // A matching acknowledgement remains valid after callback cancellation;
        // cancellation wins the producer predicate before token/text publication.
        if !cancelled {
            if reply.len() > live.steer_count || reply.capacity() > live.steer_count {
                return Err(crate::live_steering::reply_error(
                    "Reply allocation exceeds the admitted steering entry count.",
                ));
            }
            live.reply = Some(reply);
        }
        live.outstanding = None;
        live.drained = false;
        self.control.space.notify_all();
        Ok(())
    }
    pub fn discard_state(&self) {
        self.discard_stream();
    }
    /// A bounded drain; None means contention and the next R timer retries.
    /// The bool reports whether all queued rows were transferred in this batch.
    pub fn drain_stream(&self) -> Option<(Vec<StreamEvent>, bool)> {
        let mut state = self.control.state.try_lock().ok()?;
        let Some(stream) = state.stream.as_mut() else {
            return Some((Vec::new(), true));
        };
        let mut rows = Vec::with_capacity(STREAM_BATCH_ROWS);
        let mut bytes = 0usize;
        while rows.len() < STREAM_BATCH_ROWS {
            let Some(row) = stream.rows.front() else {
                break;
            };
            let Some(next) = bytes.checked_add(row.text.len()) else {
                break;
            };
            if next > STREAM_BATCH_BYTES {
                break;
            }
            bytes = next;
            rows.push(stream.rows.pop_front().expect("peeked row"));
        }
        stream.bytes -= bytes;
        let empty = stream.rows.is_empty();
        self.control.space.notify_all();
        Some((rows, empty))
    }
    pub fn stream_empty(&self) -> bool {
        self.control
            .lock()
            .stream
            .as_ref()
            .is_none_or(|stream| stream.rows.is_empty())
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
            let generated = if let Some(live) = &request.live {
                model.generate_live_tokens(tokens, &request.params, live)?
            } else {
                model.generate(tokens, &request.params)?
            };
            prompt_completed(generated.text.len())?;
            stream_prompt_end(generated.stop_reason.as_str())?;
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
        let generation = if let Some(live) = &request.live {
            model.generate_live_prompt(prompt, request.chat, &request.params, live)?
        } else if let Some(images) = &request.images {
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
        stream_prompt_end(generation.stop_reason.as_str())?;
        output.push(generation);
    }
    Ok(output)
}
fn run_fixture(request: &AsyncRequest, fixture: Fixture) -> Result<Vec<Generation>, RebirthError> {
    let mut output = Vec::with_capacity(request.prompts.len());
    // Streaming fixtures exercise real transport and ownership; they make no
    // tokenizer/model claim. Preserve the established nonstream fixture timing.
    let prompts = if request.stream {
        request.prompts.len()
    } else {
        1
    };
    for prompt in 0..prompts {
        prompt_started(prompt + 1)?;
        for i in 0..fixture.steps {
            checkpoint()?;
            if fixture.delay_ms > 0 {
                thread::sleep(Duration::from_millis(fixture.delay_ms));
            }
            sampled((i as usize + 1).min(request.params.max_tokens))?;
            stream_token((i % 32) as i32, i as usize + 1)?;
        }
        let text = match fixture.mode {
            AsyncFixtureMode::StartError => unreachable!("startup failure never enters worker"),
            AsyncFixtureMode::Error => {
                return Err(RebirthError::Generation {
                    reason: "async_fixture".into(),
                })
            }
            AsyncFixtureMode::Panic => panic!("controlled asynchronous fixture panic"),
            AsyncFixtureMode::StreamText => "NA,\"quoted\"\nλ🙂 ".repeat(32_768),
            AsyncFixtureMode::StreamEncoding => "before\0after".into(),
            AsyncFixtureMode::Success => "fixture".into(),
        };
        stream_text(&text)?;
        if request.stream {
            prompt_completed(text.len())?;
            stream_prompt_end(crate::StopReason::MaxTokens.as_str())?;
            output.push(Generation {
                tokens: (0..fixture.steps).map(|i| (i % 32) as i32).collect(),
                text,
                stop_reason: crate::StopReason::MaxTokens,
                seed: request.params.seed,
            });
        }
    }
    if !request.stream {
        output = request
            .prompts
            .iter()
            .map(|_| Generation {
                tokens: vec![],
                text: "fixture".into(),
                stop_reason: crate::StopReason::MaxTokens,
                seed: request.params.seed,
            })
            .collect();
    }
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn job_id_allocation_preserves_sequence_and_exhaustion() {
        let counter = std::sync::atomic::AtomicU64::new(1);
        assert_eq!(allocate_job_id(&counter), 1);
        assert_eq!(allocate_job_id(&counter), 2);
        counter.store(u64::MAX - 1, Ordering::Relaxed);
        assert_eq!(allocate_job_id(&counter), u64::MAX - 1);
        assert_eq!(allocate_job_id(&counter), u64::MAX);
        assert_eq!(allocate_job_id(&counter), u64::MAX);
        assert_eq!(counter.load(Ordering::Relaxed), u64::MAX);
    }

    #[test]
    fn job_id_allocation_is_unique_under_contention() {
        let counter = Arc::new(std::sync::atomic::AtomicU64::new(1));
        let barrier = Arc::new(std::sync::Barrier::new(8));
        let workers: Vec<_> = (0..8)
            .map(|_| {
                let counter = Arc::clone(&counter);
                let barrier = Arc::clone(&barrier);
                thread::spawn(move || {
                    barrier.wait();
                    (0..64)
                        .map(|_| allocate_job_id(&counter))
                        .collect::<Vec<_>>()
                })
            })
            .collect();
        let mut ids: Vec<_> = workers
            .into_iter()
            .flat_map(|worker| worker.join().unwrap())
            .collect();
        ids.sort_unstable();
        assert_eq!(ids, (1..=512).collect::<Vec<_>>());
        assert_eq!(counter.load(Ordering::Relaxed), 513);
    }

    include!("live_steering_tests.rs");

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
            stream: false,
            live: None,
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
    fn stream_control() -> Arc<Control> {
        let mut req = request();
        req.stream = true;
        Arc::new(Control::new(&req))
    }
    fn enqueue_token(control: &Control) -> Result<(), RebirthError> {
        control.enqueue("token", Some(1), Some(1), "".into(), "")
    }
    fn control_job(control: Arc<Control>) -> AsyncJob {
        AsyncJob {
            control,
            worker: None,
        }
    }
    fn live_control() -> Arc<Control> {
        let mut req = request();
        req.stream = true;
        req.live = Some(crate::live_state::tests::request());
        Arc::new(Control::new(&req))
    }
    fn live_payload(id: usize) -> crate::LiveState {
        crate::LiveState {
            job_id: 0,
            state_id: id,
            token_id: 24,
            context_pos: 2,
            source_pos: 1,
            prompt_token_count: 2,
            elapsed: 0.0,
            logits: vec![],
            steering_revision: 0,
            applied_after_state: 0,
            effective_source_pos: 0,
            steering: vec![],
            trace: crate::LiveTrace::Memory(vec![]),
        }
    }
    // Draining older events wakes the waiting producer. Observe its next wait
    // entry before testing the nonblocking state drain, so mutex contention is
    // not mistaken for a missing state. No sleep or retry weakens the assertions.
    fn drain_before_live_state(job: &AsyncJob) -> (Vec<StreamEvent>, bool) {
        let (tx, rx) = std::sync::mpsc::channel();
        *job.control.queue_waiter.lock().unwrap() = Some(tx);
        let batch = job.drain_stream().unwrap();
        rx.recv_timeout(Duration::from_secs(5)).unwrap();
        drop(job.control.lock());
        batch
    }
    #[test]
    #[cfg(feature = "spill")]
    fn live_control_allocations_cover_memory_and_spill_cancellation() {
        for spill in [false, true] {
            let mut req = request();
            let mut live = crate::live_state::tests::request();
            live.spill = spill;
            req.live = Some(live);
            let control = Arc::new(Control::new(&req));
            let actual = std::mem::size_of_val(control.as_ref())
                + std::mem::size_of::<AsyncJob>()
                + std::mem::size_of::<AsyncStartFailure>()
                + std::mem::size_of_val(control.live_cancel.as_ref())
                + 4 * std::mem::size_of::<usize>();
            assert_eq!(live_control_bytes(), actual);
        }
    }
    #[test]
    fn live_state_order_and_correlated_acknowledgement() {
        use std::sync::mpsc;
        let control = live_control();
        let job = control_job(control.clone());
        enqueue_token(&control).unwrap(); // previously published token event
        let (tx, rx) = mpsc::channel();
        *control.live_published.lock().unwrap() = Some(tx);
        let worker_control = control.clone();
        let producer = std::thread::spawn(move || {
            worker_control.publish_live(live_payload(1))?;
            enqueue_token(&worker_control)
        });
        assert_eq!(
            rx.recv_timeout(Duration::from_secs(5)).unwrap(),
            (job.id(), 1)
        );
        drop(job.control.lock());
        assert!(job.drain_state().unwrap().is_none());
        assert_eq!(drain_before_live_state(&job).0.len(), 1);
        let state = job.drain_state().unwrap().unwrap();
        assert_eq!(state.job_id, job.id());
        assert_eq!(state.state_id, 1);
        assert!(job.drain_state().unwrap().is_none());
        assert!(job.ack_state(job.id() + 1, 1).is_err());
        assert!(job.ack_state(job.id(), 2).is_err());
        assert!(job.drain_stream().unwrap().0.is_empty());
        job.ack_state(job.id(), 1).unwrap();
        producer.join().unwrap().unwrap();
        assert!(job.ack_state(job.id(), 1).is_err());
        assert_eq!(job.drain_stream().unwrap().0.len(), 1);
    }
    #[test]
    fn live_state_cancel_and_discard_wake_without_current_token() {
        use std::sync::mpsc;
        for delivered in [false, true] {
            for discard in [false, true] {
                let control = live_control();
                let job = control_job(control.clone());
                let (tx, rx) = mpsc::channel();
                *control.live_published.lock().unwrap() = Some(tx);
                let producer = std::thread::spawn(move || {
                    control.publish_live(live_payload(1))?;
                    enqueue_token(&control)
                });
                assert_eq!(
                    rx.recv_timeout(Duration::from_secs(5)).unwrap(),
                    (job.id(), 1)
                );
                drop(job.control.lock());
                if delivered {
                    assert!(job.drain_state().unwrap().is_some());
                }
                if discard {
                    job.discard_state();
                } else {
                    assert!(job.cancel());
                }
                // Cancellation inside on_state can be followed by a valid NULL ack.
                if delivered {
                    job.ack_state(job.id(), 1).unwrap();
                }
                assert!(matches!(
                    producer.join().unwrap(),
                    Err(RebirthError::Cancelled { .. })
                ));
                assert!(job.drain_state().unwrap().is_none());
                assert!(job.drain_stream().unwrap().0.is_empty());
                assert!(job.control.lock().live.as_ref().unwrap().pending.is_none());
            }
        }
    }

    #[test]
    fn live_publication_signal_is_not_a_wait_wakeup() {
        use std::sync::mpsc;
        let control = live_control();
        let job = control_job(control.clone());
        let (published_tx, published_rx) = mpsc::channel();
        *control.live_published.lock().unwrap() = Some(published_tx);
        let (waiting_tx, waiting_rx) = mpsc::channel();
        *control.queue_waiter.lock().unwrap() = Some(waiting_tx);
        let producer = std::thread::spawn(move || {
            control.publish_live(live_payload(1))?;
            enqueue_token(&control)?;
            control.publish_live(live_payload(2))?;
            enqueue_token(&control)
        });
        assert_eq!(
            published_rx.recv_timeout(Duration::from_secs(5)).unwrap(),
            (job.id(), 1)
        );
        waiting_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        drop(job.control.lock());
        // Force the exact former race: install a new wait observer before ack,
        // then let drain_stream notify the previous state's waiting producer.
        let (rewait_tx, rewait_rx) = mpsc::channel();
        *job.control.queue_waiter.lock().unwrap() = Some(rewait_tx);
        assert!(job.drain_stream().unwrap().0.is_empty());
        rewait_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        drop(job.control.lock());
        assert!(matches!(
            published_rx.try_recv(),
            Err(mpsc::TryRecvError::Empty)
        ));
        let first = job.drain_state().unwrap().unwrap();
        assert_eq!(first.state_id, 1);
        job.ack_state(first.job_id, first.state_id).unwrap();
        assert_eq!(
            published_rx.recv_timeout(Duration::from_secs(5)).unwrap(),
            (job.id(), 2)
        );
        drop(job.control.lock());
        assert_eq!(drain_before_live_state(&job).0.len(), 1);
        let second = job.drain_state().unwrap().unwrap();
        assert_eq!(second.state_id, 2);
        job.ack_state(second.job_id, second.state_id).unwrap();
        producer.join().unwrap().unwrap();
        assert_eq!(job.drain_stream().unwrap().0.len(), 1);
        assert!(matches!(
            published_rx.try_recv(),
            Err(mpsc::TryRecvError::Empty)
        ));
    }

    // Rust PR CI, download-free. Caps cover actual allocated text and descriptor
    // slots, independent row/byte saturation, and lossless FIFO drains.
    #[test]
    fn stream_caps_and_lossless_bounded_drains() {
        assert!(std::mem::size_of::<StreamEvent>() <= 128);
        let control = stream_control();
        for _ in 0..STREAM_QUEUE_ROWS {
            enqueue_token(&control).unwrap();
        }
        {
            let state = control.lock();
            let stream = state.stream.as_ref().unwrap();
            assert_eq!(stream.rows.len(), STREAM_QUEUE_ROWS);
            assert_eq!(stream.rows.capacity(), STREAM_QUEUE_ROWS);
            assert_eq!(stream.bytes, 0);
        }
        let job = control_job(control.clone());
        for batch in 0..4 {
            let (rows, empty) = job.drain_stream().unwrap();
            assert_eq!(rows.len(), STREAM_BATCH_ROWS);
            assert_eq!(empty, batch == 3);
            for (i, row) in rows.iter().enumerate() {
                assert_eq!(row.event_id as usize, batch * STREAM_BATCH_ROWS + i + 1);
            }
        }
        for _ in 0..STREAM_QUEUE_BYTES / STREAM_CHUNK_BYTES {
            control
                .enqueue(
                    "text",
                    None,
                    None,
                    "x".repeat(STREAM_CHUNK_BYTES).into_boxed_str(),
                    "",
                )
                .unwrap();
        }
        assert_eq!(
            control.lock().stream.as_ref().unwrap().bytes,
            STREAM_QUEUE_BYTES
        );
        for batch in 0..4 {
            let (rows, empty) = job.drain_stream().unwrap();
            assert_eq!(
                rows.iter().map(|r| r.text.len()).sum::<usize>(),
                STREAM_BATCH_BYTES
            );
            assert_eq!(empty, batch == 3);
        }
    }
    // Match the public polling contract: None means mutex contention, not an
    // empty queue. The caller shares this deadline with the producer watchdog.
    fn drain_stream_before(
        job: &AsyncJob,
        deadline: Instant,
        mut on_contention: impl FnMut(),
    ) -> (Vec<StreamEvent>, bool) {
        loop {
            assert!(Instant::now() < deadline, "stream drain before deadline");
            if let Some(batch) = job.drain_stream() {
                return batch;
            }
            on_contention();
            thread::yield_now();
        }
    }
    // Rust PR CI (default and no-spill). Force contention rather than relying
    // on the scheduler to expose the observer-before-unlock interval.
    #[test]
    fn stream_full_queue_drain_observes_nonblocking_contention() {
        use std::sync::mpsc;
        let control = stream_control();
        enqueue_token(&control).unwrap();
        let job = control_job(control.clone());
        let held = control.lock();
        let deadline = Instant::now() + Duration::from_secs(2);
        let (contended, observed) = mpsc::channel();
        let (done, finished) = mpsc::channel();
        thread::scope(|scope| {
            scope.spawn(|| {
                let mut first_contention = Some(contended);
                let batch = drain_stream_before(&job, deadline, || {
                    if let Some(sender) = first_contention.take() {
                        sender.send(()).unwrap();
                    }
                });
                done.send(batch).unwrap();
            });
            observed
                .recv_timeout(deadline.saturating_duration_since(Instant::now()))
                .expect("consumer observed the held predicate mutex");
            assert!(matches!(
                finished.try_recv(),
                Err(mpsc::TryRecvError::Empty)
            ));
            assert_eq!(held.stream.as_ref().unwrap().rows.len(), 1);
            drop(held);
            let (rows, empty) = finished
                .recv_timeout(deadline.saturating_duration_since(Instant::now()))
                .expect("consumer drains after predicate mutex release");
            assert_eq!(rows.len(), 1);
            assert_eq!(rows[0].event_id, 1);
            assert!(empty);
        });
        assert!(job.stream_empty());
    }
    // Rust PR CI. Observer is triggered under the predicate mutex immediately
    // before Condvar::wait; cancel/close/shutdown can never slip past that lock.
    #[test]
    fn stream_full_queue_cancel_discard_and_drain_wake_producer() {
        use std::sync::mpsc;
        for mode in 0..3 {
            for byte_full in [false, true] {
                let control = stream_control();
                if byte_full {
                    for _ in 0..STREAM_QUEUE_BYTES / STREAM_CHUNK_BYTES {
                        control
                            .enqueue(
                                "text",
                                None,
                                None,
                                "x".repeat(STREAM_CHUNK_BYTES).into_boxed_str(),
                                "",
                            )
                            .unwrap();
                    }
                } else {
                    for _ in 0..STREAM_QUEUE_ROWS {
                        enqueue_token(&control).unwrap();
                    }
                }
                let (entered, observed) = mpsc::channel();
                *control.queue_waiter.lock().unwrap() = Some(entered);
                let worker_control = control.clone();
                let (done, finished) = mpsc::channel();
                let producer = thread::spawn(move || {
                    let result = worker_control.enqueue("text", None, None, "next".into(), "");
                    done.send(result).unwrap();
                });
                observed
                    .recv_timeout(Duration::from_secs(2))
                    .expect("producer waits at limit");
                let job = control_job(control);
                let deadline = Instant::now() + Duration::from_secs(2);
                match mode {
                    0 => {
                        assert!(job.cancel());
                    }
                    1 => job.discard_stream(),
                    _ => {
                        // The observer may arrive before Condvar::wait releases
                        // the predicate mutex. A bounded retry is part of this
                        // nonblocking drain's contract, not a producer failure.
                        let (rows, _) = drain_stream_before(&job, deadline, || {});
                        assert!(!rows.is_empty());
                    }
                }
                let result = finished
                    .recv_timeout(deadline.saturating_duration_since(Instant::now()))
                    .expect("producer wakes");
                assert_eq!(result.is_ok(), mode == 2);
                producer.join().unwrap();
                if mode == 1 {
                    assert!(job.stream_empty());
                }
            }
        }
    }
    // Rust PR CI. Deterministic UTF-8 boundaries, NUL rejection, typed schema
    // markers and terminal publication discard use the same worker-local hooks.
    #[test]
    fn stream_utf8_chunks_schema_encoding_and_native_error() {
        let mut req = request();
        req.stream = true;
        req.schema = Some(CompiledSchema::compile(r#"{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"],"additionalProperties":false}"#).unwrap());
        let control = Arc::new(Control::new(&req));
        CONTROL.with(|slot| *slot.borrow_mut() = Some(control.clone()));
        let text = "λ🙂".repeat(STREAM_CHUNK_BYTES / 3);
        stream_token(0, 1).unwrap();
        stream_text(&text).unwrap();
        stream_prompt_end("length").unwrap();
        assert!(
            matches!(stream_text("a\0b"), Err(RebirthError::Stream { reason, .. }) if reason == "encoding")
        );
        CONTROL.with(|slot| slot.borrow_mut().take());
        let job = control_job(control.clone());
        let (rows, empty) = job.drain_stream().unwrap();
        assert!(empty);
        assert_eq!(rows[0].token_id, Some(1));
        assert_eq!(rows[0].validated, Some(false));
        assert_eq!(rows.last().unwrap().validated, Some(true));
        assert_eq!(
            rows.iter()
                .filter(|r| r.event == "text")
                .map(|r| r.text.as_ref())
                .collect::<String>(),
            text
        );
        assert!(rows.iter().all(|r| r.text.len() <= STREAM_CHUNK_BYTES));
        assert!(rows
            .windows(2)
            .all(|rows| rows[0].elapsed <= rows[1].elapsed));
        enqueue_token(&control).unwrap();
        let mut failure = Err(RebirthError::Generation {
            reason: "fixture".into(),
        });
        control.publish(&mut failure, false);
        assert!(job.stream_empty());
        assert!(!job.cancel());
    }
    // Rust PR CI. Exercise many cancellation/wait interleavings with a bounded
    // watchdog, without relying on sleep duration or a scheduler timing guess.
    #[test]
    fn stream_cancel_wait_race_has_no_lost_wakeup() {
        use std::sync::mpsc;
        for round in 0..128 {
            let control = stream_control();
            for _ in 0..STREAM_QUEUE_ROWS {
                enqueue_token(&control).unwrap();
            }
            let (entered, observed) = mpsc::channel();
            if round % 2 == 0 {
                *control.queue_waiter.lock().unwrap() = Some(entered);
            }
            let worker_control = control.clone();
            let (done, finished) = mpsc::channel();
            let producer = thread::spawn(move || {
                done.send(enqueue_token(&worker_control)).unwrap();
            });
            if round % 2 == 0 {
                observed.recv_timeout(Duration::from_secs(2)).unwrap();
            }
            let job = control_job(control);
            assert!(job.cancel());
            assert!(matches!(
                finished.recv_timeout(Duration::from_secs(2)).unwrap(),
                Err(RebirthError::Cancelled { .. })
            ));
            producer.join().unwrap();
        }
    }
    // Rust PR CI. A real completion owns the process reservation even after its
    // final native row has been drained; only explicit completion disposal frees it.
    #[test]
    fn stream_native_completion_retains_permit_until_delivery_ack() {
        let mut req = request();
        req.stream = true;
        let mut job = AsyncJob::start_fixture(
            req,
            ExecutionPermit::try_acquire("stream fixture").unwrap(),
            AsyncFixtureMode::Success,
            1,
            0,
        )
        .unwrap_or_else(|_| panic!("stream starts"));
        let completion = job.worker.take().unwrap().join().unwrap();
        assert!(!job.cancel());
        assert!(completion.result.is_ok());
        let (rows, empty) = job.drain_stream().unwrap();
        assert!(empty);
        assert_eq!(
            rows.iter().map(|r| r.event).collect::<Vec<_>>(),
            vec!["token", "text", "prompt_end"]
        );
        assert!(ExecutionPermit::try_acquire("last consumer").is_err());
        drop(completion);
        assert!(ExecutionPermit::try_acquire("final progress").is_ok());
    }
    // Rust PR CI. Production worker shutdown and panic/error collection after
    // backpressure retain their exactly-once ownership behavior.
    #[test]
    fn stream_shutdown_and_failures_after_backpressure_release_ownership() {
        use std::sync::mpsc;
        for mode in [
            AsyncFixtureMode::Success,
            AsyncFixtureMode::Error,
            AsyncFixtureMode::Panic,
        ] {
            let (entered, observed) = mpsc::channel();
            TEST_QUEUE_WAITER.with(|slot| *slot.borrow_mut() = Some(entered));
            let mut req = request();
            req.stream = true;
            let mut job = AsyncJob::start_fixture(
                req,
                ExecutionPermit::try_acquire("blocked fixture").unwrap(),
                mode,
                STREAM_QUEUE_ROWS as u32 + 1,
                0,
            )
            .unwrap_or_else(|_| panic!("stream starts"));
            observed
                .recv_timeout(Duration::from_secs(2))
                .expect("worker waits");
            let completion = if matches!(mode, AsyncFixtureMode::Success) {
                job.shutdown().unwrap()
            } else {
                job.drain_stream().unwrap();
                job.worker.take().unwrap().join().unwrap()
            };
            assert_eq!(
                completion.result.as_ref().unwrap_err().class(),
                match mode {
                    AsyncFixtureMode::Success => "relm_error_cancelled",
                    AsyncFixtureMode::Error => "relm_error_generation",
                    _ => "relm_error_internal",
                }
            );
            assert!(job.stream_empty());
            assert!(ExecutionPermit::try_acquire("retained failure").is_err());
            drop(completion);
            assert!(ExecutionPermit::try_acquire("recovered after failure").is_ok());
        }
    }
    // Rust PR CI. The no-token prompt still emits its ordered end marker.
    #[test]
    fn stream_zero_tokens_and_nonstream_allocate_no_spurious_rows() {
        let ordinary = Control::new(&request());
        assert!(ordinary.lock().stream.is_none());
        let control = stream_control();
        CONTROL.with(|slot| *slot.borrow_mut() = Some(control.clone()));
        stream_text("").unwrap();
        stream_prompt_end("stop").unwrap();
        CONTROL.with(|slot| slot.borrow_mut().take());
        let (rows, empty) = control_job(control).drain_stream().unwrap();
        assert!(empty);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].event, "prompt_end");
        assert_eq!(rows[0].event_id, 1);
        assert_eq!(rows[0].finish_reason, "stop");
        assert_eq!(rows[0].validated, None);
    }
    #[test]
    fn stream_limits_are_twin_pinned_to_r_delivery() {
        // Rust PR CI, paired with R tests on each R-CMD-check leg.
        let source = include_str!("../../../../R/stream.R");
        for (name, value) in [
            ("queue_rows", STREAM_QUEUE_ROWS),
            ("queue_bytes", STREAM_QUEUE_BYTES),
            ("chunk_bytes", STREAM_CHUNK_BYTES),
            ("batch_rows", STREAM_BATCH_ROWS),
            ("batch_bytes", STREAM_BATCH_BYTES),
        ] {
            assert!(
                source
                    .lines()
                    .any(|line| line == format!("relm_stream_{name} <- {value}")),
                "R/native stream bound differs: {name}"
            );
        }
    }
    #[test]
    fn live_async_synthetic_memory_and_spill_preserve_token_order() {
        use std::sync::mpsc;
        let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../../../tests/llm-golden/synthetic/synthetic-llama-2l.gguf");
        let mut model = crate::load_with_batch(
            crate::LoadRequest {
                path,
                context_length: 768,
                gpu_layers: None,
                backend: crate::BackendKind::Cpu,
                mmap: true,
                projector: None,
            },
            Some(4),
        )
        .unwrap();
        let modes = if cfg!(feature = "spill") {
            vec![false, true]
        } else {
            vec![false]
        };
        for spill in modes {
            let input = vec![1, 7];
            let mut req = request();
            req.params.max_tokens = 4;
            req.stream = true;
            req.numeric_prompts = Some(vec![input.clone()]);
            let expected = model.generate(&input, &req.params).unwrap();
            let mut live = crate::live_state::tests::request();
            live.spill = spill;
            live.trace_id = format!("async-live-{}-{}", std::process::id(), spill);
            let dir = std::env::temp_dir().join(&live.trace_id);
            live.spill_dir = dir.to_string_lossy().into_owned();
            if spill {
                live.budget_bytes = 10_000;
            }
            req.live = Some(live);
            let (tx, rx) = mpsc::channel();
            TEST_LIVE_PUBLISHED.with(|slot| *slot.borrow_mut() = Some(tx));
            let mut job = AsyncJob::start(
                model,
                req,
                ExecutionPermit::try_acquire("live synthetic transport").unwrap(),
            )
            .unwrap_or_else(|_| panic!("live synthetic starts"));
            let mut delivered = Vec::new();
            #[cfg_attr(not(feature = "spill"), allow(unused_mut))]
            let mut paths = Vec::<String>::new();
            for (index, &token) in expected.tokens.iter().enumerate() {
                assert_eq!(
                    rx.recv_timeout(Duration::from_secs(10)).unwrap(),
                    (job.id(), index + 1)
                );
                drop(job.control.lock());
                let (events, empty) = drain_before_live_state(&job);
                assert!(empty);
                delivered.extend(events.iter().filter_map(|e| e.token_id).map(|id| id - 1));
                assert_eq!(delivered, expected.tokens[..index]);
                let state = job.drain_state().unwrap().unwrap();
                assert_eq!(state.state_id, index + 1);
                assert_eq!(state.token_id, token);
                assert_eq!(state.source_pos as usize, input.len() + index - 1);
                assert_eq!(state.context_pos, state.source_pos + 1);
                assert_eq!(state.logits.len(), 5);
                match state.trace {
                    crate::LiveTrace::Memory(rows) => {
                        assert!(!spill);
                        assert_eq!(rows.len(), 6);
                        assert!(rows
                            .iter()
                            .all(|r| r.values.len() == 32 && r.token_pos == state.source_pos));
                    }
                    #[cfg(feature = "spill")]
                    crate::LiveTrace::Spilled(report) => {
                        assert!(spill);
                        assert_eq!(report.report.n_rows, 192);
                        paths.push(report.report.path.clone());
                    }
                }
                job.ack_state(state.job_id, state.state_id).unwrap();
            }
            let mut completion = job.worker.take().unwrap().join().unwrap();
            let (events, empty) = job.drain_stream().unwrap();
            assert!(empty);
            delivered.extend(events.iter().filter_map(|e| e.token_id).map(|id| id - 1));
            assert_eq!(delivered, expected.tokens);
            assert_eq!(completion.result.as_ref().unwrap()[0], expected);
            model = completion.model.take().unwrap();
            drop(completion);
            for path in paths {
                assert!(std::path::Path::new(&path).exists());
                std::fs::remove_file(path).unwrap();
            }
            if spill {
                std::fs::remove_dir(dir).unwrap();
            }
        }
    }

    // Rust PR CI: seeded sync/async stream parity on the in-repo numeric GGUF,
    // including the last sampled token before context exhaustion.
    #[test]
    fn stream_synthetic_token_parity_includes_context_exhaustion() {
        let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../../../tests/llm-golden/synthetic/synthetic-llama-2l.gguf");
        let mut model = crate::load_with_batch(
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
        // llama.cpp pads the requested window; exhaust the actual context,
        // rather than assuming the requested 64 tokens are the native limit.
        let context_length = model.context_length() as usize;
        for input in [vec![1, 7, 3], vec![1; context_length]] {
            let mut req = request();
            req.stream = true;
            req.params.max_tokens = 16;
            req.params.temperature = 0.8;
            req.numeric_prompts = Some(vec![input.clone()]);
            let expected = model.generate(&input, &req.params).unwrap();
            if input.len() == context_length {
                assert_eq!(expected.stop_reason, crate::StopReason::ContextFull);
                assert_eq!(expected.tokens.len(), 1);
            } else {
                assert_eq!(expected.stop_reason, crate::StopReason::MaxTokens);
                assert_eq!(expected.tokens.len(), req.params.max_tokens);
            }
            let mut job = AsyncJob::start(
                model,
                req,
                ExecutionPermit::try_acquire("numeric stream").unwrap(),
            )
            .unwrap_or_else(|_| panic!("numeric stream starts"));
            let mut completion = job.worker.take().unwrap().join().unwrap();
            let (rows, empty) = job.drain_stream().unwrap();
            assert!(empty);
            assert_eq!(
                rows.iter()
                    .filter_map(|row| row.token_id)
                    .map(|id| id - 1)
                    .collect::<Vec<_>>(),
                expected.tokens
            );
            assert_eq!(
                rows.iter()
                    .filter_map(|row| row.token_pos)
                    .collect::<Vec<_>>(),
                (1..=expected.tokens.len() as i32).collect::<Vec<_>>()
            );
            assert_eq!(
                rows.last().unwrap().finish_reason,
                expected.stop_reason.as_str()
            );
            assert_eq!(completion.result.as_ref().unwrap()[0], expected);
            model = completion.model.take().unwrap();
            drop(completion);
        }
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
                    stream: false,
                    live: None,
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
