//! 微密归档容器（文件夹加密，format v1）
//!
//! 设计（2026-10-20 定稿）：
//! - 新 magic `WEMI_FARC`，与单文件 `WEIMI_LOCK` / 保险箱 v3 完全隔离，
//!   老版本读到会走"格式不符"分支，不会误当普通 .wemi 解。
//! - 结构：明文头 + Argon2id salt + 加密清单（AES-256-GCM）+ 逐文件加密块。
//!   清单里只有相对路径/大小/offset，**不输密码连文件名都看不到**。
//! - 逐文件独立 GCM 校验：单个文件损坏不连坐整包；支持选择性解密。
//! - KDF 复用 vault::derive_key_v3（Argon2id m=64MB t=3 p=3）。
//! - 文件块布局与单文件格式一致（≤chunk: nonce+ct；否则 nonce+len+ct 循环），
//!   解密端靠 manifest 里的明文大小判定单块/分块，无需试探。
//! - 清单内 offset 为**相对 data_start** 的偏移，避免 manifest 长度循环依赖。

use crate::vault::derive_key_v3;
use aes_gcm::{
    aead::{Aead, KeyInit},
    Aes256Gcm, Nonce,
};
use serde::{Deserialize, Serialize};
use std::ffi::{CStr, CString};
use std::fs::{self, File};
use std::io::{BufReader, BufWriter, Read, Seek, SeekFrom, Write};
use std::os::raw::c_char;
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicI64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

const ARC_MAGIC: &[u8] = b"WEMI_FARC";
const ARC_VERSION: u32 = 1;
const SALT_SIZE: usize = 16;
// magic(9) + version(4) + salt(16) + manifest_nonce(12) + manifest_len(8)
const HEADER_FIXED: u64 = ARC_MAGIC.len() as u64 + 4 + SALT_SIZE as u64 + 12 + 8;
const MAX_FILES: usize = 500_000;
const MAX_MANIFEST_BYTES: u64 = 128 * 1024 * 1024;
const MAX_PATH_LEN: usize = 1024;

static PROGRESS_DONE: AtomicI64 = AtomicI64::new(0);
static PROGRESS_TOTAL: AtomicI64 = AtomicI64::new(0);

fn progress_reset() {
    PROGRESS_DONE.store(0, Ordering::Relaxed);
    PROGRESS_TOTAL.store(0, Ordering::Relaxed);
}

fn progress_add_done(n: u64) {
    PROGRESS_DONE.fetch_add(n as i64, Ordering::Relaxed);
}

#[no_mangle]
pub extern "C" fn archive_progress_done() -> i64 {
    PROGRESS_DONE.load(Ordering::Relaxed)
}

#[no_mangle]
pub extern "C" fn archive_progress_total() -> i64 {
    PROGRESS_TOTAL.load(Ordering::Relaxed)
}

#[derive(Serialize, Deserialize, Debug)]
pub struct ArchiveEntry {
    /// 相对路径（UTF-8，正斜杠）
    pub p: String,
    /// 明文大小
    pub s: u64,
    /// 加密块相对 data_start 的偏移
    pub o: u64,
    /// 加密块总长（含 nonce/len 前缀 + tag）
    pub l: u64,
}

#[derive(Serialize, Deserialize, Debug)]
pub struct Manifest {
    pub v: u32,
    pub created: u64,
    /// 打包时使用的 chunk 大小——解包端必须同参，否则单块/分块判定错位
    pub chunk: u64,
    #[serde(default)]
    pub hint: Option<String>,
    /// 空目录（相对路径，正斜杠）——解包时重建，避免丢结构
    #[serde(default)]
    pub dirs: Vec<String>,
    pub entries: Vec<ArchiveEntry>,
}

/// 文件块加密后的长度（与 encrypt_file_block 的写入严格一致，打包前用于算 offset）
fn block_len(plain: u64, chunk: u64) -> u64 {
    if plain <= chunk {
        12 + plain + 16
    } else {
        let n = (plain + chunk - 1) / chunk;
        n * 16 + plain + n * 16
    }
}

