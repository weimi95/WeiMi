//! LANDrop v2 协议加密原语（与 LANDrop 2.x 桌面/移动端双向兼容）
//!
//! 逆向自 LANDrop 2.7.2（electron asar 主进程 JS，协议完整可读；Qt 2024-08 版常量佐证）。
//! 本模块只做**密码学原语**（全部经 libsodium 对拍验证，见 tests/landrop_vectors.json），
//! UDP 发现 / TCP 握手 / 帧封装 / 文件流由 Dart 侧（landrop_service.dart）完成。
//!
//! 协议要点（v2）：
//! - 握手：裸 TCP。ClientHello `{supported_versions:["v2"], public_key(secp256k1 pk b64),
//!   ecdhe:{pk,sig}}`；sig = secp256k1_ecdsa_sign(blake2b-256(ecdhe.pk), identity_sk)（64B compact，低 S）。
//!   ServerHello `{version:"v2", public_key, ecdhe:{pk,sig}}`（对 ecdhe.pk 签名同上）。
//! - 会话密钥：libsodium `crypto_kx_client/server_session_keys`（X25519 + BLAKE2b-512 派生，
//!   绑定双方公钥）。verifCode = blake2b-128(kSc||kCs) 前/后 8 字节各按小端 u64 异或 % 1000000，
//!   补零成 6 位。kSc/kCs 方向：client 的 kSc=rx、kCs=tx；server 反之。
//! - 帧：`[2B 大端长度][ChaCha20-Poly1305-IETF 密文]`；nonce 为 12B 小端计数器，
//!   收发各自独立、初始 0、每记录 +1（libsodium sodium_increment 语义）。
//!   明文 = `[1B push 标志][数据]`，单记录明文上限 65518B，超限按 65518 分片、末片 push=1。
//!
//! 信任模型：TOFU 6 位码核对 + trusted_devices 按 secp256k1 身份公钥持久化（Dart 侧存储）。

use blake2::Blake2bVar;
use blake2::digest::{Update, VariableOutput};
use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Nonce as ChaNonce};
use rand::RngCore;
use secp256k1::ecdsa::Signature;
use secp256k1::{Message, PublicKey, Secp256k1, SecretKey};
use std::os::raw::c_char;
use x25519_dalek::x25519;

// ==================== 常量 ====================

const X25519_BASEPOINT: [u8; 32] = [9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
const SECP_PK_SIZE: usize = 33; // 压缩公钥
const SECP_SK_SIZE: usize = 32;
const SECP_SIG_SIZE: usize = 64; // compact
/// AEAD tag 长度（ChaCha20-Poly1305 固定 16）
const AEAD_TAG_SIZE: usize = 16;
/// 单记录明文上限（LANDrop T.maxBlockSize）
pub(crate) const LD_MAX_BLOCK_SIZE: usize = 65518;
/// verifCode 字符数（不含 NUL）
const VERIF_CODE_LEN: usize = 6;

// ==================== 内部原语 ====================

/// BLAKE2b 任意输出（1..=64 字节）。等价 libsodium crypto_generichash。
fn blake2b(out_len: usize, data: &[u8]) -> Result<Vec<u8>, ()> {
    if out_len == 0 || out_len > 64 {
        return Err(());
    }
    let mut hasher = Blake2bVar::new(out_len).map_err(|_| ())?;
    hasher.update(data);
    let mut out = vec![0u8; out_len];
    hasher.finalize_variable(&mut out).map_err(|_| ())?;
    Ok(out)
}

fn random_32() -> [u8; 32] {
    let mut b = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut b);
    b
}

/// X25519 密钥对：sk 随机，pk = X25519(sk, 9)
fn kx_keypair() -> ([u8; 32], [u8; 32]) {
    let sk = random_32();
    let pk = x25519(sk, X25519_BASEPOINT);
    (pk, sk)
}

