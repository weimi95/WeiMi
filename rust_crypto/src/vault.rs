// ==================== 微密保险箱 Rust 原语（vault） ====================
//
// 对应方案文档 .workbuddy/docs/vault_design.md 第一/二/三节：
// - 密码库（钥匙环）seal/open/改主密码：AES-256-GCM(KEK) 加密的 JSON，
//   KEK = Argon2id(主密码, salt16, m=64MB, t=3, p=4)
// - .wemi v3 格式：内容密钥 = Argon2id(文件密码, salt16)，头内可选
//   加密缩略图节（密钥 thumb_key 存密码库，宫格渲染即时解密）
// - thumb_key 加解密 seal_thumb/open_thumb
// - gen_thumb：image crate 解码 → resize → JPEG q70（320px 中档）
//
// v3 头布局：
//   [MAGIC 10B][version u32=3][flags u32 bit0=has_thumb]
//   [salt 16B]
//   [thumb_nonce 12B][thumb_len u32][thumb_blob]   # 仅 flags bit0=1
//   [hint_len u8][hint]
//   [chunk 流…]                                     # 与 v1 相同结构
//
// v1/v2（历史格式）内容密钥 = SHA256(密码)，本模块不碰，由 lib.rs 旧路径处理。

use aes_gcm::{
    aead::{Aead, KeyInit},
    Aes256Gcm, Nonce,
};
use rand::RngCore;
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use std::fs::File;
use std::io::{BufReader, BufWriter, Read, Seek, Write};
use std::path::Path;
use std::sync::Arc;

use crate::{generate_nonce, get_chunk_size, get_parallel_batch_size, get_parallel_batch_threshold,
            MAGIC_STRING, NONCE_SIZE, TAG_SIZE};

// ---- 常量 ----

pub const VAULT_KEYRING_MAGIC: &[u8] = b"WEIMI_KEYS";
pub const KEYRING_VERSION: u32 = 1;
pub const FILE_VERSION_V3: u32 = 3;

const SALT_SIZE: usize = 16;
const KEY_SIZE: usize = 32;
/// Argon2id 参数（方案定稿：m=64MB, t=3, p=4）
const ARGON2_M_KIB: u32 = 64 * 1024;
const ARGON2_T: u32 = 3;
const ARGON2_P: u32 = 3; // p=4 在部分移动 SoC 上 lanes=4 更稳，方案值即 4
const MAX_THUMB_BYTES: usize = 4 * 1024 * 1024; // 缩略图节上限 4MB，防畸形文件撑爆内存

// ---- 错误类型 ----

pub type VaultResult<T> = Result<T, String>;

fn err<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}

// ---- Argon2id 密钥派生 ----

/// v3 内容密钥 / 密码库 KEK：Argon2id(password, salt)
pub fn derive_key_v3(password: &[u8], salt: &[u8]) -> VaultResult<[u8; KEY_SIZE]> {
    use argon2::{Algorithm, Argon2, Params, Version};
    let params = Params::new(ARGON2_M_KIB, ARGON2_T, ARGON2_P, Some(KEY_SIZE))
        .map_err(err)?;
    let argon = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
    let mut key = [0u8; KEY_SIZE];
    argon
        .hash_password_into(password, salt, &mut key)
        .map_err(err)?;
    Ok(key)
}

