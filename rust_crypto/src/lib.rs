use aes_gcm::{
    aead::{Aead, KeyInit},
    Aes256Gcm, Nonce,
};
use rayon::prelude::*;
use sha2::{Digest, Sha256};
use std::slice;
use std::sync::Arc;
use std::fs::File;
use std::io::{Read, Write, BufReader, BufWriter, Seek, SeekFrom};
use std::ffi::CStr;
use std::os::raw::c_char;
use rand::RngCore;

/// FFI 边界 panic 兜底宏（v1.2.13）：extern "C" 里的任何 panic 会直接
/// abort 宿主进程（Dart 侧表现为 UI 闪退、托盘残留）。索引链路全部入口
/// 一律经此包裹：panic 时打印现场并返回类型默认值（i32→0、i64→0、()→()），
/// 宿主把非零/零结果当错误码处理，绝不死进程。
macro_rules! ffi_catch {
    ($body:expr) => {
        match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| $body)) {
            Ok(v) => v,
            Err(_) => {
                eprintln!("rust_crypto: FFI panicked, degraded to default");
                Default::default()
            }
        }
    };
}

// NTFS USN Journal 实时文件索引（仅 Windows；其他平台无此模块，Dart 侧须 Platform.isWindows 守卫）
#[cfg(windows)]
mod usn;
// 目录变更实时监视（ReadDirectoryChangesW，Everything 式增量；仅 Windows）
#[cfg(windows)]
mod watcher;
// 微密保险箱：密码库（钥匙环）+ v3 文件格式 + 缩略图（全平台）
mod vault;
// 微密归档容器：文件夹加密（.wemi 归档 format v1，magic WEMI_FARC）
mod archive;
// LANDrop v2 协议加密原语（kx/secp256k1/BLAKE2b/ChaCha20-Poly1305-IETF，libsodium 对拍）
mod landrop;
// 全盘搜索引擎 v2（v1.2.6）：排序打分 + Everything 式语法（搜索升级方案 M1+M2）
mod search;

const NONCE_SIZE: usize = 12;
const TAG_SIZE: usize = 16;
const MAGIC_STRING: &[u8] = b"WEIMI_LOCK";
const VERSION: u32 = 1;
const HEADER_SIZE: usize = 14;
const MAX_HINT_LENGTH: usize = 32;

fn derive_key(password: &[u8]) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(password);
    let result = hasher.finalize();
    let mut key = [0u8; 32];
    key.copy_from_slice(&result);
    key
}

pub(crate) fn get_chunk_size(is_mobile: bool) -> usize {
    if is_mobile {
        128 * 1024 * 1024
    } else {
        256 * 1024 * 1024
    }
}

fn get_parallel_batch_threshold(is_mobile: bool) -> usize {
    if is_mobile {
        512 * 1024 * 1024
    } else {
        1024 * 1024 * 1024
    }
}

fn get_parallel_batch_size(cpu_cores: usize, is_mobile: bool) -> usize {
    if is_mobile {
        ((cpu_cores as f32 * 0.5).round() as usize).clamp(2, 8)
    } else {
        ((cpu_cores as f32 * 0.75).round() as usize).clamp(4, 16)
    }
}

pub(crate) fn generate_nonce() -> [u8; NONCE_SIZE] {
    let mut nonce = [0u8; NONCE_SIZE];
    rand::thread_rng().fill_bytes(&mut nonce);
    nonce
}

#[no_mangle]
pub extern "C" fn encrypt_file(
    input_path_ptr: *const c_char,
    output_path_ptr: *const c_char,
    password_ptr: *const u8,
    password_len: usize,
    hint_ptr: *const c_char,
    is_mobile: bool,
    cpu_cores: usize,
) -> i32 {
    unsafe {
        let input_path = match CStr::from_ptr(input_path_ptr).to_str() {
            Ok(s) => s,
            Err(_) => return -1,
        };
        let output_path = match CStr::from_ptr(output_path_ptr).to_str() {
            Ok(s) => s,
            Err(_) => return -1,
        };
        let password = slice::from_raw_parts(password_ptr, password_len);
        let hint = if hint_ptr.is_null() {
            None
        } else {
            CStr::from_ptr(hint_ptr).to_str().ok()
        };

        match encrypt_file_internal(input_path, output_path, password, hint, is_mobile, cpu_cores) {
            Ok(_) => 0,
            Err(_) => -2,
        }
    }
}

fn encrypt_file_internal(
    input_path: &str,
    output_path: &str,
    password: &[u8],
    hint: Option<&str>,
    is_mobile: bool,
    cpu_cores: usize,
) -> Result<(), Box<dyn std::error::Error>> {
    let chunk_size = get_chunk_size(is_mobile);
    let parallel_threshold = get_parallel_batch_threshold(is_mobile);
    let batch_size = get_parallel_batch_size(cpu_cores, is_mobile);
    
    let input_file = File::open(input_path)?;
    let file_size = input_file.metadata()?.len() as usize;
    
    let mut output_file = BufWriter::new(File::create(output_path)?);
    
    let hint_bytes = hint
        .map(|h| h.as_bytes())
        .unwrap_or(&[])
        .iter()
        .take(MAX_HINT_LENGTH)
        .copied()
        .collect::<Vec<u8>>();
    let hint_len = hint_bytes.len() as u8;
    
    output_file.write_all(MAGIC_STRING)?;
    output_file.write_all(&VERSION.to_le_bytes())?;
    output_file.write_all(&[hint_len])?;
    output_file.write_all(&hint_bytes)?;
    
    let key = derive_key(password);
    let cipher = Aes256Gcm::new_from_slice(&key)?;
    
    if file_size <= chunk_size {
        let nonce_bytes = generate_nonce();
        output_file.write_all(&nonce_bytes)?;
        
        let mut data = Vec::new();
        let mut reader = BufReader::new(input_file);
        reader.read_to_end(&mut data)?;
        
        let nonce = Nonce::from_slice(&nonce_bytes);
        let encrypted = cipher.encrypt(nonce, data.as_ref())
            .map_err(|_| "Encryption failed")?;
        output_file.write_all(&encrypted)?;
    } else if file_size <= parallel_threshold {
        let mut all_data = Vec::new();
        let mut reader = BufReader::new(input_file);
        reader.read_to_end(&mut all_data)?;
        
        let mut chunks = Vec::new();
        let mut nonces = Vec::new();
        
        for chunk in all_data.chunks(chunk_size) {
            chunks.push(chunk.to_vec());
            nonces.push(generate_nonce());
        }
        
        let key_arc = Arc::new(key);
        let encrypted_chunks: Result<Vec<Vec<u8>>, &str> = chunks
            .par_iter()
            .zip(nonces.par_iter())
            .map(|(chunk, nonce_bytes)| {
                let cipher = Aes256Gcm::new_from_slice(&*key_arc)
                    .map_err(|_| "Invalid key")?;
                let nonce = Nonce::from_slice(nonce_bytes);
                cipher.encrypt(nonce, chunk.as_ref())
                    .map_err(|_| "Encryption failed")
            })
            .collect();
        
        let encrypted_chunks = encrypted_chunks?;
        
        for (encrypted, nonce_bytes) in encrypted_chunks.iter().zip(nonces.iter()) {
            output_file.write_all(nonce_bytes)?;
            output_file.write_all(&(encrypted.len() as u32).to_be_bytes())?;
            output_file.write_all(encrypted)?;
        }
    } else {
        let mut reader = BufReader::new(input_file);
        let key_arc = Arc::new(key);
        
        loop {
            let mut chunks = Vec::new();
            let mut nonces = Vec::new();
            
            for _ in 0..batch_size {
                let mut chunk = vec![0u8; chunk_size];
                match reader.read(&mut chunk)? {
                    0 => break,
                    n => {
                        chunk.truncate(n);
                        chunks.push(chunk);
                        nonces.push(generate_nonce());
                    }
                }
            }
            
            if chunks.is_empty() {
                break;
            }
            
            let encrypted_chunks: Result<Vec<Vec<u8>>, &str> = chunks
                .par_iter()
                .zip(nonces.par_iter())
                .map(|(chunk, nonce_bytes)| {
                    let cipher = Aes256Gcm::new_from_slice(&*key_arc)
                        .map_err(|_| "Invalid key")?;
                    let nonce = Nonce::from_slice(nonce_bytes);
                    cipher.encrypt(nonce, chunk.as_ref())
                        .map_err(|_| "Encryption failed")
                })
                .collect();
            
            let encrypted_chunks = encrypted_chunks?;
            
            for (encrypted, nonce_bytes) in encrypted_chunks.iter().zip(nonces.iter()) {
                output_file.write_all(nonce_bytes)?;
                output_file.write_all(&(encrypted.len() as u32).to_be_bytes())?;
                output_file.write_all(encrypted)?;
            }
        }
    }
    
    output_file.flush()?;
    Ok(())
}

