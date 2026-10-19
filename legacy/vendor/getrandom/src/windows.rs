//! Implementation for Windows (XP-compatible fork).
//!
//! Upstream getrandom 0.2.17 statically links `bcrypt.dll`
//! (BCryptGenRandom, Vista+), which makes the resulting binary
//! un-loadable on Windows XP — the XP loader rejects unknown imports
//! outright. This fork uses `RtlGenRandom` (SystemFunction036 in
//! advapi32) exclusively, available since Windows XP, keeping the
//! import table XP-clean.

use crate::Error;
use core::{ffi::c_void, mem::MaybeUninit};

#[link(name = "advapi32")]
extern "system" {
    #[link_name = "SystemFunction036"]
    fn RtlGenRandom(RandomBuffer: *mut c_void, RandomBufferLength: u32) -> u8;
}

pub fn getrandom_inner(dest: &mut [MaybeUninit<u8>]) -> Result<(), Error> {
    // Prevent overflow of u32
    for chunk in dest.chunks_mut(u32::max_value() as usize) {
        let ret =
            unsafe { RtlGenRandom(chunk.as_mut_ptr() as *mut c_void, chunk.len() as u32) };
        if ret == 0 {
            return Err(Error::WINDOWS_RTL_GEN_RANDOM);
        }
    }
    Ok(())
}
