//! Disk spill for `llm_trace()` (WP4 Step 5, D-013), behind the `spill` feature.
//!
//! When a capture's predicted size exceeds the budget and `spill = TRUE`, the
//! captured rows are streamed to an Arrow-IPC file on disk instead of being held
//! in memory (the 16 GB rule; ARCHITECTURE.md section 6). This module owns the
//! writer thread — the project's FIRST background thread (D-008 gate G2).
//!
//! # G2 discipline
//!
//! The thread receives ONLY owned plain [`CaptureRow`] data over a bounded
//! channel — never an `Robj`/`SEXP` or a `Model`/`Context` handle (those stay on
//! the R main thread, ARCHITECTURE.md section 3). The channel is bounded, so a
//! writer that falls behind exerts backpressure on the capture rather than
//! buffering without limit (unbounded buffering is WP4-forbidden).
//!
//! # On-disk format (Addendum items 4/5, verified at implementation)
//!
//! **Arrow-IPC STREAM format**, not the file format. The day-1 reader check
//! (addendum item 4) settled it: the pinned reader (`nanoarrow` 0.8, CRAN) reads
//! IPC *streams* only — `read_nanoarrow()` reads
//! `application/vnd.apache.arrow.stream`, and nanoarrow ships no Arrow *file*
//! (footer / random-access) reader. So the file format's footer-based random
//! access is unavailable; we write the stream format and the R side skips to a
//! `(prompt, layer)` slice by pulling record batches sequentially from the lazy
//! `nanoarrow` array stream (`read_nanoarrow(path, lazy = TRUE)`), stopping once
//! it has the batches it needs.
//!
//! The schema is the 7 `rebirth_trace` columns (API-GRAMMAR.md section 2).
//! `value` is stored as **float32** (the engine truth; R widens it to double on
//! read, exact) — a nanoarrow-supported primitive that halves the dominant
//! column at zero information cost (addendum item 5).
//!
//! **`token`/`component` are stored as plain UTF-8, NOT dictionary-encoded.**
//! Addendum item 5 proposed dictionary encoding, but the day-1 reader check
//! (addendum item 4, run at implementation) found the pinned `nanoarrow` 0.8 IPC
//! reader rejects dictionary-encoded IPC schemas outright — a real stream from
//! this writer read back with `read_nanoarrow()` fails with
//! `"Schema message field with DictionaryEncoding not supported"`, on both the
//! eager and the lazy path. Since the round-trip through the pinned reader is the
//! binding acceptance and dictionary encoding is a size optimization, not a
//! correctness requirement, `token`/`component` are written as plain UTF-8 (the
//! same fail-loud-then-fall-back discipline the addendum applies to the file-vs-
//! stream choice). The float32 `value` — the file's dominant column — already
//! captures most of the size saving. Revisit dictionary encoding if/when the
//! pinned nanoarrow gains IPC dictionary support.
//!
//! Indices are engine-native (0-based) on disk — the crate stays 0-based
//! throughout (ARCHITECTURE.md section 4) — and the R reader applies the same
//! 1-based shift the in-memory boundary applies. The round-trip test asserts the
//! spilled slice equals the in-memory slice, so the two conversion sites cannot
//! silently diverge. Record batches are chunked by `(prompt, layer)` so a reader
//! can skip to a slice. The schema metadata carries the integrity strings
//! (format version, trace id, model, capture-spec key) the R side authored, for
//! the staleness fail-safe (a reopened file whose spec != the object's
//! attributes → `rebirth_error_trace`).

use std::collections::HashMap;
use std::fs::File;
use std::sync::mpsc::{sync_channel, Receiver, SyncSender};
use std::sync::Arc;
use std::thread::JoinHandle;

use arrow_array::builder::{Float32Builder, StringBuilder, UInt32Builder};
use arrow_array::{ArrayRef, RecordBatch};
use arrow_ipc::writer::StreamWriter;
use arrow_schema::{DataType, Field, Schema, SchemaRef};

use crate::error::RebirthError;
use crate::trace::CaptureRow;

