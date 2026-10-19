//! 飞传协议共享定义（与主程序 Dart 侧 lan_transfer_service.dart 逐字段对齐）。
//!
//! 发现：UDP 52346 广播 JSON {"app":"weimi","action":"announce"|"reply",
//!       "id":设备ID,"name":设备名,"httpPort":端口,"v":1}
//! 传输：POST http://ip:port/weimi/send
//!       Header: X-Weimi-App / X-Sender-Id / X-Sender-Name(URL编码) /
//!               X-File-Name(URL编码) / X-File-Size
//!       响应: 200 {"ok":true,...} / 403 拒收 / 500 失败
//! 保存：桌面端落「文档\微密飞传接收」，重名加 " (n)" 后缀。

use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

pub const DISCOVERY_PORT: u16 = 52346;
pub const DEFAULT_HTTP_PORT: u16 = 52345;
pub const MAX_HTTP_PORT: u16 = DEFAULT_HTTP_PORT + 20;
pub const MAGIC: &str = "weimi";

/// 构造 announce/reply JSON（与主程序 Dart 侧逐字段一致）
pub fn build_announce(identity: &Identity, http_port: u16, action: &str) -> String {
    serde_json::json!({
        "app": MAGIC,
        "action": action,
        "id": identity.id,
        "name": identity.name,
        "httpPort": http_port,
        "v": PROTO_VERSION,
    })
    .to_string()
}
pub const PROTO_VERSION: u32 = 1;
pub const RECV_DIR_NAME: &str = "微密飞传接收";

/// 局域网设备（announce/reply 解析结果）
#[derive(Debug, Clone)]
pub struct Peer {
    pub id: String,
    pub name: String,
    pub ip: String,
    pub http_port: u16,
    pub last_seen: std::time::Instant,
}

/// 设备身份（持久化在 exe 同目录 config.json，主程序用 SettingStore，经典版从简）
#[derive(Debug, Clone)]
pub struct Identity {
    pub id: String,
    pub name: String,
}

static COUNTER: AtomicU64 = AtomicU64::new(0);

/// 简易唯一 ID：时间纳秒 + 进程 PID + 自增。不做密码学随机，设备 ID 无需不可猜测。
pub fn generate_id() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let pid = std::process::id();
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{:x}{:x}{:x}", nanos, pid, n)
}

/// 计算机名（环境变量读不到时退回「旧版电脑」）
pub fn machine_name() -> String {
    std::env::var("COMPUTERNAME")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| "旧版电脑".to_string())
}

fn config_path() -> PathBuf {
    std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.to_path_buf()))
        .unwrap_or_else(|| PathBuf::from("."))
        .join("weimi_legacy_config.json")
}

/// 读身份：没有就生成并落盘（exe 同目录，绿色软件惯例）
pub fn load_or_create_identity() -> Identity {
    let path = config_path();
    if let Ok(text) = fs::read_to_string(&path) {
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) {
            let id = v.get("id").and_then(|x| x.as_str()).unwrap_or("").to_string();
            let name = v.get("name").and_then(|x| x.as_str()).unwrap_or("").to_string();
            if !id.is_empty() {
                return Identity {
                    id,
                    name: if name.is_empty() { machine_name() } else { name },
                };
            }
        }
    }
    let id = Identity {
        id: generate_id(),
        name: machine_name(),
    };
    let _ = fs::write(
        &path,
        serde_json::json!({"id": id.id, "name": id.name}).to_string(),
    );
    id
}

/// 默认接收目录：文档\微密飞传接收（与桌面主程序一致）
pub fn default_recv_dir() -> PathBuf {
    let base = std::env::var("USERPROFILE")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."));
    base.join("Documents").join(RECV_DIR_NAME)
}

// ---------- percent 编解码（HTTP 头只允许 ASCII，中文名必须编码） ----------

const UNRESERVED: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~";

/// 对 UTF-8 字节做 percent 编码（与 Dart Uri.encodeComponent 行为对齐：
/// 除未保留字符外全部编码，含中文）
pub fn percent_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 2);
    for &b in s.as_bytes() {
        if UNRESERVED.contains(&b) {
            out.push(b as char);
        } else {
            out.push('%');
            out.push(char::from_digit((b >> 4) as u32, 16).unwrap_or('0'));
            out.push(char::from_digit((b & 0xF) as u32, 16).unwrap_or('0'));
        }
    }
    out
}

/// percent 解码（容错：非法序列原样保留）
pub fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hi = (bytes[i + 1] as char).to_digit(16);
            let lo = (bytes[i + 2] as char).to_digit(16);
            if let (Some(h), Some(l)) = (hi, lo) {
                out.push((h * 16 + l) as u8);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// 文件名清洗：对齐主程序 Dart `_safeFileName`——
/// 含 '/' 时按段拆分，过滤 '.'/'..'（防目录穿越），段间坏字符换 '_'，保留相对子目录；
/// 不含 '/' 时直接把坏字符换 '_'。
pub fn safe_file_name(name: &str) -> String {
    fn clean_seg(s: &str) -> String {
        s.chars()
            .map(|c| {
                if matches!(c, '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' | '/') {
                    '_'
                } else {
                    c
                }
            })
            .collect::<String>()
            .trim()
            .to_string()
    }
    if name.contains('/') {
        let segs: Vec<String> = name
            .split('/')
            .map(clean_seg)
            .filter(|s| !s.is_empty() && s != "." && s != "..")
            .collect();
        if segs.is_empty() {
            "unnamed".to_string()
        } else {
            segs.join("/")
        }
    } else {
        let cleaned = clean_seg(name);
        if cleaned.is_empty() {
            "unnamed".to_string()
        } else {
            cleaned
        }
    }
}

/// 重名冲突：加 " (n)" 后缀（对齐 Dart resolveSavePath）
pub fn dedup_path(target: &std::path::Path) -> PathBuf {
    if !target.exists() {
        return target.to_path_buf();
    }
    let parent = target.parent().unwrap_or_else(|| std::path::Path::new("."));
    let ext = target
        .extension()
        .map(|e| format!(".{}", e.to_string_lossy()))
        .unwrap_or_default();
    let stem = target
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default();
    let mut i = 1;
    loop {
        let candidate = parent.join(format!("{stem} ({i}){ext}"));
        if !candidate.exists() {
            return candidate;
        }
        i += 1;
    }
}