#[no_mangle]
pub extern "C" fn decrypt_file(
    input_path_ptr: *const c_char,
    output_path_ptr: *const c_char,
    password_ptr: *const u8,
    password_len: usize,
    is_mobile: bool,
    cpu_cores: usize,
) -> i32 {
    unsafe {
        let input_path = match CStr::from_ptr(input_path_ptr).to_str() {
            Ok(s) => s,
            Err(_) => return -1,
        };
        let output_path = match CStr::from_ptr(output_path_ptr).to_str() {
            Ok(s) => s,
            Err(_) => return -1,
        };
        let password = slice::from_raw_parts(password_ptr, password_len);

        // 输出目录缺失/不可写（缓存被系统清理、存储满）→ -4，与 -2（密码错/损坏）
        // 区分：否则 File::create 失败会被上层误译成「密码不正确」
        if let Some(parent) = std::path::Path::new(output_path).parent() {
            if !parent.as_os_str().is_empty() && !parent.exists() {
                return -4;
            }
        }

        match decrypt_file_internal(input_path, output_path, password, is_mobile, cpu_cores) {
            Ok(_) => 0,
            Err(_) => -2,
        }
    }
}

fn decrypt_file_internal(
    input_path: &str,
    output_path: &str,
    password: &[u8],
    is_mobile: bool,
    cpu_cores: usize,
) -> Result<(), Box<dyn std::error::Error>> {
    let chunk_size = get_chunk_size(is_mobile);
    let parallel_threshold = get_parallel_batch_threshold(is_mobile);
    let batch_size = get_parallel_batch_size(cpu_cores, is_mobile);
    
    let mut input_file = BufReader::new(File::open(input_path)?);
    
    let mut magic = vec![0u8; MAGIC_STRING.len()];
    input_file.read_exact(&mut magic)?;
    if magic != MAGIC_STRING {
        return Err("Invalid file format".into());
    }
    
    let mut version_bytes = [0u8; 4];
    input_file.read_exact(&mut version_bytes)?;
    let version = u32::from_le_bytes(version_bytes);
    if version == vault::FILE_VERSION_V3 {
        // v3（保险箱）：头带 salt + 可选加密缩略图节，内容密钥 = Argon2id，
        // 交给 vault 模块从头完整解析（此处已消费 magic+version，重开文件）。
        drop(input_file);
        return vault::decrypt_file_v3_internal(
            input_path,
            output_path,
            password,
            is_mobile,
            cpu_cores,
        )
        .map_err(std::convert::Into::into);
    }
    if version != VERSION {
        return Err("Unsupported version".into());
    }
    
    let mut hint_len_bytes = [0u8; 1];
    input_file.read_exact(&mut hint_len_bytes)?;
    let hint_len = hint_len_bytes[0] as usize;
    
    let mut hint_bytes = vec![0u8; hint_len];
    input_file.read_exact(&mut hint_bytes)?;
    
    let encrypted_data_start = HEADER_SIZE + 1 + hint_len;
    
    let file_size = std::fs::metadata(input_path)?.len() as usize;
    let encrypted_size = file_size - encrypted_data_start;
    
    let key = derive_key(password);
    let cipher = Aes256Gcm::new_from_slice(&key)?;
    
    let mut output_file = BufWriter::new(File::create(output_path)?);
    
    let is_single_chunk = {
        let mut temp_nonce = [0u8; NONCE_SIZE];
        input_file.read_exact(&mut temp_nonce)?;
        
        let remaining = encrypted_size - NONCE_SIZE;
        let is_single = remaining <= (chunk_size + TAG_SIZE);
        
        input_file.seek(SeekFrom::Start(encrypted_data_start as u64))?;
        is_single
    };
    
    if is_single_chunk {
        let mut nonce_bytes = [0u8; NONCE_SIZE];
        input_file.read_exact(&mut nonce_bytes)?;
        
        let mut encrypted_data = Vec::new();
        input_file.read_to_end(&mut encrypted_data)?;
        
        let nonce = Nonce::from_slice(&nonce_bytes);
        let decrypted = cipher.decrypt(nonce, encrypted_data.as_ref())
            .map_err(|_| "Decryption failed")?;
        
        output_file.write_all(&decrypted)?;
    } else if encrypted_size <= parallel_threshold {
        let mut chunks = Vec::new();
        let mut nonces = Vec::new();
        
        while let Ok(nonce_bytes) = {
            let mut buf = [0u8; NONCE_SIZE];
            input_file.read_exact(&mut buf).map(|_| buf)
        } {
            let mut chunk_len_bytes = [0u8; 4];
            if input_file.read_exact(&mut chunk_len_bytes).is_err() {
                break;
            }
            let chunk_len = u32::from_be_bytes(chunk_len_bytes) as usize;
            
            let mut encrypted_chunk = vec![0u8; chunk_len];
            input_file.read_exact(&mut encrypted_chunk)?;
            
            chunks.push(encrypted_chunk);
            nonces.push(nonce_bytes);
        }
        
        let key_arc = Arc::new(key);
        let decrypted_chunks: Result<Vec<Vec<u8>>, &str> = chunks
            .par_iter()
            .zip(nonces.par_iter())
            .map(|(chunk, nonce_bytes)| {
                let cipher = Aes256Gcm::new_from_slice(&*key_arc)
                    .map_err(|_| "Invalid key")?;
                let nonce = Nonce::from_slice(nonce_bytes);
                cipher.decrypt(nonce, chunk.as_ref())
                    .map_err(|_| "Decryption failed")
            })
            .collect();
        
        let decrypted_chunks = decrypted_chunks?;
        
        for decrypted in decrypted_chunks.iter() {
            output_file.write_all(decrypted)?;
        }
    } else {
        let key_arc = Arc::new(key);
        
        loop {
            let mut chunks = Vec::new();
            let mut nonces = Vec::new();
            
            for _ in 0..batch_size {
                let mut nonce_bytes = [0u8; NONCE_SIZE];
                if input_file.read_exact(&mut nonce_bytes).is_err() {
                    break;
                }
                
                let mut chunk_len_bytes = [0u8; 4];
                if input_file.read_exact(&mut chunk_len_bytes).is_err() {
                    break;
                }
                let chunk_len = u32::from_be_bytes(chunk_len_bytes) as usize;
                
                let mut encrypted_chunk = vec![0u8; chunk_len];
                if input_file.read_exact(&mut encrypted_chunk).is_err() {
                    break;
                }
                
                chunks.push(encrypted_chunk);
                nonces.push(nonce_bytes);
            }
            
            if chunks.is_empty() {
                break;
            }
            
            let decrypted_chunks: Result<Vec<Vec<u8>>, &str> = chunks
                .par_iter()
                .zip(nonces.par_iter())
                .map(|(chunk, nonce_bytes)| {
                    let cipher = Aes256Gcm::new_from_slice(&*key_arc)
                        .map_err(|_| "Invalid key")?;
                    let nonce = Nonce::from_slice(nonce_bytes);
                    cipher.decrypt(nonce, chunk.as_ref())
                        .map_err(|_| "Decryption failed")
                })
                .collect();
            
            let decrypted_chunks = decrypted_chunks?;
            
            for decrypted in decrypted_chunks.iter() {
                output_file.write_all(decrypted)?;
            }
        }
    }
    
    output_file.flush()?;
    Ok(())
}

#[no_mangle]
pub extern "C" fn decrypt_file_to_memory(
    input_path_ptr: *const c_char,
    password_ptr: *const u8,
    password_len: usize,
    output_ptr: *mut u8,
    output_len: *mut usize,
    is_mobile: bool,
    cpu_cores: usize,
) -> i32 {
    unsafe {
        let input_path = match CStr::from_ptr(input_path_ptr).to_str() {
            Ok(s) => s,
            Err(_) => return -1,
        };
        let password = slice::from_raw_parts(password_ptr, password_len);

        match decrypt_file_to_memory_internal(input_path, password, is_mobile, cpu_cores) {
            Ok(data) => {
                *output_len = data.len();
                if !output_ptr.is_null() {
                    std::ptr::copy_nonoverlapping(data.as_ptr(), output_ptr, data.len());
                }
                0
            }
            Err(_) => -2,
        }
    }
}