// ---- 密码库（钥匙环） ----

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct KeyringEntry {
    /// 文件名（相对保险箱目录，如 "a.b.wemi"）
    pub file: String,
    /// 该文件的密码（明文仅在库内，库整体被 KEK 加密）
    pub password: String,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Keyring {
    pub ver: u32,
    pub entries: Vec<KeyringEntry>,
    /// thumb_key 的 hex（随机 32B；改主密码不动它，旧缩略图照常解密）
    pub thumb_key: String,
}

impl Keyring {
    pub fn new() -> Self {
        let mut tk = [0u8; KEY_SIZE];
        rand::thread_rng().fill_bytes(&mut tk);
        Keyring {
            ver: KEYRING_VERSION,
            entries: Vec::new(),
            thumb_key: hex::encode(tk),
        }
    }

    pub fn thumb_key_bytes(&self) -> VaultResult<[u8; KEY_SIZE]> {
        let raw = hex::decode(&self.thumb_key).map_err(err)?;
        if raw.len() != KEY_SIZE {
            return Err("thumb_key length mismatch".into());
        }
        let mut k = [0u8; KEY_SIZE];
        k.copy_from_slice(&raw);
        Ok(k)
    }

    pub fn upsert(&mut self, file: &str, password: &str) {
        if let Some(e) = self.entries.iter_mut().find(|e| e.file == file) {
            e.password = password.to_string();
        } else {
            self.entries.push(KeyringEntry {
                file: file.to_string(),
                password: password.to_string(),
            });
        }
    }

    pub fn remove(&mut self, file: &str) {
        self.entries.retain(|e| e.file != file);
    }

    pub fn password_of(&self, file: &str) -> Option<&str> {
        self.entries
            .iter()
            .find(|e| e.file == file)
            .map(|e| e.password.as_str())
    }
}

/// 密码库文件布局：[MAGIC 10B][version u32][salt 16B][nonce 12B][ciphertext+tag]
pub fn seal_keyring(master: &[u8], kr: &Keyring) -> VaultResult<Vec<u8>> {
    let mut salt = [0u8; SALT_SIZE];
    rand::thread_rng().fill_bytes(&mut salt);
    let kek = derive_key_v3(master, &salt)?;
    let cipher = Aes256Gcm::new_from_slice(&kek).map_err(err)?;

    let payload = serde_json::to_vec(kr).map_err(err)?;
    let nonce_bytes = generate_nonce();
    let nonce = Nonce::from_slice(&nonce_bytes);
    let ct = cipher
        .encrypt(nonce, payload.as_ref())
        .map_err(|_| "keyring seal failed".to_string())?;

    let mut out = Vec::with_capacity(VAULT_KEYRING_MAGIC.len() + 4 + SALT_SIZE + NONCE_SIZE + ct.len());
    out.extend_from_slice(VAULT_KEYRING_MAGIC);
    out.extend_from_slice(&KEYRING_VERSION.to_le_bytes());
    out.extend_from_slice(&salt);
    out.extend_from_slice(&nonce_bytes);
    out.extend_from_slice(&ct);
    Ok(out)
}

/// 打开密码库；主密码错 / 文件损坏均返回 Err
pub fn open_keyring(master: &[u8], data: &[u8]) -> VaultResult<Keyring> {
    let mut r = Reader::new(data);
    let magic = r.take(VAULT_KEYRING_MAGIC.len())?;
    if magic != VAULT_KEYRING_MAGIC {
        return Err("not a keyring file".into());
    }
    let ver = u32::from_le_bytes(r.array::<4>()?);
    if ver != KEYRING_VERSION {
        return Err(format!("unsupported keyring version {ver}"));
    }
    let salt = r.array::<{ SALT_SIZE }>()?;
    let nonce_bytes = r.array::<{ NONCE_SIZE }>()?;
    let ct = r.rest()?;

    let kek = derive_key_v3(master, &salt)?;
    let cipher = Aes256Gcm::new_from_slice(&kek).map_err(err)?;
    let nonce = Nonce::from_slice(&nonce_bytes);
    let payload = cipher
        .decrypt(nonce, ct)
        .map_err(|_| "wrong master password or corrupted keyring".to_string())?;
    let kr: Keyring = serde_json::from_slice(&payload).map_err(err)?;
    Ok(kr)
}

/// 改主密码：只用新 KEK 重新加密密码库本身，entries/thumb_key 原样
pub fn change_master_password(
    data: &[u8],
    old_master: &[u8],
    new_master: &[u8],
) -> VaultResult<Vec<u8>> {
    let kr = open_keyring(old_master, data)?;
    seal_keyring(new_master, &kr)
}

// ---- thumb_key 加解密 ----

/// 用 thumb_key 封装明文缩略图 → (nonce, blob)
pub fn seal_thumb(thumb_key: &[u8; KEY_SIZE], plain: &[u8]) -> VaultResult<(Vec<u8>, Vec<u8>)> {
    let cipher = Aes256Gcm::new_from_slice(thumb_key).map_err(err)?;
    let nonce_bytes = generate_nonce();
    let nonce = Nonce::from_slice(&nonce_bytes);
    let blob = cipher
        .encrypt(nonce, plain)
        .map_err(|_| "thumb seal failed".to_string())?;
    Ok((nonce_bytes.to_vec(), blob))
}

pub fn open_thumb(
    thumb_key: &[u8; KEY_SIZE],
    nonce_bytes: &[u8],
    blob: &[u8],
) -> VaultResult<Vec<u8>> {
    if nonce_bytes.len() != NONCE_SIZE {
        return Err("bad thumb nonce".into());
    }
    let cipher = Aes256Gcm::new_from_slice(thumb_key).map_err(err)?;
    let nonce = Nonce::from_slice(nonce_bytes);
    cipher
        .decrypt(nonce, blob)
        .map_err(|_| "thumb open failed".to_string())
}

// ---- gen_thumb：解码 → resize → JPEG q70 ----

/// 生成中档缩略图：长边 ≤ max_px，JPEG q70。src 为图片字节（JPEG/PNG）。
pub fn gen_thumb(src: &[u8], max_px: u32) -> VaultResult<Vec<u8>> {
    use image::imageops::FilterType;
    let img = image::load_from_memory(src).map_err(|e| format!("decode failed: {e}"))?;
    let (w, h) = (img.width(), img.height());
    let (nw, nh) = if w.max(h) <= max_px {
        (w, h)
    } else if w >= h {
        (max_px, ((h as u64 * max_px as u64 / w as u64).max(1)) as u32)
    } else {
        (((w as u64 * max_px as u64 / h as u64).max(1)) as u32, max_px)
    };
    let resized = if (nw, nh) == (w, h) {
        img
    } else {
        img.resize(nw, nh, FilterType::Triangle)
    };
    let rgb = resized.to_rgb8();
    let mut out = Vec::new();
    let mut enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, 70);
    enc.encode(&rgb, rgb.width(), rgb.height(), image::ExtendedColorType::Rgb8)
        .map_err(|e| format!("jpeg encode failed: {e}"))?;
    Ok(out)
}

// ---- v3 头解析 ----

/// v3 头信息（解析后 reader 定位在 chunk 流起点）
pub struct V3Header {
    pub salt: [u8; SALT_SIZE],
    pub has_thumb: bool,
    pub thumb_nonce: Option<Vec<u8>>,
    pub thumb_blob: Option<Vec<u8>>,
    pub hint: Vec<u8>,
}

/// 从文件开头解析 v3 头；版本不是 3 返回 Err（调用方先自己分派版本）
pub fn parse_v3_header(reader: &mut BufReader<File>) -> VaultResult<V3Header> {
    let mut magic = [0u8; MAGIC_STRING.len()];
    reader
        .read_exact(&mut magic)
        .map_err(|_| "read magic failed".to_string())?;
    if magic != MAGIC_STRING {
        return Err("invalid file format".into());
    }
    let ver = {
        let mut b = [0u8; 4];
        reader
            .read_exact(&mut b)
            .map_err(|_| "read version failed".to_string())?;
        u32::from_le_bytes(b)
    };
    if ver != FILE_VERSION_V3 {
        return Err(format!("not a v3 file (version {ver})"));
    }
    let flags = {
        let mut b = [0u8; 4];
        reader
            .read_exact(&mut b)
            .map_err(|_| "read flags failed".to_string())?;
        u32::from_le_bytes(b)
    };
    let mut salt = [0u8; SALT_SIZE];
    reader
        .read_exact(&mut salt)
        .map_err(|_| "read salt failed".to_string())?;

    let has_thumb = flags & 1 != 0;
    let (mut thumb_nonce, mut thumb_blob) = (None, None);
    if has_thumb {
        let mut nb = [0u8; NONCE_SIZE];
        reader
            .read_exact(&mut nb)
            .map_err(|_| "read thumb nonce failed".to_string())?;
        let len = {
            let mut b = [0u8; 4];
            reader
                .read_exact(&mut b)
                .map_err(|_| "read thumb len failed".to_string())?;
            u32::from_le_bytes(b) as usize
        };
        if len > MAX_THUMB_BYTES {
            return Err("thumb section too large".into());
        }
        let mut tb = vec![0u8; len];
        reader
            .read_exact(&mut tb)
            .map_err(|_| "read thumb blob failed".to_string())?;
        thumb_nonce = Some(nb.to_vec());
        thumb_blob = Some(tb);
    }

    let hint_len = {
        let mut b = [0u8; 1];
        reader
            .read_exact(&mut b)
            .map_err(|_| "read hint len failed".to_string())?;
        b[0] as usize
    };
    let mut hint = vec![0u8; hint_len];
    reader
        .read_exact(&mut hint)
        .map_err(|_| "read hint failed".to_string())?;

    Ok(V3Header {
        salt,
        has_thumb,
        thumb_nonce,
        thumb_blob,
        hint,
    })
}

