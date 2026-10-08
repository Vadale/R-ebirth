//! Actual projection owner layouts. Runtime arming and callback methods remain test-only.
use crate::{ffi, Component};
use std::sync::{atomic::AtomicBool, Arc, Mutex};
pub(crate) const MAX_SITES: usize = 32;
#[derive(Clone)]
pub(crate) struct Site {
    pub layer: u32,
    pub component: Component,
    pub coef: f64,
    pub direction: Arc<[f64]>,
}

pub(crate) struct Plan {
    pub(crate) width: usize,
    pub(crate) depth: usize,
    pub(crate) sites: Box<[Site]>,
}

#[derive(Clone, Copy, Default, PartialEq, Debug)]
pub(crate) enum Fault {
    #[default]
    None,
    Missing,
    NoWrite,
    WrongSite,
    AfterRow,
    Cancel,
    Panic,
}

#[derive(Clone, Copy, Default, Debug)]
pub(crate) struct Stats {
    pub rows: u64,
    pub read_bytes: u64,
    pub write_bytes: u64,
    pub barriers: u64,
}

#[derive(Clone, Copy, Default)]
pub(crate) struct Proof {
    pub(crate) proven: bool,
    pub(crate) wrappers: Option<u32>,
    pub(crate) buffer: Option<ffi::ProjectionInfo>,
    pub(crate) buffer_reported: bool,
}

pub(crate) struct Probe {
    pub(crate) layer: u32,
    pub(crate) component: Component,
    pub(crate) producer: Box<[f32]>,
    pub(crate) consumer: Box<[f32]>,
    pub(crate) producer_seen: bool,
    pub(crate) consumer_seen: bool,
    pub(crate) edited: bool,
    pub(crate) neuron: usize,
    pub(crate) baseline_signal: f32,
}

#[derive(Debug)]
pub(crate) struct Observation {
    pub position: usize,
    pub layer: u32,
    pub component: Component,
    pub before: bool,
    pub values: Box<[f32]>,
}

pub(crate) struct Witness {
    pub(crate) position: usize,
    pub(crate) layer: u32,
    pub(crate) component: Component,
    pub(crate) dot: f64,
    pub(crate) write: bool,
    pub(crate) before_norm: f64,
    pub(crate) after_norm: f64,
}

pub(crate) struct Audit {
    pub(crate) positions: Box<[usize]>,
    pub(crate) rows: Vec<Observation>,
    pub(crate) witnesses: Vec<Witness>,
    pub(crate) bytes: usize,
}

pub(crate) struct Runtime {
    pub(crate) plan: Arc<Plan>,
    pub(crate) row: Box<[f32]>,
    pub(crate) proofs: [Proof; MAX_SITES],
    pub(crate) seen: [bool; MAX_SITES],
    pub(crate) ready: [bool; MAX_SITES],
    pub(crate) source: usize,
    pub(crate) count: usize,
    pub(crate) marker: usize,
    pub(crate) micro_rows: usize,
    pub(crate) last_only: bool,
    pub(crate) owner: Option<std::thread::ThreadId>,
    pub(crate) failure: Option<&'static str>,
    pub(crate) diagnostic: (u32, u32, i32),
    pub(crate) fault: Fault,
    pub(crate) stats: Stats,
    pub(crate) probe: Option<Box<Probe>>,
    pub(crate) audit: Option<Box<Audit>>,
}

#[derive(Default)]
pub(crate) struct Slot {
    pub(crate) active: AtomicBool,
    pub(crate) poisoned: AtomicBool,
    pub(crate) runtime: Mutex<Option<Box<Runtime>>>,
    pub(crate) timings: Mutex<(f64, f64)>,
}

pub(crate) struct ArithmeticFrame {
    pub(crate) dot: f64,
    pub(crate) value: f64,
}

pub(crate) fn layout_checksum() -> u64 {
    let mut result = 0u64;
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Site, layer) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Site, component) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Site, coef) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Site, direction) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Plan, width) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Plan, depth) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Plan, sites) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Stats, rows) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Stats, read_bytes) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Stats, write_bytes) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Stats, barriers) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Proof, proven) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Proof, wrappers) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Proof, buffer) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Proof, buffer_reported) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Probe, layer) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Probe, component) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Probe, producer) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Probe, consumer) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Probe, producer_seen) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Probe, consumer_seen) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Probe, edited) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Probe, neuron) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Probe, baseline_signal) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Observation, position) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Observation, layer) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Observation, component) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Observation, before) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Observation, values) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Witness, position) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Witness, layer) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Witness, component) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Witness, dot) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Witness, write) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Witness, before_norm) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Witness, after_norm) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Audit, positions) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Audit, rows) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Audit, witnesses) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Audit, bytes) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Runtime, plan) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Runtime, row) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Runtime, proofs) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Runtime, seen) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Runtime, ready) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Runtime, source) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Runtime, count) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Runtime, marker) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Runtime, micro_rows) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Runtime, last_only) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Runtime, owner) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Runtime, failure) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Runtime, diagnostic) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Runtime, fault) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Runtime, stats) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Runtime, probe) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Runtime, audit) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Slot, active) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Slot, poisoned) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Slot, runtime) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(Slot, timings) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(ArithmeticFrame, dot) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(ArithmeticFrame, value) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(ffi::ProjectionInfo, rows) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(ffi::ProjectionInfo, bytes) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(ffi::ProjectionInfo, wrappers) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(ffi::ProjectionInfo, access) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(ffi::ProjectionInfo, buffer) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(ffi::ProjectionBufferInfo, kind) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(ffi::ProjectionBufferInfo, is_host) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(ffi::ProjectionBufferInfo, usage) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(ffi::ProjectionBufferInfo, device_type) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(ffi::ProjectionBufferInfo, flags) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(ffi::ProjectionBufferInfo, device_index) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(ffi::ProjectionBufferInfo, type_name) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(ffi::ProjectionBufferInfo, device_name) as u64);
    result = result
        .wrapping_mul(31)
        .wrapping_add(std::mem::offset_of!(ffi::ProjectionBufferInfo, registry_name) as u64);
    let variants = [
        Fault::None,
        Fault::Missing,
        Fault::NoWrite,
        Fault::WrongSite,
        Fault::AfterRow,
        Fault::Cancel,
        Fault::Panic,
    ];
    result.wrapping_add(variants.len() as u64)
}