fn decrypt_file_to_memory_internal(
    input_path: &str,
    password: &[u8],
    is_mobile: bool,
    _cpu_cores: usize,
) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let chunk_size = get_chunk_size(is_mobile);
    let _parallel_threshold = get_parallel_batch_threshold(is_mobile);
    
    let mut input_file = BufReader::new(File::open(input_path)?);
    
    let mut magic = vec![0u8; MAGIC_STRING.len()];
    input_file.read_exact(&mut magic)?;
    if magic != MAGIC_STRING {
        return Err("Invalid file format".into());
    }
    
    let mut version_bytes = [0u8; 4];
    input_file.read_exact(&mut version_bytes)?;
    let version = u32::from_le_bytes(version_bytes);
    if version == vault::FILE_VERSION_V3 {
        // v3（保险箱）：salt + Argon2id + 可选缩略图节，交给 vault 模块
        drop(input_file);
        return vault::decrypt_file_v3_to_memory_internal(input_path, password, is_mobile, _cpu_cores)
            .map_err(std::convert::Into::into);
    }
    if version != VERSION {
        return Err("Unsupported version".into());
    }
    
    let mut hint_len_bytes = [0u8; 1];
    input_file.read_exact(&mut hint_len_bytes)?;
    let hint_len = hint_len_bytes[0] as usize;
    
    let mut hint_bytes = vec![0u8; hint_len];
    input_file.read_exact(&mut hint_bytes)?;
    
    let encrypted_data_start = HEADER_SIZE + 1 + hint_len;
    
    let file_size = std::fs::metadata(input_path)?.len() as usize;
    let encrypted_size = file_size - encrypted_data_start;
    
    let key = derive_key(password);
    let cipher = Aes256Gcm::new_from_slice(&key)?;
    
    let is_single_chunk = {
        let mut temp_nonce = [0u8; NONCE_SIZE];
        input_file.read_exact(&mut temp_nonce)?;
        
        let remaining = encrypted_size - NONCE_SIZE;
        let is_single = remaining <= (chunk_size + TAG_SIZE);
        
        input_file.seek(SeekFrom::Start(encrypted_data_start as u64))?;
        is_single
    };
    
    if is_single_chunk {
        let mut nonce_bytes = [0u8; NONCE_SIZE];
        input_file.read_exact(&mut nonce_bytes)?;
        
        let mut encrypted_data = Vec::new();
        input_file.read_to_end(&mut encrypted_data)?;
        
        let nonce = Nonce::from_slice(&nonce_bytes);
        let decrypted = cipher.decrypt(nonce, encrypted_data.as_ref())
            .map_err(|_| "Decryption failed")?;
        
        Ok(decrypted)
    } else {
        let mut chunks = Vec::new();
        let mut nonces = Vec::new();
        
        while let Ok(nonce_bytes) = {
            let mut buf = [0u8; NONCE_SIZE];
            input_file.read_exact(&mut buf).map(|_| buf)
        } {
            let mut chunk_len_bytes = [0u8; 4];
            if input_file.read_exact(&mut chunk_len_bytes).is_err() {
                break;
            }
            let chunk_len = u32::from_be_bytes(chunk_len_bytes) as usize;
            
            let mut encrypted_chunk = vec![0u8; chunk_len];
            input_file.read_exact(&mut encrypted_chunk)?;
            
            chunks.push(encrypted_chunk);
            nonces.push(nonce_bytes);
        }
        
        let key_arc = Arc::new(key);
        let decrypted_chunks: Result<Vec<Vec<u8>>, &str> = chunks
            .par_iter()
            .zip(nonces.par_iter())
            .map(|(chunk, nonce_bytes)| {
                let cipher = Aes256Gcm::new_from_slice(&*key_arc)
                    .map_err(|_| "Invalid key")?;
                let nonce = Nonce::from_slice(nonce_bytes);
                cipher.decrypt(nonce, chunk.as_ref())
                    .map_err(|_| "Decryption failed")
            })
            .collect();
        
        let decrypted_chunks = decrypted_chunks?;
        
        let mut result = Vec::new();
        for decrypted in decrypted_chunks.iter() {
            result.extend_from_slice(decrypted);
        }
        
        Ok(result)
    }
}

#[no_mangle]
pub extern "C" fn get_hint_from_file(
    input_path_ptr: *const c_char,
    hint_ptr: *mut u8,
    hint_len: *mut usize,
) -> i32 {
    unsafe {
        let input_path = match CStr::from_ptr(input_path_ptr).to_str() {
            Ok(s) => s,
            Err(_) => return -1,
        };

        match get_hint_from_file_internal(input_path) {
            Ok(hint_bytes) => {
                *hint_len = hint_bytes.len();
                if !hint_ptr.is_null() {
                    std::ptr::copy_nonoverlapping(hint_bytes.as_ptr(), hint_ptr, hint_bytes.len());
                }
                0
            }
            Err(_) => -2,
        }
    }
}

fn get_hint_from_file_internal(input_path: &str) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let mut input_file = File::open(input_path)?;
    
    let mut magic = vec![0u8; MAGIC_STRING.len()];
    input_file.read_exact(&mut magic)?;
    if magic != MAGIC_STRING {
        return Err("Invalid file format".into());
    }
    
    let mut version_bytes = [0u8; 4];
    input_file.read_exact(&mut version_bytes)?;
    let version = u32::from_le_bytes(version_bytes);

    if version == vault::FILE_VERSION_V3 {
        // v3：flags u32 + salt 16B +（flags&1 时）thumb_nonce 12B + thumb_len u32 + blob
        let mut flags_bytes = [0u8; 4];
        input_file.read_exact(&mut flags_bytes)?;
        let flags = u32::from_le_bytes(flags_bytes);
        let mut salt = [0u8; 16];
        input_file.read_exact(&mut salt)?;
        if flags & 1 != 0 {
            let mut thumb_nonce = [0u8; 12];
            input_file.read_exact(&mut thumb_nonce)?;
            let mut thumb_len_bytes = [0u8; 4];
            input_file.read_exact(&mut thumb_len_bytes)?;
            let thumb_len = u32::from_le_bytes(thumb_len_bytes) as u64;
            use std::io::Seek;
            input_file.seek(std::io::SeekFrom::Current(thumb_len as i64))?;
        }
    } else if version != VERSION {
        return Err("Unsupported version".into());
    }

    let mut hint_len_bytes = [0u8; 1];
    input_file.read_exact(&mut hint_len_bytes)?;
    let hint_len = hint_len_bytes[0] as usize;
    
    let mut hint_bytes = vec![0u8; hint_len];
    input_file.read_exact(&mut hint_bytes)?;
    
    Ok(hint_bytes)
}

#[no_mangle]
pub extern "C" fn encrypt_data_parallel(
    chunks_ptr: *const *const u8,
    chunk_lens: *const usize,
    num_chunks: usize,
    password_ptr: *const u8,
    password_len: usize,
    nonces_ptr: *const u8,
    outputs_ptr: *mut *mut u8,
    output_lens: *mut usize,
) -> i32 {
    unsafe {
        let password = slice::from_raw_parts(password_ptr, password_len);
        let key = derive_key(password);
        let key_arc = Arc::new(key);
        
        let chunk_ptrs = slice::from_raw_parts(chunks_ptr, num_chunks);
        let chunk_lengths = slice::from_raw_parts(chunk_lens, num_chunks);
        let nonces = slice::from_raw_parts(nonces_ptr, num_chunks * NONCE_SIZE);
        
        let chunks: Vec<&[u8]> = chunk_ptrs
            .iter()
            .zip(chunk_lengths.iter())
            .map(|(ptr, len)| slice::from_raw_parts(*ptr, *len))
            .collect();
        
        let results: Result<Vec<Vec<u8>>, i32> = chunks
            .par_iter()
            .enumerate()
            .map(|(i, chunk)| {
                let cipher = Aes256Gcm::new_from_slice(&*key_arc)
                    .map_err(|_| -1)?;
                
                let nonce_offset = i * NONCE_SIZE;
                let nonce = Nonce::from_slice(&nonces[nonce_offset..nonce_offset + NONCE_SIZE]);
                
                cipher.encrypt(nonce, chunk.as_ref())
                    .map_err(|_| -2)
            })
            .collect();
        
        match results {
            Ok(encrypted_chunks) => {
                let output_lens_slice = slice::from_raw_parts_mut(output_lens, num_chunks);
                let outputs_slice = slice::from_raw_parts_mut(outputs_ptr, num_chunks);
                
                for (i, encrypted) in encrypted_chunks.iter().enumerate() {
                    output_lens_slice[i] = encrypted.len();
                    if !outputs_slice[i].is_null() {
                        std::ptr::copy_nonoverlapping(
                            encrypted.as_ptr(),
                            outputs_slice[i],
                            encrypted.len(),
                        );
                    }
                }
                0
            }
            Err(code) => code,
        }
    }
}