/// libsodium crypto_kx_*_session_keys 等价实现。
///
/// 派生（已对拍确认）：d = BLAKE2b-512( q || client_pk || server_pk )，
/// 其中 q = X25519(sk, peer_pk)，client_pk/server_pk 按**角色**排序（与自身是 client 还是 server 无关）。
/// client: rx=d[0:32], tx=d[32:64]；server: 二者对调。
/// 任一侧 q 全零（弱公钥）按 libsodium 语义返回错误。
fn kx_session_keys(
    is_client: bool,
    own_sk: &[u8; 32],
    own_pk: &[u8; 32],
    peer_pk: &[u8; 32],
) -> Result<([u8; 32], [u8; 32]), ()> {
    let q = x25519(*own_sk, *peer_pk);
    if q.iter().all(|&b| b == 0) {
        return Err(());
    }
    let (client_pk, server_pk) = if is_client {
        (own_pk, peer_pk)
    } else {
        (peer_pk, own_pk)
    };
    let mut input = Vec::with_capacity(32 + 64);
    input.extend_from_slice(&q);
    input.extend_from_slice(client_pk);
    input.extend_from_slice(server_pk);
    let d = blake2b(64, &input)?;
    let (first, second) = (
        <[u8; 32]>::try_from(&d[0..32]).unwrap(),
        <[u8; 32]>::try_from(&d[32..64]).unwrap(),
    );
    if is_client {
        Ok((first, second))
    } else {
        Ok((second, first))
    }
}

/// LANDrop verifCode：blake2b-128(kSc||kCs)，前后 8 字节小端 u64 异或 % 1000000，补零 6 位。
fn verif_code(k_sc: &[u8; 32], k_cs: &[u8; 32]) -> Result<String, ()> {
    let mut input = Vec::with_capacity(64);
    input.extend_from_slice(k_sc);
    input.extend_from_slice(k_cs);
    let digest = blake2b(16, &input)?;
    let t = u64::from_le_bytes(<[u8; 8]>::try_from(&digest[0..8]).unwrap());
    let s = u64::from_le_bytes(<[u8; 8]>::try_from(&digest[8..16]).unwrap());
    Ok(format!("{:06}", (t ^ s) % 1_000_000))
}

/// secp256k1 身份密钥对：pk 压缩 33B
fn secp_keypair() -> Result<([u8; 33], [u8; 32]), ()> {
    let sk_bytes = random_32();
    secp_pk_from_sk(&sk_bytes).map(|pk| (pk, sk_bytes))
}

fn secp_pk_from_sk(sk_bytes: &[u8; 32]) -> Result<[u8; 33], ()> {
    let sk = SecretKey::from_slice(sk_bytes).map_err(|_| ())?;
    let secp = Secp256k1::new();
    let pk = PublicKey::from_secret_key(&secp, &sk);
    Ok(pk.serialize())
}

/// LANDrop 签名：sig = secp256k1_ecdsa_sign(blake2b-256(msg), sk)，64B compact（低 S）
fn secp_sign(msg: &[u8], sk_bytes: &[u8; 32]) -> Result<[u8; 64], ()> {
    let digest = blake2b(32, msg)?;
    let sk = SecretKey::from_slice(sk_bytes).map_err(|_| ())?;
    let message = Message::from_digest_slice(&digest).map_err(|_| ())?;
    let secp = Secp256k1::new();
    let sig: Signature = secp.sign_ecdsa(&message, &sk);
    Ok(sig.serialize_compact())
}

/// LANDrop 验签：先 normalize_s 再验签（与 LANDrop JS 完全一致，兼容高 S 签名）
fn secp_verify(sig_bytes: &[u8; 64], msg: &[u8], pk_bytes: &[u8; 33]) -> Result<bool, ()> {
    let digest = blake2b(32, msg)?;
    let message = Message::from_digest_slice(&digest).map_err(|_| ())?;
    let mut sig = Signature::from_compact(sig_bytes).map_err(|_| ())?;
    // 与 LANDrop JS 一致：先 normalize_s（低 S）再验签，兼容高 S 签名
    sig.normalize_s();
    let pk = PublicKey::from_slice(pk_bytes).map_err(|_| ())?;
    let secp = Secp256k1::new();
    Ok(secp.verify_ecdsa(&message, &sig, &pk).is_ok())
}