/// 分块大小（与单文件路径共用一套策略）
fn arc_chunk_size(is_mobile: bool) -> u64 {
    crate::get_chunk_size(is_mobile) as u64
}

fn gen_nonce() -> [u8; 12] {
    crate::generate_nonce()
}

fn new_cipher(key: &[u8]) -> Result<Aes256Gcm, String> {
    Aes256Gcm::new_from_slice(key).map_err(|_| "invalid key".to_string())
}

/// 把单个文件加密写入 out（布局：≤chunk → nonce+ct；否则 (nonce+len+ct)*），返回写入字节数
fn encrypt_file_block(
    file: &Path,
    out: &mut BufWriter<File>,
    key: &[u8],
    chunk_size: u64,
    plain_size: u64,
) -> Result<u64, String> {
    let cipher = new_cipher(key)?;
    let mut reader = BufReader::new(File::open(file).map_err(|e| e.to_string())?);
    let mut written: u64 = 0;

    if plain_size <= chunk_size {
        let mut data = Vec::with_capacity(plain_size as usize);
        reader.read_to_end(&mut data).map_err(|e| e.to_string())?;
        let nonce_bytes = gen_nonce();
        let ct = cipher
            .encrypt(Nonce::from_slice(&nonce_bytes), data.as_ref())
            .map_err(|_| "encrypt failed".to_string())?;
        out.write_all(&nonce_bytes).map_err(|e| e.to_string())?;
        out.write_all(&ct).map_err(|e| e.to_string())?;
        written = 12 + ct.len() as u64;
    } else {
        loop {
            let mut buf = vec![0u8; chunk_size as usize];
            let n = reader.read(&mut buf).map_err(|e| e.to_string())?;
            if n == 0 {
                break;
            }
            buf.truncate(n);
            let nonce_bytes = gen_nonce();
            let ct = cipher
                .encrypt(Nonce::from_slice(&nonce_bytes), buf.as_ref())
                .map_err(|_| "encrypt failed".to_string())?;
            out.write_all(&nonce_bytes).map_err(|e| e.to_string())?;
            out.write_all(&(ct.len() as u32).to_be_bytes())
                .map_err(|e| e.to_string())?;
            out.write_all(&ct).map_err(|e| e.to_string())?;
            written += 12 + 4 + ct.len() as u64;
            progress_add_done(n as u64);
        }
    }
    if plain_size <= chunk_size {
        progress_add_done(plain_size);
    }
    Ok(written)
}

/// 从 reader 当前流位置解密一个文件块写到 dest（manifest 已知明文大小，无需试探单块/分块）
fn decrypt_file_block(
    reader: &mut BufReader<File>,
    dest: &Path,
    key: &[u8],
    chunk_size: u64,
    plain_size: u64,
) -> Result<(), String> {
    let cipher = new_cipher(key)?;
    let mut out = BufWriter::new(File::create(dest).map_err(|e| e.to_string())?);

    if plain_size <= chunk_size {
        let mut nonce_bytes = [0u8; 12];
        reader
            .read_exact(&mut nonce_bytes)
            .map_err(|_| "corrupt archive".to_string())?;
        let mut ct = vec![0u8; plain_size as usize + 16];
        reader
            .read_exact(&mut ct)
            .map_err(|_| "corrupt archive".to_string())?;
        let pt = cipher
            .decrypt(Nonce::from_slice(&nonce_bytes), ct.as_ref())
            .map_err(|_| "decrypt failed".to_string())?;
        out.write_all(&pt).map_err(|e| e.to_string())?;
    } else {
        let mut remaining = plain_size;
        while remaining > 0 {
            let mut nonce_bytes = [0u8; 12];
            reader
                .read_exact(&mut nonce_bytes)
                .map_err(|_| "corrupt archive".to_string())?;
            let mut len_bytes = [0u8; 4];
            reader
                .read_exact(&mut len_bytes)
                .map_err(|_| "corrupt archive".to_string())?;
            let ct_len = u32::from_be_bytes(len_bytes) as usize;
            if ct_len < 16 {
                return Err("corrupt archive".to_string());
            }
            let mut ct = vec![0u8; ct_len];
            reader
                .read_exact(&mut ct)
                .map_err(|_| "corrupt archive".to_string())?;
            let pt = cipher
                .decrypt(Nonce::from_slice(&nonce_bytes), ct.as_ref())
                .map_err(|_| "decrypt failed".to_string())?;
            out.write_all(&pt).map_err(|e| e.to_string())?;
            remaining -= (ct_len - 16) as u64;
        }
    }
    out.flush().map_err(|e| e.to_string())?;
    Ok(())
}