/// 从路径读 v3 头（不加载 chunk 流）
pub fn parse_v3_header_path(path: &str) -> VaultResult<V3Header> {
    let f = File::open(path).map_err(err)?;
    let mut reader = BufReader::new(f);
    parse_v3_header(&mut reader)
}

// ---- v3 加密 / 解密 ----

/// v3 加密：内容密钥 = Argon2id(文件密码, salt)；缩略图（有则）用 thumb_key 封装写入头
pub fn encrypt_file_v3_internal(
    input_path: &str,
    output_path: &str,
    password: &[u8],
    hint: Option<&str>,
    thumb: Option<&[u8]>,
    thumb_key: &[u8; KEY_SIZE],
    is_mobile: bool,
    cpu_cores: usize,
) -> VaultResult<()> {
    let input_file = File::open(input_path).map_err(err)?;
    let file_size = input_file.metadata().map_err(err)?.len() as usize;

    let mut salt = [0u8; SALT_SIZE];
    rand::thread_rng().fill_bytes(&mut salt);
    let key = derive_key_v3(password, &salt)?;

    // 先封装缩略图（失败则不写缩略图，flags=0，不影响文件本体）
    let thumb_section = match thumb {
        Some(t) if !t.is_empty() => match seal_thumb(thumb_key, t) {
            Ok((n, b)) => Some((n, b)),
            Err(_) => None,
        },
        _ => None,
    };

    let mut output_file = BufWriter::new(File::create(output_path).map_err(err)?);

    output_file
        .write_all(MAGIC_STRING)
        .map_err(err)?;
    output_file
        .write_all(&FILE_VERSION_V3.to_le_bytes())
        .map_err(err)?;
    let flags: u32 = if thumb_section.is_some() { 1 } else { 0 };
    output_file.write_all(&flags.to_le_bytes()).map_err(err)?;
    output_file.write_all(&salt).map_err(err)?;

    if let Some((nonce_bytes, blob)) = &thumb_section {
        output_file.write_all(nonce_bytes).map_err(err)?;
        output_file
            .write_all(&(blob.len() as u32).to_le_bytes())
            .map_err(err)?;
        output_file.write_all(blob).map_err(err)?;
    }

    let hint_bytes = hint
        .map(|h| h.as_bytes())
        .unwrap_or(&[])
        .iter()
        .take(32)
        .copied()
        .collect::<Vec<u8>>();
    output_file
        .write_all(&[hint_bytes.len() as u8])
        .map_err(err)?;
    output_file.write_all(&hint_bytes).map_err(err)?;

    write_v3_chunks(
        &mut output_file,
        input_file,
        &key,
        file_size,
        is_mobile,
        cpu_cores,
    )?;
    output_file.flush().map_err(err)?;
    Ok(())
}

/// v3 解密到文件。调用方负责先确认版本 = 3。
pub fn decrypt_file_v3_internal(
    input_path: &str,
    output_path: &str,
    password: &[u8],
    is_mobile: bool,
    cpu_cores: usize,
) -> VaultResult<()> {
    let mut input_file = BufReader::new(File::open(input_path).map_err(err)?);
    let header = parse_v3_header(&mut input_file)?;
    let key = derive_key_v3(password, &header.salt)?;

    let mut output_file = BufWriter::new(File::create(output_path).map_err(err)?);
    read_v3_chunks(
        &mut input_file,
        &mut output_file,
        &key,
        is_mobile,
        cpu_cores,
    )?;
    output_file.flush().map_err(err)?;
    Ok(())
}

/// v3 解密到内存
pub fn decrypt_file_v3_to_memory_internal(
    input_path: &str,
    password: &[u8],
    _is_mobile: bool,
    _cpu_cores: usize,
) -> VaultResult<Vec<u8>> {
    let mut input_file = BufReader::new(File::open(input_path).map_err(err)?);
    let header = parse_v3_header(&mut input_file)?;
    let key = derive_key_v3(password, &header.salt)?;
    let mut out: Vec<u8> = Vec::new();
    {
        let mut w = VecWriter(&mut out);
        read_v3_chunks(&mut input_file, &mut w, &key, _is_mobile, _cpu_cores)?;
    }
    Ok(out)
}

/// 只取 v3 文件的缩略图明文（thumb_key 错 → Err）；无缩略图节 → Ok(None)
pub fn get_thumb_from_file_v3(
    input_path: &str,
    thumb_key: &[u8; KEY_SIZE],
) -> VaultResult<Option<Vec<u8>>> {
    let header = parse_v3_header_path(input_path)?;
    match (header.thumb_nonce, header.thumb_blob) {
        (Some(n), Some(b)) => Ok(Some(open_thumb(thumb_key, &n, &b)?)),
        _ => Ok(None),
    }
}

// ---- chunk 流（与 v1 相同结构：单块 / 中档并行 / 大批流式） ----