/// ChaCha20-Poly1305-IETF 加密（ad = null）。输出 = ct || tag
fn aead_seal(key: &[u8; 32], nonce: &[u8; 12], plaintext: &[u8]) -> Result<Vec<u8>, ()> {
    let cipher = ChaCha20Poly1305::new_from_slice(key).map_err(|_| ())?;
    cipher
        .encrypt(ChaNonce::from_slice(nonce), plaintext)
        .map_err(|_| ())
}

fn aead_open(key: &[u8; 32], nonce: &[u8; 12], ciphertext: &[u8]) -> Result<Vec<u8>, ()> {
    let cipher = ChaCha20Poly1305::new_from_slice(key).map_err(|_| ())?;
    cipher
        .decrypt(ChaNonce::from_slice(nonce), ciphertext)
        .map_err(|_| ())
}

/// libsodium sodium_increment：12B 小端计数器 +1（溢出回绕）
fn nonce_increment(nonce: &mut [u8; 12]) {
    for b in nonce.iter_mut() {
        *b = b.wrapping_add(1);
        if *b != 0 {
            return;
        }
    }
}

// ==================== FFI ====================

/// 取单记录明文上限（LANDrop maxBlockSize）
#[no_mangle]
pub extern "C" fn landrop_max_block_size() -> usize {
    LD_MAX_BLOCK_SIZE
}

/// BLAKE2b 任意输出（out_len 1..=64）。两次调用模式：out_ptr 为空则只回长度。
#[no_mangle]
pub extern "C" fn landrop_blake2b(
    out_ptr: *mut u8,
    out_len: usize,
    data_ptr: *const u8,
    data_len: usize,
) -> i32 {
    if out_len == 0 || out_len > 64 {
        return -3;
    }
    let data = unsafe { std::slice::from_raw_parts(data_ptr, data_len) };
    let out = match blake2b(out_len, data) {
        Ok(o) => o,
        Err(_) => return -3,
    };
    unsafe {
        if out_ptr.is_null() {
            return 0;
        }
        std::ptr::copy_nonoverlapping(out.as_ptr(), out_ptr, out_len);
    }
    0
}

/// 生成 X25519 密钥对（pk 32B 入 pk_out，sk 32B 入 sk_out）
#[no_mangle]
pub extern "C" fn landrop_kx_keypair(pk_out: *mut u8, sk_out: *mut u8) -> i32 {
    if pk_out.is_null() || sk_out.is_null() {
        return -3;
    }
    let (pk, sk) = kx_keypair();
    unsafe {
        std::ptr::copy_nonoverlapping(pk.as_ptr(), pk_out, 32);
        std::ptr::copy_nonoverlapping(sk.as_ptr(), sk_out, 32);
    }
    0
}

/// 计算 kx 会话密钥。is_client：本方是发起方（连接别人）为 true。
/// rx/tx 各 32B。返回 0 成功；-1 弱公钥（q 全零）；-3 参数空。
#[no_mangle]
pub extern "C" fn landrop_kx_session_keys(
    is_client: bool,
    own_sk: *const u8,
    own_pk: *const u8,
    peer_pk: *const u8,
    rx_out: *mut u8,
    tx_out: *mut u8,
) -> i32 {
    if own_sk.is_null() || own_pk.is_null() || peer_pk.is_null() || rx_out.is_null() || tx_out.is_null()
    {
        return -3;
    }
    unsafe {
        let own_sk = <[u8; 32]>::try_from(std::slice::from_raw_parts(own_sk, 32)).unwrap();
        let own_pk = <[u8; 32]>::try_from(std::slice::from_raw_parts(own_pk, 32)).unwrap();
        let peer_pk = <[u8; 32]>::try_from(std::slice::from_raw_parts(peer_pk, 32)).unwrap();
        match kx_session_keys(is_client, &own_sk, &own_pk, &peer_pk) {
            Ok((rx, tx)) => {
                std::ptr::copy_nonoverlapping(rx.as_ptr(), rx_out, 32);
                std::ptr::copy_nonoverlapping(tx.as_ptr(), tx_out, 32);
                0
            }
            Err(_) => -1,
        }
    }
}