#[no_mangle]
pub extern "C" fn decrypt_data_parallel(
    chunks_ptr: *const *const u8,
    chunk_lens: *const usize,
    num_chunks: usize,
    password_ptr: *const u8,
    password_len: usize,
    nonces_ptr: *const u8,
    outputs_ptr: *mut *mut u8,
    output_lens: *mut usize,
) -> i32 {
    unsafe {
        let password = slice::from_raw_parts(password_ptr, password_len);
        let key = derive_key(password);
        let key_arc = Arc::new(key);
        
        let chunk_ptrs = slice::from_raw_parts(chunks_ptr, num_chunks);
        let chunk_lengths = slice::from_raw_parts(chunk_lens, num_chunks);
        let nonces = slice::from_raw_parts(nonces_ptr, num_chunks * NONCE_SIZE);
        
        let chunks: Vec<&[u8]> = chunk_ptrs
            .iter()
            .zip(chunk_lengths.iter())
            .map(|(ptr, len)| slice::from_raw_parts(*ptr, *len))
            .collect();
        
        let results: Result<Vec<Vec<u8>>, i32> = chunks
            .par_iter()
            .enumerate()
            .map(|(i, chunk)| {
                let cipher = Aes256Gcm::new_from_slice(&*key_arc)
                    .map_err(|_| -1)?;
                
                let nonce_offset = i * NONCE_SIZE;
                let nonce = Nonce::from_slice(&nonces[nonce_offset..nonce_offset + NONCE_SIZE]);
                
                cipher.decrypt(nonce, chunk.as_ref())
                    .map_err(|_| -2)
            })
            .collect();
        
        match results {
            Ok(decrypted_chunks) => {
                let output_lens_slice = slice::from_raw_parts_mut(output_lens, num_chunks);
                let outputs_slice = slice::from_raw_parts_mut(outputs_ptr, num_chunks);
                
                for (i, decrypted) in decrypted_chunks.iter().enumerate() {
                    output_lens_slice[i] = decrypted.len();
                    if !outputs_slice[i].is_null() {
                        std::ptr::copy_nonoverlapping(
                            decrypted.as_ptr(),
                            outputs_slice[i],
                            decrypted.len(),
                        );
                    }
                }
                0
            }
            Err(code) => code,
        }
    }
}

#[no_mangle]
pub extern "C" fn encrypt_data(
    data_ptr: *const u8,
    data_len: usize,
    password_ptr: *const u8,
    password_len: usize,
    nonce_ptr: *const u8,
    output_ptr: *mut u8,
    output_len: *mut usize,
) -> i32 {
    unsafe {
        let data = slice::from_raw_parts(data_ptr, data_len);
        let password = slice::from_raw_parts(password_ptr, password_len);
        let nonce_bytes = slice::from_raw_parts(nonce_ptr, NONCE_SIZE);
        
        let key = derive_key(password);
        let cipher = match Aes256Gcm::new_from_slice(&key) {
            Ok(c) => c,
            Err(_) => return -1,
        };
        
        let nonce = Nonce::from_slice(nonce_bytes);
        
        let encrypted = match cipher.encrypt(nonce, data) {
            Ok(e) => e,
            Err(_) => return -2,
        };
        
        *output_len = encrypted.len();
        
        if !output_ptr.is_null() {
            std::ptr::copy_nonoverlapping(encrypted.as_ptr(), output_ptr, encrypted.len());
        }
        
        0
    }
}

#[no_mangle]
pub extern "C" fn decrypt_data(
    encrypted_ptr: *const u8,
    encrypted_len: usize,
    password_ptr: *const u8,
    password_len: usize,
    nonce_ptr: *const u8,
    output_ptr: *mut u8,
    output_len: *mut usize,
) -> i32 {
    unsafe {
        let encrypted = slice::from_raw_parts(encrypted_ptr, encrypted_len);
        let password = slice::from_raw_parts(password_ptr, password_len);
        let nonce_bytes = slice::from_raw_parts(nonce_ptr, NONCE_SIZE);
        
        let key = derive_key(password);
        let cipher = match Aes256Gcm::new_from_slice(&key) {
            Ok(c) => c,
            Err(_) => return -1,
        };
        
        let nonce = Nonce::from_slice(nonce_bytes);
        
        let decrypted = match cipher.decrypt(nonce, encrypted) {
            Ok(d) => d,
            Err(_) => return -2,
        };
        
        *output_len = decrypted.len();
        
        if !output_ptr.is_null() {
            std::ptr::copy_nonoverlapping(decrypted.as_ptr(), output_ptr, decrypted.len());
        }
        
        0
    }
}