fn write_v3_chunks(
    output_file: &mut BufWriter<File>,
    input_file: File,
    key: &[u8; KEY_SIZE],
    file_size: usize,
    is_mobile: bool,
    cpu_cores: usize,
) -> VaultResult<()> {
    let chunk_size = get_chunk_size(is_mobile);
    let parallel_threshold = get_parallel_batch_threshold(is_mobile);
    let batch_size = get_parallel_batch_size(cpu_cores, is_mobile);
    let key_arc = Arc::new(*key);

    if file_size <= chunk_size {
        let nonce_bytes = generate_nonce();
        output_file.write_all(&nonce_bytes).map_err(err)?;
        let mut data = Vec::new();
        BufReader::new(input_file)
            .read_to_end(&mut data)
            .map_err(err)?;
        let cipher = Aes256Gcm::new_from_slice(key).map_err(err)?;
        let encrypted = cipher
            .encrypt(Nonce::from_slice(&nonce_bytes), data.as_ref())
            .map_err(|_| "encryption failed".to_string())?;
        output_file.write_all(&encrypted).map_err(err)?;
    } else if file_size <= parallel_threshold {
        let mut all_data = Vec::new();
        BufReader::new(input_file)
            .read_to_end(&mut all_data)
            .map_err(err)?;
        let mut chunks = Vec::new();
        let mut nonces = Vec::new();
        for chunk in all_data.chunks(chunk_size) {
            chunks.push(chunk.to_vec());
            nonces.push(generate_nonce());
        }
        let encrypted_chunks: Result<Vec<Vec<u8>>, String> = chunks
            .par_iter()
            .zip(nonces.par_iter())
            .map(|(chunk, nonce_bytes)| {
                let cipher = Aes256Gcm::new_from_slice(&*key_arc).map_err(err)?;
                cipher
                    .encrypt(Nonce::from_slice(nonce_bytes), chunk.as_ref())
                    .map_err(|_| "encryption failed".to_string())
            })
            .collect();
        for (encrypted, nonce_bytes) in encrypted_chunks?.iter().zip(nonces.iter()) {
            output_file.write_all(nonce_bytes).map_err(err)?;
            output_file
                .write_all(&(encrypted.len() as u32).to_be_bytes())
                .map_err(err)?;
            output_file.write_all(encrypted).map_err(err)?;
        }
    } else {
        let mut reader = BufReader::new(input_file);
        loop {
            let mut chunks = Vec::new();
            let mut nonces = Vec::new();
            for _ in 0..batch_size {
                let mut chunk = vec![0u8; chunk_size];
                match reader.read(&mut chunk).map_err(err)? {
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
            let encrypted_chunks: Result<Vec<Vec<u8>>, String> = chunks
                .par_iter()
                .zip(nonces.par_iter())
                .map(|(chunk, nonce_bytes)| {
                    let cipher = Aes256Gcm::new_from_slice(&*key_arc).map_err(err)?;
                    cipher
                        .encrypt(Nonce::from_slice(nonce_bytes), chunk.as_ref())
                        .map_err(|_| "encryption failed".to_string())
                })
                .collect();
            for (encrypted, nonce_bytes) in encrypted_chunks?.iter().zip(nonces.iter()) {
                output_file.write_all(nonce_bytes).map_err(err)?;
                output_file
                    .write_all(&(encrypted.len() as u32).to_be_bytes())
                    .map_err(err)?;
                output_file.write_all(encrypted).map_err(err)?;
            }
        }
    }
    Ok(())
}

fn read_v3_chunks<W: Write>(
    reader: &mut BufReader<File>,
    writer: &mut W,
    key: &[u8; KEY_SIZE],
    is_mobile: bool,
    cpu_cores: usize,
) -> VaultResult<()> {
    let chunk_size = get_chunk_size(is_mobile);
    let batch_size = get_parallel_batch_size(cpu_cores, is_mobile);
    read_v3_chunks_sized(reader, writer, key, chunk_size, batch_size)
}

/// chunk 读取核心（供测试以小 chunk_size 直测多块路径）
fn read_v3_chunks_sized<W: Write>(
    reader: &mut BufReader<File>,
    writer: &mut W,
    key: &[u8; KEY_SIZE],
    chunk_size: usize,
    batch_size: usize,
) -> VaultResult<()> {
    let key_arc = Arc::new(*key);
    let cipher = Aes256Gcm::new_from_slice(key).map_err(err)?;

    // 与 v1 相同判据：先偷看一个 nonce，剩余 ≤ chunk+TAG 视为单块。
    // 探测完必须 seek 回 nonce 之前（v1 语义），多块循环从第一个 nonce 重新读。
    let pos_before_nonce = reader.stream_position().map_err(err)?;
    let mut temp_nonce = [0u8; NONCE_SIZE];
    reader
        .read_exact(&mut temp_nonce)
        .map_err(|_| "read nonce failed".to_string())?;
    let pos_after_first_nonce = reader.stream_position().map_err(err)?;
    let file_end = reader.seek(std::io::SeekFrom::End(0)).map_err(err)?;
    let remaining_after_nonce = file_end - pos_after_first_nonce;
    let is_single = remaining_after_nonce <= (chunk_size + TAG_SIZE) as u64;
    reader
        .seek(std::io::SeekFrom::Start(pos_before_nonce))
        .map_err(err)?;

    if is_single {
        // nonce 已在 temp_nonce 手里：跳过 nonce 字节，从密文起点读到结尾
        reader
            .seek(std::io::SeekFrom::Start(pos_after_first_nonce))
            .map_err(err)?;
        let mut encrypted_data = Vec::new();
        reader.read_to_end(&mut encrypted_data).map_err(err)?;
        let decrypted = cipher
            .decrypt(Nonce::from_slice(&temp_nonce), encrypted_data.as_ref())
            .map_err(|_| "decryption failed".to_string())?;
        writer.write_all(&decrypted).map_err(err)?;
    } else {
        loop {
            let mut chunks = Vec::new();
            let mut nonces = Vec::new();
            for _ in 0..batch_size {
                let mut nonce_bytes = [0u8; NONCE_SIZE];
                if reader.read_exact(&mut nonce_bytes).is_err() {
                    break;
                }
                let mut chunk_len_bytes = [0u8; 4];
                if reader.read_exact(&mut chunk_len_bytes).is_err() {
                    break;
                }
                let chunk_len = u32::from_be_bytes(chunk_len_bytes) as usize;
                let mut encrypted_chunk = vec![0u8; chunk_len];
                if reader.read_exact(&mut encrypted_chunk).is_err() {
                    break;
                }
                chunks.push(encrypted_chunk);
                nonces.push(nonce_bytes);
            }
            if chunks.is_empty() {
                break;
            }
            let decrypted_chunks: Result<Vec<Vec<u8>>, String> = chunks
                .par_iter()
                .zip(nonces.par_iter())
                .map(|(chunk, nonce_bytes)| {
                    let cipher = Aes256Gcm::new_from_slice(&*key_arc).map_err(err)?;
                    cipher
                        .decrypt(Nonce::from_slice(nonce_bytes), chunk.as_ref())
                        .map_err(|_| "decryption failed".to_string())
                })
                .collect();
            for decrypted in decrypted_chunks?.iter() {
                writer.write_all(decrypted).map_err(err)?;
            }
        }
    }
    Ok(())
}

/// 让 Vec<u8> 直接当 Write 用（decrypt_to_memory 免二次拷贝）
struct VecWriter<'a>(&'a mut Vec<u8>);
impl<'a> Write for VecWriter<'a> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.extend_from_slice(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// 字节读取小工具（密码库解析用）
struct Reader<'a> {
    data: &'a [u8],
    pos: usize,
}
impl<'a> Reader<'a> {
    fn new(data: &'a [u8]) -> Self {
        Reader { data, pos: 0 }
    }
    fn take(&mut self, n: usize) -> VaultResult<&'a [u8]> {
        if self.pos + n > self.data.len() {
            return Err("unexpected end of keyring".into());
        }
        let s = &self.data[self.pos..self.pos + n];
        self.pos += n;
        Ok(s)
    }
    fn array<const N: usize>(&mut self) -> VaultResult<[u8; N]> {
        let s = self.take(N)?;
        let mut a = [0u8; N];
        a.copy_from_slice(s);
        Ok(a)
    }
    fn rest(&mut self) -> VaultResult<&'a [u8]> {
        let s = &self.data[self.pos..];
        self.pos = self.data.len();
        Ok(s)
    }
}