/// 计算 6 位 verifCode。out 需 ≥7 字节（6 位数字 + NUL）。返回 0 成功。
#[no_mangle]
pub extern "C" fn landrop_verif_code(
    k_sc: *const u8,
    k_cs: *const u8,
    out: *mut c_char,
) -> i32 {
    if k_sc.is_null() || k_cs.is_null() || out.is_null() {
        return -3;
    }
    unsafe {
        let k_sc = <[u8; 32]>::try_from(std::slice::from_raw_parts(k_sc, 32)).unwrap();
        let k_cs = <[u8; 32]>::try_from(std::slice::from_raw_parts(k_cs, 32)).unwrap();
        match verif_code(&k_sc, &k_cs) {
            Ok(code) => {
                let bytes = code.as_bytes();
                std::ptr::copy_nonoverlapping(bytes.as_ptr(), out as *mut u8, VERIF_CODE_LEN);
                *out.add(VERIF_CODE_LEN) = 0;
                0
            }
            Err(_) => -3,
        }
    }
}

/// 生成 secp256k1 身份密钥对（pk 33B 压缩 / sk 32B）
#[no_mangle]
pub extern "C" fn landrop_secp_keypair(pk_out: *mut u8, sk_out: *mut u8) -> i32 {
    if pk_out.is_null() || sk_out.is_null() {
        return -3;
    }
    match secp_keypair() {
        Ok((pk, sk)) => {
            unsafe {
                std::ptr::copy_nonoverlapping(pk.as_ptr(), pk_out, SECP_PK_SIZE);
                std::ptr::copy_nonoverlapping(sk.as_ptr(), sk_out, SECP_SK_SIZE);
            }
            0
        }
        Err(_) => -1,
    }
}

/// 由 sk 恢复压缩公钥（信任列表按公钥持久化，启动时反查）
#[no_mangle]
pub extern "C" fn landrop_secp_pk_from_sk(sk_ptr: *const u8, pk_out: *mut u8) -> i32 {
    if sk_ptr.is_null() || pk_out.is_null() {
        return -3;
    }
    unsafe {
        let sk = <[u8; 32]>::try_from(std::slice::from_raw_parts(sk_ptr, 32)).unwrap();
        match secp_pk_from_sk(&sk) {
            Ok(pk) => {
                std::ptr::copy_nonoverlapping(pk.as_ptr(), pk_out, SECP_PK_SIZE);
                0
            }
            Err(_) => -1,
        }
    }
}

/// secp256k1 签名（LANDrop 语义：blake2b-256(msg) 后 ECDSA，64B compact 低 S）
#[no_mangle]
pub extern "C" fn landrop_secp_sign(
    msg_ptr: *const u8,
    msg_len: usize,
    sk_ptr: *const u8,
    sig_out: *mut u8,
) -> i32 {
    if msg_ptr.is_null() || sk_ptr.is_null() || sig_out.is_null() {
        return -3;
    }
    unsafe {
        let msg = std::slice::from_raw_parts(msg_ptr, msg_len);
        let sk = <[u8; 32]>::try_from(std::slice::from_raw_parts(sk_ptr, 32)).unwrap();
        match secp_sign(msg, &sk) {
            Ok(sig) => {
                std::ptr::copy_nonoverlapping(sig.as_ptr(), sig_out, SECP_SIG_SIZE);
                0
            }
            Err(_) => -1,
        }
    }
}

/// secp256k1 验签。返回 0 有效；-1 无效/格式错；-3 参数空。
#[no_mangle]
pub extern "C" fn landrop_secp_verify(
    sig_ptr: *const u8,
    msg_ptr: *const u8,
    msg_len: usize,
    pk_ptr: *const u8,
) -> i32 {
    if sig_ptr.is_null() || msg_ptr.is_null() || pk_ptr.is_null() {
        return -3;
    }
    unsafe {
        let sig = <[u8; 64]>::try_from(std::slice::from_raw_parts(sig_ptr, 64)).unwrap();
        let msg = std::slice::from_raw_parts(msg_ptr, msg_len);
        let pk = <[u8; 33]>::try_from(std::slice::from_raw_parts(pk_ptr, 33)).unwrap();
        match secp_verify(&sig, msg, &pk) {
            Ok(true) => 0,
            Ok(false) => -1,
            Err(_) => -1,
        }
    }
}

