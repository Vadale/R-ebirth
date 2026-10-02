//! Process-wide native ownership (D-037). A permit reserves the engine even
//! while unbound in transit. Only its bound thread can obtain raw pointers.
//! Guards are deliberately !Send/!Sync; permits carry no R data and are Send.

use crate::RebirthError;
use std::cell::Cell;
use std::marker::PhantomData;
use std::rc::Rc;
use std::sync::{Condvar, Mutex, MutexGuard};
use std::thread::ThreadId;

struct Domain {
    next: u64,
    reserved: Option<u64>,
    owner: Option<ThreadId>,
}
static DOMAIN: Mutex<Domain> = Mutex::new(Domain {
    next: 0,
    reserved: None,
    owner: None,
});
static RELEASED: Condvar = Condvar::new();
thread_local! { static ACTIVE: Cell<Option<u64>> = const { Cell::new(None) }; }

fn state() -> MutexGuard<'static, Domain> {
    DOMAIN.lock().unwrap_or_else(|e| e.into_inner())
}

fn busy(operation: &str) -> RebirthError {
    RebirthError::Busy {
        operation: operation.into(),
        reason: "native execution is already reserved by another operation".into(),
    }
}

/// Exclusive reservation, movable only while no thread is bound to it. The
/// generation nonce prevents stale thread-local capabilities from authorizing
/// access after a reservation has been returned and acquired again.
#[derive(Debug)]
pub struct ExecutionPermit {
    generation: u64,
}
impl ExecutionPermit {
    pub fn try_acquire(operation: &str) -> Result<Self, RebirthError> {
        let mut domain = state();
        if domain.reserved.is_some() {
            return Err(busy(operation));
        }
        domain.next = domain
            .next
            .checked_add(1)
            .expect("native generation exhausted");
        let generation = domain.next;
        domain.reserved = Some(generation);
        Ok(Self { generation })
    }

    /// Bind a reserved execution domain to this thread. Borrowing `&mut self`
    /// prevents transferring or releasing the permit until the guard is gone.
    pub fn enter(&mut self) -> ExecutionGuard<'_> {
        let mut domain = state();
        assert_eq!(
            domain.reserved,
            Some(self.generation),
            "stale native permit"
        );
        assert!(domain.owner.is_none(), "native permit is already bound");
        ACTIVE.with(|active| {
            assert!(active.get().is_none(), "nested native permit binding");
            active.set(Some(self.generation));
        });
        domain.owner = Some(std::thread::current().id());
        ExecutionGuard {
            permit: self,
            _local: PhantomData,
        }
    }
}
impl Drop for ExecutionPermit {
    fn drop(&mut self) {
        let mut domain = state();
        assert_eq!(
            domain.reserved,
            Some(self.generation),
            "stale native permit release"
        );
        assert!(domain.owner.is_none(), "bound native permit release");
        domain.reserved = None;
        RELEASED.notify_all();
    }
}

pub struct ExecutionGuard<'a> {
    permit: &'a mut ExecutionPermit,
    _local: PhantomData<Rc<()>>,
}
impl Drop for ExecutionGuard<'_> {
    fn drop(&mut self) {
        unbind(self.permit.generation);
    }
}
fn unbind(generation: u64) {
    let mut domain = state();
    assert_eq!(domain.reserved, Some(generation), "stale native guard");
    assert_eq!(
        domain.owner,
        Some(std::thread::current().id()),
        "off-thread native guard"
    );
    ACTIVE.with(|active| {
        assert_eq!(
            active.replace(None),
            Some(generation),
            "missing native guard"
        );
    });
    domain.owner = None;
}

/// A synchronous operation's reentrant guard. Admission never waits. R's FFI
/// acquires this before reaching infallible legacy Rust methods, mapping Busy
/// to an R condition. Rust Result-returning methods also acquire it themselves.
pub struct NativeGuard {
    permit: Option<ExecutionPermit>,
    _local: PhantomData<Rc<()>>,
}
impl NativeGuard {
    pub fn try_acquire(operation: &str) -> Result<Self, RebirthError> {
        if ACTIVE.with(|active| active.get().is_some()) {
            assert_current();
            return Ok(Self {
                permit: None,
                _local: PhantomData,
            });
        }
        let mut permit = ExecutionPermit::try_acquire(operation)?;
        // Bind without retaining a self-referential ExecutionGuard.
        let binding = permit.enter();
        std::mem::forget(binding);
        Ok(Self {
            permit: Some(permit),
            _local: PhantomData,
        })
    }

    /// Legacy infallible Rust queries cannot return Busy. FFI callers always
    /// preflight with try_acquire, so this assertion never becomes an R panic.
    pub(crate) fn acquire(operation: &str) -> Self {
        Self::try_acquire(operation).unwrap_or_else(|error| panic!("{error}"))
    }

    /// Native destruction is never concurrent. The R registry defers drops and
    /// invokes them under its permit, hence never waits here. A standalone Rust
    /// owner dropped on another thread may wait for an active operation to end.
    pub(crate) fn for_drop() -> Self {
        loop {
            if let Ok(guard) = Self::try_acquire("native destruction") {
                return guard;
            }
            let domain = state();
            let _domain = RELEASED
                .wait_while(domain, |domain| domain.reserved.is_some())
                .unwrap_or_else(|e| e.into_inner());
        }
    }
}
impl Drop for NativeGuard {
    fn drop(&mut self) {
        if let Some(permit) = self.permit.take() {
            unbind(permit.generation);
            drop(permit);
        }
    }
}

/// Release-build check at every private raw-pointer gateway. Do not weaken to
/// debug_assert: Send/Sync safety depends on this invariant in shipped builds.
pub(crate) fn assert_current() {
    let generation = ACTIVE.with(Cell::get);
    assert!(
        generation.is_some(),
        "native access without an execution permit"
    );
    let domain = state();
    assert_eq!(
        domain.reserved, generation,
        "stale native execution generation"
    );
    assert_eq!(
        domain.owner,
        Some(std::thread::current().id()),
        "off-thread native access"
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    // Rust PR job, debug and release; R-free, no model or backend initialized.
    #[test]
    fn async_domain_handoff_and_release_checks() {
        let mut permit = ExecutionPermit::try_acquire("ownership fixture").unwrap();
        assert!(NativeGuard::try_acquire("overlap").is_err());
        let generation = permit.generation;
        {
            let _bound = permit.enter();
            assert_current();
            assert!(NativeGuard::try_acquire("nested").is_ok());
        }
        assert!(std::panic::catch_unwind(assert_current).is_err());
        let mut permit = std::thread::spawn(move || {
            let _bound = permit.enter();
            assert_current();
            drop(_bound);
            permit
        })
        .join()
        .unwrap();
        {
            let _bound = permit.enter();
            assert_current();
        }
        drop(permit);
        let mut replacement = ExecutionPermit::try_acquire("replacement").unwrap();
        assert_ne!(replacement.generation, generation);
        ACTIVE.with(|active| active.set(Some(generation)));
        assert!(std::panic::catch_unwind(assert_current).is_err());
        ACTIVE.with(|active| active.set(None));
        {
            let _bound = replacement.enter();
            assert_current();
        }
    }
}