#[no_mangle]
pub extern "C" fn derive_key_ffi(
    password_ptr: *const u8,
    password_len: usize,
    output_ptr: *mut u8,
) -> i32 {
    unsafe {
        let password = slice::from_raw_parts(password_ptr, password_len);
        let key = derive_key(password);
        std::ptr::copy_nonoverlapping(key.as_ptr(), output_ptr, 32);
        0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_derive_key() {
        let password = b"test_password";
        let key = derive_key(password);
        assert_eq!(key.len(), 32);
    }

    #[test]
    fn test_encrypt_decrypt() {
        let data = b"Hello, World! This is a test message.";
        let password = b"secure_password";
        let nonce = [0u8; NONCE_SIZE];
        
        let mut encrypted = vec![0u8; data.len() + TAG_SIZE];
        let mut encrypted_len = 0usize;
        
        let result = unsafe {
            encrypt_data(
                data.as_ptr(),
                data.len(),
                password.as_ptr(),
                password.len(),
                nonce.as_ptr(),
                encrypted.as_mut_ptr(),
                &mut encrypted_len as *mut usize,
            )
        };
        
        assert_eq!(result, 0);
        encrypted.truncate(encrypted_len);
        
        let mut decrypted = vec![0u8; encrypted_len];
        let mut decrypted_len = 0usize;
        
        let result = unsafe {
            decrypt_data(
                encrypted.as_ptr(),
                encrypted.len(),
                password.as_ptr(),
                password.len(),
                nonce.as_ptr(),
                decrypted.as_mut_ptr(),
                &mut decrypted_len as *mut usize,
            )
        };
        
        assert_eq!(result, 0);
        decrypted.truncate(decrypted_len);
        assert_eq!(decrypted, data);
    }

    /// v1.2.21 真增量刷新：深层新建/删除/删子树/根层新建/无变化不误删。
    /// 单函数顺序执行（INDEX_PATHS 是进程级全局，避免并行测试互踩）。
    #[test]
    fn test_index_refresh_incremental() {
        fn idx_contains(name: &str) -> bool {
            lock_or_recover(&INDEX_PATHS)
                .as_ref()
                .map(|v| v.iter().any(|p| p.contains(name)))
                .unwrap_or(false)
        }
        let tmp = std::env::temp_dir().join(format!(
            "wm_idx_inc_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let root = tmp.join("root");
        let deep = root.join("a").join("b").join("c");
        std::fs::create_dir_all(&deep).unwrap();
        std::fs::write(root.join("f1.txt"), b"x").unwrap();
        std::fs::write(deep.join("old.bin"), b"y").unwrap();
        let roots = vec![root.clone()];
        // 模拟 index_build 的结果（扫描 + 快照目录 mtime）
        let (paths, dirs) = scan_roots(&roots);
        *lock_or_recover(&INDEX_PATHS) = Some(paths);
        *lock_or_recover(&INDEX_DIR_MTIMES) = Some(dirs);
        *lock_or_recover(&INDEX_ROOTS) = Some(vec![norm_dir_key(&root)]);
        assert!(idx_contains("f1.txt"), "初始应有 f1.txt");
        assert!(idx_contains("old.bin"), "初始应有 old.bin");

        // ① 深层新建文件（旧版只比根 mtime，此处永远发现不了）
        std::fs::write(deep.join("new.txt"), b"z").unwrap();
        assert!(!refresh_incremental(&roots), "不该截断");
        assert!(
            idx_contains("new.txt"),
            "深层新建文件应进索引（v1.2.21 核心场景）"
        );
        assert!(idx_contains("old.bin"), "未变文件不应被误删");

        // ② 删除文件
        std::fs::remove_file(deep.join("old.bin")).unwrap();
        refresh_incremental(&roots);
        assert!(!idx_contains("old.bin"), "删除的文件应移除");
        assert!(idx_contains("new.txt"), "同目录其他文件应保留");

        // ③ 删除整个子树目录
        let victim = root.join("a").join("b");
        std::fs::remove_dir_all(&victim).unwrap();
        refresh_incremental(&roots);
        assert!(!idx_contains("new.txt"), "删子树后其文件应全部移除");
        assert!(idx_contains("f1.txt"), "根层文件不受影响");

        // ④ 根层直接新建
        std::fs::write(root.join("top.dat"), b"w").unwrap();
        refresh_incremental(&roots);
        assert!(idx_contains("top.dat"), "根层新建应进索引");

        // ⑤ 无变化再刷一次：不得误删（prev==cur 跳过路径）
        refresh_incremental(&roots);
        assert!(idx_contains("f1.txt") && idx_contains("top.dat"), "无变化不得误删");

        // ⑥ 目录 key 规范化：卷根 "E:\" 形态与 "E:" 等价
        assert_eq!(norm_dir_key(std::path::Path::new("E:\\")), "E:");
        assert_eq!(norm_dir_key(std::path::Path::new("E:\\Ai\\")), "E:\\Ai");
        assert_eq!(norm_dir_key(std::path::Path::new("E:\\Ai")), "E:\\Ai");

        let _ = std::fs::remove_dir_all(&tmp);
    }
}

// ==================== 全盘文件名索引（方案A：多线程遍历 + 内存索引） ====================
//
// 设计：
// - index_build：多线程工作队列遍历目录，把所有「文件」的完整路径存进进程级内存索引。
//   跳过系统垃圾目录（回收站/卷信息/WindowsApps 等），跳过符号链接防止循环。
//   上限 100 万条防止内存失控（每条约占 100 字节堆内存）。返回索引条数（负数为错误）。
// - index_free：释放进程级索引内存，下次 index_build 重建。
// - index_search：文件名不区分大小写子串匹配，返回 \n 连接的路径串（两次调用模式：
//   先 out_ptr=null 拿长度，再传缓冲区取数据）。阻塞调用，建议放后台线程/isolate。
// - index_save / index_load：索引落盘（路径 + 各目录 mtime + 根列表），跨启动复用，
//   避免每次启动全量重建。
// - index_refresh：增量刷新。比对各根目录 mtime，未变则跳过重扫，仅重扫变化的盘/目录。

use std::collections::HashMap;

pub(crate) static INDEX_PATHS: std::sync::Mutex<Option<Vec<String>>> = std::sync::Mutex::new(None);
/// 各目录（含根）的 mtime（纳秒），用于增量刷新时判断是否需要重扫
static INDEX_DIR_MTIMES: std::sync::Mutex<Option<HashMap<String, i64>>> =
    std::sync::Mutex::new(None);
/// 索引根目录列表（与 build 入参一致）
static INDEX_ROOTS: std::sync::Mutex<Option<Vec<String>>> = std::sync::Mutex::new(None);
/// 用户排除模式（通配符，匹配完整路径小写）。由 index_set_excludes 设置，index_build/refresh 遍历时生效
static INDEX_EXCLUDES: std::sync::Mutex<Option<Vec<String>>> = std::sync::Mutex::new(None);
/// 最近一次 scan 是否撞上限被截断（v1.2.21：截断时 index_build 返回 -5 告知上层）
static INDEX_TRUNCATED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// 无依赖通配符匹配：`*` 匹配任意字符（含路径分隔符），`?` 匹配单个字符
pub(crate) fn wildcard_match(pat: &[u8], text: &[u8]) -> bool {
    let (mut pi, mut ti) = (0usize, 0usize);
    let (mut star, mut mark) = (usize::MAX, 0usize);
    while ti < text.len() {
        if pi < pat.len() && (pat[pi] == b'?' || pat[pi] == text[ti]) {
            pi += 1;
            ti += 1;
        } else if pi < pat.len() && pat[pi] == b'*' {
            star = pi;
            mark = ti;
            pi += 1;
        } else if star != usize::MAX {
            pi = star + 1;
            mark += 1;
            ti = mark;
        } else {
            return false;
        }
    }
    while pi < pat.len() && pat[pi] == b'*' {
        pi += 1;
    }
    pi == pat.len()
}

/// 设置排除模式（构建索引前由 Dart 调用）；传 null/0 清空
#[no_mangle]
pub extern "C" fn index_set_excludes(
    patterns_ptr: *const *const c_char,
    num_patterns: usize,
) -> i32 {
    ffi_catch!({
    if patterns_ptr.is_null() || num_patterns == 0 {
        *lock_or_recover(&INDEX_EXCLUDES) = Some(Vec::new());
        return 0;
    }
    let mut out: Vec<String> = Vec::new();
    unsafe {
        let ptrs = slice::from_raw_parts(patterns_ptr, num_patterns);
        for &pp in ptrs {
            let s = CStr::from_ptr(pp).to_string_lossy().trim().to_lowercase();
            if !s.is_empty() {
                out.push(s);
            }
        }
    }
    *lock_or_recover(&INDEX_EXCLUDES) = Some(out);
    0
})
}

/// 取目录 mtime（纳秒），失败返回 None
pub(crate) fn dir_mtime_ns(path: &std::path::Path) -> Option<i64> {
    if let Ok(meta) = std::fs::metadata(path) {
        if let Ok(t) = meta.modified() {
            if let Ok(d) = t.duration_since(std::time::UNIX_EPOCH) {
                return Some(d.as_nanos() as i64);
            }
        }
    }
    None
}

/// 目录 key 规范化（v1.2.21 增量刷新用）：Windows 卷根 PathBuf 显示为 "E:\"
/// （带尾分隔符），子目录是 "E:\Ai"——直接拼前缀会拼出 "E:\\Ai" 匹配不上。
/// 统一去掉尾部分隔符（"E:\"→"E:"），卷根名保留。
pub(crate) fn norm_dir_key(p: &std::path::Path) -> String {
    let s = p.to_string_lossy().to_string();
    let trimmed = s.trim_end_matches(['\\', '/']);
    if trimmed.is_empty() {
        s
    } else {
        trimmed.to_string()
    }
}

/// 多线程遍历 roots，收集文件路径 + 各目录 mtime，返回容器（不替换外部状态）。
/// v1.2.21：上限 100 万→500 万（老板机器实测 96.9 万逼近旧顶，新目录整个漏扫）。
/// 参照：Everything 不设条目上限、内存按需增长；这里的安全阀只是内存护栏
/// （每条约 100-200B，500 万≈0.5-1GB，16G 民用机无压力），撞上限置
/// INDEX_TRUNCATED，index_build 据此返回 -5 让上层知晓而非静默丢数据。
pub(crate) fn scan_roots(roots: &[std::path::PathBuf]) -> (Vec<String>, HashMap<String, i64>) {
    let max_entries: usize = 5_000_000;
    let queue: Arc<std::sync::Mutex<Vec<std::path::PathBuf>>> =
        Arc::new(std::sync::Mutex::new(roots.to_vec()));
    let paths: Arc<std::sync::Mutex<Vec<String>>> = Arc::new(std::sync::Mutex::new(Vec::new()));
    let dir_mtimes: Arc<std::sync::Mutex<HashMap<String, i64>>> =
        Arc::new(std::sync::Mutex::new(HashMap::new()));
    let busy = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let total = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));

    let workers = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4);
    // 快照排除模式，各 worker 无锁匹配（每条路径只匹配小写一次）
    let excludes: Arc<Vec<String>> = Arc::new(
        INDEX_EXCLUDES
            .lock()
            .unwrap()
            .as_ref()
            .cloned()
            .unwrap_or_default(),
    );
    let mut handles = Vec::new();
    for _ in 0..workers {
        let queue = queue.clone();
        let paths = paths.clone();
        let dir_mtimes = dir_mtimes.clone();
        let busy = busy.clone();
        let total = total.clone();
        let stop = stop.clone();
        let excludes = excludes.clone();
        handles.push(std::thread::spawn(move || {
            let mut local: Vec<String> = Vec::new();
            let mut local_dirs: HashMap<String, i64> = HashMap::new();
            loop {
                if stop.load(std::sync::atomic::Ordering::Relaxed) {
                    break;
                }
                let dir = {
                    let mut q = lock_or_recover(&queue);
                    match q.pop() {
                        Some(d) => {
                            busy.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                            d
                        }
                        None => {
                            if busy.load(std::sync::atomic::Ordering::Relaxed) == 0 {
                                stop.store(true, std::sync::atomic::Ordering::Relaxed);
                                break;
                            }
                            drop(q);
                            std::thread::sleep(std::time::Duration::from_millis(2));
                            continue;
                        }
                    }
                };
                if let Some(mt) = dir_mtime_ns(&dir) {
                    local_dirs.insert(norm_dir_key(&dir), mt);
                }
                if let Ok(rd) = std::fs::read_dir(&dir) {
                    for e in rd.flatten() {
                        if stop.load(std::sync::atomic::Ordering::Relaxed) {
                            break;
                        }
                        let name_os = e.file_name();
                        let name = name_os.to_string_lossy().to_string();
                        let Ok(ft) = e.file_type() else { continue };
                        if ft.is_symlink() {
                            continue;
                        }
                        let is_dir = ft.is_dir();
                        // 用户排除列表：完整路径通配符匹配（目录不入队、文件不入索引）
                        let path_lower = e.path().to_string_lossy().to_lowercase();
                        if excludes
                            .iter()
                            .any(|pat| wildcard_match(pat.as_bytes(), path_lower.as_bytes()))
                        {
                            continue;
                        }
                        if is_dir {
                            if index_skip_dir(&name) {
                                continue;
                            }
                            let mut q = lock_or_recover(&queue);
                            q.push(e.path());
                        } else {
                            if total.load(std::sync::atomic::Ordering::Relaxed) >= max_entries {
                                INDEX_TRUNCATED.store(true, std::sync::atomic::Ordering::Relaxed);
                                stop.store(true, std::sync::atomic::Ordering::Relaxed);
                            } else {
                                local.push(e.path().to_string_lossy().to_string());
                                if local.len() >= 4096 {
                                    let n = local.len();
                                    lock_or_recover(&paths).extend(local.drain(..));
                                    total.fetch_add(n, std::sync::atomic::Ordering::Relaxed);
                                }
                            }
                        }
                    }
                }
                busy.fetch_sub(1, std::sync::atomic::Ordering::Relaxed);
            }
            if !local.is_empty()
                && total.load(std::sync::atomic::Ordering::Relaxed) < max_entries
            {
                lock_or_recover(&paths).extend(local);
            }
            {
                let mut dm = lock_or_recover(&dir_mtimes);
                for (k, v) in local_dirs {
                    dm.insert(k, v);
                }
            }
        }));
    }
    for h in handles {
        let _ = h.join();
    }
    let final_paths = lock_or_recover(&paths).clone();
    let final_dirs = lock_or_recover(&dir_mtimes).clone();
    (final_paths, final_dirs)
}

