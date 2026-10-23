//! Focused CRAN portability control; real extendr calls, no engine or models.
use extendr_api::prelude::*;
use std::cell::Cell;

#[extendr]
fn lookup_probe(env: Environment, name: &str, inherits: bool) -> List {
    struct Guard<'a>(&'a Cell<u32>);
    impl Drop for Guard<'_> {
        fn drop(&mut self) {
            self.0.set(self.0.get() + 1);
        }
    }
    let drops = Cell::new(0);
    let result = {
        let _guard = Guard(&drops);
        let key: Robj = Symbol::from_string(name).into();
        if inherits {
            env.find_var(key)
        } else {
            env.local(key)
        }
    };
    match result {
        Ok(value) => list!(status = "ok", value = value, drops = drops.get() as i32),
        Err(Error::NotFound(_)) => {
            list!(status = "missing", value = (), drops = drops.get() as i32)
        }
        Err(Error::EvalError(_)) => list!(status = "error", value = (), drops = drops.get() as i32),
        Err(e) => list!(
            status = e.to_string(),
            value = (),
            drops = drops.get() as i32
        ),
    }
}

#[extendr]
fn lookup_raw_present(env: Environment, name: &str, inherits: bool) -> Robj {
    let key = Symbol::from_string(name);
    // SAFETY: the R control supplies only existing ordinary bindings; no error
    // or promise is invoked through this raw ABI-signature control.
    unsafe {
        let value = if inherits {
            extendr_ffi::get_var(key.get(), env.get())
        } else {
            extendr_ffi::get_var_in_frame(env.get(), key.get())
        };
        Robj::from_sexp(value)
    }
}

extendr_module! {
    mod lookup;
    fn lookup_probe;
    fn lookup_raw_present;
}