/// Bounded channel depth (in [`CaptureRow`]s). Small enough that the buffered
/// rows stay a few MB even for a wide model (one row is `n_embd` f32), large
/// enough that the writer thread is rarely starved between the callback's bursts.
const CHANNEL_BOUND: usize = 256;

/// Schema-metadata keys for the integrity footer. The R side authors the values
/// (opaque strings) and compares them on read; the writer treats them as opaque.
pub const META_FORMAT: &str = "rebirth.spill_format";
pub const META_TRACE_ID: &str = "rebirth.trace_id";
pub const META_MODEL: &str = "rebirth.model";
pub const META_SPEC: &str = "rebirth.spec";
/// Bumped if the on-disk layout changes so an old reader refuses a new file.
pub const FORMAT_VERSION: &str = "1";

/// The integrity/routing data the writer needs, all supplied by the R boundary.
pub struct SpillMeta {
    /// Absolute path of the `.arrow` file to write.
    pub path: String,
    /// Per-trace identity (R-authored) for the staleness fail-safe.
    pub trace_id: String,
    /// The model identifier (its path) the object also records.
    pub model: String,
    /// A canonical capture-spec string the object also records.
    pub spec: String,
    /// Row width; every [`CaptureRow`] carries exactly this many `values`.
    pub n_embd: usize,
}

/// A running disk-spill target: a bounded [`SyncSender`] feeding a writer thread.
/// [`push`](Self::push) hands owned rows across; [`finish`](Self::finish) closes
/// the channel and joins the thread, returning the number of long-format rows
/// written. Dropping without `finish` still joins the thread (no leak).
pub struct SpillSink {
    sender: Option<SyncSender<CaptureRow>>,
    handle: Option<JoinHandle<Result<u64, RebirthError>>>,
}

impl SpillSink {
    /// Create the file and spawn the writer thread. The thread holds only the
    /// file, the receiver, and the schema — no handle (G2).
    pub fn new(meta: SpillMeta) -> Result<SpillSink, RebirthError> {
        let file = File::create(&meta.path).map_err(|e| RebirthError::Trace {
            reason: format!(
                "Could not open the spill file '{}' for writing ({e}). \
                 Check the spill directory exists and is writable, or pass a \
                 different spill_dir.",
                meta.path
            ),
        })?;
        let (sender, receiver) = sync_channel::<CaptureRow>(CHANNEL_BOUND);
        let handle = std::thread::Builder::new()
            .name("rebirth-spill".to_string())
            .spawn(move || writer_loop(file, receiver, meta))
            .map_err(|e| RebirthError::Trace {
                reason: format!("Could not start the disk-spill writer thread ({e})."),
            })?;
        Ok(SpillSink {
            sender: Some(sender),
            handle: Some(handle),
        })
    }

    /// Hand one captured row to the writer thread, blocking (backpressure) when
    /// the bounded channel is full. A send error means the writer thread has
    /// stopped (an I/O failure); the specific cause surfaces from [`finish`].
    pub fn push(&self, row: CaptureRow) -> Result<(), RebirthError> {
        match &self.sender {
            Some(sender) => sender.send(row).map_err(|_| RebirthError::Trace {
                reason: "The disk-spill writer stopped early. The disk may be full \
                         or the spill directory may have become unwritable."
                    .to_string(),
            }),
            None => Ok(()),
        }
    }

    /// Close the channel, join the writer thread, and return the row count.
    pub fn finish(mut self) -> Result<u64, RebirthError> {
        self.sender = None; // hang up so the writer sees the channel close
        match self.handle.take() {
            Some(handle) => match handle.join() {
                Ok(result) => result,
                Err(_) => Err(RebirthError::Internal {
                    context: "the disk-spill writer thread panicked".to_string(),
                }),
            },
            None => Ok(0),
        }
    }
}