const INDEX_SKIP_DIRS: &[&str] = &[
    "$recycle.bin",
    "system volume information",
    "windowsapps",
    "$windows.et",
    "recovery",
];

pub(crate) fn index_skip_dir(name: &str) -> bool {
    let lower = name.to_lowercase();
    INDEX_SKIP_DIRS.contains(&lower.as_str())
}

#[no_mangle]
/// 初始化空索引（USN 全量重建前调用：INDEX_PATHS 置空 Vec，usn_sync 往里填）
#[no_mangle]
pub extern "C" fn index_init() -> i32 {
    ffi_catch!({
    *lock_or_recover(&INDEX_PATHS) = Some(Vec::new());
    *lock_or_recover(&INDEX_DIR_MTIMES) = Some(HashMap::new());
    *lock_or_recover(&INDEX_ROOTS) = Some(Vec::new());
    0
})
}

#[no_mangle]
pub extern "C" fn index_build(roots_ptr: *const *const c_char, num_roots: usize) -> i64 {
    ffi_catch!({
    let mut roots: Vec<std::path::PathBuf> = Vec::new();
    unsafe {
        if roots_ptr.is_null() {
            return -1;
        }
        let ptrs = slice::from_raw_parts(roots_ptr, num_roots);
        for &rp in ptrs {
            let cs = CStr::from_ptr(rp);
            let s = cs.to_string_lossy().to_string();
            if !s.is_empty() && std::path::Path::new(&s).exists() {
                roots.push(std::path::PathBuf::from(&s));
            }
        }
    }
    if roots.is_empty() {
        return -2;
    }

    INDEX_TRUNCATED.store(false, std::sync::atomic::Ordering::Relaxed);
    let (final_paths, final_dirs) = scan_roots(&roots);
    let n = final_paths.len() as i64;
    *lock_or_recover(&INDEX_PATHS) = Some(final_paths);
    let root_strs: Vec<String> = roots.iter().map(|p| p.to_string_lossy().to_string()).collect();
    *lock_or_recover(&INDEX_DIR_MTIMES) = Some(final_dirs);
    *lock_or_recover(&INDEX_ROOTS) = Some(root_strs);
    if INDEX_TRUNCATED.load(std::sync::atomic::Ordering::Relaxed) {
        // 撞上限截断：返回 -5（上层记日志/提示），条数放 _COUNT 已由 replace 生效
        return -5;
    }
    n
})
}

#[no_mangle]
pub extern "C" fn index_count() -> i64 {
    ffi_catch!({
    match lock_or_recover(&INDEX_PATHS).as_ref() {
        Some(v) => v.len() as i64,
        None => -1,
    }
})
}

/// 释放全盘索引内存（全部置回 None：路径 Vec + 目录 MTIMES 表 + 根列表）。
/// 收托盘/隐藏窗口时调用，内存随 drop 归还；下次搜索前 rebuildIfStale 会重建。
#[no_mangle]
pub extern "C" fn index_free() {
    ffi_catch!({
    *lock_or_recover(&INDEX_PATHS) = None;
    *lock_or_recover(&INDEX_DIR_MTIMES) = None;
    *lock_or_recover(&INDEX_ROOTS) = None;
})
}

#[no_mangle]
pub extern "C" fn index_search(
    query_ptr: *const c_char,
    limit: usize,
    out_ptr: *mut u8,
    out_len: *mut usize,
) -> i32 {
    // 老入口兼容：默认开拼音、开 stat 类函数（size:/dm:/dc:）。
    // 开关级控制走 index_search2（Dart 侧按设置拼 flags）。
    index_search2(
        query_ptr,
        limit,
        search::FLAG_PINYIN | search::FLAG_STAT,
        out_ptr,
        out_len,
    )
}

/// 搜索引擎 v2 入口（v1.2.6）。flags: bit0=拼音转拼 bit1=允许 stat 类函数（size:/dm:/dc:）。
/// 语法与打分见 search.rs 模块注释。
///
/// v1.2.11：extern "C" 边界 panic 会直接 abort 整个宿主进程（曾导致 UI 输入
/// 搜索词即闪退、托盘残留）。这里用 catch_unwind 兜底：引擎内部任何 panic
/// 都降级为返回 -4（Dart 侧视为无结果），绝不死进程。
#[no_mangle]
pub extern "C" fn index_search2(
    query_ptr: *const c_char,
    limit: usize,
    flags: u32,
    out_ptr: *mut u8,
    out_len: *mut usize,
) -> i32 {
    if out_len.is_null() {
        return -3;
    }
    let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        index_search2_inner(query_ptr, limit, flags, out_ptr, out_len)
    }));
    match r {
        Ok(code) => code,
        Err(_) => {
            eprintln!("rust_crypto: index_search2 panicked (degraded to empty)");
            unsafe {
                *out_len = 0;
            }
            -4
        }
    }
}

fn index_search2_inner(
    query_ptr: *const c_char,
    limit: usize,
    flags: u32,
    out_ptr: *mut u8,
    out_len: *mut usize,
) -> i32 {
    let query = if query_ptr.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(query_ptr) }.to_string_lossy().to_string()
    };
    let fl = search::Flags {
        case: false,
        word: false,
        path: false,
        regex: false,
        pinyin: flags & search::FLAG_PINYIN != 0,
        stat: flags & search::FLAG_STAT != 0,
    };
    let guard = lock_or_recover(&INDEX_PATHS);
    let data = match guard.as_ref() {
        Some(d) => d,
        None => return -1,
    };
    let joined = search::run(data, &query, limit, fl);
    let out = joined.as_bytes();
    unsafe {
        if out_ptr.is_null() {
            *out_len = out.len();
        } else {
            let cap = *out_len;
            let n = out.len().min(cap);
            std::ptr::copy_nonoverlapping(out.as_ptr(), out_ptr, n);
            *out_len = n;
        }
    }
    0
}

