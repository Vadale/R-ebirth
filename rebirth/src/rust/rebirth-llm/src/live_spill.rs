//! One completed live Arrow stream per source state. Only the generation worker
//! joins this writer. Queue predicates and cancellation use the same mutex.
use crate::live_state::{
    trace_error, LiveEstimate, LiveRequest, LiveSpillReport, LIVE_BATCH_ROWS, LIVE_SPILL_BYTES,
    LIVE_TRANSPORT_BYTES,
};
use crate::{CaptureRow, RebirthError, SpillReport};
use arrow_array::builder::{Float32Builder, StringBuilder, UInt32Builder};
use arrow_array::{ArrayRef, RecordBatch};
use arrow_ipc::writer::StreamWriter;
use arrow_schema::{DataType, Field, Schema};
use std::collections::{HashMap, VecDeque};
use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex, PoisonError, Weak};
use std::thread::JoinHandle;

#[derive(Default)]
pub(crate) struct LiveCancel {
    cancelled: std::sync::atomic::AtomicBool,
    writer: Mutex<Option<Weak<Queue>>>,
}
impl LiveCancel {
    pub(crate) fn cancel(&self) {
        self.cancelled
            .store(true, std::sync::atomic::Ordering::Release);
        if let Some(queue) = self
            .writer
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .as_ref()
            .and_then(Weak::upgrade)
        {
            queue.abort();
        }
    }
    pub(crate) fn is_cancelled(&self) -> bool {
        self.cancelled.load(std::sync::atomic::Ordering::Acquire)
    }
    fn register(&self, queue: &Arc<Queue>) {
        let mut registered = self.writer.lock().unwrap_or_else(PoisonError::into_inner);
        *registered = Some(Arc::downgrade(queue));
        if self.is_cancelled() {
            queue.abort();
        }
    }
}
struct QueueState {
    rows: VecDeque<CaptureRow>,
    bytes: usize,
    closed: bool,
    cancelled: bool,
    error: Option<RebirthError>,
}
struct Queue {
    limit: usize,
    #[cfg(test)]
    blocked: Mutex<Option<std::sync::mpsc::Sender<()>>>,
    state: Mutex<QueueState>,
    ready: Condvar,
    space: Condvar,
}
impl Queue {
    fn abort(&self) {
        self.state
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .cancelled = true;
        self.ready.notify_all();
        self.space.notify_all();
    }
    fn failure(&self, error: RebirthError) {
        self.state
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .error = Some(error);
        self.ready.notify_all();
        self.space.notify_all();
    }
}

/// Owns only the exclusively created file identity. A completed but undelivered
/// file is removed on the generation worker; delivery relinquishes this guard.
#[derive(Debug)]
pub(crate) struct OwnedLiveFile {
    path: PathBuf,
    metadata: std::fs::Metadata,
    retained: bool,
}
impl Drop for OwnedLiveFile {
    fn drop(&mut self) {
        if self.retained {
            return;
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            if let Ok(current) = std::fs::symlink_metadata(&self.path) {
                if current.is_file()
                    && current.dev() == self.metadata.dev()
                    && current.ino() == self.metadata.ino()
                {
                    let _ = std::fs::remove_file(&self.path);
                }
            }
        }
    }
}
struct LimitedFile {
    file: File,
    written: u64,
    limit: u64,
}
impl Write for LimitedFile {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if (buf.len() as u64)
            .checked_add(self.written)
            .is_none_or(|n| n > self.limit)
        {
            return Err(io::Error::other("live serialized byte limit exceeded"));
        }
        let count = self.file.write(buf)?;
        self.written += count as u64;
        Ok(count)
    }
    fn flush(&mut self) -> io::Result<()> {
        self.file.flush()
    }
}
struct Complete {
    file: OwnedLiveFile,
    rows: u64,
    bytes: u64,
}
pub(crate) struct LiveSpillSink {
    queue: Arc<Queue>,
    handle: Option<JoinHandle<Result<Complete, RebirthError>>>,
    report: Option<LiveSpillReport>,
}