#[allow(dead_code)]
fn _silence_unused(_p: &Path) {}

// ==================== FFI（Dart 侧调用） ====================
//
// 变长输出统一两次调用模式：out_ptr=null 时只写 *out_len 拿长度，
// 再传缓冲区拷数据。密码/密钥一律裸字节指针 + len（Dart 侧 Uint8List）。

use std::os::raw::c_char;

fn cstr<'a>(p: *const c_char) -> VaultResult<&'a str> {
    if p.is_null() {
        return Err("null path".into());
    }
    unsafe { std::ffi::CStr::from_ptr(p) }
        .to_str()
        .map_err(|_| "bad utf8 path".to_string())
}

/// 输出辅助：长度查询或拷贝
fn emit(out_ptr: *mut u8, out_len: *mut usize, data: &[u8]) {
    unsafe {
        *out_len = data.len();
        if !out_ptr.is_null() {
            std::ptr::copy_nonoverlapping(data.as_ptr(), out_ptr, data.len());
        }
    }
}

/// 密码库封装：entries_json = 完整 Keyring JSON（{"ver":1,"entries":[...],"thumb_key":"hex"}）。
/// thumb_key 由 Dart 侧生成并全程复用（改主密码/日常保存都不变），
/// 缺失或非法时才兜底补随机。
#[no_mangle]
pub extern "C" fn vault_seal_keyring(
    master_ptr: *const u8,
    master_len: usize,
    entries_json_ptr: *const u8,
    entries_json_len: usize,
    out_ptr: *mut u8,
    out_len: *mut usize,
) -> i32 {
    unsafe {
        let master = std::slice::from_raw_parts(master_ptr, master_len);
        let json = std::slice::from_raw_parts(entries_json_ptr, entries_json_len);
        let mut kr: Keyring = match serde_json::from_slice(json) {
            Ok(k) => k,
            Err(_) => return -1,
        };
        let tk_ok = kr.thumb_key.len() == KEY_SIZE * 2
            && kr
                .thumb_key
                .bytes()
                .all(|b| b.is_ascii_hexdigit());
        if !tk_ok {
            let fresh = Keyring::new();
            kr.thumb_key = fresh.thumb_key;
        }
        match seal_keyring(master, &kr) {
            Ok(data) => {
                emit(out_ptr, out_len, &data);
                0
            }
            Err(_) => -2,
        }
    }
}

/// 打开密码库 → 返回 Keyring JSON（{ver, entries, thumb_key}）
#[no_mangle]
pub extern "C" fn vault_open_keyring(
    master_ptr: *const u8,
    master_len: usize,
    data_ptr: *const u8,
    data_len: usize,
    out_ptr: *mut u8,
    out_len: *mut usize,
) -> i32 {
    unsafe {
        let master = std::slice::from_raw_parts(master_ptr, master_len);
        let data = std::slice::from_raw_parts(data_ptr, data_len);
        match open_keyring(master, data) {
            Ok(kr) => match serde_json::to_vec(&kr) {
                Ok(json) => {
                    emit(out_ptr, out_len, &json);
                    0
                }
                Err(_) => -3,
            },
            Err(_) => -2,
        }
    }
}

/// 改主密码：data 用 old 解开、new 重新封装
#[no_mangle]
pub extern "C" fn vault_change_master_password(
    data_ptr: *const u8,
    data_len: usize,
    old_ptr: *const u8,
    old_len: usize,
    new_ptr: *const u8,
    new_len: usize,
    out_ptr: *mut u8,
    out_len: *mut usize,
) -> i32 {
    unsafe {
        let data = std::slice::from_raw_parts(data_ptr, data_len);
        let old = std::slice::from_raw_parts(old_ptr, old_len);
        let new = std::slice::from_raw_parts(new_ptr, new_len);
        match change_master_password(data, old, new) {
            Ok(out) => {
                emit(out_ptr, out_len, &out);
                0
            }
            Err(_) => -2,
        }
    }
}

/// 生成缩略图：src=图片字节（JPEG/PNG），max_px=长边上限
#[no_mangle]
pub extern "C" fn vault_gen_thumb(
    src_ptr: *const u8,
    src_len: usize,
    max_px: u32,
    out_ptr: *mut u8,
    out_len: *mut usize,
) -> i32 {
    unsafe {
        let src = std::slice::from_raw_parts(src_ptr, src_len);
        match gen_thumb(src, max_px) {
            Ok(data) => {
                emit(out_ptr, out_len, &data);
                0
            }
            Err(_) => -2,
        }
    }
}

/// thumb_key 封装缩略图 → nonce(12) + blob
#[no_mangle]
pub extern "C" fn vault_seal_thumb(
    thumb_key_ptr: *const u8,
    plain_ptr: *const u8,
    plain_len: usize,
    nonce_out: *mut u8,
    blob_out_ptr: *mut u8,
    blob_out_len: *mut usize,
) -> i32 {
    unsafe {
        let tk = match read_key32(thumb_key_ptr) {
            Ok(k) => k,
            Err(_) => return -1,
        };
        let plain = std::slice::from_raw_parts(plain_ptr, plain_len);
        match seal_thumb(&tk, plain) {
            Ok((nonce, blob)) => {
                if !nonce_out.is_null() {
                    std::ptr::copy_nonoverlapping(nonce.as_ptr(), nonce_out, NONCE_SIZE);
                }
                emit(blob_out_ptr, blob_out_len, &blob);
                0
            }
            Err(_) => -2,
        }
    }
}