/// ChaCha20-Poly1305-IETF 加密。out 容量需 ≥ pt_len+16。两次调用：out_ptr 空则只回长度。
#[no_mangle]
pub extern "C" fn landrop_seal(
    key_ptr: *const u8,
    nonce_ptr: *const u8,
    pt_ptr: *const u8,
    pt_len: usize,
    out_ptr: *mut u8,
    out_len: *mut usize,
) -> i32 {
    if key_ptr.is_null() || nonce_ptr.is_null() || out_len.is_null() || (pt_len > 0 && pt_ptr.is_null())
    {
        return -3;
    }
    unsafe {
        let key = <[u8; 32]>::try_from(std::slice::from_raw_parts(key_ptr, 32)).unwrap();
        let nonce = <[u8; 12]>::try_from(std::slice::from_raw_parts(nonce_ptr, 12)).unwrap();
        let pt = std::slice::from_raw_parts(pt_ptr, pt_len);
        match aead_seal(&key, &nonce, pt) {
            Ok(ct) => {
                *out_len = ct.len();
                if !out_ptr.is_null() {
                    std::ptr::copy_nonoverlapping(ct.as_ptr(), out_ptr, ct.len());
                }
                0
            }
            Err(_) => -1,
        }
    }
}

/// ChaCha20-Poly1305-IETF 解密。两次调用：out_ptr 空则只回长度。认证失败 -2。
#[no_mangle]
pub extern "C" fn landrop_open(
    key_ptr: *const u8,
    nonce_ptr: *const u8,
    ct_ptr: *const u8,
    ct_len: usize,
    out_ptr: *mut u8,
    out_len: *mut usize,
) -> i32 {
    if key_ptr.is_null() || nonce_ptr.is_null() || out_len.is_null()
        || (ct_len > 0 && ct_ptr.is_null())
    {
        return -3;
    }
    unsafe {
        let key = <[u8; 32]>::try_from(std::slice::from_raw_parts(key_ptr, 32)).unwrap();
        let nonce = <[u8; 12]>::try_from(std::slice::from_raw_parts(nonce_ptr, 12)).unwrap();
        let ct = std::slice::from_raw_parts(ct_ptr, ct_len);
        match aead_open(&key, &nonce, ct) {
            Ok(pt) => {
                *out_len = pt.len();
                if !out_ptr.is_null() {
                    std::ptr::copy_nonoverlapping(pt.as_ptr(), out_ptr, pt.len());
                }
                0
            }
            Err(_) => -2,
        }
    }
}

/// 12B 小端 nonce +1（sodium_increment 语义）
#[no_mangle]
pub extern "C" fn landrop_nonce_increment(nonce_ptr: *mut u8) -> i32 {
    if nonce_ptr.is_null() {
        return -3;
    }
    unsafe {
        let nonce = &mut *(nonce_ptr as *mut [u8; 12]);
        nonce_increment(nonce);
    }
    0
}

// ==================== 测试 ====================

#[cfg(test)]
mod tests {
    use super::*;

    fn hex_of(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{:02x}", b)).collect()
    }

    #[test]
    fn test_blake2b_roundtrip_sizes() {
        for n in [1usize, 16, 32, 64] {
            let out = blake2b(n, b"hello landrop").unwrap();
            assert_eq!(out.len(), n);
        }
        assert!(blake2b(0, b"x").is_err());
        assert!(blake2b(65, b"x").is_err());
    }

    #[test]
    fn test_kx_both_sides_agree() {
        let (cpk, csk) = kx_keypair();
        let (spk, ssk) = kx_keypair();
        let (c_rx, c_tx) = kx_session_keys(true, &csk, &cpk, &spk).unwrap();
        let (s_rx, s_tx) = kx_session_keys(false, &ssk, &spk, &cpk).unwrap();
        // client 的 tx == server 的 rx，client 的 rx == server 的 tx
        assert_eq!(c_tx, s_rx);
        assert_eq!(c_rx, s_tx);
        // verifCode 两端一致：client 的 kSc=rx/kCs=tx，server 的 kSc=tx/kCs=rx
        let c_code = verif_code(&c_rx, &c_tx).unwrap();
        let s_code = verif_code(&s_tx, &s_rx).unwrap();
        assert_eq!(c_code, s_code);
        assert_eq!(c_code.len(), 6);
        assert!(c_code.chars().all(|c| c.is_ascii_digit()));
    }

