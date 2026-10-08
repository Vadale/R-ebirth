//! Managed spill lifetimes, independent of inference/model ownership.
//! Registration is memory-only; the filesystem lease is acquired by SpillSink
//! immediately before its first file is created and retained for lazy readers.
use crate::RebirthError;
use std::collections::HashMap;
use std::ffi::{c_char, c_void, CString};
use std::path::{Path, PathBuf};
use std::ptr::NonNull;
use std::sync::Mutex;

extern "C" {
    #[cfg(feature = "spill")]
    fn relm_spill_lease_create(root: *const c_char, leaf: *const c_char) -> *mut c_void;
    fn relm_spill_lease_release(ptr: *mut c_void);
    #[cfg(feature = "spill")]
    fn relm_spill_lease_valid(ptr: *mut c_void) -> i32;
    #[cfg(feature = "spill")]
    fn relm_spill_lease_open(ptr: *mut c_void, name: *const c_char) -> i32;
    fn relm_spill_lease_cleanup(ptr: *mut c_void) -> i32;
    fn relm_spill_lease_sweep(root: *const c_char, leaf: *const c_char, cutoff: f64) -> i32;
}
struct Lease(NonNull<c_void>);
// SAFETY: the opaque object owns only OS descriptors/identity metadata, never R
// or model state. All access is serialized by REGISTRY; close may run on any thread.
unsafe impl Send for Lease {}
impl Drop for Lease {
    fn drop(&mut self) {
        // SAFETY: created by relm_spill_lease_create, owned exactly once here.
        unsafe { relm_spill_lease_release(self.0.as_ptr()) };
    }
}
struct Entry {
    pid: u32,
    lease: Option<Lease>,
}
static REGISTRY: Mutex<Option<HashMap<PathBuf, Entry>>> = Mutex::new(None);

fn invalid(reason: &str) -> RebirthError {
    RebirthError::Trace {
        reason: format!("{reason} Managed spill files were retained. Check cache ownership/permissions or choose a caller-managed spill_dir."),
    }
}
fn parts(path: &Path) -> Result<(CString, CString), RebirthError> {
    let root = path.parent().filter(|_| path.is_absolute());
    let leaf = path.file_name().and_then(|s| s.to_str());
    let root = root.and_then(|s| s.to_str());
    match (root, leaf) {
        (Some(root), Some(leaf)) if !leaf.is_empty() => Ok((
            CString::new(root).map_err(|_| invalid("Invalid spill root."))?,
            CString::new(leaf).map_err(|_| invalid("Invalid spill directory."))?,
        )),
        _ => Err(invalid("Expected an absolute managed spill directory.")),
    }
}

/// Register an R-owned session path without creating anything on disk.
pub fn prepare_managed_spill(path: &str) -> Result<(), RebirthError> {
    let path = PathBuf::from(path);
    parts(&path)?;
    let mut reg = REGISTRY.lock().unwrap_or_else(|e| e.into_inner());
    let entry = reg
        .get_or_insert_with(HashMap::new)
        .entry(path)
        .or_insert(Entry {
            pid: std::process::id(),
            lease: None,
        });
    if entry.pid != std::process::id() {
        return Err(invalid("A spill session cannot be inherited through fork."));
    }
    Ok(())
}

/// Acquire only registered managed paths. Custom paths retain caller ownership.
#[cfg(feature = "spill")]
pub(crate) fn open_managed_spill(path: &Path) -> Result<Option<std::fs::File>, RebirthError> {
    let parent = path
        .parent()
        .ok_or_else(|| invalid("Missing spill parent."))?;
    let mut reg = REGISTRY.lock().unwrap_or_else(|e| e.into_inner());
    let Some(entry) = reg.as_mut().and_then(|r| r.get_mut(parent)) else {
        return Ok(None);
    };
    if entry.pid != std::process::id() {
        return Err(invalid("A spill session cannot be inherited through fork."));
    }
    if let Some(lease) = &entry.lease {
        // SAFETY: the registry exclusively owns this live opaque lease.
        if unsafe { relm_spill_lease_valid(lease.0.as_ptr()) } != 1 {
            return Err(invalid("The managed spill directory was replaced."));
        }
    } else {
        let (root, leaf) = parts(parent)?;
        // SAFETY: NUL-terminated paths live throughout the call; C++ catches errors.
        let ptr = unsafe { relm_spill_lease_create(root.as_ptr(), leaf.as_ptr()) };
        entry.lease = Some(Lease(NonNull::new(ptr).ok_or_else(|| {
            invalid("Could not create a safely leased managed spill directory.")
        })?));
    }
    let name = path
        .file_name()
        .and_then(|p| p.to_str())
        .ok_or_else(|| invalid("Invalid spill filename."))?;
    let name = CString::new(name).map_err(|_| invalid("Invalid spill filename."))?;
    let lease = entry.lease.as_ref().expect("lease acquired above");
    // SAFETY: the mutex retains the lease; openat returns a new exclusively owned
    // descriptor, with no path-based re-open between validation and creation.
    let fd = unsafe { relm_spill_lease_open(lease.0.as_ptr(), name.as_ptr()) };
    if fd < 0 {
        return Err(invalid(
            "Could not create a new file in the leased spill directory.",
        ));
    }
    #[cfg(unix)]
    {
        use std::os::fd::FromRawFd;
        // SAFETY: the native bridge transfers ownership of this valid new fd.
        Ok(Some(unsafe { std::fs::File::from_raw_fd(fd) }))
    }
    #[cfg(not(unix))]
    Err(invalid(
        "Managed spill leases are unavailable on this platform.",
    ))
}

/// Best-effort normal shutdown. Only the registered owner can request deletion.
pub fn cleanup_managed_spill(path: &str) -> bool {
    let mut reg = REGISTRY.lock().unwrap_or_else(|e| e.into_inner());
    let Some(entry) = reg.as_mut().and_then(|r| r.remove(Path::new(path))) else {
        return false;
    };
    if entry.pid != std::process::id() {
        return false;
    }
    entry.lease.is_some_and(|lease| {
        // SAFETY: lease remains alive/locked through deletion and drops afterwards.
        unsafe { relm_spill_lease_cleanup(lease.0.as_ptr()) == 1 }
    })
}

/// Attempt one aged candidate; unknown, live, changed or unsupported paths stay.
pub fn sweep_managed_spill(path: &str, cutoff: f64) -> bool {
    if !cutoff.is_finite() {
        return false;
    }
    let Ok((root, leaf)) = parts(Path::new(path)) else {
        return false;
    };
    // SAFETY: C++ owns and releases the temporary descriptor-relative lease.
    unsafe { relm_spill_lease_sweep(root.as_ptr(), leaf.as_ptr(), cutoff) == 1 }
}