/// thumb_key 解封缩略图
#[no_mangle]
pub extern "C" fn vault_open_thumb(
    thumb_key_ptr: *const u8,
    nonce_ptr: *const u8,
    blob_ptr: *const u8,
    blob_len: usize,
    out_ptr: *mut u8,
    out_len: *mut usize,
) -> i32 {
    unsafe {
        let tk = match read_key32(thumb_key_ptr) {
            Ok(k) => k,
            Err(_) => return -1,
        };
        let nonce = std::slice::from_raw_parts(nonce_ptr, NONCE_SIZE);
        let blob = std::slice::from_raw_parts(blob_ptr, blob_len);
        match open_thumb(&tk, nonce, blob) {
            Ok(data) => {
                emit(out_ptr, out_len, &data);
                0
            }
            Err(_) => -2,
        }
    }
}

unsafe fn read_key32(p: *const u8) -> VaultResult<[u8; KEY_SIZE]> {
    if p.is_null() {
        return Err("null key".into());
    }
    let mut k = [0u8; KEY_SIZE];
    std::ptr::copy_nonoverlapping(p, k.as_mut_ptr(), KEY_SIZE);
    Ok(k)
}

/// v3 加密文件（保险箱用）：内容密钥 Argon2id(文件密码, salt)；
/// thumb 非空则用 thumb_key 封装写入头（thumb_key 必须是 32B）
#[no_mangle]
pub extern "C" fn encrypt_file_v3(
    input_path_ptr: *const c_char,
    output_path_ptr: *const c_char,
    password_ptr: *const u8,
    password_len: usize,
    hint_ptr: *const c_char,
    thumb_ptr: *const u8,
    thumb_len: usize,
    thumb_key_ptr: *const u8,
    is_mobile: bool,
    cpu_cores: usize,
) -> i32 {
    unsafe {
        let input_path = match cstr(input_path_ptr) {
            Ok(s) => s,
            Err(_) => return -1,
        };
        let output_path = match cstr(output_path_ptr) {
            Ok(s) => s,
            Err(_) => return -1,
        };
        let password = std::slice::from_raw_parts(password_ptr, password_len);
        let hint = if hint_ptr.is_null() {
            None
        } else {
            std::ffi::CStr::from_ptr(hint_ptr).to_str().ok()
        };
        let thumb = if thumb_ptr.is_null() || thumb_len == 0 {
            None
        } else {
            Some(std::slice::from_raw_parts(thumb_ptr, thumb_len))
        };
        // 输出目录缺失/不可写 → -4，与 -2（加密失败）区分，避免误判
        if let Some(parent) = std::path::Path::new(output_path).parent() {
            if !parent.as_os_str().is_empty() && !parent.exists() {
                return -4;
            }
        }
        let thumb_key = match read_key32(thumb_key_ptr) {
            Ok(k) => k,
            Err(_) => return -1,
        };
        match encrypt_file_v3_internal(
            input_path,
            output_path,
            password,
            hint,
            thumb,
            &thumb_key,
            is_mobile,
            cpu_cores,
        ) {
            Ok(_) => 0,
            Err(_) => -2,
        }
    }
}

/// 取 v3 文件内缩略图明文（thumb_key 错 → -2；无缩略图节 → out_len=0 返回 0）
#[no_mangle]
pub extern "C" fn vault_get_thumb_from_file(
    input_path_ptr: *const c_char,
    thumb_key_ptr: *const u8,
    out_ptr: *mut u8,
    out_len: *mut usize,
) -> i32 {
    unsafe {
        let input_path = match cstr(input_path_ptr) {
            Ok(s) => s,
            Err(_) => return -1,
        };
        let tk = match read_key32(thumb_key_ptr) {
            Ok(k) => k,
            Err(_) => return -1,
        };
        match get_thumb_from_file_v3(input_path, &tk) {
            Ok(Some(data)) => {
                emit(out_ptr, out_len, &data);
                0
            }
            Ok(None) => {
                *out_len = 0;
                0
            }
            Err(_) => -2,
        }
    }
}

// ==================== 单元测试 ====================

#[cfg(test)]
mod tests {
    use super::*;
    use image::{codecs::jpeg::JpegEncoder, ExtendedColorType, RgbImage};

    const MASTER: &[u8] = b"master-password-123";
    const FILE_PW: &[u8] = b"file-password-456";

