//! System Mutexes (Windows XP compatible)
//!
//! Newer `std` uses `SRWLOCK` here, but `SRWLOCK` is unavailable on Windows XP.
//! `CRITICAL_SECTION` cannot be `const`-initialized, so instead we build a mutex
//! from an atomic state word plus a stack of per-waiter auto-reset events. This
//! keeps `Mutex::new()` a `const fn` (required by the portable wrapper) and uses
//! only XP-native APIs (`CreateEventW`, `WaitForSingleObject`, `SetEvent`,
//! `CloseHandle`).

use crate::cell::UnsafeCell;
use crate::ptr;
use crate::sync::atomic::{AtomicPtr, AtomicU32, Ordering};
use crate::sys::c;

// `SetEvent` is not part of `std`'s pinned Win32 bindings; declare it directly
// (resolves against kernel32, available on every Windows version including XP).
unsafe extern "system" {
    fn SetEvent(h: c::HANDLE) -> c::BOOL;
}

const UNLOCKED: u32 = 0;
const LOCKED: u32 = 1;

// A parked waiter. Lives on the stack of the waiting thread for as long as it is
// parked, so the `next` pointer always references a live `Waiter`.
struct Waiter {
    event: c::HANDLE,
    next: *mut Waiter,
}

pub struct Mutex {
    // 0 = unlocked, 1 = locked.
    state: AtomicU32,
    // Stack of parked waiters (non-empty only while locked with parked threads).
    waiters: AtomicPtr<Waiter>,
}

unsafe impl Send for Mutex {}
unsafe impl Sync for Mutex {}

impl Mutex {
    #[inline]
    pub const fn new() -> Mutex {
        Mutex { state: AtomicU32::new(UNLOCKED), waiters: AtomicPtr::new(ptr::null_mut()) }
    }

    #[inline]
    pub fn lock(&self) {
        if self.state.compare_exchange(UNLOCKED, LOCKED, Ordering::Acquire, Ordering::Relaxed).is_ok() {
            return;
        }
        self.lock_slow();
    }

    #[cold]
    fn lock_slow(&self) {
        // Per-wait parking event allocated on our own stack.
        let w = Waiter {
            event: unsafe { c::CreateEventW(ptr::null_mut(), 0, 0, ptr::null_mut()) },
            next: ptr::null_mut(),
        };
        let w_ptr = &w as *const Waiter as *mut Waiter;
        loop {
            if self.state.load(Ordering::Relaxed) == UNLOCKED {
                if self.state.compare_exchange(UNLOCKED, LOCKED, Ordering::Acquire, Ordering::Relaxed).is_ok()
                {
                    unsafe {
                        c::CloseHandle(w.event);
                    }
                    return;
                }
                continue;
            }
            // Push our waiter onto the stack.
            let head = self.waiters.load(Ordering::Relaxed);
            unsafe {
                (*w_ptr).next = head;
            }
            if self.waiters.compare_exchange(head, w_ptr, Ordering::AcqRel, Ordering::Relaxed).is_ok() {
                break;
            }
        }
        unsafe {
            c::WaitForSingleObject(w.event, c::INFINITE);
            c::CloseHandle(w.event);
        }
        // Ownership was transferred to us by the unlocking thread (it kept
        // `state` at LOCKED and signalled our event).
    }

    #[inline]
    pub fn try_lock(&self) -> bool {
        self.state.compare_exchange(UNLOCKED, LOCKED, Ordering::Acquire, Ordering::Relaxed).is_ok()
    }

    #[inline]
    pub unsafe fn unlock(&self) {
        // Try to hand off to a parked waiter.
        let head = self.waiters.load(Ordering::Acquire);
        if !head.is_null() {
            let next = (*head).next;
            if self.waiters.compare_exchange(head, next, Ordering::AcqRel, Ordering::Relaxed).is_ok() {
                // Keep the lock held for the woken thread and wake it.
                self.state.store(LOCKED, Ordering::Release);
                SetEvent((*head).event);
                return;
            }
            // Lost the pop race; fall through to a plain release.
        }
        self.state.store(UNLOCKED, Ordering::Release);
    }
}