impl LiveSpillSink {
    pub(crate) fn new(
        request: &LiveRequest,
        estimate: &LiveEstimate,
        state_id: usize,
        prompt_count: usize,
        source_pos: u32,
        written: u64,
        cancel: Arc<LiveCancel>,
    ) -> Result<Self, RebirthError> {
        let nonce = format!("{}-{state_id}", request.trace_id)
            .into_boxed_str()
            .into_string();
        let path = PathBuf::from(&request.spill_dir).join(format!("{nonce}.arrow"));
        let file = if let Some(file) = crate::spill_lease::open_managed_spill(&path)? {
            file
        } else {
            std::fs::create_dir_all(&request.spill_dir)
                .map_err(|e| trace_error(format!("Could not create live spill directory: {e}")))?;
            OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&path)
                .map_err(|e| {
                    trace_error(format!("Could not exclusively create live spill file: {e}"))
                })?
        };
        let owner = OwnedLiveFile {
            path: path.clone(),
            metadata: file.metadata().map_err(|e| trace_error(e.to_string()))?,
            retained: false,
        };
        let spec = request.state_spec(state_id, prompt_count, source_pos, estimate.batch_bytes);
        let schema = schema(
            &nonce,
            &request.model,
            &spec,
            state_id,
            prompt_count,
            source_pos,
            estimate.batch_bytes,
        );
        let rows = VecDeque::with_capacity(64);
        let descriptor_bytes = rows.capacity() * std::mem::size_of::<CaptureRow>();
        let queue = Arc::new(Queue {
            limit: (LIVE_TRANSPORT_BYTES - estimate.capture_control_bytes) as usize,
            #[cfg(test)]
            blocked: Mutex::new(None),
            state: Mutex::new(QueueState {
                rows,
                bytes: descriptor_bytes,
                closed: false,
                cancelled: false,
                error: None,
            }),
            ready: Condvar::new(),
            space: Condvar::new(),
        });
        cancel.register(&queue);
        let worker_queue = queue.clone();
        let maximum_batch = estimate.batch_bytes;
        let record_frame = estimate.record_frame_bytes;
        let maximum_piece = estimate.max_piece_bytes;
        let limit = LIVE_SPILL_BYTES
            .min(estimate.spill_bytes)
            .checked_sub(written)
            .ok_or_else(|| trace_error("live spill byte accounting overflow"))?;
        let handle = std::thread::Builder::new()
            .name("relm-live-spill".into())
            .spawn(move || {
                let result = crate::async_job::catch_background(|| {
                    writer_loop(
                        file,
                        owner,
                        &worker_queue,
                        schema,
                        maximum_batch,
                        record_frame,
                        maximum_piece,
                        limit,
                    )
                })
                .unwrap_or_else(|_| {
                    Err(RebirthError::Internal {
                        context: "live spill writer panicked".into(),
                    })
                });
                if let Err(error) = &result {
                    worker_queue.failure(error.clone());
                }
                result
            })
            .map_err(|e| trace_error(format!("Could not start live spill writer: {e}")))?;
        Ok(Self {
            queue,
            handle: Some(handle),
            report: Some(LiveSpillReport {
                report: SpillReport {
                    path: path.to_string_lossy().into_owned(),
                    n_rows: estimate.n_values,
                    n_positions: 1,
                    layers: request.layers.clone(),
                    positions: vec![source_pos],
                    components: request.components.clone(),
                    n_embd: estimate.hidden_size,
                    trace_id: nonce,
                    positions_recycled: false,
                },
                spec_key: spec,
                batch_bytes: estimate.batch_bytes,
                serialized_bytes: 0,
                owned: None,
            }),
        })
    }
    pub(crate) fn push(&self, row: CaptureRow) -> Result<(), RebirthError> {
        let bytes = row
            .values
            .capacity()
            .checked_mul(4)
            .and_then(|n| n.checked_add(row.token.as_ref().map_or(0, String::capacity)))
            .ok_or_else(|| trace_error("live writer payload overflow"))?;
        if bytes
            .checked_add(64 * std::mem::size_of::<CaptureRow>())
            .is_none_or(|n| n > self.queue.limit)
        {
            return Err(trace_error(
                "one live writer row exceeds the transport bound",
            ));
        }
        let mut state = self
            .queue
            .state
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        loop {
            if let Some(error) = &state.error {
                return Err(error.clone());
            }
            if state.cancelled || state.closed {
                return Err(trace_error("live writer cancelled"));
            }
            if state.rows.len() < state.rows.capacity()
                && state
                    .bytes
                    .checked_add(bytes)
                    .is_some_and(|n| n <= self.queue.limit)
            {
                break;
            }
            #[cfg(test)]
            if let Some(observer) = self.queue.blocked.lock().unwrap().take() {
                observer.send(()).expect("live queue observer");
            }
            state = self
                .queue
                .space
                .wait(state)
                .unwrap_or_else(PoisonError::into_inner);
        }
        state.bytes += bytes;
        state.rows.push_back(row);
        self.queue.ready.notify_one();
        Ok(())
    }
    pub(crate) fn finish(mut self) -> Result<LiveSpillReport, RebirthError> {
        self.queue
            .state
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .closed = true;
        self.queue.ready.notify_all();
        let complete = self
            .handle
            .take()
            .ok_or_else(|| trace_error("live writer ownership lost"))?
            .join()
            .map_err(|_| trace_error("live writer panicked"))??;
        let mut report = self
            .report
            .take()
            .ok_or_else(|| trace_error("live spill report missing"))?;
        if complete.rows != report.report.n_rows {
            return Err(trace_error("live spill emitted the wrong activation count"));
        }
        report.serialized_bytes = complete.bytes;
        report.owned = Some(complete.file);
        Ok(report)
    }
}
impl Drop for LiveSpillSink {
    fn drop(&mut self) {
        self.queue.abort();
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}
impl LiveSpillReport {
    pub(crate) fn delivered(&mut self) {
        if let Some(mut owner) = self.owned.take() {
            owner.retained = true;
        }
    }
}

fn schema(
    nonce: &str,
    model: &str,
    spec: &str,
    state_id: usize,
    prompt_count: usize,
    source_pos: u32,
    batch_bytes: u64,
) -> Arc<Schema> {
    let mut metadata = HashMap::with_capacity(10);
    for (key, value) in [
        ("relm.spill_format", "1".to_owned()),
        ("relm.trace_id", nonce.into()),
        ("relm.model", model.into()),
        ("relm.spec", spec.into()),
        ("relm.position_space", "model_context".into()),
        ("relm.prompt_token_count", prompt_count.to_string()),
        ("relm.state_id", state_id.to_string()),
        ("relm.source_pos", (source_pos + 1).to_string()),
        ("relm.live_batch_rows", LIVE_BATCH_ROWS.to_string()),
        ("relm.live_batch_bytes", batch_bytes.to_string()),
    ] {
        metadata.insert(key.into(), value.into_boxed_str().into_string());
    }
    Arc::new(
        Schema::new(vec![
            Field::new("prompt_id", DataType::UInt32, false),
            Field::new("token_pos", DataType::UInt32, false),
            Field::new("token", DataType::Utf8, true),
            Field::new("layer", DataType::UInt32, false),
            Field::new("component", DataType::Utf8, false),
            Field::new("neuron", DataType::UInt32, false),
            Field::new("value", DataType::Float32, false),
        ])
        .with_metadata(metadata),
    )
}
/// IPC sizing is metadata-only: an exact maximum-width schema and a tiny
/// nullable prototype exercise all seven field nodes and sixteen buffers.
#[derive(Default)]
pub(crate) struct ArrowBounds {
    pub schema_frame: u64,
    pub record_frame: u64,
    pub batch_bytes: u64,
    pub body_bytes: u64,
    pub per_file: u64,
    pub workspace: u64,
    pub fixed: u64,
}
fn align64(value: u64) -> Result<u64, RebirthError> {
    Ok(crate::live_state::add(value, 63)? / 64 * 64)
}
pub(crate) fn body_bound(n: u64, token: u64, component: u64) -> Result<u64, RebirthError> {
    use crate::live_state::{add, mul, sum};
    sum(&[
        mul(5, align64(mul(4, n)?)?)?,
        mul(2, align64(mul(4, add(n, 1)?)?)?)?,
        align64(mul(n, token)?)?,
        align64(mul(n, component)?)?,
        mul(7, align64(n.div_ceil(8))?)?,
    ])
}
pub(crate) fn chunk_rows(
    width: usize,
    token: u64,
    component: u64,
    frame: u64,
    limit: u64,
) -> Result<usize, RebirthError> {
    let mut low = 1;
    let mut high = width.min(LIVE_BATCH_ROWS);
    if high == 0 || crate::live_state::add(frame, body_bound(1, token, component)?)? > limit {
        return Err(trace_error("live Arrow single-row bound is inconsistent"));
    }
    while low < high {
        let mid = low + (high - low).div_ceil(2);
        if crate::live_state::add(frame, body_bound(mid as u64, token, component)?)? <= limit {
            low = mid;
        } else {
            high = mid - 1;
        }
    }
    Ok(low)
}
pub(crate) fn arrow_bounds(
    request: &LiveRequest,
    width: usize,
    token: u64,
) -> Result<ArrowBounds, RebirthError> {
    use crate::live_state::{add, mul, sum, LIVE_BATCH_BYTES, LIVE_MAX_STATES};
    use arrow_array::{Float32Array, StringArray, UInt32Array};
    use arrow_ipc::writer::{DictionaryTracker, EncodedData, IpcDataGenerator, IpcWriteOptions};
    use std::mem::size_of;
    let prototype_schema = Arc::new(Schema::new(vec![
        Field::new("prompt_id", DataType::UInt32, true),
        Field::new("token_pos", DataType::UInt32, true),
        Field::new("token", DataType::Utf8, true),
        Field::new("layer", DataType::UInt32, true),
        Field::new("component", DataType::Utf8, true),
        Field::new("neuron", DataType::UInt32, true),
        Field::new("value", DataType::Float32, true),
    ]));
    // One non-null and one null row force nonempty value and validity buffers.
    // FieldNode/Buffer entries are fixed-width structs; row counts do not change
    // framed metadata length once the record/body lengths are nonzero.
    let integers: ArrayRef = Arc::new(UInt32Array::from(vec![Some(1), None]));
    let strings: ArrayRef = Arc::new(StringArray::from(vec![Some("x"), None]));
    let floats: ArrayRef = Arc::new(Float32Array::from(vec![Some(1.0), None]));
    let prototype = RecordBatch::try_new(
        prototype_schema,
        vec![
            integers.clone(),
            integers.clone(),
            strings.clone(),
            integers.clone(),
            strings,
            integers,
            floats,
        ],
    )
    .map_err(|e| trace_error(e.to_string()))?;
    let options = IpcWriteOptions::default();
    let generator = IpcDataGenerator::default();
    let mut tracker = DictionaryTracker::new(false);
    let (dictionaries, encoded) = generator
        .encode(&prototype, &mut tracker, &options, &mut Default::default())
        .map_err(|e| trace_error(e.to_string()))?;
    if !dictionaries.is_empty() {
        return Err(trace_error(
            "live Arrow prototype unexpectedly has dictionaries",
        ));
    }
    let record_message = encoded.ipc_message.len() as u64;
    let record_frame = align64(add(record_message, 8)?)?;
    let mut batch_bytes = LIVE_BATCH_BYTES;
    for component in &request.components {
        batch_bytes = batch_bytes.max(add(
            record_frame,
            body_bound(1, token, component.as_str().len() as u64)?,
        )?);
    }
    let nonce = format!("{}-{LIVE_MAX_STATES}", request.trace_id);
    let spec = request.state_spec(
        LIVE_MAX_STATES,
        i32::MAX as usize,
        i32::MAX as u32 - 1,
        batch_bytes,
    );
    let maximum_schema = schema(
        &nonce,
        &request.model,
        &spec,
        LIVE_MAX_STATES,
        i32::MAX as usize,
        i32::MAX as u32 - 1,
        batch_bytes,
    );
    let schema_encoded = generator.schema_to_bytes_with_dictionary_tracker(
        &maximum_schema,
        &mut DictionaryTracker::new(false),
        &options,
    );
    let schema_message = schema_encoded.ipc_message.len() as u64;
    let schema_frame = align64(add(schema_message, 8)?)?;
    let mut records = 0;
    // Reserve the complete admitted frame remainder for every encoded body,
    // including encoded-vector growth. Runtime rows per fragment are fixed from
    // the same maximum label used below for the whole-call serialized bound.
    let body_bytes = batch_bytes
        .checked_sub(record_frame)
        .ok_or_else(|| trace_error("live Arrow frame exceeds its admitted batch"))?;
    for component in &request.components {
        let c = component.as_str().len() as u64;
        let n = chunk_rows(width, token, c, record_frame, batch_bytes)? as u64;
        let body = body_bound(n, token, c)?;
        records = add(records, mul(width as u64 / n, add(record_frame, body)?)?)?;
        let remainder = width as u64 % n;
        if remainder != 0 {
            records = add(
                records,
                add(record_frame, body_bound(remainder, token, c)?)?,
            )?;
        }
    }
    let per_file = sum(&[schema_frame, 8, mul(request.layers.len() as u64, records)?])?;
    // Source-derived growth peaks: FlatBuffer field locations cap8*8, vtables
    // cap32*4; IPC nodes cap8*16, buffers cap16*16; schema offsets7*4,
    // sorted key pointers10*pointer and metadata offsets10*4. No shared-string
    // pool, compression or dictionaries. 18 is the largest transient vtable.
    let workspace = sum(&[
        mul(4, add(schema_message.max(record_message), 18)?)?,
        3 * (8 * 8 + 32 * 4 + 8 * 16 + 16 * 16) / 2,
        7 * 4 + 10 * size_of::<usize>() as u64 + 10 * 4,
        7 * size_of::<EncodedData>() as u64,
        8 * size_of::<Vec<u8>>() as u64,
        size_of::<DictionaryTracker>() as u64,
    ])?;
    let metadata_strings = maximum_schema
        .metadata()
        .iter()
        .try_fold(0_u64, |n, (k, v)| {
            add(n, add(k.capacity() as u64, v.capacity() as u64)?)
        })?;
    let field_strings = maximum_schema
        .fields()
        .iter()
        .try_fold(0_u64, |n, f| add(n, f.name().capacity() as u64))?;
    // HashMap::with_capacity(10) uses16 buckets; each bucket includes its
    // control byte and a (String,String), plus the16-byte group sentinel.
    let schema_heap = sum(&[
        size_of::<Schema>() as u64,
        2 * size_of::<usize>() as u64,
        7 * (size_of::<Field>() + size_of::<Arc<Field>>() + 2 * size_of::<usize>()) as u64,
        16 * (size_of::<(String, String)>() + 1) as u64 + 16,
        metadata_strings,
        field_strings,
    ])?;
    let fixed = sum(&[
        size_of::<Queue>() as u64 + 2 * size_of::<usize>() as u64,
        // The boxed enum variants own these full heap pointees. Their Box
        // pointers are separately embedded in CaptureSink/LiveTrace and counted
        // by the compiled dispatcher/snapshot/state sizes. Keep both pointee
        // slots in this conservative sum even as the owning enums shrink.
        size_of::<LiveSpillSink>() as u64,
        size_of::<LiveSpillReport>() as u64,
        size_of::<Complete>() as u64,
        size_of::<OwnedLiveFile>() as u64,
        size_of::<StreamWriter<LimitedFile>>() as u64,
        size_of::<RecordBatch>() as u64,
        7 * (size_of::<ArrayRef>() + 2 * size_of::<usize>()) as u64,
        4 * (size_of::<UInt32Array>() + size_of::<UInt32Builder>()) as u64,
        (size_of::<Float32Array>() + size_of::<Float32Builder>()) as u64,
        2 * (size_of::<StringArray>() + size_of::<StringBuilder>()) as u64,
        schema_heap,
    ])?;
    Ok(ArrowBounds {
        schema_frame,
        record_frame,
        batch_bytes,
        body_bytes,
        per_file,
        workspace,
        fixed,
    })
}

#[allow(clippy::too_many_arguments)]
fn writer_loop(
    file: File,
    owner: OwnedLiveFile,
    queue: &Queue,
    schema: Arc<Schema>,
    batch_bytes: u64,
    record_frame: u64,
    maximum_piece: u64,
    limit: u64,
) -> Result<Complete, RebirthError> {
    let mut writer = StreamWriter::try_new(
        LimitedFile {
            file,
            written: 0,
            limit,
        },
        &schema,
    )
    .map_err(|e| trace_error(e.to_string()))?;
    let mut total = 0_u64;
    loop {
        let row = {
            let mut state = queue.state.lock().unwrap_or_else(PoisonError::into_inner);
            loop {
                if state.cancelled {
                    return Err(trace_error("live writer cancelled"));
                }
                if let Some(row) = state.rows.pop_front() {
                    state.bytes -=
                        row.values.capacity() * 4 + row.token.as_ref().map_or(0, String::capacity);
                    queue.space.notify_all();
                    break Some(row);
                }
                if state.closed {
                    break None;
                }
                state = queue
                    .ready
                    .wait(state)
                    .unwrap_or_else(PoisonError::into_inner);
            }
        };
        let Some(row) = row else {
            break;
        };
        let label = row.token.as_deref().unwrap_or("");
        let component = row.component.as_str();
        if label.len() as u64 > maximum_piece {
            return Err(trace_error(
                "live source label exceeded its admitted display bound",
            ));
        }
        // Use the admission-time maximum label for every fragment. Recomputing
        // with a shorter actual label changes the row count and64-byte padding;
        // that can increase total serialized bytes despite the shorter label.
        let chunk = chunk_rows(
            row.values.len(),
            maximum_piece,
            component.len() as u64,
            record_frame,
            batch_bytes,
        )?;
        for (chunk_id, values) in row.values.chunks(chunk).enumerate() {
            if queue
                .state
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .cancelled
            {
                return Err(trace_error("live writer cancelled"));
            }
            let n = values.len();
            let mut prompt = UInt32Builder::with_capacity(n);
            let mut positions = UInt32Builder::with_capacity(n);
            let mut tokens = StringBuilder::with_capacity(
                n,
                n.checked_mul(label.len())
                    .ok_or_else(|| trace_error("live string allocation overflow"))?,
            );
            let mut layers = UInt32Builder::with_capacity(n);
            let mut components = StringBuilder::with_capacity(n, n * component.len());
            let mut neurons = UInt32Builder::with_capacity(n);
            let mut output = Float32Builder::with_capacity(n);
            for (offset, &value) in values.iter().enumerate() {
                prompt.append_value(row.prompt_id);
                positions.append_value(row.token_pos);
                if row.token.is_some() {
                    tokens.append_value(label);
                } else {
                    tokens.append_null();
                }
                layers.append_value(row.layer);
                components.append_value(component);
                neurons.append_value((chunk_id * chunk + offset) as u32);
                output.append_value(value);
            }
            let columns: Vec<ArrayRef> = vec![
                Arc::new(prompt.finish()),
                Arc::new(positions.finish()),
                Arc::new(tokens.finish()),
                Arc::new(layers.finish()),
                Arc::new(components.finish()),
                Arc::new(neurons.finish()),
                Arc::new(output.finish()),
            ];
            let batch = RecordBatch::try_new(schema.clone(), columns)
                .map_err(|e| trace_error(e.to_string()))?;
            let before = writer.get_ref().written;
            writer
                .write(&batch)
                .map_err(|e| trace_error(e.to_string()))?;
            if writer.get_ref().written - before > batch_bytes {
                return Err(trace_error(
                    "encoded live Arrow batch exceeds its advertised bound",
                ));
            }
            total = total
                .checked_add(n as u64)
                .ok_or_else(|| trace_error("live Arrow row count overflow"))?;
        }
    }
    writer.finish().map_err(|e| trace_error(e.to_string()))?;
    Ok(Complete {
        file: owner,
        rows: total,
        bytes: writer.get_ref().written,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use arrow_array::{Float32Array, UInt32Array};
    use arrow_ipc::reader::StreamReader;
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(1);
    fn setup() -> (LiveRequest, LiveEstimate, PathBuf) {
        let mut req = crate::live_state::tests::request();
        let dir = std::env::temp_dir().join(format!(
            "relm-live-spill-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        req.spill_dir = dir.to_string_lossy().into_owned();
        req.spill = true;
        req.top = 0;
        req.budget_bytes = req.r_fixed_bytes;
        let mut meta = crate::live_state::tests::metadata();
        meta.hidden_size = 5000;
        meta.max_token_piece_bytes = 9;
        let estimate = req.preflight(&meta, 2).unwrap();
        assert!(estimate.spilled);
        (req, estimate, dir)
    }
    fn row(layer: u32, component: crate::Component, width: usize) -> CaptureRow {
        CaptureRow {
            prompt_id: 0,
            token_pos: 11,
            layer,
            component,
            token: Some("<x>".into()),
            values: (0..width)
                .map(|n| n as f32 + layer as f32 * 10000.0)
                .collect(),
        }
    }
    #[test]
    fn live_spill_completed_fragments_and_delivery_ownership() {
        let (req, e, dir) = setup();
        let writer = LiveSpillSink::new(&req, &e, 1, 12, 11, 0, Arc::default()).unwrap();
        for &layer in &req.layers {
            for &comp in &req.components {
                writer.push(row(layer, comp, e.hidden_size)).unwrap();
            }
        }
        let mut completed = writer.finish().unwrap();
        let path = PathBuf::from(&completed.report.path);
        assert!(path.exists());
        assert!(completed.serialized_bytes <= e.spill_bytes / 2);
        let reader = StreamReader::try_new(File::open(&path).unwrap(), None).unwrap();
        let metadata = reader.schema().metadata().clone();
        assert_eq!(metadata["relm.position_space"], "model_context");
        assert_eq!(metadata["relm.source_pos"], "12");
        assert_eq!(metadata["relm.prompt_token_count"], "12");
        assert_eq!(metadata["relm.state_id"], "1");
        assert_eq!(metadata["relm.spec"], completed.spec_key);
        assert_eq!(metadata["relm.live_batch_bytes"], e.batch_bytes.to_string());
        let mut total = 0;
        for batch in reader {
            let batch = batch.unwrap();
            assert!(batch.num_rows() <= LIVE_BATCH_ROWS);
            let neuron = batch
                .column(5)
                .as_any()
                .downcast_ref::<UInt32Array>()
                .unwrap();
            let layer = batch
                .column(3)
                .as_any()
                .downcast_ref::<UInt32Array>()
                .unwrap();
            let value = batch
                .column(6)
                .as_any()
                .downcast_ref::<Float32Array>()
                .unwrap();
            for i in 0..batch.num_rows() {
                assert_eq!(neuron.value(i) as usize, total % e.hidden_size);
                assert_eq!(
                    value.value(i),
                    neuron.value(i) as f32 + layer.value(i) as f32 * 10000.0
                );
                total += 1;
            }
        }
        assert_eq!(total as u64, e.n_values);
        completed.delivered();
        drop(completed);
        assert!(path.exists());
        std::fs::remove_file(&path).unwrap();
        let writer = LiveSpillSink::new(&req, &e, 2, 12, 11, 0, Arc::default()).unwrap();
        for &layer in &req.layers {
            for &comp in &req.components {
                writer.push(row(layer, comp, e.hidden_size)).unwrap();
            }
        }
        let undelivered = writer.finish().unwrap();
        let path = PathBuf::from(&undelivered.report.path);
        drop(undelivered);
        assert!(!path.exists());
        std::fs::remove_dir(dir).unwrap();
    }
    #[test]
    fn live_spill_writer_failure_and_cancel_remove_unpublished_files() {
        let (req, mut e, dir) = setup();
        e.spill_bytes = 1;
        let writer = LiveSpillSink::new(&req, &e, 1, 12, 11, 0, Arc::default()).unwrap();
        assert!(writer.finish().is_err());
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 0);
        let (_, e, _) = setup();
        let cancel = Arc::new(LiveCancel::default());
        let writer = LiveSpillSink::new(&req, &e, 2, 12, 11, 0, cancel.clone()).unwrap();
        cancel.cancel();
        assert!(writer
            .push(row(0, crate::Component::Residual, e.hidden_size))
            .is_err());
        drop(writer);
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 0);
        std::fs::remove_dir(dir).unwrap();
    }
    #[test]
    fn live_spill_padding_boundary_preserves_per_file_and_call_bounds() {
        let (mut req, _, dir) = setup();
        req.layers = vec![0];
        req.components = vec![crate::Component::Residual];
        let mut meta = crate::live_state::tests::metadata();
        meta.hidden_size = 4096;
        meta.max_token_piece_bytes = 8082;
        let e = req.preflight(&meta, 2).unwrap();
        let component = crate::Component::Residual.as_str();
        let admitted_n = chunk_rows(
            e.hidden_size,
            8082,
            component.len() as u64,
            e.record_frame_bytes,
            e.batch_bytes,
        )
        .unwrap();
        let adaptive_n = chunk_rows(
            e.hidden_size,
            8080,
            component.len() as u64,
            e.record_frame_bytes,
            e.batch_bytes,
        )
        .unwrap();
        assert_eq!(admitted_n, 128);
        assert_eq!(adaptive_n, 129);
        let mut total = 0;
        for state_id in 1..=2 {
            let writer =
                LiveSpillSink::new(&req, &e, state_id, 12, 11, total, Arc::default()).unwrap();
            let mut value = row(0, crate::Component::Residual, e.hidden_size);
            value.token = Some("x".repeat(8080));
            writer.push(value).unwrap();
            let completed = writer.finish().unwrap();
            // These are bytes from actual IPC encoding/writes, including schema,
            // record padding and EOS. The old adaptive129-row writer exceeds
            // the per-file estimate by4,480 body bytes for this boundary.
            assert!(completed.serialized_bytes <= e.spill_bytes / 2);
            total += completed.serialized_bytes;
            assert!(total <= e.spill_bytes);
            let reader =
                StreamReader::try_new(File::open(&completed.report.path).unwrap(), None).unwrap();
            let mut batches = 0;
            let mut rows = 0;
            for batch in reader {
                let batch = batch.unwrap();
                assert_eq!(batch.num_rows(), admitted_n);
                batches += 1;
                rows += batch.num_rows();
            }
            assert_eq!(batches, 32);
            assert_eq!(rows, e.hidden_size);
            drop(completed);
        }
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 0);
        std::fs::remove_dir(dir).unwrap();
    }
    #[test]
    fn live_spill_shorter_label_body_fits_reserved_workspace() {
        use arrow_array::{ArrayRef, StringArray};
        use arrow_ipc::writer::{DictionaryTracker, IpcDataGenerator, IpcWriteOptions};
        let (mut req, _, _) = setup();
        req.layers = vec![0];
        req.components = vec![crate::Component::Residual];
        let mut meta = crate::live_state::tests::metadata();
        meta.hidden_size = 64;
        meta.max_token_piece_bytes = 600_000;
        let e = req.preflight(&meta, 1).unwrap();
        let component = crate::Component::Residual.as_str();
        let worst_n = chunk_rows(
            e.hidden_size,
            600_000,
            component.len() as u64,
            e.record_frame_bytes,
            e.batch_bytes,
        )
        .unwrap();
        let actual_n = chunk_rows(
            e.hidden_size,
            250_000,
            component.len() as u64,
            e.record_frame_bytes,
            e.batch_bytes,
        )
        .unwrap();
        assert!(actual_n > worst_n);
        let label = "x".repeat(250_000);
        let integers: ArrayRef = Arc::new(UInt32Array::from(vec![1; actual_n]));
        let tokens: ArrayRef = Arc::new(StringArray::from(vec![label.as_str(); actual_n]));
        let components: ArrayRef = Arc::new(StringArray::from(vec![component; actual_n]));
        let values: ArrayRef = Arc::new(Float32Array::from(vec![1.0; actual_n]));
        let schema = schema("test", "synthetic", "live-test", 1, 12, 11, e.batch_bytes);
        let batch = RecordBatch::try_new(
            schema,
            vec![
                integers.clone(),
                integers.clone(),
                tokens,
                integers.clone(),
                components,
                integers,
                values,
            ],
        )
        .unwrap();
        let (_, encoded) = IpcDataGenerator::default()
            .encode(
                &batch,
                &mut DictionaryTracker::new(false),
                &IpcWriteOptions::default(),
                &mut Default::default(),
            )
            .unwrap();
        assert!(
            encoded.arrow_data.len() as u64
                > body_bound(worst_n as u64, 600_000, component.len() as u64).unwrap()
        );
        assert_eq!(e.arrow_body_bytes, e.batch_bytes - e.record_frame_bytes);
        assert!(encoded.arrow_data.len() as u64 <= e.arrow_body_bytes);
        assert!(encoded.arrow_data.capacity() as u64 <= 2 * e.arrow_body_bytes);
    }
    #[test]
    fn live_spill_long_label_uses_one_row_above_internal_target() {
        let (mut req, _, dir) = setup();
        req.layers = vec![0];
        req.components = vec![crate::Component::Residual];
        let mut meta = crate::live_state::tests::metadata();
        meta.hidden_size = 1;
        meta.max_token_piece_bytes = 3 * 400_000;
        let e = req.preflight(&meta, 1).unwrap();
        assert!(e.batch_bytes > crate::LIVE_BATCH_BYTES);
        let writer = LiveSpillSink::new(&req, &e, 1, 12, 11, 0, Arc::default()).unwrap();
        let mut value = row(0, crate::Component::Residual, 1);
        value.token = Some("x".repeat(1_100_000));
        writer.push(value).unwrap();
        let completed = writer.finish().unwrap();
        assert!(completed.serialized_bytes > crate::LIVE_BATCH_BYTES);
        assert!(completed.serialized_bytes <= e.spill_bytes);
        let reader =
            StreamReader::try_new(File::open(&completed.report.path).unwrap(), None).unwrap();
        assert_eq!(reader.map(|b| b.unwrap().num_rows()).sum::<usize>(), 1);
        drop(completed);
        std::fs::remove_dir(dir).unwrap();
    }
    #[test]
    fn live_spill_full_queue_cancel_wakes_producer() {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut rows = VecDeque::with_capacity(1);
        rows.push_back(row(0, crate::Component::Residual, 1));
        let queue = Arc::new(Queue {
            limit: LIVE_TRANSPORT_BYTES as usize,
            blocked: Mutex::new(Some(tx)),
            state: Mutex::new(QueueState {
                bytes: std::mem::size_of::<CaptureRow>() + 7,
                rows,
                closed: false,
                cancelled: false,
                error: None,
            }),
            ready: Condvar::new(),
            space: Condvar::new(),
        });
        let cancel = LiveCancel::default();
        cancel.register(&queue);
        let sink = LiveSpillSink {
            queue,
            handle: None,
            report: None,
        };
        let worker = std::thread::spawn(move || sink.push(row(0, crate::Component::Residual, 1)));
        rx.recv_timeout(std::time::Duration::from_secs(5)).unwrap();
        cancel.cancel();
        assert!(worker.join().unwrap().is_err());
    }
}
