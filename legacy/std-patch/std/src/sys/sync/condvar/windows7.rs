//! Condition variables (Windows XP compatible)
//!
//! Newer `std` uses `CONDITION_VARIABLE` (Vista+) together with `SRWLOCK`. Since
//! we target XP, we implement the condition variable on top of a lazily-created
//! *manual-reset* event plus a "missed wakeup" counter. `notify_all` simply
//! credits `waiters` missed wakeups and pulses the (manual-reset) event once,
//! which lets every parked waiter drain one wakeup and re-acquire the mutex.

use crate::cell::UnsafeCell;
use crate::ptr;
use crate::sync::atomic::{AtomicU32, Ordering};
use crate::sys::c;
use crate::sys::sync::Mutex;
use crate::time::{Duration, Instant};

// `SetEvent`/`ResetEvent` are not part of `std`'s pinned Win32 bindings; declare
// them directly (resolve against kernel32, available on every Windows version
// including XP).
unsafe extern "system" {
    fn SetEvent(h: c::HANDLE) -> c::BOOL;
    fn ResetEvent(h: c::HANDLE) -> c::BOOL;
}

pub struct Condvar {
    // Number of threads currently parked in `wait`.
    waiters: AtomicU32,
    // Number of pending wakeups not yet consumed by a waiter.
    missed: AtomicU32,
    // Lazily created manual-reset event.
    event: UnsafeCell<c::HANDLE>,
    event_state: AtomicU32, // 0 = uninit, 1 = initializing, 2 = ready
}

unsafe impl Send for Condvar {}
unsafe impl Sync for Condvar {}

impl Condvar {
    #[inline]
    pub const fn new() -> Condvar {
        Condvar {
            waiters: AtomicU32::new(0),
            missed: AtomicU32::new(0),
            event: UnsafeCell::new(ptr::null_mut()),
            event_state: AtomicU32::new(0),
        }
    }

    #[cold]
    fn blocking_event(&self) -> c::HANDLE {
        if self.event_state.load(Ordering::Acquire) == 2 {
            return unsafe { *self.event.get() };
        }
        match self.event_state.compare_exchange(0, 1, Ordering::AcqRel, Ordering::Acquire) {
            Ok(_) => {
                // Manual-reset event (bManualReset = 1) so a single pulse can
                // release every parked waiter for `notify_all`.
                let h = unsafe { c::CreateEventW(ptr::null_mut(), 1, 0, ptr::null_mut()) };
                unsafe {
                    *self.event.get() = h;
                }
                self.event_state.store(2, Ordering::Release);
                h
            }
            Err(_) => {
                while self.event_state.load(Ordering::Acquire) != 2 {
                    crate::hint::spin_loop();
                }
                unsafe { *self.event.get() }
            }
        }
    }

    #[inline]
    pub unsafe fn wait(&self, mutex: &Mutex) {
        self.waiters.fetch_add(1, Ordering::AcqRel);
        mutex.unlock();
        let h = self.blocking_event();
        loop {
            let m = self.missed.load(Ordering::Acquire);
            if m > 0 {
                if self.missed.compare_exchange(m, m - 1, Ordering::AcqRel, Ordering::Relaxed).is_ok() {
                    if self.missed.load(Ordering::Acquire) == 0 {
                        ResetEvent(h);
                    }
                    break;
                }
                continue;
            }
            c::WaitForSingleObject(h, c::INFINITE);
        }
        self.waiters.fetch_sub(1, Ordering::AcqRel);
        mutex.lock();
    }

    pub unsafe fn wait_timeout(&self, mutex: &Mutex, dur: Duration) -> bool {
        self.waiters.fetch_add(1, Ordering::AcqRel);
        mutex.unlock();
        let h = self.blocking_event();
        let deadline = Instant::now().checked_add(dur);
        let mut timed_out = false;
        loop {
            let m = self.missed.load(Ordering::Acquire);
            if m > 0 {
                if self.missed.compare_exchange(m, m - 1, Ordering::AcqRel, Ordering::Relaxed).is_ok() {
                    if self.missed.load(Ordering::Acquire) == 0 {
                        ResetEvent(h);
                    }
                    break;
                }
                continue;
            }
            let remain = match deadline {
                Some(d) => d.saturating_duration_since(Instant::now()),
                None => dur,
            };
            if remain.is_zero() {
                timed_out = true;
                break;
            }
            let ms = crate::sys::pal::dur2timeout(remain);
            let r = c::WaitForSingleObject(h, ms);
            if r == c::WAIT_TIMEOUT {
                timed_out = true;
                break;
            }
        }
        self.waiters.fetch_sub(1, Ordering::AcqRel);
        mutex.lock();
        !timed_out
    }

    #[inline]
    pub fn notify_one(&self) {
        if self.waiters.load(Ordering::Acquire) > 0 {
            self.missed.fetch_add(1, Ordering::AcqRel);
            let h = self.blocking_event();
            unsafe {
                SetEvent(h);
            }
        }
    }

    #[inline]
    pub fn notify_all(&self) {
        let w = self.waiters.load(Ordering::Acquire);
        if w > 0 {
            self.missed.fetch_add(w, Ordering::AcqRel);
            let h = self.blocking_event();
            unsafe {
                SetEvent(h);
            }
        }
    }
}