impl Drop for SpillSink {
    fn drop(&mut self) {
        // Cleanup path (an aborted capture): hang up and join so the thread is
        // never leaked. The writer's result is discarded — the caller surfaces
        // the capture error and removes the partial file.
        self.sender = None;
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

/// The writer thread: drain the channel, group contiguous rows by `(prompt,
/// layer)`, and write one Arrow record batch per group. Returns the number of
/// long-format rows written, or the first I/O/encoding error.
fn writer_loop(
    file: File,
    receiver: Receiver<CaptureRow>,
    meta: SpillMeta,
) -> Result<u64, RebirthError> {
    let schema = Arc::new(build_schema(&meta));
    let mut writer = StreamWriter::try_new(file, &schema).map_err(arrow_err)?;

    let mut group: Vec<CaptureRow> = Vec::new();
    let mut group_key: Option<(u32, u32)> = None;
    let mut total_rows: u64 = 0;

    // Rows for one (prompt, layer) arrive contiguously (the graph computes a
    // block's tapped tensors before the next block's, and prompts run
    // sequentially), so flushing on key change batches by (prompt, layer). If an
    // ordering surprise ever split a group, the extra batch is still correct —
    // the reader concatenates every batch for the requested (prompt, layer).
    for row in receiver.iter() {
        let key = (row.prompt_id, row.layer);
        if group_key.is_some() && group_key != Some(key) {
            total_rows += flush_group(&mut writer, &schema, &group, meta.n_embd)?;
            group.clear();
        }
        group_key = Some(key);
        group.push(row);
    }
    if !group.is_empty() {
        total_rows += flush_group(&mut writer, &schema, &group, meta.n_embd)?;
    }

    writer.finish().map_err(arrow_err)?;
    Ok(total_rows)
}

/// The 7-column `rebirth_trace` schema with the on-disk encodings (float32
/// `value`, plain UTF-8 `token`/`component` — see the module note on why not
/// dictionary) plus the integrity metadata.
fn build_schema(meta: &SpillMeta) -> Schema {
    let fields = vec![
        Field::new("prompt_id", DataType::UInt32, false),
        Field::new("token_pos", DataType::UInt32, false),
        Field::new("token", DataType::Utf8, true),
        Field::new("layer", DataType::UInt32, false),
        Field::new("component", DataType::Utf8, false),
        Field::new("neuron", DataType::UInt32, false),
        Field::new("value", DataType::Float32, false),
    ];
    let mut metadata = HashMap::new();
    metadata.insert(META_FORMAT.to_string(), FORMAT_VERSION.to_string());
    metadata.insert(META_TRACE_ID.to_string(), meta.trace_id.clone());
    metadata.insert(META_MODEL.to_string(), meta.model.clone());
    metadata.insert(META_SPEC.to_string(), meta.spec.clone());
    Schema::new(fields).with_metadata(metadata)
}

/// Expand one `(prompt, layer)` group of [`CaptureRow`]s into a record batch:
/// each captured row (one `(prompt, pos, layer, component)`) becomes `n_embd`
/// long-format rows, one per neuron. Returns the batch's row count.
fn flush_group(
    writer: &mut StreamWriter<File>,
    schema: &SchemaRef,
    group: &[CaptureRow],
    n_embd: usize,
) -> Result<u64, RebirthError> {
    let n_rows = group.len() * n_embd;
    let mut prompt_id = UInt32Builder::with_capacity(n_rows);
    let mut token_pos = UInt32Builder::with_capacity(n_rows);
    let mut token = StringBuilder::new();
    let mut layer = UInt32Builder::with_capacity(n_rows);
    let mut component = StringBuilder::new();
    let mut neuron = UInt32Builder::with_capacity(n_rows);
    let mut value = Float32Builder::with_capacity(n_rows);

    for row in group {
        let comp = row.component.as_str();
        for (k, &v) in row.values.iter().enumerate() {
            prompt_id.append_value(row.prompt_id);
            token_pos.append_value(row.token_pos);
            match &row.token {
                Some(piece) => token.append_value(piece),
                None => token.append_null(),
            }
            layer.append_value(row.layer);
            component.append_value(comp);
            neuron.append_value(k as u32);
            value.append_value(v);
        }
    }

    let columns: Vec<ArrayRef> = vec![
        Arc::new(prompt_id.finish()),
        Arc::new(token_pos.finish()),
        Arc::new(token.finish()),
        Arc::new(layer.finish()),
        Arc::new(component.finish()),
        Arc::new(neuron.finish()),
        Arc::new(value.finish()),
    ];
    let batch = RecordBatch::try_new(schema.clone(), columns).map_err(arrow_err)?;
    writer.write(&batch).map_err(arrow_err)?;
    Ok(n_rows as u64)
}

/// Map an Arrow error to a classed trace error (the R user sees
/// `rebirth_error_trace` — a spill write failed).
fn arrow_err<E: std::fmt::Display>(e: E) -> RebirthError {
    RebirthError::Trace {
        reason: format!(
            "Failed to write the activation trace to its spill file ({e}). \
             The disk may be full or the spill directory unwritable."
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::trace::Component;

    /// Build a handful of `CaptureRow`s spanning two prompts x two layers so the
    /// writer emits multiple `(prompt, layer)` batches (exercising dictionary
    /// replacement across batches — the exact case the nanoarrow reader must
    /// handle). Distinct token pieces per prompt make the per-batch dictionaries
    /// genuinely differ.
    fn sample_rows(n_embd: usize) -> Vec<CaptureRow> {
        let mut rows = Vec::new();
        for prompt_id in 0..2u32 {
            for layer in 0..2u32 {
                for token_pos in 0..2u32 {
                    let values: Vec<f32> = (0..n_embd)
                        .map(|k| {
                            (prompt_id * 1000 + layer * 100 + token_pos * 10 + k as u32) as f32
                                + 0.5
                        })
                        .collect();
                    rows.push(CaptureRow {
                        prompt_id,
                        token_pos,
                        layer,
                        component: Component::Residual,
                        token: Some(format!("p{prompt_id}_tok{token_pos}")),
                        values,
                    });
                }
            }
        }
        rows
    }

    /// Round-trips rows through the writer thread and asserts the reported row
    /// count. The nanoarrow *read* side is exercised by the R round-trip test
    /// (`test-llm-trace-spill.R`) — this only proves the writer thread drains the
    /// bounded channel, batches by `(prompt, layer)`, and produces a file.
    #[test]
    fn spill_sink_writes_all_rows_and_reports_the_count() {
        let n_embd = 4usize;
        let rows = sample_rows(n_embd);
        let expected_long_rows = rows.len() as u64 * n_embd as u64;

        let mut path = std::env::temp_dir();
        path.push(format!("rebirth-spill-unit-{}.arrow", std::process::id()));
        let path_str = path.to_string_lossy().to_string();

        let sink = SpillSink::new(SpillMeta {
            path: path_str.clone(),
            trace_id: "unit-trace".to_string(),
            model: "unit-model".to_string(),
            spec: "unit-spec".to_string(),
            n_embd,
        })
        .expect("spawn spill writer");

        for row in rows {
            sink.push(row).expect("push row");
        }
        let written = sink.finish().expect("finish spill");
        assert_eq!(
            written, expected_long_rows,
            "reported long-format row count"
        );
        assert!(std::fs::metadata(&path_str).is_ok(), "spill file exists");
        let _ = std::fs::remove_file(&path_str);
    }

    /// A dropped sink (an aborted capture) must join its thread without leaking,
    /// even with rows still queued.
    #[test]
    fn dropping_a_sink_joins_the_writer_thread() {
        let mut path = std::env::temp_dir();
        path.push(format!("rebirth-spill-drop-{}.arrow", std::process::id()));
        let path_str = path.to_string_lossy().to_string();

        let sink = SpillSink::new(SpillMeta {
            path: path_str.clone(),
            trace_id: "t".to_string(),
            model: "m".to_string(),
            spec: "s".to_string(),
            n_embd: 2,
        })
        .expect("spawn spill writer");
        sink.push(CaptureRow {
            prompt_id: 0,
            token_pos: 0,
            layer: 0,
            component: Component::Residual,
            token: None,
            values: vec![1.0, 2.0],
        })
        .expect("push row");
        drop(sink); // must not hang or leak
        let _ = std::fs::remove_file(&path_str);
    }
}