/// 带 panic 兜底的互斥锁：Mutex 一旦被 poison，内部数据依然完好可用
/// （ poison 只表示上次持锁时发生了 panic）。FFI 库里对 poison 锁再 unwrap
/// 会造成连环 panic → abort 进程，统一走这里恢复。
pub(crate) fn lock_or_recover<T>(m: &std::sync::Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// 启动自检抽样：按 LCG 伪随机取 n 条路径（\n 连接）。
/// 同 seed 结果可复现；n > 总数时全量。只读不写，O(n)。
#[no_mangle]
pub extern "C" fn index_sample(
    seed: u64,
    n: usize,
    out_ptr: *mut u8,
    out_len: *mut usize,
) -> i32 {
    ffi_catch!({
    if out_len.is_null() {
        return -3;
    }
    let guard = lock_or_recover(&INDEX_PATHS);
    let data = match guard.as_ref() {
        Some(d) => d,
        None => return -1,
    };
    let total = data.len();
    if total == 0 {
        return 0;
    }
    let take = n.min(total);
    let mut state = seed ^ 0x9E37_79B9_7F4A_7C15;
    let mut picked: Vec<&str> = Vec::with_capacity(take);
    let mut seen = std::collections::HashSet::new();
    let mut attempts: usize = 0;
    while picked.len() < take && attempts < take * 20 + 64 {
        attempts += 1;
        state = state
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        let idx = (state >> 16) as usize % total;
        if seen.insert(idx) {
            picked.push(data[idx].as_str());
        }
    }
    let joined = picked.join("\n");
    let out = joined.as_bytes();
    unsafe {
        if out_ptr.is_null() {
            *out_len = out.len();
        } else {
            let cap = *out_len;
            let m = out.len().min(cap);
            std::ptr::copy_nonoverlapping(out.as_ptr(), out_ptr, m);
            *out_len = m;
        }
    }
    0
})
}

/// v1/v2 通用 body 写入：路径列表 + 各目录 mtime + 根列表。
fn write_index_body<W: std::io::Write>(
    w: &mut W,
    paths: &[String],
    rmt: &HashMap<String, i64>,
    roots: &[String],
) -> Result<(), ()> {
    let wb = |w: &mut W, b: &[u8]| w.write_all(b).map_err(|_| ());
    wb(w, &(paths.len() as u64).to_le_bytes())?;
    for p in paths {
        let b = p.as_bytes();
        wb(w, &(b.len() as u32).to_le_bytes())?;
        wb(w, b)?;
    }
    wb(w, &(rmt.len() as u64).to_le_bytes())?;
    for (k, v) in rmt {
        let b = k.as_bytes();
        wb(w, &(b.len() as u32).to_le_bytes())?;
        wb(w, b)?;
        wb(w, &v.to_le_bytes())?;
    }
    wb(w, &(roots.len() as u64).to_le_bytes())?;
    for r in roots {
        let b = r.as_bytes();
        wb(w, &(b.len() as u32).to_le_bytes())?;
        wb(w, b)?;
    }
    Ok(())
}

/// v1/v2 通用 body 解析。
fn parse_index_body<R: std::io::Read>(
    r: &mut R,
) -> Result<(Vec<String>, HashMap<String, i64>, Vec<String>), ()> {
    let mut nbuf = [0u8; 8];
    let mut rb = |r: &mut R, b: &mut [u8]| r.read_exact(b).map_err(|_| ());
    rb(r, &mut nbuf)?;
    let fc = u64::from_le_bytes(nbuf);
    let mut paths = Vec::with_capacity(fc as usize);
    for _ in 0..fc {
        let mut lb = [0u8; 4];
        rb(r, &mut lb)?;
        let l = u32::from_le_bytes(lb) as usize;
        let mut buf = vec![0u8; l];
        rb(r, &mut buf)?;
        paths.push(String::from_utf8_lossy(&buf).into_owned());
    }
    rb(r, &mut nbuf)?;
    let mc = u64::from_le_bytes(nbuf);
    let mut rmt = HashMap::with_capacity(mc as usize);
    for _ in 0..mc {
        let mut lb = [0u8; 4];
        rb(r, &mut lb)?;
        let l = u32::from_le_bytes(lb) as usize;
        let mut buf = vec![0u8; l];
        rb(r, &mut buf)?;
        let key = String::from_utf8_lossy(&buf).into_owned();
        let mut mb = [0u8; 8];
        rb(r, &mut mb)?;
        let mt = i64::from_le_bytes(mb);
        // v1.2.21：旧版落盘的 key 未去尾分隔符（"E:\" 形态），加载时统一
        // norm 化，保证与增量刷新的 norm_dir_key 查表一致
        let nk = norm_dir_key(std::path::Path::new(&key));
        rmt.insert(nk, mt);
    }
    rb(r, &mut nbuf)?;
    let rc = u64::from_le_bytes(nbuf);
    let mut roots = Vec::with_capacity(rc as usize);
    for _ in 0..rc {
        let mut lb = [0u8; 4];
        rb(r, &mut lb)?;
        let l = u32::from_le_bytes(lb) as usize;
        let mut buf = vec![0u8; l];
        rb(r, &mut buf)?;
        roots.push(String::from_utf8_lossy(&buf).into_owned());
    }
    Ok((paths, rmt, roots))
}

/// 索引落盘：magic WMIX + version。
/// v2（当前）：body 整体 deflate 压缩（miniz_oxide），约 128MB → 18MB；
/// v1（旧版未压缩）仍可读，升级后下一次落盘自动变为 v2。
#[no_mangle]
pub extern "C" fn index_save(file_ptr: *const c_char) -> i32 {
    ffi_catch!({
    let cpath = unsafe { CStr::from_ptr(file_ptr) };
    let path = cpath.to_string_lossy().to_string();

    // 先在内存里组 body（拿锁期间完成，不做 IO）
    let body = {
        let pg = lock_or_recover(&INDEX_PATHS);
        let rg = lock_or_recover(&INDEX_DIR_MTIMES);
        let og = lock_or_recover(&INDEX_ROOTS);
        let paths = match pg.as_ref() {
            Some(p) => p,
            None => return -1,
        };
        let rmt = match rg.as_ref() {
            Some(m) => m,
            None => return -1,
        };
        let roots = match og.as_ref() {
            Some(r) => r,
            None => return -1,
        };
        let mut body: Vec<u8> = Vec::with_capacity(1 << 20);
        if write_index_body(&mut body, paths, rmt, roots).is_err() {
            return -3;
        }
        body
    };

    // body 压缩（zlib wrapper，level 6）
    let compressed = miniz_oxide::deflate::compress_to_vec_zlib(&body, 6);

    let f = match std::fs::File::create(&path) {
        Ok(f) => f,
        Err(_) => return -2,
    };
    let mut w = BufWriter::new(f);
    if w.write_all(&[0x57u8, 0x4d, 0x49, 0x58]).is_err() {
        return -3;
    }
    if w.write_all(&2u32.to_le_bytes()).is_err() {
        return -3;
    }
    // v2: 压缩后长度 + 压缩 payload
    if w.write_all(&(compressed.len() as u64).to_le_bytes()).is_err() {
        return -3;
    }
    if w.write_all(&compressed).is_err() {
        return -3;
    }
    match w.flush() {
        Ok(_) => 0,
        Err(_) => -3,
    }
})
}

/// 从落盘文件恢复索引（成功返回 0）。
/// 兼容 v1（未压缩）与 v2（deflate 压缩）。
#[no_mangle]
pub extern "C" fn index_load(file_ptr: *const c_char) -> i32 {
    ffi_catch!({
    let cpath = unsafe { CStr::from_ptr(file_ptr) };
    let path = cpath.to_string_lossy().to_string();
    let f = match std::fs::File::open(&path) {
        Ok(f) => f,
        Err(_) => return -2,
    };
    let mut r = BufReader::new(f);
    let mut magic = [0u8; 4];
    if r.read_exact(&mut magic).is_err() || magic != [0x57, 0x4d, 0x49, 0x58] {
        return -4;
    }
    let mut ver = [0u8; 4];
    if r.read_exact(&mut ver).is_err() {
        return -4;
    }
    let ver = u32::from_le_bytes(ver);
    let (paths, rmt, roots) = match ver {
        1 => match parse_index_body(&mut r) {
            Ok(v) => v,
            Err(_) => return -4,
        },
        2 => {
            let mut nbuf = [0u8; 8];
            if r.read_exact(&mut nbuf).is_err() {
                return -4;
            }
            let clen = u64::from_le_bytes(nbuf) as usize;
            // 上限保护：解压前校验长度（索引上限 100 万条，压缩后不会超过 64MB）
            if clen == 0 || clen > (64 << 20) {
                return -4;
            }
            let mut compressed = vec![0u8; clen];
            if r.read_exact(&mut compressed).is_err() {
                return -4;
            }
            let body = match miniz_oxide::inflate::decompress_to_vec_zlib_with_limit(
                &compressed,
                (256 << 20),
            ) {
                Ok(b) => b,
                Err(_) => return -4,
            };
            let mut br = std::io::Cursor::new(body);
            match parse_index_body(&mut br) {
                Ok(v) => v,
                Err(_) => return -4,
            }
        }
        _ => return -4,
    };
    *lock_or_recover(&INDEX_PATHS) = Some(paths);
    *lock_or_recover(&INDEX_DIR_MTIMES) = Some(rmt);
    *lock_or_recover(&INDEX_ROOTS) = Some(roots);
    0
})
}

/// 增量刷新：比对各根目录 mtime，未变跳过重扫，仅重扫变化的盘/目录。
/// 索引未建立（未 load 也未 build）时返回 -3，调用方应先 buildIndex。
/// v1.2.21：重写为**真增量**——旧版只比根目录 mtime，深层新建文件不改根
/// mtime 导致永远判定「没变」跳过（老板实测 v1220 资产目录整个漏扫）。
/// 新实现递归比对各目录 mtime（build/load 时快照全量目录表），未变的目录
/// 整棵子树跳过，变化的目录只重扫其直接子文件，消失的目录按前缀删子树。
/// 返回条数；撞上限截断返回 -5；索引未建立 -3。
#[no_mangle]
pub extern "C" fn index_refresh(
    roots_ptr: *const *const c_char,
    num_roots: usize,
) -> i64 {
    ffi_catch!({
    let mut roots: Vec<std::path::PathBuf> = Vec::new();
    unsafe {
        if roots_ptr.is_null() {
            return -1;
        }
        let ptrs = slice::from_raw_parts(roots_ptr, num_roots);
        for &rp in ptrs {
            let cs = CStr::from_ptr(rp);
            let s = cs.to_string_lossy().to_string();
            if !s.is_empty() && std::path::Path::new(&s).exists() {
                roots.push(std::path::PathBuf::from(&s));
            }
        }
    }
    if roots.is_empty() {
        return -2;
    }
    {
        let g = lock_or_recover(&INDEX_PATHS);
        if g.is_none() {
            return -3;
        }
    }
    let truncated = refresh_incremental(&roots);
    let g = lock_or_recover(&INDEX_PATHS);
    match g.as_ref() {
        Some(v) => {
            if truncated {
                -5
            } else {
                v.len() as i64
            }
        }
        None => -3,
    }
})
}

/// 真增量刷新实现（见 index_refresh 文档）。返回是否撞上限截断。
/// 三阶段：① 遍历目录树收集「重扫目录的新文件清单 + 消失目录前缀」；
/// ② 一轮 retain 删旧条目（重扫目录的直接子文件 + 消失目录子树）；
/// ③ 再把新文件并入。删必须先于加，否则新条目父目录同样命中重扫集合被误删。
pub(crate) fn refresh_incremental(roots: &[std::path::PathBuf]) -> bool {
    const MAX_ENTRIES: usize = 5_000_000;
    let sep = std::path::MAIN_SEPARATOR;
    let excludes: Vec<String> = lock_or_recover(&INDEX_EXCLUDES)
        .as_ref()
        .cloned()
        .unwrap_or_default();
    // BFS 目录队列
    let mut queue: Vec<std::path::PathBuf> = Vec::new();
    // ① 收集：重扫目录 key → 新直接子文件；消失目录前缀列表
    let mut rescanned: std::collections::HashMap<String, Vec<String>> =
        std::collections::HashMap::new();
    let mut gone_prefixes: Vec<String> = Vec::new();
    for r in roots {
        queue.push(r.clone());
    }
    while let Some(dir) = queue.pop() {
        let key = norm_dir_key(&dir);
        let cur = dir_mtime_ns(&dir);
        let prev = {
            let rmt = lock_or_recover(&INDEX_DIR_MTIMES);
            rmt.as_ref().and_then(|m| m.get(&key).copied())
        };
        if cur.is_none() {
            // 目录消失（或元信息读不到）：整棵子树从索引移除
            if prev.is_some() {
                gone_prefixes.push(format!("{}{}", key, sep));
                let mut rmt = lock_or_recover(&INDEX_DIR_MTIMES);
                if let Some(m) = rmt.as_mut() {
                    let prefix = format!("{}{}", key, sep);
                    m.retain(|k, _| {
                        k.as_str() != key.as_str() && !k.starts_with(prefix.as_str())
                    });
                }
            }
            continue;
        }
        let cur = cur.unwrap();
        // v1.2.21 修正：目录 mtime 只反映**直接子项**的增删改名——深层新建
        // 文件只改最深目录 mtime，中间层都不变。旧算法「未变跳过子树」会
        // 整棵丢掉含变化的分支（老板实测资产目录整个漏扫的根因之一）。
        // 正确做法：未变的目录也要递归（只收子目录、不碰文件条目），
        // 仅对 mtime 变化的目录重扫其直接子文件。
        let changed = prev != Some(cur);
        let mut new_files: Vec<String> = Vec::new();
        let mut subdirs: Vec<std::path::PathBuf> = Vec::new();
        if let Ok(rd) = std::fs::read_dir(&dir) {
            for e in rd.flatten() {
                let Ok(ft) = e.file_type() else { continue };
                if ft.is_symlink() {
                    continue;
                }
                let path_lower = e.path().to_string_lossy().to_lowercase();
                if excludes
                    .iter()
                    .any(|pat| wildcard_match(pat.as_bytes(), path_lower.as_bytes()))
                {
                    continue;
                }
                if ft.is_dir() {
                    let name = e.file_name().to_string_lossy().to_string();
                    if index_skip_dir(&name) {
                        continue;
                    }
                    subdirs.push(e.path());
                } else if changed {
                    new_files.push(e.path().to_string_lossy().to_string());
                }
            }
        }
        if changed {
            {
                let mut rmt = lock_or_recover(&INDEX_DIR_MTIMES);
                if let Some(m) = rmt.as_mut() {
                    m.insert(key.clone(), cur);
                }
            }
            rescanned.insert(key.clone(), new_files);
            // 消失的直接子目录：旧快照里记录过、本次 read_dir 已看不到——
            // 它不会入队被访问，子树条目会成孤儿，必须在这里按前缀删掉
            let subdir_keys: std::collections::HashSet<String> =
                subdirs.iter().map(|s| norm_dir_key(s)).collect();
            let prefix = format!("{}{}", key, sep);
            let gone_children: Vec<String> = {
                let rmt = lock_or_recover(&INDEX_DIR_MTIMES);
                rmt.as_ref()
                    .map(|m| {
                        m.keys()
                            .filter(|k| {
                                k.starts_with(prefix.as_str())
                                    && !k[prefix.len()..].contains(sep)
                            })
                            .cloned()
                            .collect()
                    })
                    .unwrap_or_default()
            };
            for g in gone_children {
                if subdir_keys.contains(&g) {
                    continue; // 还在，只是 mtime 变，入队继续比对
                }
                gone_prefixes.push(format!("{}{}", g, sep));
                let mut rmt = lock_or_recover(&INDEX_DIR_MTIMES);
                if let Some(m) = rmt.as_mut() {
                    let gpre = format!("{}{}", g, sep);
                    m.retain(|k, _| {
                        k.as_str() != g.as_str() && !k.starts_with(gpre.as_str())
                    });
                }
            }
        }
        for sd in subdirs {
            queue.push(sd);
        }
    }
    // ② 删：一轮 retain——父目录被重扫的直接子文件旧条目 + 消失目录子树。
    // 每条路径只做一次 rfind(sep) + HashMap 查找，与变化目录数量无关。
    if !rescanned.is_empty() || !gone_prefixes.is_empty() {
        let mut pg = lock_or_recover(&INDEX_PATHS);
        if let Some(v) = pg.as_mut() {
            v.retain(|p| {
                if gone_prefixes
                    .iter()
                    .any(|pre| p.starts_with(pre.as_str()))
                {
                    return false;
                }
                if let Some(i) = p.rfind(sep) {
                    let parent = &p[..i];
                    if rescanned.contains_key(parent) {
                        return false;
                    }
                }
                true
            });
        }
    }
    // ③ 加：并入新文件（受上限约束，撞顶截断）
    let mut truncated = false;
    {
        let mut pg = lock_or_recover(&INDEX_PATHS);
        if let Some(v) = pg.as_mut() {
            'outer: for (_, files) in rescanned.iter() {
                for f in files {
                    if v.len() >= MAX_ENTRIES {
                        truncated = true;
                        break 'outer;
                    }
                    v.push(f.clone());
                }
            }
        }
    }
    truncated
}
