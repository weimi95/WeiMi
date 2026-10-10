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

fn get_chunk_size(is_mobile: bool) -> usize {
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

fn generate_nonce() -> [u8; NONCE_SIZE] {
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

static INDEX_PATHS: std::sync::Mutex<Option<Vec<String>>> = std::sync::Mutex::new(None);
/// 各目录（含根）的 mtime（纳秒），用于增量刷新时判断是否需要重扫
static INDEX_DIR_MTIMES: std::sync::Mutex<Option<HashMap<String, i64>>> =
    std::sync::Mutex::new(None);
/// 索引根目录列表（与 build 入参一致）
static INDEX_ROOTS: std::sync::Mutex<Option<Vec<String>>> = std::sync::Mutex::new(None);

/// 取目录 mtime（纳秒），失败返回 None
fn dir_mtime_ns(path: &std::path::Path) -> Option<i64> {
    if let Ok(meta) = std::fs::metadata(path) {
        if let Ok(t) = meta.modified() {
            if let Ok(d) = t.duration_since(std::time::UNIX_EPOCH) {
                return Some(d.as_nanos() as i64);
            }
        }
    }
    None
}

/// 多线程遍历 roots，收集文件路径 + 各目录 mtime，返回容器（不替换外部状态）
fn scan_roots(roots: &[std::path::PathBuf]) -> (Vec<String>, HashMap<String, i64>) {
    let max_entries: usize = 1_000_000;
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
    let mut handles = Vec::new();
    for _ in 0..workers {
        let queue = queue.clone();
        let paths = paths.clone();
        let dir_mtimes = dir_mtimes.clone();
        let busy = busy.clone();
        let total = total.clone();
        let stop = stop.clone();
        handles.push(std::thread::spawn(move || {
            let mut local: Vec<String> = Vec::new();
            let mut local_dirs: HashMap<String, i64> = HashMap::new();
            loop {
                if stop.load(std::sync::atomic::Ordering::Relaxed) {
                    break;
                }
                let dir = {
                    let mut q = queue.lock().unwrap();
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
                    local_dirs.insert(dir.to_string_lossy().to_string(), mt);
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
                        if is_dir {
                            if index_skip_dir(&name) {
                                continue;
                            }
                            let mut q = queue.lock().unwrap();
                            q.push(e.path());
                        } else {
                            if total.load(std::sync::atomic::Ordering::Relaxed) >= max_entries {
                                stop.store(true, std::sync::atomic::Ordering::Relaxed);
                            } else {
                                local.push(e.path().to_string_lossy().to_string());
                                if local.len() >= 4096 {
                                    let n = local.len();
                                    paths.lock().unwrap().extend(local.drain(..));
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
                paths.lock().unwrap().extend(local);
            }
            {
                let mut dm = dir_mtimes.lock().unwrap();
                for (k, v) in local_dirs {
                    dm.insert(k, v);
                }
            }
        }));
    }
    for h in handles {
        let _ = h.join();
    }
    let final_paths = paths.lock().unwrap().clone();
    let final_dirs = dir_mtimes.lock().unwrap().clone();
    (final_paths, final_dirs)
}

const INDEX_SKIP_DIRS: &[&str] = &[
    "$recycle.bin",
    "system volume information",
    "windowsapps",
    "$windows.et",
    "recovery",
];

fn index_skip_dir(name: &str) -> bool {
    let lower = name.to_lowercase();
    INDEX_SKIP_DIRS.contains(&lower.as_str())
}

#[no_mangle]
pub extern "C" fn index_build(roots_ptr: *const *const c_char, num_roots: usize) -> i64 {
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

    let (final_paths, final_dirs) = scan_roots(&roots);
    let n = final_paths.len() as i64;
    *INDEX_PATHS.lock().unwrap() = Some(final_paths);
    let root_strs: Vec<String> = roots.iter().map(|p| p.to_string_lossy().to_string()).collect();
    *INDEX_DIR_MTIMES.lock().unwrap() = Some(final_dirs);
    *INDEX_ROOTS.lock().unwrap() = Some(root_strs);
    n
}

#[no_mangle]
pub extern "C" fn index_count() -> i64 {
    match INDEX_PATHS.lock().unwrap().as_ref() {
        Some(v) => v.len() as i64,
        None => -1,
    }
}

/// 释放全盘索引内存（置回 None，Vec 随 drop 归还）
#[no_mangle]
pub extern "C" fn index_free() {
    *INDEX_PATHS.lock().unwrap() = None;
}

#[no_mangle]
pub extern "C" fn index_search(
    query_ptr: *const c_char,
    limit: usize,
    out_ptr: *mut u8,
    out_len: *mut usize,
) -> i32 {
    if out_len.is_null() {
        return -3;
    }
    let query = if query_ptr.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(query_ptr) }
            .to_string_lossy()
            .to_lowercase()
    };
    let guard = INDEX_PATHS.lock().unwrap();
    let data = match guard.as_ref() {
        Some(d) => d,
        None => return -1,
    };
    let mut results: Vec<&str> = Vec::new();
    for p in data {
        let bytes = p.as_bytes();
        // 文件名起点 = 最后一个路径分隔符之后
        let mut start = 0usize;
        let mut i = bytes.len();
        while i > 0 {
            i -= 1;
            if bytes[i] == b'/' || bytes[i] == b'\\' {
                start = i + 1;
                break;
            }
        }
        let name = &p[start..];
        if name.to_lowercase().contains(&query) {
            results.push(p.as_str());
            if results.len() >= limit {
                break;
            }
        }
    }
    let joined = results.join("\n");
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

/// 索引落盘：路径列表 + 各目录 mtime + 根列表，二进制（magic WMIX + version）
#[no_mangle]
pub extern "C" fn index_save(file_ptr: *const c_char) -> i32 {
    let cpath = unsafe { CStr::from_ptr(file_ptr) };
    let path = cpath.to_string_lossy().to_string();
    let f = match std::fs::File::create(&path) {
        Ok(f) => f,
        Err(_) => return -2,
    };
    let mut w = BufWriter::new(f);
    {
        let pg = INDEX_PATHS.lock().unwrap();
        let rg = INDEX_DIR_MTIMES.lock().unwrap();
        let og = INDEX_ROOTS.lock().unwrap();
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
        if w.write_all(&[0x57u8, 0x4d, 0x49, 0x58]).is_err() {
            return -3;
        }
        if w.write_all(&1u32.to_le_bytes()).is_err() {
            return -3;
        }
        // 文件路径
        if w.write_all(&(paths.len() as u64).to_le_bytes()).is_err() {
            return -3;
        }
        for p in paths {
            let b = p.as_bytes();
            if w.write_all(&(b.len() as u32).to_le_bytes()).is_err() {
                return -3;
            }
            if w.write_all(b).is_err() {
                return -3;
            }
        }
        // 目录 mtime
        if w.write_all(&(rmt.len() as u64).to_le_bytes()).is_err() {
            return -3;
        }
        for (k, v) in rmt {
            let b = k.as_bytes();
            if w.write_all(&(b.len() as u32).to_le_bytes()).is_err() {
                return -3;
            }
            if w.write_all(b).is_err() {
                return -3;
            }
            if w.write_all(&v.to_le_bytes()).is_err() {
                return -3;
            }
        }
        // 根列表
        if w.write_all(&(roots.len() as u64).to_le_bytes()).is_err() {
            return -3;
        }
        for r in roots {
            let b = r.as_bytes();
            if w.write_all(&(b.len() as u32).to_le_bytes()).is_err() {
                return -3;
            }
            if w.write_all(b).is_err() {
                return -3;
            }
        }
    }
    match w.flush() {
        Ok(_) => 0,
        Err(_) => -3,
    }
}

/// 从落盘文件恢复索引（成功返回 0）
#[no_mangle]
pub extern "C" fn index_load(file_ptr: *const c_char) -> i32 {
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
    let _ver = u32::from_le_bytes(ver);
    let mut nbuf = [0u8; 8];
    // 文件路径
    if r.read_exact(&mut nbuf).is_err() {
        return -4;
    }
    let fc = u64::from_le_bytes(nbuf);
    let mut paths = Vec::with_capacity(fc as usize);
    for _ in 0..fc {
        let mut lb = [0u8; 4];
        if r.read_exact(&mut lb).is_err() {
            return -4;
        }
        let l = u32::from_le_bytes(lb) as usize;
        let mut buf = vec![0u8; l];
        if r.read_exact(&mut buf).is_err() {
            return -4;
        }
        paths.push(String::from_utf8_lossy(&buf).into_owned());
    }
    // 目录 mtime
    if r.read_exact(&mut nbuf).is_err() {
        return -4;
    }
    let mc = u64::from_le_bytes(nbuf);
    let mut rmt = HashMap::with_capacity(mc as usize);
    for _ in 0..mc {
        let mut lb = [0u8; 4];
        if r.read_exact(&mut lb).is_err() {
            return -4;
        }
        let l = u32::from_le_bytes(lb) as usize;
        let mut buf = vec![0u8; l];
        if r.read_exact(&mut buf).is_err() {
            return -4;
        }
        let key = String::from_utf8_lossy(&buf).into_owned();
        let mut mb = [0u8; 8];
        if r.read_exact(&mut mb).is_err() {
            return -4;
        }
        let mt = i64::from_le_bytes(mb);
        rmt.insert(key, mt);
    }
    // 根列表
    if r.read_exact(&mut nbuf).is_err() {
        return -4;
    }
    let rc = u64::from_le_bytes(nbuf);
    let mut roots = Vec::with_capacity(rc as usize);
    for _ in 0..rc {
        let mut lb = [0u8; 4];
        if r.read_exact(&mut lb).is_err() {
            return -4;
        }
        let l = u32::from_le_bytes(lb) as usize;
        let mut buf = vec![0u8; l];
        if r.read_exact(&mut buf).is_err() {
            return -4;
        }
        roots.push(String::from_utf8_lossy(&buf).into_owned());
    }
    *INDEX_PATHS.lock().unwrap() = Some(paths);
    *INDEX_DIR_MTIMES.lock().unwrap() = Some(rmt);
    *INDEX_ROOTS.lock().unwrap() = Some(roots);
    0
}

/// 增量刷新：比对各根目录 mtime，未变跳过重扫，仅重扫变化的盘/目录。
/// 索引未建立（未 load 也未 build）时返回 -3，调用方应先 buildIndex。
#[no_mangle]
pub extern "C" fn index_refresh(
    roots_ptr: *const *const c_char,
    num_roots: usize,
) -> i64 {
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
                roots.push(std::path::PathBuf::from(s));
            }
        }
    }
    if roots.is_empty() {
        return -2;
    }
    {
        let g = INDEX_PATHS.lock().unwrap();
        if g.is_none() {
            return -3;
        }
    }
    let sep = std::path::MAIN_SEPARATOR;
    for root in &roots {
        let rkey = root.to_string_lossy().to_string();
        let cur = dir_mtime_ns(root);
        let prev = {
            let rmt = INDEX_DIR_MTIMES.lock().unwrap();
            rmt.as_ref().and_then(|m| m.get(&rkey).copied())
        };
        let unchanged = root.exists() && prev.is_some() && cur == prev;
        if unchanged {
            continue;
        }
        // 移除该根旧条目
        {
            let mut pg = INDEX_PATHS.lock().unwrap();
            if let Some(v) = pg.as_mut() {
                let prefix = format!("{}{}", rkey, sep);
                v.retain(|p| p.as_str() != rkey.as_str() && !p.starts_with(prefix.as_str()));
            }
            let mut rmt = INDEX_DIR_MTIMES.lock().unwrap();
            if let Some(m) = rmt.as_mut() {
                let prefix = format!("{}{}", rkey, sep);
                m.retain(|k, _| k.as_str() != rkey.as_str() && !k.starts_with(prefix.as_str()));
            }
        }
        // 重扫该根并并入
        let (local_paths, local_dirs) = scan_roots(&[root.clone()]);
        if !local_paths.is_empty() {
            let mut pg = INDEX_PATHS.lock().unwrap();
            if let Some(v) = pg.as_mut() {
                v.extend(local_paths);
            }
        }
        {
            let mut rmt = INDEX_DIR_MTIMES.lock().unwrap();
            if let Some(m) = rmt.as_mut() {
                m.insert(rkey.clone(), cur.unwrap_or(0));
                for (k, v) in local_dirs {
                    m.insert(k, v);
                }
            }
        }
    }
    let g = INDEX_PATHS.lock().unwrap();
    match g.as_ref() {
        Some(v) => v.len() as i64,
        None => -3,
    }
}