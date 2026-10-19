//! Support for Windows TLS destructors (Windows XP compatible).
//!
//! Newer `std` relies on Fiber Local Storage (`FlsAlloc`) to obtain an automatic
//! destructor callback per thread, but `FlsAlloc` is unavailable on Windows XP.
//! Instead we run the destructors manually:
//!
//! * `enable` registers a one-time `atexit` hook that drains the *main* thread's
//!   TLS destructors at process exit.
//! * `run_thread_dtors` is invoked by the std thread wrapper
//!   (`sys::thread::windows::thread_start`) when each spawned thread finishes.
//!
//! Threads not spawned by `std` (e.g. FFI callbacks) will leak their
//! thread-locals, which matches the pre-FLS behaviour and is acceptable here.

use core::sync::atomic::{AtomicBool, Ordering};

use crate::sys::c;

/// Set up the current thread to run its TLS destructors when it finishes.
///
/// On Windows we cannot rely on an OS callback (FLS is XP-unavailable), so the
/// destruction is triggered explicitly: spawned threads call `run_thread_dtors`
/// from their entry point, and the main thread is covered by a one-time `atexit`
/// registration performed here.
pub fn enable() {
    // Register the main-thread destructor hook exactly once per process.
    if !ATEXIT_REGISTERED.swap(true, Ordering::AcqRel) {
        unsafe {
            let res = c::atexit(dtor_atexit);
            if res != 0 {
                rtabort!("failed to register tls atexit hook");
            }
        }
    }
}

static ATEXIT_REGISTERED: AtomicBool = AtomicBool::new(false);

/// Run the destructors registered for the *current* thread, then perform `std`'s
/// thread cleanup. Called by the std thread wrapper and the main-thread `atexit`
/// hook. Safe to call exactly once per thread.
pub fn run_thread_dtors() {
    unsafe {
        #[cfg(target_thread_local)]
        super::super::destructors::run();
        #[cfg(not(target_thread_local))]
        super::super::key::run_dtors();
        crate::rt::thread_cleanup();
    }
}

extern "C" fn dtor_atexit() {
    run_thread_dtors();
}