/// 路径安全校验：拒绝绝对路径、盘符、.. 穿越（防恶意 manifest）
fn sanitize_rel(p: &str) -> Result<&Path, String> {
    if p.is_empty() || p.len() > MAX_PATH_LEN {
        return Err("bad path".to_string());
    }
    let path = Path::new(p);
    for comp in path.components() {
        match comp {
            Component::Normal(_) => {}
            _ => return Err("path traversal blocked".to_string()),
        }
    }
    Ok(path)
}

/// 递归收集（跳过符号链接，按路径排序保证 manifest 确定性）
fn collect_tree(root: &Path) -> Result<(Vec<(String, PathBuf)>, Vec<String>), String> {
    let mut files: Vec<(String, PathBuf)> = Vec::new();
    let mut dirs: Vec<String> = Vec::new();

    fn walk(
        dir: &Path,
        base: &Path,
        files: &mut Vec<(String, PathBuf)>,
        dirs: &mut Vec<String>,
    ) -> Result<(), String> {
        let rd = fs::read_dir(dir).map_err(|e| format!("{}: {}", dir.display(), e))?;
        for ent in rd {
            let ent = ent.map_err(|e| e.to_string())?;
            let ft = ent.file_type().map_err(|e| e.to_string())?;
            if ft.is_symlink() {
                continue; // 符号链接不跟进（防环 + 防逃逸）
            }
            let path = ent.path();
            if ft.is_dir() {
                if let Ok(rel) = path.strip_prefix(base) {
                    dirs.push(rel.to_string_lossy().replace('\\', "/"));
                }
                walk(&path, base, files, dirs)?;
            } else if ft.is_file() {
                if let Ok(rel) = path.strip_prefix(base) {
                    files.push((rel.to_string_lossy().replace('\\', "/"), path));
                }
            }
        }
        Ok(())
    }

    walk(root, root, &mut files, &mut dirs)?;
    files.sort_by(|a, b| a.0.cmp(&b.0));
    dirs.sort();
    if files.len() > MAX_FILES {
        return Err(format!("too many files: {}", files.len()));
    }
    Ok((files, dirs))
}

struct Header {
    salt: [u8; SALT_SIZE],
    manifest_nonce: [u8; 12],
    manifest_ct: Vec<u8>,
}