    #[test]
    fn test_aead_roundtrip_and_tamper() {
        let key = [7u8; 32];
        let nonce = [0u8; 12];
        let pt = b"landrop frame payload";
        let ct = aead_seal(&key, &nonce, pt).unwrap();
        assert_eq!(ct.len(), pt.len() + AEAD_TAG_SIZE);
        let back = aead_open(&key, &nonce, &ct).unwrap();
        assert_eq!(back, pt);
        // 篡改一个字节 → 认证失败
        let mut bad = ct.clone();
        bad[0] ^= 0xff;
        assert!(aead_open(&key, &nonce, &bad).is_err());
        // nonce 不对 → 失败
        assert!(aead_open(&key, &[1u8; 12], &ct).is_err());
    }

    #[test]
    fn test_nonce_increment_le_and_wrap() {
        let mut n = [0u8; 12];
        nonce_increment(&mut n);
        assert_eq!(n, [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        let mut n = [0xff, 0xff, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
        nonce_increment(&mut n);
        assert_eq!(n, [0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        let mut n = [0xff; 12];
        nonce_increment(&mut n);
        assert_eq!(n, [0u8; 12]); // 全回绕
    }

    #[test]
    fn test_secp_sign_verify() {
        let (pk, sk) = secp_keypair().unwrap();
        let msg = b"ecdhe public key bytes (32)";
        let sig = secp_sign(msg, &sk).unwrap();
        assert_eq!(secp_verify(&sig, msg, &pk).unwrap(), true);
        // 错消息
        assert_eq!(secp_verify(&sig, b"other message", &pk).unwrap(), false);
        // 错公钥
        let (pk2, _) = secp_keypair().unwrap();
        assert_eq!(secp_verify(&sig, msg, &pk2).unwrap(), false);
    }

    #[test]
    fn test_secp_pk_from_sk_matches() {
        let (pk, sk) = secp_keypair().unwrap();
        let pk2 = secp_pk_from_sk(&sk).unwrap();
        assert_eq!(pk, pk2);
        assert_eq!(pk.len(), 33);
    }

    #[test]
    fn test_kx_weak_peer_rejected() {
        // 全零 peer pk → q 全零 → 拒绝（libsodium 语义）
        let (cpk, csk) = kx_keypair();
        assert!(kx_session_keys(true, &csk, &cpk, &[0u8; 32]).is_err());
    }

    /// 与 Node libsodium-wrappers / secp256k1 生成的官方行为向量逐项对拍。
    /// 向量文件由 tools/gen_landrop_vectors.mjs 生成（tests/landrop_vectors.json）。
    /// 文件缺失时跳过（CI 上由生成步骤保证存在；本地未生成不算失败）。
    #[test]
    fn test_libsodium_vectors() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/landrop_vectors.json"
        );
        let text = match std::fs::read_to_string(path) {
            Ok(t) => t,
            Err(_) => {
                eprintln!("SKIP: vectors file not found: {}", path);
                return;
            }
        };
        let v: serde_json::Value = serde_json::from_str(&text).unwrap();
        let unhex = |s: &str| -> Vec<u8> {
            (0..s.len())
                .step_by(2)
                .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
                .collect()
        };

        // --- kx 会话密钥（含 verifCode）---
        let ck = &v["kx"]["client"];
        let sk_ = &v["kx"]["server"];
        let cpk = unhex(ck["pk"].as_str().unwrap());
        let csk = unhex(ck["sk"].as_str().unwrap());
        let spk = unhex(sk_["pk"].as_str().unwrap());
        let ssk = unhex(sk_["sk"].as_str().unwrap());
        let (c_rx, c_tx) = kx_session_keys(
            true,
            &<[u8; 32]>::try_from(csk.as_slice()).unwrap(),
            &<[u8; 32]>::try_from(cpk.as_slice()).unwrap(),
            &<[u8; 32]>::try_from(spk.as_slice()).unwrap(),
        )
        .unwrap();
        let (s_rx, s_tx) = kx_session_keys(
            false,
            &<[u8; 32]>::try_from(ssk.as_slice()).unwrap(),
            &<[u8; 32]>::try_from(spk.as_slice()).unwrap(),
            &<[u8; 32]>::try_from(cpk.as_slice()).unwrap(),
        )
        .unwrap();
        let sess = &v["kx"]["session"];
        assert_eq!(hex_of(&c_rx), sess["client_rx"].as_str().unwrap());
        assert_eq!(hex_of(&c_tx), sess["client_tx"].as_str().unwrap());
        assert_eq!(hex_of(&s_rx), sess["server_rx"].as_str().unwrap());
        assert_eq!(hex_of(&s_tx), sess["server_tx"].as_str().unwrap());

        // --- verifCode ---
        let vf = &v["verif"];
        let code = verif_code(
            &<[u8; 32]>::try_from(unhex(vf["kSc"].as_str().unwrap()).as_slice()).unwrap(),
            &<[u8; 32]>::try_from(unhex(vf["kCs"].as_str().unwrap()).as_slice()).unwrap(),
        )
        .unwrap();
        assert_eq!(code, vf["code"].as_str().unwrap());

        // --- secp256k1 密钥对 / 签名 / 验签 ---
        let sp = &v["secp"];
        let spk_bytes = unhex(sp["pk"].as_str().unwrap());
        let ssk_bytes = unhex(sp["sk"].as_str().unwrap());
        let pk_from_sk = secp_pk_from_sk(&<[u8; 32]>::try_from(ssk_bytes.as_slice()).unwrap())
            .unwrap();
        assert_eq!(hex_of(&pk_from_sk), hex_of(&spk_bytes));
        let msg = unhex(sp["msg"].as_str().unwrap());
        let sig = secp_sign(&msg, &<[u8; 32]>::try_from(ssk_bytes.as_slice()).unwrap()).unwrap();
        assert_eq!(hex_of(&sig), sp["sig"].as_str().unwrap());
        let pk_arr = <[u8; 33]>::try_from(spk_bytes.as_slice()).unwrap();
        assert_eq!(
            secp_verify(
                &<[u8; 64]>::try_from(unhex(sp["sig"].as_str().unwrap()).as_slice()).unwrap(),
                &msg,
                &pk_arr,
            )
            .unwrap(),
            true
        );
        // 高 S 签名：normalize 后必须验过（LANDrop normalize-then-verify 同行为）
        if let Some(hi) = sp.get("sig_high_s").and_then(|x| x.as_str()) {
            assert_eq!(
                secp_verify(
                    &<[u8; 64]>::try_from(unhex(hi).as_slice()).unwrap(),
                    &msg,
                    &pk_arr,
                )
                .unwrap(),
                true
            );
        }

        // --- BLAKE2b 多长度 ---
        for case in v["blake2b"].as_array().unwrap() {
            let out_len = case["out_len"].as_u64().unwrap() as usize;
            let data = unhex(case["in"].as_str().unwrap());
            let expect = case["out"].as_str().unwrap();
            assert_eq!(hex_of(&blake2b(out_len, &data).unwrap()), expect);
        }

        // --- ChaCha20-Poly1305-IETF ---
        for case in v["aead"].as_array().unwrap() {
            let key = <[u8; 32]>::try_from(unhex(case["key"].as_str().unwrap()).as_slice()).unwrap();
            let nonce =
                <[u8; 12]>::try_from(unhex(case["nonce"].as_str().unwrap()).as_slice()).unwrap();
            let pt = unhex(case["pt"].as_str().unwrap());
            let ct_expect = unhex(case["ct"].as_str().unwrap());
            let ct = aead_seal(&key, &nonce, &pt).unwrap();
            assert_eq!(hex_of(&ct), hex_of(&ct_expect));
            assert_eq!(aead_open(&key, &nonce, &ct).unwrap(), pt);
        }

        // --- sodium_increment ---
        for case in v["nonce_inc"].as_array().unwrap() {
            let mut n = <[u8; 12]>::try_from(unhex(case["start"].as_str().unwrap()).as_slice())
                .unwrap();
            for step in case["steps"].as_array().unwrap() {
                nonce_increment(&mut n);
                assert_eq!(hex_of(&n), step.as_str().unwrap());
            }
        }
    }
}