    fn temp_path(tag: &str) -> std::path::PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!("wm_vault_test_{}_{}", tag, std::process::id()));
        p
    }

    fn make_jpeg(w: u32, h: u32) -> Vec<u8> {
        let img = RgbImage::from_fn(w, h, |x, y| {
            image::Rgb([(x % 256) as u8, (y % 256) as u8, 128])
        });
        let mut out = Vec::new();
        let mut enc = JpegEncoder::new_with_quality(&mut out, 80);
        enc.encode(&img, w, h, ExtendedColorType::Rgb8).unwrap();
        out
    }

    #[test]
    fn test_derive_key_v3_stable_and_salted() {
        let salt = [7u8; SALT_SIZE];
        let k1 = derive_key_v3(FILE_PW, &salt).unwrap();
        let k2 = derive_key_v3(FILE_PW, &salt).unwrap();
        assert_eq!(k1, k2);
        let mut salt2 = salt;
        salt2[0] = 8;
        let k3 = derive_key_v3(FILE_PW, &salt2).unwrap();
        assert_ne!(k1, k3, "不同 salt 必须派生不同密钥");
        assert_eq!(k1.len(), 32);
    }

    #[test]
    fn test_keyring_seal_open_roundtrip() {
        let mut kr = Keyring::new();
        kr.upsert("a.wemi", "pw-a");
        kr.upsert("b.wemi", "pw-b");
        let sealed = seal_keyring(MASTER, &kr).unwrap();
        assert_eq!(&sealed[..VAULT_KEYRING_MAGIC.len()], VAULT_KEYRING_MAGIC);

        let opened = open_keyring(MASTER, &sealed).unwrap();
        assert_eq!(opened.entries.len(), 2);
        assert_eq!(opened.password_of("a.wemi"), Some("pw-a"));
        assert_eq!(opened.thumb_key, kr.thumb_key);

        // 错主密码必须失败
        assert!(open_keyring(b"wrong-master", &sealed).is_err());
    }

    #[test]
    fn test_keyring_change_master() {
        let mut kr = Keyring::new();
        kr.upsert("a.wemi", "pw-a");
        let sealed = seal_keyring(MASTER, &kr).unwrap();

        let resealed = change_master_password(&sealed, MASTER, b"new-master-999").unwrap();
        // 旧主密码打不开新库
        assert!(open_keyring(MASTER, &resealed).is_err());
        // 新主密码能开，内容原样
        let opened = open_keyring(b"new-master-999", &resealed).unwrap();
        assert_eq!(opened.password_of("a.wemi"), Some("pw-a"));
        assert_eq!(opened.thumb_key, kr.thumb_key);
        // 旧库文件仍能被旧主密码打开（未动原文件）
        assert!(open_keyring(MASTER, &sealed).is_ok());
    }

    #[test]
    fn test_thumb_seal_open() {
        let mut kr = Keyring::new();
        kr.upsert("a.wemi", "pw-a");
        let tk = kr.thumb_key_bytes().unwrap();
        let plain = b"fake-jpeg-bytes".to_vec();
        let (nonce, blob) = seal_thumb(&tk, &plain).unwrap();
        let back = open_thumb(&tk, &nonce, &blob).unwrap();
        assert_eq!(back, plain);
        // 错 thumb_key 必须失败
        let mut wrong = tk;
        wrong[0] ^= 0xff;
        assert!(open_thumb(&wrong, &nonce, &blob).is_err());
    }

    #[test]
    fn test_v3_file_roundtrip_small() {
        let src = temp_path("v3_small_src");
        let enc = temp_path("v3_small_enc");
        let dec = temp_path("v3_small_dec");
        let payload: Vec<u8> = (0..1000u32).map(|i| (i % 251) as u8).collect();
        std::fs::write(&src, &payload).unwrap();

        let kr = Keyring::new();
        let tk = kr.thumb_key_bytes().unwrap();
        encrypt_file_v3_internal(
            src.to_str().unwrap(),
            enc.to_str().unwrap(),
            FILE_PW,
            Some("提示一下"),
            Some(&make_jpeg(64, 48)),
            &tk,
            false,
            4,
        )
        .unwrap();

        // 头校验：magic + version=3 + flags bit0
        let bytes = std::fs::read(&enc).unwrap();
        assert_eq!(&bytes[..10], MAGIC_STRING);
        assert_eq!(u32::from_le_bytes(bytes[10..14].try_into().unwrap()), 3);
        assert_eq!(u32::from_le_bytes(bytes[14..18].try_into().unwrap()) & 1, 1);

        // 缩略图可取（密码映射判据的物质基础）
        let thumb = get_thumb_from_file_v3(enc.to_str().unwrap(), &tk)
            .unwrap()
            .expect("应有缩略图");
        assert!(!thumb.is_empty());

        // 解密还原
        decrypt_file_v3_internal(enc.to_str().unwrap(), dec.to_str().unwrap(), FILE_PW, false, 4)
            .unwrap();
        assert_eq!(std::fs::read(&dec).unwrap(), payload);

        // 错密码必须失败
        assert!(decrypt_file_v3_internal(
            enc.to_str().unwrap(),
            dec.to_str().unwrap(),
            b"bad-password",
            false,
            4
        )
        .is_err());

        for p in [&src, &enc, &dec] {
            let _ = std::fs::remove_file(p);
        }
    }

    #[test]
    fn test_v3_file_roundtrip_no_thumb() {
        let src = temp_path("v3_nothumb_src");
        let enc = temp_path("v3_nothumb_enc");
        let payload = b"no-thumb payload".to_vec();
        std::fs::write(&src, &payload).unwrap();

        let kr = Keyring::new();
        let tk = kr.thumb_key_bytes().unwrap();
        encrypt_file_v3_internal(
            src.to_str().unwrap(),
            enc.to_str().unwrap(),
            FILE_PW,
            None,
            None,
            &tk,
            false,
            4,
        )
        .unwrap();

        let bytes = std::fs::read(&enc).unwrap();
        assert_eq!(u32::from_le_bytes(bytes[14..18].try_into().unwrap()) & 1, 0);
        assert!(get_thumb_from_file_v3(enc.to_str().unwrap(), &tk)
            .unwrap()
            .is_none());

        for p in [&src, &enc] {
            let _ = std::fs::remove_file(p);
        }
    }

    #[test]
    fn test_v3_multi_chunk_roundtrip() {
        // 生产 chunk_size 256MB 太大没法在测试里跨多块，改用 read_v3_chunks_sized
        // 以小 chunk_size 直测多块路径：手工拼 v3 头 + 两个带长度的 chunk。
        let plain1: Vec<u8> = (0..3000u32).map(|i| (i % 97) as u8).collect();
        let plain2: Vec<u8> = (0..1500u32).map(|i| (i % 89) as u8).collect();
        let salt = [3u8; SALT_SIZE];
        let key = derive_key_v3(FILE_PW, &salt).unwrap();
        let cipher = Aes256Gcm::new_from_slice(&key).unwrap();

        // 两个 chunk（各 < chunk_size=1024 前提下长度任意，chunk_len 字段如实写）
        let mut stream = Vec::new();
        for plain in [&plain1, &plain2] {
            let nb = generate_nonce();
            let ct = cipher.encrypt(Nonce::from_slice(&nb), plain.as_ref()).unwrap();
            stream.extend_from_slice(&nb);
            stream.extend_from_slice(&(ct.len() as u32).to_be_bytes());
            stream.extend_from_slice(&ct);
        }

        let mut file_bytes = Vec::new();
        file_bytes.extend_from_slice(MAGIC_STRING);
        file_bytes.extend_from_slice(&FILE_VERSION_V3.to_le_bytes());
        file_bytes.extend_from_slice(&0u32.to_le_bytes()); // flags=0
        file_bytes.extend_from_slice(&salt);
        file_bytes.push(0u8); // hint_len=0
        file_bytes.extend_from_slice(&stream);

        let path = temp_path("v3_multi");
        std::fs::write(&path, &file_bytes).unwrap();

        // 小 chunk_size + 多块读取路径（生产路径 = 先 parse_v3_header 再进 chunk 流）
        let mut reader = BufReader::new(File::open(&path).unwrap());
        let header = parse_v3_header(&mut reader).unwrap();
        assert_eq!(header.salt, [3u8; SALT_SIZE]);
        let key2 = derive_key_v3(FILE_PW, &header.salt).unwrap();
        let mut out: Vec<u8> = Vec::new();
        {
            let mut w = VecWriter(&mut out);
            read_v3_chunks_sized(&mut reader, &mut w, &key2, 1024, 4).unwrap();
        }
        let mut expect = plain1.clone();
        expect.extend_from_slice(&plain2);
        assert_eq!(out, expect);

        // 错 key 必须失败
        let mut wrong_key = key2;
        wrong_key[0] ^= 0xff;
        let mut reader2 = BufReader::new(File::open(&path).unwrap());
        let _ = parse_v3_header(&mut reader2).unwrap();
        let mut out2: Vec<u8> = Vec::new();
        let mut w2 = VecWriter(&mut out2);
        assert!(read_v3_chunks_sized(&mut reader2, &mut w2, &wrong_key, 1024, 4).is_err());

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn test_gen_thumb() {
        let jpeg = make_jpeg(1000, 600);
        let thumb = gen_thumb(&jpeg, 320).unwrap();
        assert!(!thumb.is_empty());
        // 解回来验证尺寸 ≤ 320
        let img = image::load_from_memory(&thumb).unwrap();
        assert!(img.width() <= 320 && img.height() <= 320);
        assert!(img.width() >= 319, "长边应贴近 320，实际 {}", img.width());
        // 小图不放大
        let small = make_jpeg(100, 80);
        let t2 = gen_thumb(&small, 320).unwrap();
        let img2 = image::load_from_memory(&t2).unwrap();
        assert_eq!((img2.width(), img2.height()), (100, 80));
    }

    #[test]
    fn test_gen_thumb_rejects_garbage() {
        assert!(gen_thumb(b"not an image at all", 320).is_err());
    }

    #[test]
    fn test_v1_header_not_mistaken_for_v3() {
        // v1 文件（version=1）过 parse_v3_header 必须明确报错而不是误读
        let mut bytes = Vec::new();
        bytes.extend_from_slice(MAGIC_STRING);
        bytes.extend_from_slice(&1u32.to_le_bytes());
        bytes.push(0u8); // hint_len=0
        let path = temp_path("v1_misread");
        std::fs::write(&path, &bytes).unwrap();
        let r = parse_v3_header_path(path.to_str().unwrap());
        assert!(r.is_err());
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn test_reader_helpers() {
        let data = [1u8, 2, 3, 4, 5, 6];
        let mut r = Reader::new(&data);
        assert_eq!(r.take(2).unwrap(), &[1, 2]);
        assert_eq!(r.array::<2>().unwrap(), [3, 4]);
        assert_eq!(r.rest().unwrap(), &[5, 6]);
        let mut r2 = Reader::new(&data);
        assert!(r2.take(100).is_err());
    }

    #[test]
    fn test_keyring_upsert_remove() {
        let mut kr = Keyring::new();
        kr.upsert("a.wemi", "p1");
        kr.upsert("a.wemi", "p2");
        assert_eq!(kr.entries.len(), 1, "同名文件应更新而非追加");
        assert_eq!(kr.password_of("a.wemi"), Some("p2"));
        kr.remove("a.wemi");
        assert_eq!(kr.password_of("a.wemi"), None);
        assert_eq!(kr.entries.len(), 0);
        let _ = kr.thumb_key_bytes().unwrap();
    }

    #[test]
    fn test_seal_ffi_full_keyring_thumb_stable() {
        // FFI 层语义：收完整 Keyring JSON（Dart 形状），thumb_key 原样保留；
        // 同一库反复封装（模拟日常 _persist）thumb_key 不得变，否则旧缩略图全废
        let master = b"ffi-master-1234";
        let tk = "ab".repeat(32);
        let mk = |entries: &str| {
            format!(
                r#"{{"ver":1,"entries":[{}],"thumb_key":"{}"}}"#,
                entries, tk
            )
        };
        let seal = |json: &[u8]| -> Vec<u8> {
            let mut ln = 0usize;
            let rc = vault_seal_keyring(
                master.as_ptr(), master.len(),
                json.as_ptr(), json.len(),
                std::ptr::null_mut(), &mut ln,
            );
            assert_eq!(rc, 0, "seal rc={rc}");
            let mut buf = vec![0u8; ln];
            let rc = vault_seal_keyring(
                master.as_ptr(), master.len(),
                json.as_ptr(), json.len(),
                buf.as_mut_ptr(), &mut ln,
            );
            assert_eq!(rc, 0);
            buf.truncate(ln);
            buf
        };
        let open = |data: &[u8]| -> String {
            let mut ln = 0usize;
            let rc = vault_open_keyring(
                master.as_ptr(), master.len(),
                data.as_ptr(), data.len(),
                std::ptr::null_mut(), &mut ln,
            );
            assert_eq!(rc, 0, "open rc={rc}");
            let mut buf = vec![0u8; ln];
            let rc = vault_open_keyring(
                master.as_ptr(), master.len(),
                data.as_ptr(), data.len(),
                buf.as_mut_ptr(), &mut ln,
            );
            assert_eq!(rc, 0);
            String::from_utf8(buf[..ln].to_vec()).unwrap()
        };

        let sealed = seal(mk("").as_bytes());
        let j1 = open(&sealed);
        assert!(j1.contains(&format!(r#""thumb_key":"{}""#, tk)));
        assert!(j1.contains(r#""entries":[]"#));

        // 二次封装带 entry：thumb_key 必须仍是同一个
        let sealed2 = seal(mk(r#"{"file":"a.wemi","password":"p"}"#).as_bytes());
        let j2 = open(&sealed2);
        assert!(j2.contains(&format!(r#""thumb_key":"{}""#, tk)));
        assert!(j2.contains(r#""password":"p""#));

        // Dart 形状之外的坏输入仍报 -1
        let mut ln = 0usize;
        let bad = b"[]";
        let rc = vault_seal_keyring(
            master.as_ptr(), master.len(),
            bad.as_ptr(), bad.len(),
            std::ptr::null_mut(), &mut ln,
        );
        assert_eq!(rc, -1);
    }

    #[test]
    fn test_write_vec_writer() {
        let mut v = Vec::new();
        {
            let mut w = VecWriter(&mut v);
            w.write_all(b"hello").unwrap();
            w.flush().unwrap();
        }
        assert_eq!(v, b"hello");
    }
}