/// 读明文头 + 解出 manifest 与内容密钥（密码错 = GCM tag 失败）
fn read_manifest(archive: &Path, password: &[u8]) -> Result<(Manifest, [u8; 32], u64), String> {
    let mut f = BufReader::new(File::open(archive).map_err(|_| "cannot open archive")?);
    let mut magic = vec![0u8; ARC_MAGIC.len()];
    f.read_exact(&mut magic).map_err(|_| "not wemi archive")?;
    if magic != ARC_MAGIC {
        return Err("not wemi archive".to_string());
    }
    let mut ver = [0u8; 4];
    f.read_exact(&mut ver).map_err(|_| "corrupt header")?;
    if u32::from_le_bytes(ver) != ARC_VERSION {
        return Err("unsupported archive version".to_string());
    }
    let mut salt = [0u8; SALT_SIZE];
    f.read_exact(&mut salt).map_err(|_| "corrupt header")?;
    let mut nonce = [0u8; 12];
    f.read_exact(&mut nonce).map_err(|_| "corrupt header")?;
    let mut len_bytes = [0u8; 8];
    f.read_exact(&mut len_bytes).map_err(|_| "corrupt header")?;
    let manifest_len = u64::from_le_bytes(len_bytes);
    if manifest_len > MAX_MANIFEST_BYTES {
        return Err("manifest too large".to_string());
    }
    let mut manifest_ct = vec![0u8; manifest_len as usize];
    f.read_exact(&mut manifest_ct)
        .map_err(|_| "corrupt header".to_string())?;

    let key = derive_key_v3(password, &salt).map_err(|e| e.to_string())?;
    let cipher = new_cipher(&key)?;
    let json = cipher
        .decrypt(Nonce::from_slice(&nonce), manifest_ct.as_ref())
        .map_err(|_| "wrong password or corrupt".to_string())?;
    let manifest: Manifest =
        serde_json::from_slice(&json).map_err(|_| "corrupt manifest".to_string())?;
    if manifest.v != ARC_VERSION {
        return Err("unsupported manifest version".to_string());
    }
    if manifest.entries.len() > MAX_FILES {
        return Err("too many entries".to_string());
    }
    Ok((manifest, key, data_start(manifest_len)))
}

fn data_start(manifest_len: u64) -> u64 {
    HEADER_FIXED + manifest_len
}

/// 打包文件夹 → 单文件归档。返回打包的明文总字节数。
fn pack_folder_internal(
    dir: &Path,
    output: &Path,
    password: &[u8],
    hint: Option<&str>,
    is_mobile: bool,
) -> Result<u64, String> {
    if !dir.is_dir() {
        return Err("source folder not found".to_string());
    }
    let (files, dirs) = collect_tree(dir)?;
    if files.is_empty() {
        return Err("folder is empty".to_string());
    }

    let chunk = arc_chunk_size(is_mobile);
    progress_reset();

    // 1) 预计算每文件块长与相对 offset（布局确定性强依赖）
    let mut entries: Vec<ArchiveEntry> = Vec::with_capacity(files.len());
    let mut rel: u64 = 0;
    let mut total_plain: u64 = 0;
    for (relp, abs) in &files {
        let size = fs::metadata(abs)
            .map_err(|e| format!("{}: {}", relp, e))?
            .len();
        let l = block_len(size, chunk);
        entries.push(ArchiveEntry {
            p: relp.clone(),
            s: size,
            o: rel,
            l,
        });
        rel += l;
        total_plain += size;
    }
    PROGRESS_TOTAL.store(total_plain as i64, Ordering::Relaxed);

    let manifest = Manifest {
        v: ARC_VERSION,
        created: SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0),
        chunk,
        hint: hint.map(|h| h.chars().take(32).collect()),
        dirs,
        entries,
    };

    // 2) 盐 + manifest 加密
    let mut salt = [0u8; SALT_SIZE];
    {
        use rand::RngCore;
        rand::thread_rng().fill_bytes(&mut salt);
    }
    let key = derive_key_v3(password, &salt).map_err(|e| e.to_string())?;
    let cipher = new_cipher(&key)?;
    let manifest_nonce = gen_nonce();
    let manifest_ct = cipher
        .encrypt(
            Nonce::from_slice(&manifest_nonce),
            serde_json::to_vec(&manifest).map_err(|e| e.to_string())?.as_ref(),
        )
        .map_err(|_| "manifest encrypt failed".to_string())?;

    // 3) 写头 + manifest，然后顺序写文件块（实际写入偏移与预算不符即中止）
    let mut out = BufWriter::new(File::create(output).map_err(|e| e.to_string())?);
    out.write_all(ARC_MAGIC).map_err(|e| e.to_string())?;
    out.write_all(&ARC_VERSION.to_le_bytes())
        .map_err(|e| e.to_string())?;
    out.write_all(&salt).map_err(|e| e.to_string())?;
    out.write_all(&manifest_nonce).map_err(|e| e.to_string())?;
    out.write_all(&(manifest_ct.len() as u64).to_le_bytes())
        .map_err(|e| e.to_string())?;
    out.write_all(&manifest_ct).map_err(|e| e.to_string())?;
    let data_start = data_start(manifest_ct.len() as u64);

    for (i, (relp, abs)) in files.iter().enumerate() {
        let written = encrypt_file_block(abs, &mut out, &key, chunk, manifest.entries[i].s)?;
        if written != manifest.entries[i].l {
            return Err("layout mismatch (internal)".to_string());
        }
    }
    out.flush().map_err(|e| e.to_string())?;
    let _ = data_start;
    Ok(total_plain)
}

/// 解包（全部或勾选）。only 为 None = 全部。返回解出的明文字节数。
fn unpack_internal(
    archive: &Path,
    output_dir: &Path,
    password: &[u8],
    only: Option<&[String]>,
) -> Result<u64, String> {
    let (manifest, key, ds) = read_manifest(archive, password)?;
    let chunk = manifest.chunk;

    let mut f = BufReader::new(File::open(archive).map_err(|_| "cannot open archive")?);
    fs::create_dir_all(output_dir).map_err(|e| e.to_string())?;

    let extract_all = only.is_none();
    if extract_all {
        for d in &manifest.dirs {
            if let Ok(rel) = sanitize_rel(d) {
                let _ = fs::create_dir_all(output_dir.join(rel));
            }
        }
    }

    let want: Option<Vec<&str>> = only.map(|v| v.iter().map(|s| s.as_str()).collect());
    let mut done: u64 = 0;
    let mut extracted: u64 = 0;

    for e in &manifest.entries {
        if let Some(w) = &want {
            if !w.contains(&e.p.as_str()) {
                continue;
            }
        }
        let rel = sanitize_rel(&e.p)?;
        let dest = output_dir.join(rel);
        if let Some(parent) = dest.parent() {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        f.seek(SeekFrom::Start(ds + e.o))
            .map_err(|_| "corrupt archive".to_string())?;
        decrypt_file_block(&mut f, &dest, &key, chunk, e.s)?;
        done += e.s;
        extracted += 1;
        progress_add_done(e.s);
    }

    if extracted == 0 && !extract_all {
        return Err("no matching entries".to_string());
    }
    Ok(done)
}

// ---- FFI ----

fn cstr_arg(ptr: *const c_char) -> Result<String, String> {
    if ptr.is_null() {
        return Err("null arg".to_string());
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map(|s| s.to_string())
        .map_err(|_| "bad utf8".to_string())
}

#[no_mangle]
pub extern "C" fn pack_folder(
    dir_path_ptr: *const c_char,
    output_path_ptr: *const c_char,
    password_ptr: *const u8,
    password_len: usize,
    hint_ptr: *const c_char,
    is_mobile: bool,
) -> i32 {
    progress_reset();
    let dir = match cstr_arg(dir_path_ptr) {
        Ok(s) => PathBuf::from(s),
        Err(_) => return -1,
    };
    let out = match cstr_arg(output_path_ptr) {
        Ok(s) => PathBuf::from(s),
        Err(_) => return -1,
    };
    let password = unsafe { std::slice::from_raw_parts(password_ptr, password_len) };
    let hint = if hint_ptr.is_null() {
        None
    } else {
        match cstr_arg(hint_ptr) {
            Ok(s) => Some(s),
            Err(_) => return -1,
        }
    };
    if password.is_empty() {
        return -1;
    }
    match pack_folder_internal(&dir, &out, password, hint.as_deref(), is_mobile) {
        Ok(_) => 0,
        Err(e) => {
            if e == "folder is empty" {
                -3
            } else if e.starts_with("source folder") {
                -4
            } else {
                -2
            }
        }
    }
}

#[no_mangle]
pub extern "C" fn unpack_archive(
    archive_path_ptr: *const c_char,
    output_dir_ptr: *const c_char,
    password_ptr: *const u8,
    password_len: usize,
    is_mobile: bool,
) -> i32 {
    let archive = match cstr_arg(archive_path_ptr) {
        Ok(s) => PathBuf::from(s),
        Err(_) => return -1,
    };
    let out_dir = match cstr_arg(output_dir_ptr) {
        Ok(s) => PathBuf::from(s),
        Err(_) => return -1,
    };
    let password = unsafe { std::slice::from_raw_parts(password_ptr, password_len) };
    if password.is_empty() {
        return -1;
    }
    let _ = is_mobile;
    match unpack_internal(&archive, &out_dir, password, None) {
        Ok(_) => 0,
        Err(e) => {
            if e.contains("wrong password") || e.contains("decrypt failed") {
                -2
            } else if e == "not wemi archive" {
                -3
            } else if e.contains("path traversal") {
                -5
            } else {
                -4
            }
        }
    }
}

/// 输密码后列清单。返回 JSON 字符串（调用方 archive_free_string 释放）：
/// {"ok":true,"entries":[{"p":..,"s":..}],"dirs":[...],"hint":..}
/// 密码错/非归档 → {"ok":false,"code":-2}（不返回 null，便于上层区分）
#[no_mangle]
pub extern "C" fn archive_list(
    archive_path_ptr: *const c_char,
    password_ptr: *const u8,
    password_len: usize,
) -> *mut c_char {
    let archive = match cstr_arg(archive_path_ptr) {
        Ok(s) => PathBuf::from(s),
        Err(_) => return CString::new("{\"ok\":false,\"code\":-1}")
            .map(|c| c.into_raw())
            .unwrap_or(std::ptr::null_mut()),
    };
    let password = unsafe { std::slice::from_raw_parts(password_ptr, password_len) };
    let result = match read_manifest(&archive, password) {
        Ok((m, _, _)) => {
            let entries: Vec<serde_json::Value> = m
                .entries
                .iter()
                .map(|e| serde_json::json!({"p": e.p, "s": e.s}))
                .collect();
            serde_json::json!({
                "ok": true,
                "entries": entries,
                "dirs": m.dirs,
                "hint": m.hint,
            })
            .to_string()
        }
        Err(e) => {
            let code = if e == "not wemi archive" { -3 } else { -2 };
            serde_json::json!({"ok": false, "code": code, "error": e}).to_string()
        }
    };
    match CString::new(result) {
        Ok(c) => c.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// 选择性解密。paths_json 为 JSON 字符串数组（要抽取的相对路径）；null/空 = 全部。
#[no_mangle]
pub extern "C" fn extract_selected(
    archive_path_ptr: *const c_char,
    output_dir_ptr: *const c_char,
    password_ptr: *const u8,
    password_len: usize,
    paths_json_ptr: *const c_char,
) -> i32 {
    let archive = match cstr_arg(archive_path_ptr) {
        Ok(s) => PathBuf::from(s),
        Err(_) => return -1,
    };
    let out_dir = match cstr_arg(output_dir_ptr) {
        Ok(s) => PathBuf::from(s),
        Err(_) => return -1,
    };
    let password = unsafe { std::slice::from_raw_parts(password_ptr, password_len) };
    let only: Option<Vec<String>> = if paths_json_ptr.is_null() {
        None
    } else {
        match cstr_arg(paths_json_ptr) {
            Ok(s) if s.trim().is_empty() => None,
            Ok(s) => match serde_json::from_str::<Vec<String>>(&s) {
                Ok(v) if v.is_empty() => None,
                Ok(v) => Some(v),
                Err(_) => return -1,
            },
            Err(_) => return -1,
        }
    };
    match unpack_internal(&archive, &out_dir, password, only.as_deref()) {
        Ok(_) => 0,
        Err(e) => {
            if e.contains("wrong password") || e.contains("decrypt failed") {
                -2
            } else if e == "not wemi archive" {
                -3
            } else if e.contains("path traversal") {
                -5
            } else if e == "no matching entries" {
                -6
            } else {
                -4
            }
        }
    }
}

#[no_mangle]
pub extern "C" fn archive_free_string(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        drop(CString::from_raw(ptr));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!("wm_arc_test_{}_{}", name, std::process::id()));
        let _ = fs::remove_dir_all(&p);
        fs::create_dir_all(&p).unwrap();
        p
    }

    fn setup_src(tag: &str) -> PathBuf {
        let src = tmp(&format!("src_{}", tag));
        fs::create_dir_all(src.join("sub/deep")).unwrap();
        fs::write(src.join("a.txt"), b"hello archive").unwrap();
        fs::write(src.join("sub/b.bin"), vec![7u8; 300 * 1024]).unwrap(); // 跨 chunk（测试用 chunk 极小不便，走单块路径）
        fs::write(src.join("sub/deep/中文名.txt"), "内容".as_bytes()).unwrap();
        fs::write(src.join("empty.dat"), b"").unwrap();
        fs::create_dir_all(src.join("emptydir")).unwrap();
        src
    }

    #[test]
    fn roundtrip_full() {
        let src = setup_src("rt");
        let arc = tmp("out").join("farc.wemi");
        let dst = tmp("out").join("dst");
        let pw = b"TestPass123";

        let total = pack_folder_internal(&src, &arc, pw, Some("提示语"), false).unwrap();
        assert!(total > 0);
        assert!(arc.exists());

        // 布局自校验：HEADER_FIXED + manifest_len + Σl == 文件实际大小
        {
            let raw = fs::read(&arc).unwrap();
            let manifest_len = u64::from_le_bytes(raw[41..49].try_into().unwrap());
            let ds = HEADER_FIXED + manifest_len;
            let (m, _, _) = read_manifest(&arc, pw).unwrap();
            let sum: u64 = m.entries.iter().map(|e| e.l).sum();
            assert_eq!(raw.len() as u64, ds + sum, "archive layout mismatch");
        }

        // 无密码读 manifest 必须失败（清单加密验证）
        assert!(read_manifest(&arc, b"wrong-pass").is_err());

        unpack_internal(&arc, &dst, pw, None).unwrap();
        assert_eq!(
            fs::read(src.join("a.txt")).unwrap(),
            fs::read(dst.join("a.txt")).unwrap()
        );
        assert_eq!(
            fs::read(src.join("sub/b.bin")).unwrap(),
            fs::read(dst.join("sub/b.bin")).unwrap()
        );
        assert_eq!(
            fs::read(src.join("sub/deep/中文名.txt")).unwrap(),
            fs::read(dst.join("sub/deep/中文名.txt")).unwrap()
        );
        assert_eq!(
            fs::read(src.join("empty.dat")).unwrap(),
            fs::read(dst.join("empty.dat")).unwrap()
        );
        assert!(dst.join("emptydir").is_dir());
    }

    #[test]
    fn wrong_password_rejected() {
        let src = setup_src("wp");
        let arc = tmp("out2").join("farc.wemi");
        let dst = tmp("out2").join("dst");
        pack_folder_internal(&src, &arc, b"right-pass", None, false).unwrap();
        let e = unpack_internal(&arc, &dst, b"wrong-pass", None).unwrap_err();
        assert!(e.contains("wrong password"));
    }

    #[test]
    fn selective_extract() {
        let src = setup_src("se");
        let arc = tmp("out3").join("farc.wemi");
        let dst = tmp("out3").join("dst");
        pack_folder_internal(&src, &arc, b"pw-selective", None, false).unwrap();
        unpack_internal(
            &arc,
            &dst,
            b"pw-selective",
            Some(&["a.txt".to_string(), "sub/deep/中文名.txt".to_string()]),
        )
        .unwrap();
        assert!(dst.join("a.txt").exists());
        assert!(dst.join("sub/deep/中文名.txt").exists());
        assert!(!dst.join("sub/b.bin").exists());
    }

    #[test]
    fn empty_folder_rejected() {
        let src = tmp("empty_src");
        fs::create_dir_all(&src).unwrap();
        let arc = tmp("out4").join("farc.wemi");
        let e = pack_folder_internal(&src, &arc, b"pw", None, false).unwrap_err();
        assert_eq!(e, "folder is empty");
    }

    #[test]
    fn bad_magic_rejected() {
        let junk = tmp("junk_dir").join("junk.wemi");
        fs::write(&junk, b"NOTMAGICAT_ALL__").unwrap();
        let e = read_manifest(&junk, b"pw").unwrap_err();
        assert_eq!(e, "not wemi archive");
    }

    #[test]
    fn block_pair_roundtrip() {
        // 最小对：encrypt_file_block → decrypt_file_block 同进程直接验证
        // 同时覆盖单块与分块两种布局（分块在真实打包里要 >256MB 才触发）
        let d = tmp("dbg");
        let srcf = d.join("in.bin");
        let data: Vec<u8> = (0..10_000u32).map(|i| (i % 251) as u8).collect();
        fs::write(&srcf, &data).unwrap();
        for (tag, chunk) in [("single", 256 * 1024 * 1024u64), ("chunked", 1024u64)] {
            let key = [42u8; 32];
            let blk = d.join(format!("blk_{}.bin", tag));
            {
                let mut out = BufWriter::new(File::create(&blk).unwrap());
                let n = encrypt_file_block(&srcf, &mut out, &key, chunk, data.len() as u64).unwrap();
                out.flush().unwrap();
                // 布局预算校验
                assert_eq!(n, block_len(data.len() as u64, chunk), "{} layout", tag);
            }
            let mut f = BufReader::new(File::open(&blk).unwrap());
            let out_bin = d.join(format!("out_{}.bin", tag));
            decrypt_file_block(&mut f, &out_bin, &key, chunk, data.len() as u64).unwrap();
            assert_eq!(fs::read(&out_bin).unwrap(), data, "{} roundtrip", tag);
        }
    }

    #[test]
    fn traversal_blocked() {
        // 构造恶意 manifest：路径带 .. 必须被拒
        let m = Manifest {
            v: ARC_VERSION,
            created: 0,
            chunk: 1024,
            hint: None,
            dirs: vec![],
            entries: vec![ArchiveEntry {
                p: "../evil.txt".to_string(),
                s: 0,
                o: 0,
                l: 28,
            }],
        };
        assert!(sanitize_rel(&m.entries[0].p).is_err());
    }

    #[test]
    fn single_file_corruption_isolated() {
        let src = tmp("src5");
        fs::create_dir_all(&src).unwrap();
        fs::write(src.join("one"), vec![1u8; 1000]).unwrap();
        fs::write(src.join("two"), vec![2u8; 1000]).unwrap();
        let arc = tmp("out5").join("farc.wemi");
        let dst = tmp("out5").join("dst"); // 先取路径（tmp 会清目录，必须在 pack 前调用）
        pack_folder_internal(&src, &arc, b"pw-corrupt", None, false).unwrap();

        // 破坏第二个文件块中间一个字节（定位在 manifest 之后的数据区）
        let mut buf = fs::read(&arc).unwrap();
        let (m, _, ds) = read_manifest(&arc, b"pw-corrupt").unwrap();
        let second = &m.entries[1];
        let flip = (ds + second.o + 20) as usize;
        if flip < buf.len() {
            buf[flip] ^= 0xFF;
        }
        fs::write(&arc, &buf).unwrap();

        // 全量解包必然报错（tag 校验），但错误应精确到 decrypt failed
        let e = unpack_internal(&arc, &dst, b"pw-corrupt", None).unwrap_err();
        assert!(e.contains("decrypt failed") || e.contains("corrupt"));

        // 第一个文件仍应可单独解出（损坏不连坐）
        unpack_internal(&arc, &dst, b"pw-corrupt", Some(&["one".to_string()])).unwrap();
        assert_eq!(fs::read(dst.join("one")).unwrap(), vec![1u8; 1000]);
    }
}
