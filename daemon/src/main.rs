//! WeMi tray daemon (Windows only).
//!
//! Takes over tray icon + LAN transfer receiving while the Flutter UI is
//! fully exited, keeping tray-mode memory at ~10MB.
//!
//! Contract with UI (weimi.exe):
//! - Config push: TCP 127.0.0.1:52349, one JSON line per connection
//!   (sender closes the connection after writing):
//!     {"cmd":"apply","device_id":..,"device_name":..,"discover_enabled":..,
//!      "web_share_enabled":..,"receive_dir":..,"docs_dir":..,"exe_path":..,
//!      "ui_active":bool,"untrusted_confirm":bool}
//!     {"cmd":"quit"}
//!     {"cmd":"get_pending"}             -> {"ok":true,"pending":[...]}  (reply)
//!     {"cmd":"confirm","token":..,"accept":bool} -> {"ok":true,"found":bool} (reply)
//! - v1.2.17+: ui_active no longer releases ports (UI never binds 52345/52346
//!   since the web page moved into the daemon); it only affects the receive
//!   confirm path (launch UI for user confirmation). Ports are held whenever
//!   discover_enabled OR web_share_enabled.
//! - Tray menu: open UI (CreateProcess exe_path) / quit daemon
//! - Trust policy in tray mode: trusted devices (docs_dir/trusted_devices.json)
//!   auto-accept; untrusted -> ask user via UI (launch + pending map, 30s
//!   timeout auto-reject) when untrusted_confirm, else reject 403 directly.

#![cfg(windows)]
#![allow(non_snake_case)]

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream, UdpSocket};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU16, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::Deserialize;

/// LANDrop v2 协议加密原语（与 rust_crypto 同一份源码，#[path] 引进避免双份
/// 漂移；FFI 符号在 exe 里导出无害）。已对拍 libsodium，见 landrop.rs 内测试。
#[path = "../../rust_crypto/src/landrop.rs"]
mod landrop;

// ==================== config ====================

const DISCOVERY_PORT: u16 = 52346;
const HTTP_PORT_BASE: u16 = 52345;
const HTTP_PORT_MAX: u16 = 52365;
const CONFIG_PORT: u16 = 52349;
const MAGIC: &str = "weimi";

#[derive(Clone, Default)]
struct Config {
    device_id: String,
    device_name: String,
    discover_enabled: bool,
    web_share_enabled: bool,
    receive_dir: String,
    docs_dir: String,
    exe_path: String,
    ui_active: bool,
    untrusted_confirm: bool,
    untrusted_confirm_secs: u32,
    open_recv_dir: bool,
    /// LANDrop 兼容总开关（设置→微密飞传→LANDrop 兼容）
    landrop_on: bool,
    /// LANDrop 身份公钥 base64（Dart landrop_service 持久化，UI 启动时同步。
    /// daemon 托盘保活用同一把 pk，保对端 TOFU 信任不裂）
    landrop_pk: String,
    /// LANDrop 身份私钥 base64（v1.2.20：托盘收文件时 ServerHello 签名必需。
    /// 与 Dart SharedPreferences 里的 sk 同一把，由 UI apply 同步）
    landrop_sk: String,
}

static CONFIG: Mutex<Option<Config>> = Mutex::new(None);
static TRANSFER_ON: AtomicBool = AtomicBool::new(false);
static HTTP_PORT: AtomicU16 = AtomicU16::new(HTTP_PORT_BASE);
/// LANDrop 传输端口（v1.2.20）：托盘传输线程 bind 成功后写入，发现包的 port
/// 字段报它（LANDrop 语义=对端要连的 TCP 传输端口，不是 HTTP 端口）。
static LANDROP_TCP_PORT: AtomicU16 = AtomicU16::new(LANDROP_PORT);
static TASKBAR_MSG: AtomicU32 = AtomicU32::new(0);
/// 接收完成计数（自动开目录的批内去抖：2 秒内连收多个文件只开一次目录）
static RECV_TICK: AtomicU64 = AtomicU64::new(0);

/// 局域网发现的本机可达对端（微密协议）。daemon 永久持有发现端口，收到
/// announce/reply 即入表，15s 无更新则过期。UI（Windows）不再自绑 52345/52346，
/// 改由 listPeers 拉取此表，彻底消灭双进程抢端口。
#[derive(Clone)]
struct Peer {
    id: String,
    name: String,
    ip: String,
    port: u16,
    last_seen: u64,
}
static PEERS: Mutex<Vec<Peer>> = Mutex::new(Vec::new());

fn upsert_peer(id: &str, name: &str, ip: &str, port: u16) {
    let mut peers = PEERS.lock().unwrap();
    if let Some(p) = peers.iter_mut().find(|p| p.id == id) {
        p.name = name.to_string();
        p.ip = ip.to_string();
        p.port = port;
        p.last_seen = now_ms();
    } else {
        peers.push(Peer {
            id: id.to_string(),
            name: name.to_string(),
            ip: ip.to_string(),
            port,
            last_seen: now_ms(),
        });
    }
}

/// 远端主机的网页客户端（v1.2.18：从 announce/reply 的 webPeers 字段学习）。
/// 发送方向：HTTP POST 到 host 的 httpPort 带 X-Weimi-To: <房间id>，由 host
/// 转进其 WS 房间；显示方向：并入 webPeers 52349 应答，UI 生成虚拟会话。
#[derive(Clone)]
struct RemoteWeb {
    id: String,
    name: String,
    host_id: String,
    host_ip: String,
    host_port: u16,
    last_seen: u64,
}
static REMOTE_WEB: Mutex<Vec<RemoteWeb>> = Mutex::new(Vec::new());

/// 按 host 同步其网页客户端清单：host 最新包里没列的即删除（浏览器关了），
/// 45s 没刷新的整 host 过期（主机下线）。
fn sync_remote_web(host_id: &str, host_ip: &str, host_port: u16, items: &[(String, String)]) {
    let now = now_ms();
    let mut w = REMOTE_WEB.lock().unwrap();
    w.retain(|r| r.host_id != host_id && now.saturating_sub(r.last_seen) < 45_000);
    for (id, name) in items {
        if let Some(r) = w.iter_mut().find(|r| r.host_id == host_id && r.id == *id) {
            r.name = name.clone();
            r.host_ip = host_ip.to_string();
            r.host_port = host_port;
            r.last_seen = now;
        } else {
            w.push(RemoteWeb {
                id: id.clone(),
                name: name.clone(),
                host_id: host_id.to_string(),
                host_ip: host_ip.to_string(),
                host_port,
                last_seen: now,
            });
        }
    }
}

fn log(msg: &str) {
    use std::fmt::Write as _;
    let mut line = String::new();
    let t = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let _ = writeln!(line, "[{}] {}", t, msg);
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(std::env::temp_dir().join("weimi_daemon.log"))
    {
        let _ = f.write_all(line.as_bytes());
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// 收到文件后按「接收后自动打开文件夹」设置打开所在目录（托盘模式）。
/// 批内去抖：2 秒内连收多个文件，只由最后一个完成者开一次目录。
fn maybe_open_recv_dir(save: &std::path::Path) {
    let enabled = CONFIG
        .lock()
        .unwrap()
        .as_ref()
        .map(|c| c.open_recv_dir)
        .unwrap_or(false);
    if !enabled {
        return;
    }
    open_recv_dir_now(save);
}

/// 立即打开 save 所在目录（explorer），2 秒防抖：批量收文件只开最后一个。
fn open_recv_dir_now(save: &std::path::Path) {
    let Some(dir) = save.parent() else {
        return;
    };
    let dir = dir.to_path_buf();
    let my = RECV_TICK.fetch_add(1, Ordering::SeqCst) + 1;
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(2));
        if RECV_TICK.load(Ordering::SeqCst) != my {
            return; // 2 秒内又有文件收完，交给最后一个开
        }
        let _ = std::process::Command::new("explorer.exe").arg(&dir).spawn();
    });
}

// ==================== win32 ffi ====================

type HWND = *mut core::ffi::c_void;
type HICON = *mut core::ffi::c_void;
type HMENU = *mut core::ffi::c_void;
type HINSTANCE = *mut core::ffi::c_void;
type HANDLE = *mut core::ffi::c_void;
type HCURSOR = *mut core::ffi::c_void;
type HBRUSH = *mut core::ffi::c_void;

const WM_CREATE: u32 = 0x0001;
const GWLP_USERDATA: i32 = -21;
const BS_PUSHBUTTON: u32 = 0x0000_0000;
const BS_DEFPUSHBUTTON: u32 = 0x0000_0001;
const BS_AUTOCHECKBOX: u32 = 0x0000_0003;
const BM_GETCHECK: u32 = 0x00F0;
const BST_CHECKED: u32 = 0x0001;
const WS_CHILD: u32 = 0x4000_0000;
const WS_VISIBLE: u32 = 0x1000_0000;
const WS_OVERLAPPED: u32 = 0x0000_0000;
const WS_CAPTION: u32 = 0x00C0_0000;
const WS_SYSMENU: u32 = 0x0008_0000;
const WS_EX_TOPMOST: u32 = 0x0000_0008;
const WS_EX_DLGMODALFRAME: u32 = 0x0000_0001;
const SS_LEFT: u32 = 0x0000_0000;
const SS_ICON: u32 = 0x0000_0003;
const SW_SHOW: i32 = 5;
const IDC_ARROW: usize = 32512;
const IDI_QUESTION: usize = 32514;
const COLOR_3DFACE: i32 = 15;
// 确认对话框控件 id
const IDC_YES: usize = 101;
const IDC_NO: usize = 102;
const IDC_CANCEL: usize = 103;
const IDC_BATCH: usize = 104;

const NIM_ADD: u32 = 0;
const NIM_MODIFY: u32 = 1;
const NIM_DELETE: u32 = 2;
const NIF_MESSAGE: u32 = 0x1;
const NIF_ICON: u32 = 0x2;
const NIF_TIP: u32 = 0x4;
const NIF_INFO: u32 = 0x10;
const NIIF_INFO: u32 = 0x1;
const WM_USER_TRAYCB: u32 = 0x500; // WM_USER-based custom callback id
const WM_RBUTTONUP: u32 = 0x0205;
const WM_LBUTTONDBLCLK: u32 = 0x0203;
const NIN_BALLOONUSERCLICK: u32 = 0x405; // user clicked the notification balloon
const WM_COMMAND: u32 = 0x0111;
const WM_CLOSE: u32 = 0x0010;
const WM_DESTROY: u32 = 0x0002;
const WM_TIMER: u32 = 0x0113;
const TPM_BOTTOMALIGN: u32 = 0x20;
const MF_STRING: u32 = 0x0;
const MF_SEPARATOR: u32 = 0x800;
const IDI_APPLICATION: u16 = 32512;
const IMAGE_ICON: u32 = 1;
const LR_LOADFROMFILE: u32 = 0x10;
const LR_DEFAULTSIZE: u32 = 0x40;
const CREATE_NEW_CONSOLE: u32 = 0x10;
const WAIT_OBJECT_0: u32 = 0;
const AF_INET: i32 = 2;
const AF_UNSPEC: u32 = 0;
const GAA_FLAG_SKIP_ANYCAST: u32 = 2;
const GAA_FLAG_SKIP_MULTICAST: u32 = 4;

#[repr(C)]
struct NOTIFYICONDATAW {
    cbSize: u32,
    hWnd: HWND,
    uID: u32,
    uFlags: u32,
    uCallbackMessage: u32,
    hIcon: HICON,
    szTip: [u16; 128],
    dwState: u32,
    dwStateMask: u32,
    szInfo: [u16; 256],
    uVersion: u32,
    szInfoTitle: [u16; 64],
    dwInfoFlags: u32,
    guidItem: [u8; 16],
    hBalloonIcon: HICON,
}

#[repr(C)]
struct MSG {
    hwnd: HWND,
    message: u32,
    wParam: usize,
    lParam: isize,
    time: u32,
    ptX: i32,
    ptY: i32,
    lPrivate: i32,
}

#[repr(C)]
struct WNDCLASSW {
    style: u32,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: HINSTANCE,
    hIcon: HICON,
    hCursor: *mut core::ffi::c_void,
    hbrBackground: *mut core::ffi::c_void,
    lpszMenuName: *const u16,
    lpszClassName: *const u16,
}
type WNDPROC = Option<unsafe extern "system" fn(HWND, u32, usize, isize) -> isize>;

#[repr(C)]
struct POINT {
    x: i32,
    y: i32,
}

#[repr(C)]
struct SOCKADDR_INET_UNION {
    family: u16,
    data: [u8; 26],
}

#[repr(C)]
struct SOCKET_ADDRESS {
    lpSockaddr: *mut SOCKADDR_INET_UNION,
    iSockaddrLength: i32,
}

#[repr(C)]
struct IP_ADAPTER_UNICAST_ADDRESS_LH {
    length: u32,
    flags: u32,
    next: *mut IP_ADAPTER_UNICAST_ADDRESS_LH,
    address: SOCKET_ADDRESS,
    _opaque: [u8; 64],
}

#[repr(C)]
struct IP_ADAPTER_ADDRESSES_LH {
    length: u32,
    ifIndex: u32,
    next: *mut IP_ADAPTER_ADDRESSES_LH,
    adapterName: *const u8,
    firstUnicastAddress: *mut IP_ADAPTER_UNICAST_ADDRESS_LH,
    _opaque: [u8; 512],
}

#[link(name = "user32")]
extern "system" {
    fn RegisterClassW(lpwcx: *const WNDCLASSW) -> u16;
    fn SendMessageW(hwnd: HWND, msg: u32, wp: usize, lp: isize) -> isize;
    fn SetWindowLongPtrW(hwnd: HWND, index: i32, value: isize) -> isize;
    fn GetWindowLongPtrW(hwnd: HWND, index: i32) -> isize;
    fn GetDlgItem(hwnd: HWND, id: usize) -> HWND;
    fn EndDialog(hwnd: HWND, result: isize) -> i32;
    fn KillTimer(hwnd: HWND, id: usize) -> i32;
    fn DialogBoxIndirectParamW(
        inst: HINSTANCE,
        tmpl: *const core::ffi::c_void,
        parent: HWND,
        proc_: DLGPROC,
        init: isize,
    ) -> i32;
    fn LoadCursorW(inst: HINSTANCE, name: usize) -> HCURSOR;
    fn GetSysColorBrush(index: i32) -> HBRUSH;
    fn ShowWindow(hwnd: HWND, cmd: i32) -> i32;
    fn UpdateWindow(hwnd: HWND) -> i32;
    fn CreateWindowExW(
        dwExStyle: u32,
        lpClassName: *const u16,
        lpWindowName: *const u16,
        dwStyle: u32,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        parent: HWND,
        menu: HMENU,
        inst: HINSTANCE,
        param: *mut core::ffi::c_void,
    ) -> HWND;
    fn GetMessageW(lpmsg: *mut MSG, hwnd: HWND, min: u32, max: u32) -> i32;
    fn TranslateMessage(lpmsg: *const MSG) -> i32;
    fn DispatchMessageW(lpmsg: *const MSG) -> isize;
    fn DefWindowProcW(hwnd: HWND, msg: u32, wp: usize, lp: isize) -> isize;
    fn PostQuitMessage(code: i32);
    fn DestroyWindow(hwnd: HWND) -> i32;
    fn SetForegroundWindow(hwnd: HWND) -> i32;
    fn TrackPopupMenu(
        menu: HMENU,
        flags: u32,
        x: i32,
        y: i32,
        reserved: i32,
        hwnd: HWND,
        rect: *const core::ffi::c_void,
    ) -> i32;
    fn CreatePopupMenu() -> HMENU;
    fn AppendMenuW(menu: HMENU, flags: u32, id: usize, text: *const u16) -> i32;
    fn DestroyMenu(menu: HMENU) -> i32;
    fn GetCursorPos(pt: *mut POINT) -> i32;
    fn LoadIconW(inst: HINSTANCE, name: *const u16) -> HICON;
    fn LoadImageW(
        inst: HINSTANCE,
        name: *const u16,
        typ: u32,
        cx: i32,
        cy: i32,
        flags: u32,
    ) -> HANDLE;
    fn RegisterWindowMessageW(text: *const u16) -> u32;
    fn FindWindowW(cls: *const u16, title: *const u16) -> HWND;
    fn GetAsyncKeyState(vk: i32) -> i16;
    fn GetModuleHandleW(name: *const u16) -> HINSTANCE;
    fn SetTimer(hwnd: HWND, id: usize, ms: u32, proc_: usize) -> usize;
}

#[link(name = "shell32")]
extern "system" {
    fn Shell_NotifyIconW(msg: u32, data: *const NOTIFYICONDATAW) -> i32;
    fn ExtractIconExW(
        file: *const u16,
        index: i32,
        large: *mut HICON,
        small: *mut HICON,
        count: u32,
    ) -> u32;
}

#[link(name = "kernel32")]
extern "system" {
    fn Sleep(ms: u32);
    fn CreateMutexW(attr: *const core::ffi::c_void, initial: i32, name: *const u16) -> HANDLE;
    fn WaitForSingleObject(h: HANDLE, ms: u32) -> u32;
    fn CreateProcessW(
        app: *const u16,
        cmd: *mut u16,
        procattr: *const core::ffi::c_void,
        threadattr: *const core::ffi::c_void,
        inherit: i32,
        flags: u32,
        env: *const core::ffi::c_void,
        cwd: *const u16,
        si: *mut core::ffi::c_void,
        pi: *mut core::ffi::c_void,
    ) -> i32;
    fn GetCurrentThreadId() -> u32;
    fn LoadLibraryW(name: *const u16) -> HINSTANCE;
    fn GetProcAddress(module: HINSTANCE, name: *const u8) -> *mut core::ffi::c_void;
}

#[link(name = "iphlpapi")]
extern "system" {
    fn GetAdaptersAddresses(
        family: u32,
        flags: u32,
        reserved: *const core::ffi::c_void,
        adapter: *mut IP_ADAPTER_ADDRESSES_LH,
        size: *mut u32,
    ) -> u32;
}

#[link(name = "ws2_32")]
extern "system" {
    fn setsockopt(
        s: u64,
        level: i32,
        optname: i32,
        optval: *const u8,
        optlen: i32,
    ) -> i32;
}
const SOL_SOCKET: i32 = 0xffff;
const SO_BROADCAST: i32 = 0x0020;

/// 给 std UdpSocket 开广播权限（Windows 发 255.255.255.255 / 定向广播必须）。
fn enable_broadcast(sock: &std::net::UdpSocket) {
    use std::os::windows::io::AsRawSocket;
    let one: [u8; 4] = [1, 0, 0, 0];
    unsafe {
        setsockopt(
            sock.as_raw_socket(),
            SOL_SOCKET,
            SO_BROADCAST,
            one.as_ptr(),
            one.len() as i32,
        );
    }
}

// ==================== helpers ====================

fn to_wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// local IPv4s of running adapters (best effort), ordered like the Dart side.
fn local_ipv4s() -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    unsafe {
        let mut size: u32 = 16 * 1024;
        for _ in 0..3 {
            let mut buf = vec![0u8; size as usize];
            let rc = GetAdaptersAddresses(
                AF_UNSPEC,
                GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST,
                std::ptr::null(),
                buf.as_mut_ptr() as *mut IP_ADAPTER_ADDRESSES_LH,
                &mut size,
            );
            if rc == 0 {
                let mut ad = buf.as_ptr() as *const IP_ADAPTER_ADDRESSES_LH;
                while !ad.is_null() {
                    let a = &*ad;
                    let mut ua = a.firstUnicastAddress;
                    while !ua.is_null() {
                        let sa = &(*ua).address;
                        if !sa.lpSockaddr.is_null() && (*sa.lpSockaddr).family == AF_INET as u16 {
                            let b = &(*sa.lpSockaddr).data;
                            let ip = format!("{}.{}.{}.{}", b[2], b[3], b[4], b[5]);
                            if !ip.starts_with("169.254.") && !out.contains(&ip) {
                                out.push(ip);
                            }
                        }
                        ua = (*ua).next;
                    }
                    ad = a.next;
                }
                break;
            }
            if rc != 111 {
                // not ERROR_BUFFER_OVERFLOW -> give up
                break;
            }
        }
    }
    out.sort_by_key(|ip| {
        if ip.starts_with("192.168.") {
            0
        } else if ip.starts_with("10.") {
            1
        } else {
            2
        }
    });
    out
}

// ============ 配置持久化（v1.2.19） ============
// daemon 重启（开机自启直进托盘）后内存配置丢失，LANDrop 身份 pk 等材料
// 要能恢复，否则保活要等 UI 启动同步过一次才激活。文件放 daemon.exe 同目录
// （便携安装可写；写失败静默跳过，不影响其他功能）。
fn config_file_path() -> Option<std::path::PathBuf> {
    let p = std::env::current_exe().ok()?;
    Some(p.with_file_name("daemon_config.json"))
}

fn save_config() {
    let Some(path) = config_file_path() else { return };
    let cfg = CONFIG.lock().unwrap();
    let Some(c) = cfg.as_ref() else { return };
    let json = serde_json::json!({
        "device_id": c.device_id,
        "device_name": c.device_name,
        "discover_enabled": c.discover_enabled,
        "web_share_enabled": c.web_share_enabled,
        "untrusted_confirm": c.untrusted_confirm,
        "untrusted_confirm_secs": c.untrusted_confirm_secs,
        "open_recv_dir": c.open_recv_dir,
        "receive_dir": c.receive_dir,
        "landrop_on": c.landrop_on,
        "landrop_pk": c.landrop_pk,
        "landrop_sk": c.landrop_sk,
    });
    if let Ok(txt) = serde_json::to_string_pretty(&json) {
        let _ = std::fs::write(path, txt);
    }
}

fn load_config() {
    let Some(path) = config_file_path() else { return };
    let Ok(txt) = std::fs::read_to_string(&path) else { return };
    let Ok(v) = serde_json::from_str::<serde_json::Value>(&txt) else { return };
    let mut cfg = CONFIG.lock().unwrap();
    let c = cfg.get_or_insert_with(Config::default);
    let mut n = 0usize;
    macro_rules! take_str {
        ($k:literal, $f:ident) => {
            if let Some(s) = v.get($k).and_then(|x| x.as_str()) {
                if !s.is_empty() {
                    c.$f = s.to_string();
                    n += 1;
                }
            }
        };
    }
    take_str!("device_id", device_id);
    take_str!("device_name", device_name);
    take_str!("receive_dir", receive_dir);
    take_str!("landrop_pk", landrop_pk);
    take_str!("landrop_sk", landrop_sk);
    if let Some(b) = v.get("discover_enabled").and_then(|x| x.as_bool()) {
        c.discover_enabled = b;
        n += 1;
    }
    if let Some(b) = v.get("web_share_enabled").and_then(|x| x.as_bool()) {
        c.web_share_enabled = b;
        n += 1;
    }
    if let Some(b) = v.get("untrusted_confirm").and_then(|x| x.as_bool()) {
        c.untrusted_confirm = b;
        n += 1;
    }
    if let Some(b) = v.get("open_recv_dir").and_then(|x| x.as_bool()) {
        c.open_recv_dir = b;
        n += 1;
    }
    if let Some(b) = v.get("landrop_on").and_then(|x| x.as_bool()) {
        c.landrop_on = b;
        n += 1;
    }
    if let Some(s) = v.get("untrusted_confirm_secs").and_then(|x| x.as_u64()) {
        c.untrusted_confirm_secs = s as u32;
        n += 1;
    }
    // daemon 刚起，UI 必然不在跑
    c.ui_active = false;
    if n > 0 {
        log(&format!("config loaded from disk ({} fields)", n));
    }
}

// ============ LANDrop 发现保活 + 传输（v1.2.19 发现 / v1.2.20 传输，托盘模式） ============
// 背景：LANDrop 发现层（UDP 52637 组播 announce/query）原先只存在于 Dart UI
// 进程（landrop_service.dart）。关主界面进托盘后 UI 退出，没人发 announce →
// 手机 LANDrop APP（被动设计只收 announce）永远发现不了电脑端微密。
// v1.2.19：daemon 接管发现（announce + query 应答）。
// v1.2.20：daemon 再接管 TCP 52637 传输服务（握手 + 收文件/文本），托盘下
// 完整可收；身份 pk/sk 由 UI 经 apply 同步（保对端 TOFU 信任列表不裂，
// sk 是 ServerHello 签名必需材料）。
// UI 一上线（ui_active=true）两个循环都让位 52637，交回 Dart landrop_service。
const LANDROP_PORT: u16 = 52637;
const LANDROP_GROUP: &str = "239.192.52.63";
const LANDROP_ANNOUNCE_SECS: u64 = 10;

/// 本网卡 /24 定向广播地址（对齐 Dart _directedBroadcastTargets）
fn directed_broadcast_ips() -> Vec<String> {
    local_ipv4s()
        .into_iter()
        .map(|ip| {
            let p: Vec<&str> = ip.split('.').collect();
            if p.len() == 4 {
                format!("{}.{}.{}.255", p[0], p[1], p[2])
            } else {
                ip
            }
        })
        .collect()
}

/// 保活激活条件：UI 不在跑 + 用户没关 LANDrop 兼容 + 已同步到身份 pk/sk。
/// v1.2.20 起 sk 也是必需项（托盘收文件时 ServerHello 要签名）；老 UI 只同步
/// pk 不同步 sk → 整个托盘 LANDrop 特性不激活（宁可全关，不可半残）。
fn landrop_active() -> Option<(String, String, String)> {
    let cfg = CONFIG.lock().unwrap();
    let c = cfg.as_ref()?;
    if c.ui_active || !c.landrop_on || c.landrop_pk.is_empty() || c.landrop_sk.is_empty() {
        return None;
    }
    Some((c.landrop_pk.clone(), c.landrop_sk.clone(), c.device_name.clone()))
}

/// LANDrop 发现包 JSON（与真实 LANDrop 及 Dart 侧字段完全一致）
fn landrop_packet(pk: &str, name: &str, port: u16, request: bool) -> Vec<u8> {
    serde_json::json!({
        "request": request,
        "supported_versions": ["v2"],
        "public_key": pk,
        "port": port,
        "device_info": {"name": name, "type": "pc"},
        "discoverable": true,
    })
    .to_string()
    .into_bytes()
}

/// 托盘模式 LANDrop 发现保活主循环。
/// - UI 活跃（ui_active=true）：完全静默并释放 52637，把发现层交还 Dart
/// - UI 收托盘（ui_active=false）：bind 52637（被真 LANDrop 占用则降级
///   临时端口、5s 重试抢回），每 10s 发 announce+query，对收到的 query
///   单播应答
/// - 逐网卡发送 socket（绑源 IP）绕开系统路由挑选：防 Wintun/ZeroTier
///   虚拟网卡（metric 最低）把组播/广播吞进隧道（v1.2.17 同款修复）
fn landrop_discovery_loop() {
    let mut main: Option<std::net::UdpSocket> = None; // 收包 + 单播应答
    let mut degraded = false; // 52637 被占（同机装着真 LANDrop）
    let mut senders: Vec<(String, std::net::UdpSocket)> = Vec::new();
    let mut last_send =
        std::time::Instant::now() - std::time::Duration::from_secs(3600);
    let mut last_rebind = std::time::Instant::now();
    let mut last_drained = 0usize;
    loop {
        let Some((pk, _sk, name)) = landrop_active() else {
            // UI 接管：释放 52637 给 Dart landrop_service
            if let Some(s) = main.take() {
                log("landrop: ui active, releasing 52637");
                drop(s);
                degraded = false;
            }
            senders.clear();
            std::thread::sleep(Duration::from_secs(2));
            continue;
        };
        if main.is_none() {
            match std::net::UdpSocket::bind(("0.0.0.0", LANDROP_PORT)) {
                Ok(s) => {
                    let _ = s.set_read_timeout(Some(Duration::from_millis(500)));
                    log("landrop: tray-mode discovery active on 52637");
                    main = Some(s);
                    degraded = false;
                }
                Err(e) => {
                    if !degraded {
                        degraded = true;
                        log(&format!(
                            "landrop: 52637 bind failed: {} (raw={:?}), degraded to temp port",
                            e,
                            e.raw_os_error()
                        ));
                    }
                    match std::net::UdpSocket::bind(("0.0.0.0", 0)) {
                        Ok(s) => {
                            let _ = s.set_read_timeout(Some(Duration::from_millis(500)));
                            main = Some(s);
                        }
                        Err(e) => {
                            log(&format!("landrop: udp bind failed: {}", e));
                            std::thread::sleep(Duration::from_secs(2));
                            continue;
                        }
                    }
                }
            }
        }
        // degraded（真 LANDrop 占了 52637）时每 5s 重试抢回：对方退出后
        // 无感恢复主端口（对齐 Dart _rebindTimer）
        if degraded && main.is_some() && last_rebind.elapsed() >= Duration::from_secs(5) {
            last_rebind = std::time::Instant::now();
            if let Ok(s) = std::net::UdpSocket::bind(("0.0.0.0", LANDROP_PORT)) {
                let _ = s.set_read_timeout(Some(Duration::from_millis(500)));
                if let Some(old) = main.replace(s) {
                    drop(old);
                }
                degraded = false;
                log("landrop: rebind 52637 OK");
            }
        }
        // 收包：query → 无条件单播应答（LANDrop 协议语义）；判自跳过。
        // **必须整轮排空**：我方每 10s 往组播/广播/定向广播发 announce+query
        // （4 socket × 6 目标 × 2 类型 ≈ 48 包），主 socket 0.0.0.0:52637 会把
        // 这些自回声全部收回来。若每轮只 recv 一次（500ms 超时）+sleep 500ms，
        // 处理速率 2 包/秒追不上 4.8 包/秒的自回流量，backlog 持续增长，
        // 对端 query 的应答延迟被拖到分钟级（实测单播 query 2 秒内无应答）。
        // 排空后每轮把所有待处理包一次做完，自回声当轮消化。
        if let Some(s) = &main {
            let mut buf = [0u8; 4096];
            let mut drained = 0usize;
            loop {
                match s.recv_from(&mut buf) {
                    Ok((n, src)) => {
                        drained += 1;
                        if let Ok(v) =
                            serde_json::from_slice::<serde_json::Value>(&buf[..n])
                        {
                            let from_pk =
                                v.get("public_key").and_then(|x| x.as_str()).unwrap_or("");
                            if from_pk == pk.as_str() {
                                // 自己逐网卡 socket 的回声
                            } else {
                                log(&format!(
                                    "landrop: recv from {} pk={}",
                                    src,
                                    &from_pk[..from_pk.len().min(12)]
                                ));
                                if v.get("request").and_then(|x| x.as_bool()) == Some(true) {
                                    let pkt = landrop_packet(
                                        &pk,
                                        &name,
                                        LANDROP_TCP_PORT.load(Ordering::Relaxed),
                                        false,
                                    );
                                    let _ = s.send_to(&pkt, src);
                                    log("landrop: query answered");
                                }
                            }
                        }
                    }
                    // 排空完成：读超时/非阻塞即缓冲区已空
                    Err(_) => break,
                }
            }
            last_drained = drained;
        }
        // 周期发包：announce + query → 组播 + 全网广播 + 逐网卡定向广播
        if last_send.elapsed() >= Duration::from_secs(LANDROP_ANNOUNCE_SECS) {
            last_send = std::time::Instant::now();
            // port 字段 = LANDrop TCP 传输端口（协议语义：对端握手连这）。
            // v1.2.19 曾误填 HTTP_PORT(52345)——对端连上去对着 HTTP 服务说
            // LANDrop 协议，必然失败；v1.2.20 传输线程起来后报真实监听端口。
            let port = LANDROP_TCP_PORT.load(Ordering::Relaxed);
            let announce = landrop_packet(&pk, &name, port, false);
            let query = landrop_packet(&pk, &name, port, true);
            let ips = local_ipv4s();
            senders.retain(|(ip, _)| ips.contains(ip));
            for ip in &ips {
                if senders.iter().any(|(i, _)| i == ip) {
                    continue;
                }
                if let Ok(s) = std::net::UdpSocket::bind((ip.as_str(), 0)) {
                    enable_broadcast(&s);
                    senders.push((ip.clone(), s));
                }
            }
            let mut targets: Vec<String> = vec![
                format!("{}:{}", LANDROP_GROUP, LANDROP_PORT),
                format!("255.255.255.255:{}", LANDROP_PORT),
            ];
            targets.extend(
                directed_broadcast_ips()
                    .into_iter()
                    .map(|ip| format!("{}:{}", ip, LANDROP_PORT)),
            );
            for (_, s) in &senders {
                for t in &targets {
                    let _ = s.send_to(&announce, t.as_str());
                    let _ = s.send_to(&query, t.as_str());
                }
            }
            log(&format!(
                "landrop: sent announce+query ({} sockets x {} targets), drained {} pkt/round",
                senders.len(),
                targets.len(),
                last_drained
            ));
        }
        std::thread::sleep(Duration::from_millis(500));
    }
}

/// Load the app icon: try the configured exe (ExtractIconEx), else .ico beside
/// daemon, else the default application icon.
// ============ LANDrop 传输（v1.2.20，托盘收文件/文本） ============
// 协议与 Dart landrop_service.dart 逐字段对齐（同一份 rust_crypto 原语）：
// 裸 TCP → ServerHello 握手 → supported_message_types/device_info 互换 →
// file_send_request（信任免确认/未信任确认框）→ 逐记录流式落盘 → 历史 + 气球。
// 端口让位：ui_active=true 时本循环整体静默并释放 52637，交还 Dart。

/// 单记录明文上限（与 landrop.rs LD_MAX_BLOCK_SIZE 一致）
const LD_MAX_BLOCK: usize = 65518;

/// supported_message_types 应答的能力清单（与 Dart 侧一致）
const LD_MSG_TYPES: &[&str] = &[
    "ack",
    "supported_message_types",
    "device_info",
    "file_send_request",
    "file_send_request_reply",
    "text_send",
];

// ---------- landrop.rs FFI 的 Rust 友好封装 ----------

fn ld_kx_keypair() -> ([u8; 32], [u8; 32]) {
    let mut pk = [0u8; 32];
    let mut sk = [0u8; 32];
    landrop::landrop_kx_keypair(pk.as_mut_ptr(), sk.as_mut_ptr());
    (pk, sk)
}

fn ld_kx_session_keys(
    is_client: bool,
    own_sk: &[u8; 32],
    own_pk: &[u8; 32],
    peer_pk: &[u8; 32],
) -> Option<([u8; 32], [u8; 32])> {
    let mut rx = [0u8; 32];
    let mut tx = [0u8; 32];
    let rc = landrop::landrop_kx_session_keys(
        is_client,
        own_sk.as_ptr(),
        own_pk.as_ptr(),
        peer_pk.as_ptr(),
        rx.as_mut_ptr(),
        tx.as_mut_ptr(),
    );
    if rc == 0 {
        Some((rx, tx))
    } else {
        None
    }
}

/// 6 位 verifCode（out 为 c_char 缓冲；Windows c_char=i8）
fn ld_verif_code(k_sc: &[u8; 32], k_cs: &[u8; 32]) -> String {
    let mut out = [0i8; 7];
    let rc = landrop::landrop_verif_code(k_sc.as_ptr(), k_cs.as_ptr(), out.as_mut_ptr());
    if rc != 0 {
        return String::new();
    }
    let bytes: Vec<u8> = out
        .iter()
        .take_while(|&&c| c != 0)
        .map(|&c| c as u8)
        .collect();
    String::from_utf8(bytes).unwrap_or_default()
}

fn ld_secp_keypair() -> Option<([u8; 33], [u8; 32])> {
    let mut pk = [0u8; 33];
    let mut sk = [0u8; 32];
    if landrop::landrop_secp_keypair(pk.as_mut_ptr(), sk.as_mut_ptr()) == 0 {
        Some((pk, sk))
    } else {
        None
    }
}

fn ld_pk_from_sk(sk: &[u8; 32]) -> Option<[u8; 33]> {
    let mut pk = [0u8; 33];
    if landrop::landrop_secp_pk_from_sk(sk.as_ptr(), pk.as_mut_ptr()) == 0 {
        Some(pk)
    } else {
        None
    }
}

fn ld_secp_sign(msg: &[u8], sk: &[u8; 32]) -> Option<[u8; 64]> {
    let mut sig = [0u8; 64];
    let rc = landrop::landrop_secp_sign(msg.as_ptr(), msg.len(), sk.as_ptr(), sig.as_mut_ptr());
    if rc == 0 {
        Some(sig)
    } else {
        None
    }
}

fn ld_secp_verify(sig: &[u8; 64], msg: &[u8], pk: &[u8; 33]) -> bool {
    landrop::landrop_secp_verify(sig.as_ptr(), msg.as_ptr(), msg.len(), pk.as_ptr()) == 0
}

fn ld_seal(key: &[u8; 32], nonce: &[u8; 12], pt: &[u8]) -> Vec<u8> {
    let mut out = vec![0u8; pt.len() + 16];
    let mut out_len: usize = 0;
    let rc = landrop::landrop_seal(
        key.as_ptr(),
        nonce.as_ptr(),
        pt.as_ptr(),
        pt.len(),
        out.as_mut_ptr(),
        &mut out_len,
    );
    if rc != 0 {
        return Vec::new();
    }
    out.truncate(out_len);
    out
}

fn ld_open(key: &[u8; 32], nonce: &[u8; 12], ct: &[u8]) -> Option<Vec<u8>> {
    let mut out = vec![0u8; ct.len()];
    let mut out_len: usize = 0;
    let rc = landrop::landrop_open(
        key.as_ptr(),
        nonce.as_ptr(),
        ct.as_ptr(),
        ct.len(),
        out.as_mut_ptr(),
        &mut out_len,
    );
    if rc != 0 {
        return None;
    }
    out.truncate(out_len);
    Some(out)
}

fn ld_nonce_inc(nonce: &mut [u8; 12]) {
    landrop::landrop_nonce_increment(nonce.as_mut_ptr());
}

/// base64 解码（标准字母表 + padding；容忍换行）
fn b64d(s: &str) -> Option<Vec<u8>> {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut rev = [255u8; 256];
    for (i, &c) in T.iter().enumerate() {
        rev[c as usize] = i as u8;
    }
    let mut out = Vec::with_capacity(s.len() * 3 / 4);
    let mut chunk = [0u8; 4];
    let mut n = 0usize;
    for &b in s.as_bytes() {
        if b == b'\n' || b == b'\r' {
            continue;
        }
        if b == b'=' {
            break;
        }
        let v = rev[b as usize];
        if v == 255 {
            return None;
        }
        chunk[n] = v;
        n += 1;
        if n == 4 {
            out.push((chunk[0] << 2) | (chunk[1] >> 4));
            out.push((chunk[1] << 4) | (chunk[2] >> 2));
            out.push((chunk[2] << 6) | chunk[3]);
            n = 0;
        }
    }
    match n {
        2 => out.push((chunk[0] << 2) | (chunk[1] >> 4)),
        3 => {
            out.push((chunk[0] << 2) | (chunk[1] >> 4));
            out.push((chunk[1] << 4) | (chunk[2] >> 2));
        }
        _ => {}
    }
    Some(out)
}

/// 连接级环境快照（accept 时取，避免会话中途持锁）
struct LdEnv {
    docs_dir: String,
    receive_dir: String,
    confirm_on: bool,
    confirm_secs: u32,
    self_pk_b64: String,
    self_sk_b64: String,
    self_name: String,
}

fn ld_env(pk_b64: &str, sk_b64: &str, name: &str) -> LdEnv {
    let cfg = CONFIG.lock().unwrap();
    let c = cfg.as_ref();
    LdEnv {
        docs_dir: c.map(|x| x.docs_dir.clone()).unwrap_or_default(),
        receive_dir: c.map(|x| x.receive_dir.clone()).unwrap_or_default(),
        confirm_on: c.map(|x| x.untrusted_confirm).unwrap_or(true),
        confirm_secs: c.map(|x| x.untrusted_confirm_secs).unwrap_or(30),
        self_pk_b64: pk_b64.to_string(),
        self_sk_b64: sk_b64.to_string(),
        self_name: name.to_string(),
    }
}

/// LANDrop 会话（服务端角色）：帧层 + 消息层 + 握手。
struct LdSession {
    stream: TcpStream,
    buf: Vec<u8>,
    rx_key: [u8; 32],
    tx_key: [u8; 32],
    rx_nonce: [u8; 12],
    tx_nonce: [u8; 12],
    peer_pk_b64: String,
    peer_name: String,
    verif_code: String,
    /// v1.2.20：本次 file_send_request 确认框里用户勾的「接收后打开文件夹」
    dialog_open_dir: bool,
}

impl LdSession {
    fn new(stream: TcpStream) -> Self {
        LdSession {
            stream,
            buf: Vec::new(),
            rx_key: [0u8; 32],
            tx_key: [0u8; 32],
            rx_nonce: [0u8; 12],
            tx_nonce: [0u8; 12],
            peer_pk_b64: String::new(),
            peer_name: "LANDrop 设备".to_string(),
            verif_code: String::new(),
            dialog_open_dir: false,
        }
    }

    // ---------- 帧层：[2B 大端长度][密文] ----------

    fn fill(&mut self) -> bool {
        let mut tmp = [0u8; 65536];
        match self.stream.read(&mut tmp) {
            Ok(0) => false,
            Ok(n) => {
                self.buf.extend_from_slice(&tmp[..n]);
                true
            }
            Err(_) => false,
        }
    }

    fn write_raw(&mut self, data: &[u8]) -> std::io::Result<()> {
        if data.len() > 65535 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "frame too long",
            ));
        }
        let hdr = [(data.len() >> 8) as u8, data.len() as u8];
        self.stream.write_all(&hdr)?;
        self.stream.write_all(data)?;
        self.stream.flush()
    }

    /// 读一个完整记录。None = 对端关闭或协议违例。
    fn read_raw(&mut self) -> Option<Vec<u8>> {
        loop {
            if self.buf.len() >= 2 {
                let len = ((self.buf[0] as usize) << 8) | self.buf[1] as usize;
                if len > LD_MAX_BLOCK + 17 {
                    return None; // 单记录明文 1B push + ≤65518 + 16 tag
                }
                if self.buf.len() >= len + 2 {
                    let out = self.buf[2..2 + len].to_vec();
                    self.buf.drain(..2 + len);
                    return Some(out);
                }
            }
            if !self.fill() {
                return None;
            }
        }
    }

    // ---------- 消息层：AEAD 记录 + push 分片 ----------

    fn send_bytes(&mut self, data: &[u8]) -> std::io::Result<()> {
        let mut off = 0usize;
        loop {
            let end = (off + LD_MAX_BLOCK).min(data.len());
            let last = end >= data.len();
            let mut plain = Vec::with_capacity(1 + (end - off));
            plain.push(if last { 1u8 } else { 0u8 });
            plain.extend_from_slice(&data[off..end]);
            let ct = ld_seal(&self.tx_key, &self.tx_nonce, &plain);
            if ct.is_empty() {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::Other,
                    "aead seal failed",
                ));
            }
            self.write_raw(&ct)?;
            ld_nonce_inc(&mut self.tx_nonce);
            off = end;
            if off >= data.len() {
                break;
            }
        }
        Ok(())
    }

    /// 收一条完整消息（跨记录累积到 push=1）。None = 关闭/解密失败。
    fn recv_bytes(&mut self) -> Option<Vec<u8>> {
        let mut out = Vec::new();
        loop {
            let ct = self.read_raw()?;
            let pt = ld_open(&self.rx_key, &self.rx_nonce, &ct)?;
            ld_nonce_inc(&mut self.rx_nonce);
            if pt.is_empty() {
                return None; // 异常空记录
            }
            let push = pt[0];
            out.extend_from_slice(&pt[1..]);
            if push == 1 {
                return Some(out);
            }
        }
    }

    fn send_json(&mut self, v: &serde_json::Value) -> std::io::Result<()> {
        let bytes = serde_json::to_vec(v)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e.to_string()))?;
        self.send_bytes(&bytes)
    }

    fn recv_json(&mut self) -> Option<serde_json::Value> {
        let bytes = self.recv_bytes()?;
        serde_json::from_slice(&bytes).ok()
    }

    // ---------- 握手（服务端） ----------

    fn handshake_server(&mut self, my_pk_b64: &str, my_sk_b64: &str) -> Result<(), String> {
        let hello_bytes = self
            .read_raw()
            .ok_or_else(|| "ClientHello 未到达".to_string())?;
        let hello: serde_json::Value = serde_json::from_slice(&hello_bytes)
            .map_err(|e| format!("ClientHello 解析失败: {}", e))?;
        let versions = hello
            .get("supported_versions")
            .and_then(|v| v.as_array())
            .ok_or_else(|| "ClientHello 缺 supported_versions".to_string())?;
        if !versions.iter().any(|v| v.as_str() == Some("v2")) {
            return Err("对端不支持 v2".to_string());
        }
        let peer_pk_b64 = hello
            .get("public_key")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        if peer_pk_b64.is_empty() {
            return Err("ClientHello 缺 public_key".to_string());
        }
        let peer_pk = b64d(peer_pk_b64).ok_or_else(|| "public_key base64 损坏".to_string())?;
        let peer_pk: [u8; 33] = peer_pk
            .try_into()
            .map_err(|_| "public_key 长度异常".to_string())?;
        let ecdhe = hello
            .get("ecdhe")
            .ok_or_else(|| "ClientHello 缺 ecdhe".to_string())?;
        let peer_ecdhe_pk =
            b64d(ecdhe.get("public_key").and_then(|v| v.as_str()).unwrap_or(""))
                .ok_or_else(|| "ecdhe.public_key base64 损坏".to_string())?;
        let sig = b64d(ecdhe.get("sig").and_then(|v| v.as_str()).unwrap_or(""))
            .ok_or_else(|| "ecdhe.sig base64 损坏".to_string())?;
        let peer_ecdhe_pk: [u8; 32] = peer_ecdhe_pk
            .try_into()
            .map_err(|_| "ecdhe.public_key 长度异常".to_string())?;
        let sig: [u8; 64] = sig
            .try_into()
            .map_err(|_| "ecdhe.sig 长度异常".to_string())?;
        // 验签：sig = secp256k1_sign(blake2b-256(ecdhe.pk), 对端 sk)
        if !ld_secp_verify(&sig, &peer_ecdhe_pk, &peer_pk) {
            return Err("ClientHello 验签失败".to_string());
        }
        // 我方 kx 密钥对 + 签名
        let (kx_pk, kx_sk) = ld_kx_keypair();
        let my_sk = b64d(my_sk_b64).ok_or_else(|| "身份 sk base64 损坏".to_string())?;
        let my_sk: [u8; 32] = my_sk
            .try_into()
            .map_err(|_| "身份 sk 长度异常".to_string())?;
        let my_sig =
            ld_secp_sign(&kx_pk, &my_sk).ok_or_else(|| "ServerHello 签名失败".to_string())?;
        let server_hello = serde_json::json!({
            "version": "v2",
            "public_key": my_pk_b64,
            "ecdhe": {
                "public_key": b64(&kx_pk),
                "sig": b64(&my_sig),
            },
        });
        let bytes = serde_json::to_vec(&server_hello)
            .map_err(|e| format!("ServerHello 序列化失败: {}", e))?;
        self.write_raw(&bytes)
            .map_err(|e| format!("ServerHello 发送失败: {}", e))?;
        // 派生会话密钥（server 角色）
        let (rx, tx) = ld_kx_session_keys(false, &kx_sk, &kx_pk, &peer_ecdhe_pk)
            .ok_or_else(|| "会话密钥派生失败（弱公钥）".to_string())?;
        self.rx_key = rx;
        self.tx_key = tx;
        self.peer_pk_b64 = peer_pk_b64.to_string();
        // server 角色：kSc=tx, kCs=rx（与 Dart landrop_service 一致）
        self.verif_code = ld_verif_code(&self.tx_key, &self.rx_key);
        Ok(())
    }

    // ---------- 消息循环 ----------

    fn listen(&mut self, env: &LdEnv) {
        loop {
            let Some(msg) = self.recv_json() else { return };
            let ty = msg.get("type").and_then(|v| v.as_str()).unwrap_or("");
            let data = msg.get("data").cloned().unwrap_or(serde_json::Value::Null);
            match ty {
                "supported_message_types" => {
                    let _ = self.send_json(&serde_json::json!({
                        "type": "supported_message_types",
                        "data": {"types": LD_MSG_TYPES},
                    }));
                }
                "device_info" => {
                    self.peer_name = data
                        .get("name")
                        .and_then(|v| v.as_str())
                        .unwrap_or("LANDrop 设备")
                        .to_string();
                    let _ = self.send_json(&serde_json::json!({
                        "type": "device_info",
                        "data": {"name": env.self_name, "type": "pc"},
                    }));
                }
                "file_send_request" => {
                    let files = data
                        .get("files")
                        .and_then(|v| v.as_array())
                        .cloned()
                        .unwrap_or_default();
                    self.handle_file_send_request(env, &files);
                }
                "text_send" => {
                    let text = data.get("text").and_then(|v| v.as_str()).unwrap_or("");
                    self.handle_text_send(env, text);
                }
                _ => {
                    let _ = self.send_json(&serde_json::json!({"type": "ack", "data": {"ack": false}}));
                }
            }
        }
    }

    // ---------- 接收决策 / 落盘 ----------

    fn reply_file_send_request(&mut self, accept: bool) -> std::io::Result<()> {
        self.send_json(&serde_json::json!({
            "type": "file_send_request_reply",
            "data": {"accept": accept, "compression": "none"},
        }))?;
        if !accept {
            // LANDrop 拒收后关闭连接（先 flush 保 reply 到达）
            self.stream.flush()?;
            let _ = self.stream.shutdown(std::net::Shutdown::Both);
        }
        Ok(())
    }

    fn handle_file_send_request(&mut self, env: &LdEnv, files: &[serde_json::Value]) {
        if files.is_empty() {
            let _ = self.reply_file_send_request(false);
            return;
        }
        let total: u64 = files
            .iter()
            .map(|f| f.get("size").and_then(|v| v.as_u64()).unwrap_or(0))
            .sum();
        // 信任设备免确认直收（与 Dart/网页版同一个 trusted_devices.json）
        let trusted = trusted_ids(&env.docs_dir).contains(&self.peer_pk_b64);
        let accept = if trusted {
            true
        } else if env.confirm_on {
            let hint = if files.len() == 1 {
                safe_file_name(
                    files[0]
                        .get("filename")
                        .and_then(|v| v.as_str())
                        .unwrap_or("未命名文件"),
                )
            } else {
                format!("{} 个文件", files.len())
            };
            let (a, o) = wait_untrusted_confirm(
                &self.peer_name,
                &self.peer_pk_b64,
                &hint,
                total,
                false,
                env.confirm_secs,
                &self.verif_code,
            );
            // v1.2.20：用户在确认框选的「接收后打开文件夹」传给写盘点
            self.dialog_open_dir = o;
            a
        } else {
            false
        };
        if !accept {
            let _ = self.reply_file_send_request(false);
            balloon(
                "微密飞传",
                &format!(
                    "已拒收：{} 未在信任列表\n（{}）",
                    self.peer_name,
                    if env.confirm_on {
                        format!("{}秒未确认，自动拒收", env.confirm_secs.max(5))
                    } else {
                        "策略为直接拒绝".to_string()
                    }
                ),
            );
            for f in files {
                let name = safe_file_name(
                    f.get("filename")
                        .and_then(|v| v.as_str())
                        .unwrap_or("未命名文件"),
                );
                let size = f.get("size").and_then(|v| v.as_u64()).unwrap_or(0);
                record_history(
                    "file",
                    &name,
                    size,
                    &self.peer_name,
                    false,
                    None,
                    None,
                    Some(&self.peer_pk_b64),
                );
            }
            return;
        }
        let _ = self.reply_file_send_request(true);
        for f in files {
            let raw = f
                .get("filename")
                .and_then(|v| v.as_str())
                .unwrap_or("未命名文件");
            let size = f.get("size").and_then(|v| v.as_u64()).unwrap_or(0);
            let lm = f.get("last_modified").and_then(|v| v.as_u64()).unwrap_or(0);
            self.receive_one_file(env, raw, size, lm);
        }
    }

    fn receive_one_file(&mut self, env: &LdEnv, raw_name: &str, size: u64, last_modified: u64) {
        // 路径净化（safe_file_name 会把 '/' 拍平，文件夹传输落为扁平文件）
        let name = safe_file_name(raw_name);
        let Some(save) = resolve_save_path(&env.receive_dir, &name) else {
            balloon(
                "微密飞传",
                &format!("接收失败：无法创建保存路径（{}）", name),
            );
            record_history(
                "file",
                &name,
                size,
                &self.peer_name,
                false,
                None,
                None,
                Some(&self.peer_pk_b64),
            );
            return;
        };
        let mut ok = true;
        let mut file = match std::fs::File::create(&save) {
            Ok(f) => f,
            Err(e) => {
                log(&format!("landrop: create {} failed: {}", save.display(), e));
                ok = false;
                match std::fs::File::open(std::path::Path::new("NUL")) {
                    Ok(f) => f, // 占位：走统一的失败收尾（字节仍要排空）
                    Err(_) => {
                        record_history(
                            "file",
                            &name,
                            size,
                            &self.peer_name,
                            false,
                            None,
                            None,
                            Some(&self.peer_pk_b64),
                        );
                        return;
                    }
                }
            }
        };
        let mut remaining = size;
        while remaining > 0 {
            let Some(chunk) = self.recv_bytes() else {
                ok = false;
                break;
            };
            if chunk.len() as u64 > remaining {
                ok = false; // 对端多送：协议违例
                break;
            }
            if file.write_all(&chunk).is_err() {
                ok = false;
                break;
            }
            remaining -= chunk.len() as u64;
        }
        drop(file);
        if ok {
            // 恢复 mtime（权限字段 Windows 无意义，忽略）
            if last_modified > 0 {
                let t = UNIX_EPOCH + Duration::from_secs(last_modified);
                if let Ok(f) =
                    std::fs::OpenOptions::new().write(true).open(&save)
                {
                    let _ = f.set_modified(t);
                }
            }
            // v1.2.20：确认框选了「接收并打开文件夹」→ 无视配置强制开；
            // 否则按配置（设置→接收后自动打开文件夹）
            if self.dialog_open_dir {
                open_recv_dir_now(&save);
            } else {
                maybe_open_recv_dir(&save);
            }
            balloon(
                "微密飞传",
                &format!("收到文件：{}\n来自 {}", name, self.peer_name),
            );
            record_history(
                "file",
                &name,
                size,
                &self.peer_name,
                true,
                None,
                Some(&save.to_string_lossy()),
                Some(&self.peer_pk_b64),
            );
        } else {
            let _ = std::fs::remove_file(&save);
            balloon(
                "微密飞传",
                &format!("接收失败：{}\n来自 {}", name, self.peer_name),
            );
            record_history(
                "file",
                &name,
                size,
                &self.peer_name,
                false,
                None,
                None,
                Some(&self.peer_pk_b64),
            );
        }
    }

    fn handle_text_send(&mut self, env: &LdEnv, text: &str) {
        // v1.2.21：未信任设备的文本也要确认（原来直接收，与文件路径不对称——
        // 老板实测未信任时文本不弹确认框）。
        // 信任设备免确认直收（与 Dart/网页版同一个 trusted_devices.json）
        let trusted = trusted_ids(&env.docs_dir).contains(&self.peer_pk_b64);
        if !trusted {
            if !env.confirm_on {
                // 策略为直接拒绝
                let _ = self.send_json(
                    &serde_json::json!({"type": "ack", "data": {"ack": false}}),
                );
                record_history(
                    "text",
                    "（已拒收）一条文本",
                    text.chars().count() as u64,
                    &self.peer_name,
                    false,
                    None,
                    None,
                    Some(&self.peer_pk_b64),
                );
                return;
            }
            let (accept, _open) = wait_untrusted_confirm(
                &self.peer_name,
                &self.peer_pk_b64,
                "一条文本消息",
                text.chars().count() as u64,
                true,
                env.confirm_secs,
                &self.verif_code,
            );
            if !accept {
                let _ = self.send_json(
                    &serde_json::json!({"type": "ack", "data": {"ack": false}}),
                );
                record_history(
                    "text",
                    "（已拒收）一条文本",
                    text.chars().count() as u64,
                    &self.peer_name,
                    false,
                    None,
                    None,
                    Some(&self.peer_pk_b64),
                );
                return;
            }
        }
        let _ = self.send_json(&serde_json::json!({"type": "ack", "data": {"ack": true}}));
        balloon(
            "微密飞传",
            &format!("收到文本：{}\n来自 {}", short_text(text), self.peer_name),
        );
        record_history(
            "text",
            &short_text(text),
            text.chars().count() as u64,
            &self.peer_name,
            true,
            Some(text),
            None,
            Some(&self.peer_pk_b64),
        );
    }
}

/// 单连接处理（握手 + 会话循环）。
fn handle_landrop_conn(stream: TcpStream, env: LdEnv) {
    // 监听器是非阻塞的；显式回阻塞 + 读超时（记录间 30s 无数据即断）
    let _ = stream.set_nonblocking(false);
    let _ = stream.set_read_timeout(Some(Duration::from_secs(30)));
    let _ = stream.set_nodelay(true);
    let peer = stream
        .peer_addr()
        .map(|a| a.to_string())
        .unwrap_or_else(|_| "?".to_string());
    let mut sess = LdSession::new(stream);
    if let Err(e) = sess.handshake_server(&env.self_pk_b64, &env.self_sk_b64) {
        log(&format!("landrop: handshake failed from {}: {}", peer, e));
        return;
    }
    log(&format!(
        "landrop: session up from {} peer={} verif={}",
        peer,
        &sess.peer_pk_b64[..sess.peer_pk_b64.len().min(12)],
        sess.verif_code
    ));
    sess.listen(&env);
}

/// 托盘模式 LANDrop 传输主循环（v1.2.20）。
/// - UI 活跃（ui_active=true）：静默并释放 52637，交还 Dart landrop_service
/// - 否则 bind TCP 52637（被真 LANDrop 占→降级临时端口，发现包报真实端口），
///   每连接一线程；非阻塞轮询 accept 保证 ~300ms 内响应 ui_active 翻转
fn landrop_transfer_loop() {
    let mut listener: Option<TcpListener> = None;
    let mut degraded = false;
    let mut last_rebind = std::time::Instant::now();
    let mut ident_bad_logged = false;
    loop {
        let Some((pk_b64, sk_b64, name)) = landrop_active() else {
            if let Some(l) = listener.take() {
                log("landrop: ui active, releasing tcp 52637");
                drop(l);
                degraded = false;
                LANDROP_TCP_PORT.store(LANDROP_PORT, Ordering::Relaxed);
            }
            ident_bad_logged = false;
            std::thread::sleep(Duration::from_secs(2));
            continue;
        };
        // sk→pk 自检：身份材料不配套（老 UI 只同步了 pk）时拒绝传输，
        // 否则占着端口但握手必失败。发现层照常（对方至少能看到设备）。
        let ident_ok = match (b64d(&sk_b64), b64d(&pk_b64)) {
            (Some(sk), Some(pk)) if sk.len() == 32 && pk.len() == 33 => {
                match ld_pk_from_sk(<&[u8; 32]>::try_from(&sk[..]).unwrap()) {
                    Some(derived) => b64(&derived) == pk_b64,
                    None => false,
                }
            }
            _ => false,
        };
        if !ident_ok {
            if !ident_bad_logged {
                log("landrop: identity sk/pk mismatch, transfer disabled");
                ident_bad_logged = true;
            }
            LANDROP_TCP_PORT.store(0, Ordering::Relaxed);
            std::thread::sleep(Duration::from_secs(5));
            continue;
        }
        if listener.is_none() {
            match TcpListener::bind(("0.0.0.0", LANDROP_PORT)) {
                Ok(l) => {
                    let port = l.local_addr().map(|a| a.port()).unwrap_or(LANDROP_PORT);
                    LANDROP_TCP_PORT.store(port, Ordering::Relaxed);
                    log(&format!("landrop: tray-mode transfer active on {}", port));
                    listener = Some(l);
                    degraded = false;
                }
                Err(e) => {
                    if !degraded {
                        degraded = true;
                        log(&format!(
                            "landrop: tcp {} bind failed: {} (raw={:?}), degraded to temp port",
                            LANDROP_PORT,
                            e,
                            e.raw_os_error()
                        ));
                    }
                    match TcpListener::bind(("0.0.0.0", 0)) {
                        Ok(l) => {
                            let port = l.local_addr().map(|a| a.port()).unwrap_or(0);
                            LANDROP_TCP_PORT.store(port, Ordering::Relaxed);
                            listener = Some(l);
                        }
                        Err(e) => {
                            log(&format!("landrop: tcp bind failed: {}", e));
                            std::thread::sleep(Duration::from_secs(2));
                            continue;
                        }
                    }
                }
            }
        }
        // degraded（真 LANDrop 占了 52637）时每 5s 抢回
        if degraded && last_rebind.elapsed() >= Duration::from_secs(5) {
            last_rebind = std::time::Instant::now();
            if let Ok(l) = TcpListener::bind(("0.0.0.0", LANDROP_PORT)) {
                let port = l.local_addr().map(|a| a.port()).unwrap_or(LANDROP_PORT);
                LANDROP_TCP_PORT.store(port, Ordering::Relaxed);
                if let Some(old) = listener.replace(l) {
                    drop(old);
                }
                degraded = false;
                log("landrop: rebind tcp 52637 OK");
            }
        }
        // 非阻塞 accept：无连接即睡 300ms 回头查 ui_active
        let l = listener.as_ref().unwrap();
        let _ = l.set_nonblocking(true);
        match l.accept() {
            Ok((stream, addr)) => {
                let env = ld_env(&pk_b64, &sk_b64, &name);
                log(&format!("landrop: inbound conn from {}", addr));
                std::thread::spawn(move || handle_landrop_conn(stream, env));
            }
            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(300));
            }
            Err(_) => {
                if let Some(old) = listener.take() {
                    drop(old);
                }
                std::thread::sleep(Duration::from_secs(1));
            }
        }
    }
}

fn load_app_icon(exe_path: &str) -> HICON {
    unsafe {
        if !exe_path.is_empty() && Path::new(exe_path).exists() {
            let w = to_wide(exe_path);
            let mut big: HICON = std::ptr::null_mut();
            let mut small: HICON = std::ptr::null_mut();
            if ExtractIconExW(w.as_ptr(), 0, &mut big, &mut small, 1) > 0 && !small.is_null() {
                return small;
            }
        }
        if let Some(dir) = std::env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(|d| d.to_path_buf()))
        {
            let ico = dir.join("app_icon.ico");
            if ico.exists() {
                let w = to_wide(ico.to_string_lossy().as_ref());
                let h = LoadImageW(
                    std::ptr::null_mut(),
                    w.as_ptr(),
                    IMAGE_ICON,
                    0,
                    0,
                    LR_LOADFROMFILE | LR_DEFAULTSIZE,
                );
                if !h.is_null() {
                    return h as HICON;
                }
            }
        }
        LoadIconW(std::ptr::null_mut(), IDI_APPLICATION as *const u16)
    }
}

// ==================== tray ====================

struct TrayState {
    hwnd: isize, // HWND as isize: raw pointer is not Send, isize is
    icon: isize,
}

impl TrayState {
    fn hwnd(&self) -> HWND {
        self.hwnd as HWND
    }
    fn icon(&self) -> HICON {
        self.icon as HICON
    }
}

static TRAY: Mutex<Option<TrayState>> = Mutex::new(None);

const MENU_OPEN: usize = 1001;
const MENU_QUIT: usize = 1002;

fn tray_add(hwnd: HWND, icon: HICON) -> bool {
    let mut nid: NOTIFYICONDATAW = unsafe { std::mem::zeroed() };
    nid.cbSize = std::mem::size_of::<NOTIFYICONDATAW>() as u32;
    nid.hWnd = hwnd;
    nid.uID = 1;
    nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    nid.uCallbackMessage = WM_USER_TRAYCB;
    nid.hIcon = icon;
    let tip = to_wide("微密文件（托盘模式）");
    let n = tip.len().min(127);
    nid.szTip[..n].copy_from_slice(&tip[..n]);
    unsafe { Shell_NotifyIconW(NIM_ADD, &nid) != 0 }
}

fn tray_delete() {
    if let Ok(g) = TRAY.lock() {
        if let Some(t) = g.as_ref() {
            unsafe {
                let mut nid: NOTIFYICONDATAW = std::mem::zeroed();
                nid.cbSize = std::mem::size_of::<NOTIFYICONDATAW>() as u32;
                nid.hWnd = t.hwnd();
                nid.uID = 1;
                Shell_NotifyIconW(NIM_DELETE, &nid);
            }
        }
    }
}

fn balloon(title: &str, text: &str) {
    if let Ok(g) = TRAY.lock() {
        if let Some(t) = g.as_ref() {
            unsafe {
                let mut nid: NOTIFYICONDATAW = std::mem::zeroed();
                nid.cbSize = std::mem::size_of::<NOTIFYICONDATAW>() as u32;
                nid.hWnd = t.hwnd();
                nid.uID = 1;
                nid.uFlags = NIF_INFO;
                nid.dwInfoFlags = NIIF_INFO;
                let ti = to_wide(title);
                let n = ti.len().min(63);
                nid.szInfoTitle[..n].copy_from_slice(&ti[..n]);
                let tx = to_wide(text);
                let m = tx.len().min(255);
                nid.szInfo[..m].copy_from_slice(&tx[..m]);
                Shell_NotifyIconW(NIM_MODIFY, &nid);
            }
        }
    }
}

fn tray_menu(hwnd: HWND) {
    unsafe {
        let menu = CreatePopupMenu();
        if menu.is_null() {
            return;
        }
        let t1 = to_wide("打开微密文件");
        let t2 = to_wide("退出");
        AppendMenuW(menu, MF_STRING, MENU_OPEN, t1.as_ptr());
        AppendMenuW(menu, MF_SEPARATOR, 0, std::ptr::null());
        AppendMenuW(menu, MF_STRING, MENU_QUIT, t2.as_ptr());
        let mut pt = POINT { x: 0, y: 0 };
        GetCursorPos(&mut pt);
        SetForegroundWindow(hwnd); // required so menu dismisses on outside click
        TrackPopupMenu(menu, TPM_BOTTOMALIGN, pt.x, pt.y, 0, hwnd, std::ptr::null());
        DestroyMenu(menu);
    }
}

fn launch_ui(page: Option<&str>) {
    let exe = {
        let cfg = CONFIG.lock().unwrap();
        cfg.as_ref()
            .map(|c| c.exe_path.clone())
            .unwrap_or_default()
    };
    if exe.is_empty() {
        log("open clicked but no exe_path configured");
        balloon("微密文件", "尚未配置主程序路径");
        return;
    }
    // 主界面已在跑：不再重复拉起（UI 只有一个实例）
    unsafe {
        let cls = to_wide("FLUTTER_RUNNER_WIN32_WINDOW");
        if !FindWindowW(cls.as_ptr(), std::ptr::null()).is_null() {
            log("launch_ui: main window already open");
            return;
        }
    }
    unsafe {
        let w = to_wide(&exe);
        let cmdline = match page {
            Some(p) => format!("\"{}\" --page={}", exe, p),
            None => format!("\"{}\"", exe),
        };
        let mut cmd = to_wide(&cmdline);
        let mut si: [u8; 104] = [0; 104]; // STARTUPINFOW x64
        let mut pi: [u8; 24] = [0; 24]; // PROCESS_INFORMATION x64
        si[0] = 104;
        let ok = CreateProcessW(
            w.as_ptr(),
            cmd.as_mut_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            0,
            CREATE_NEW_CONSOLE,
            std::ptr::null(),
            std::ptr::null(),
            si.as_mut_ptr() as *mut core::ffi::c_void,
            pi.as_mut_ptr() as *mut core::ffi::c_void,
        );
        if ok == 0 {
            log(&format!("CreateProcessW failed for {}", exe));
            balloon("微密文件", "打开主程序失败");
        }
    }
}

/// 双击 Ctrl 呼出快捷搜索浮窗（UI 进程不在时由守护进程代听）。
/// 与 Dart HotkeyService 同参数：80ms 采样、350ms 窗口、按下沿判定。
/// UI 在跑时（主窗口存在）守护进程不介入，由 UI 自己处理。
fn hotkey_thread() {
    std::thread::spawn(|| {
        const VK_LCTRL: i32 = 0xA2;
        const VK_RCTRL: i32 = 0xA3;
        const WINDOW_MS: u128 = 350;
        // 两次按下之间必须的真实释放间隔：小于此值视为长按中途的按键抖动
        const MIN_RELEASE_GAP_MS: u128 = 60;
        let mut was_down = false;
        let mut last_press: Option<std::time::Instant> = None;
        let mut released_at: Option<std::time::Instant> = None;
        loop {
            unsafe { Sleep(30) };
            // 主窗口存在 → UI 自己监听，守护进程静默
            unsafe {
                let cls = to_wide("FLUTTER_RUNNER_WIN32_WINDOW");
                if !FindWindowW(cls.as_ptr(), std::ptr::null()).is_null() {
                    was_down = false;
                    last_press = None;
                    released_at = None;
                    continue;
                }
            }
            let down = unsafe {
                (GetAsyncKeyState(VK_LCTRL) as u16 & 0x8000) != 0
                    || (GetAsyncKeyState(VK_RCTRL) as u16 & 0x8000) != 0
            };
            if down {
                if !was_down {
                    let now = std::time::Instant::now();
                    match (last_press, released_at) {
                        (Some(t), Some(rel))
                            if now.duration_since(t).as_millis() <= WINDOW_MS =>
                        {
                            if now.duration_since(rel).as_millis()
                                >= MIN_RELEASE_GAP_MS
                            {
                                // 真实双击：两次按下间有足够长的释放间隔
                                last_press = None;
                                released_at = None;
                                log("double ctrl: launching ui popup");
                                launch_ui(Some("popup"));
                            }
                            // 释放间隔太短：按点弹跳，视作同一次按压延续
                        }
                        _ => {
                            last_press = Some(now);
                            released_at = None;
                        }
                    }
                }
                was_down = true;
            } else {
                if last_press.is_some() && released_at.is_none() {
                    released_at = Some(std::time::Instant::now());
                }
                was_down = false;
                if let Some(t) = last_press {
                    if t.elapsed().as_millis() > WINDOW_MS {
                        last_press = None;
                        released_at = None;
                    }
                }
            }
        }
    });
}

fn tray_update_icon(new_icon: HICON) {    if let Ok(mut g) = TRAY.lock() {
        if let Some(t) = g.as_mut() {
            t.icon = new_icon as isize;
            unsafe {
                let mut nid: NOTIFYICONDATAW = std::mem::zeroed();
                nid.cbSize = std::mem::size_of::<NOTIFYICONDATAW>() as u32;
                nid.hWnd = t.hwnd();
                nid.uID = 1;
                nid.uFlags = NIF_ICON;
                nid.hIcon = new_icon;
                Shell_NotifyIconW(NIM_MODIFY, &nid);
            }
        }
    }
}

unsafe extern "system" fn wnd_proc(hwnd: HWND, msg: u32, wp: usize, lp: isize) -> isize {
    let tb = TASKBAR_MSG.load(Ordering::Relaxed);
    if tb != 0 && msg == tb {
        // explorer restarted: re-add icon
        if let Ok(g) = TRAY.lock() {
            if let Some(t) = g.as_ref() {
                tray_add(t.hwnd(), t.icon());
            }
        }
        return 0;
    }
    match msg {
        WM_USER_TRAYCB => {
            let m = (lp & 0xFFFF) as u32;
            if m == WM_RBUTTONUP {
                tray_menu(hwnd);
            } else if m == WM_LBUTTONDBLCLK {
                launch_ui(None);
            } else if m == NIN_BALLOONUSERCLICK {
                // 点通知气泡：直达传输记录页
                launch_ui(Some("transfer"));
            }
            0
        }
        WM_COMMAND => match wp & 0xFFFF {
            MENU_OPEN => {
                launch_ui(None);
                0
            }
            MENU_QUIT => {
                DestroyWindow(hwnd);
                0
            }
            _ => 0,
        },
        WM_TIMER => 0,
        WM_CLOSE => {
            DestroyWindow(hwnd);
            0
        }
        WM_DESTROY => {
            tray_delete();
            PostQuitMessage(0);
            0
        }
        _ => DefWindowProcW(hwnd, msg, wp, lp),
    }
}

// ==================== trusted devices ====================

fn trusted_ids(docs_dir: &str) -> Vec<String> {
    let mut out = Vec::new();
    if docs_dir.is_empty() {
        return out;
    }
    let p = Path::new(docs_dir).join("trusted_devices.json");
    if let Ok(raw) = std::fs::read_to_string(p) {
        if let Ok(serde_json::Value::Object(map)) = serde_json::from_str::<serde_json::Value>(&raw)
        {
            for k in map.keys() {
                out.push(k.clone());
            }
        }
    }
    out
}

// ==================== untrusted confirm (30s countdown) ====================

/// One pending untrusted request: decision cell + describe info for UI.
struct PendingReq {
    cell: Arc<(Mutex<Option<bool>>, Condvar)>,
    from: String,
    name: String,
    size: u64,
    is_text: bool,
}

static PENDING: std::sync::OnceLock<Mutex<HashMap<String, PendingReq>>> =
    std::sync::OnceLock::new();
static PENDING_SEQ: AtomicU32 = AtomicU32::new(0);

/// v1.2.21 批量决策缓存：设备 key → (accept, open_dir, 过期时刻)。
/// 用户在确认框勾选「同批后续按此次选择」后写入，5 分钟内同设备的后续
/// 文件/文本请求直接按此次决定执行，不再逐个弹框。
static BATCH: std::sync::OnceLock<Mutex<HashMap<String, (bool, bool, std::time::Instant)>>> =
    std::sync::OnceLock::new();

fn batch_map() -> &'static Mutex<HashMap<String, (bool, bool, std::time::Instant)>> {
    BATCH.get_or_init(|| Mutex::new(HashMap::new()))
}

fn pending_map() -> &'static Mutex<HashMap<String, PendingReq>> {
    PENDING.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Wait for the user's decision on an untrusted request. True = accept.
/// - UI 活跃：拉起主程序走 UI 确认框（原有路径）
/// - 托盘模式（UI 未运行）：直接弹**原生 Win32 确认框**，全程不需要主程序；
///   超时自动关框=拒收
/// 未信任设备接收确认。返回 (accept, open_dir)：
/// - UI 活跃分支：UI 弹窗点「是」(accept, 不开——UI 侧有自己的开目录逻辑)
/// - 托盘分支：三按钮原生框（是=开文件夹 / 否=仅接收 / 取消=拒收），
///   v1.2.21 加「同批后续按此次选择」勾选（BATCH_DECISIONS 按设备缓存 5 分钟）
/// - 返回 (accept, open_dir)
fn wait_untrusted_confirm(
    sender_name: &str,
    device_key: &str,
    name: &str,
    size: u64,
    is_text: bool,
    timeout_secs: u32,
    verif: &str,
) -> (bool, bool) {
    let timeout_secs: u64 = if timeout_secs < 5 { 5 } else { timeout_secs as u64 };
    // 批量模式：同设备 5 分钟内已勾选过「同批按此次选择」→ 不再弹框
    if !device_key.is_empty() {
        let b = batch_map().lock().unwrap();
        if let Some((accept, open, until)) = b.get(device_key) {
            if std::time::Instant::now() < *until {
                log(&format!(
                    "untrusted request from {} ({}): batch decision accept={}",
                    sender_name, name, accept
                ));
                return (*accept, *open);
            }
        }
    }
    let token = format!("p{}-{}", now_ms(), PENDING_SEQ.fetch_add(1, Ordering::Relaxed));
    let entry = PendingReq {
        cell: Arc::new((Mutex::new(None), Condvar::new())),
        from: sender_name.to_string(),
        name: name.to_string(),
        size,
        is_text,
    };
    pending_map()
        .lock()
        .unwrap()
        .insert(token.clone(), entry);

    let ui_active = CONFIG
        .lock()
        .unwrap()
        .as_ref()
        .map(|c| c.ui_active)
        .unwrap_or(false);

    let mut decision = false;
    // 托盘分支三按钮框的「接收后打开文件夹」选择（UI 分支恒 false）
    let mut dlg_open = false;
    // 托盘分支勾选「同批后续按此次选择」（UI 分支恒 false）
    let mut dlg_batch = false;
    let verif_hint = if verif.is_empty() {
        String::new()
    } else {
        format!("\n核对码：{}（请与发送方核对）", verif)
    };
    if ui_active {
        balloon(
            "微密飞传",
            &format!(
                "{} 请求发送：{}{}\n已拉起微密文件，{}秒内未确认将自动拒收",
                sender_name, name, verif_hint, timeout_secs
            ),
        );
        launch_ui(None);

        let deadline = std::time::Instant::now() + Duration::from_secs(timeout_secs);
        {
            let entry = pending_map()
            .lock()
            .unwrap()
            .get(&token)
            .map(|e| e.cell.clone());
            if let Some(cell) = entry {
                let (m, cv) = &*cell;
                loop {
                    let guard = m.lock().unwrap();
                    if let Some(v) = *guard {
                        decision = v;
                        break;
                    }
                    let now = std::time::Instant::now();
                    if now >= deadline {
                        break;
                    }
                    let (g, _) = cv.wait_timeout(guard, deadline - now).unwrap();
                    if let Some(v) = *g {
                        decision = v;
                        break;
                    }
                }
            }
        }
    } else {
        // 托盘独立接收：不调主程序，弹原生确认框
        balloon(
            "微密飞传",
            &format!(
                "{} 请求发送：{}{}\n请在弹出的确认框里选择，{}秒内未确认将自动拒收",
                sender_name, name, verif_hint, timeout_secs
            ),
        );
        let (d, o, b) = native_confirm_dialog(sender_name, name, is_text, timeout_secs, verif);
        decision = d;
        dlg_open = o;
        dlg_batch = b;
    }
    // 勾选了批量 → 按设备缓存 5 分钟（后续同设备请求直接按此次决定）
    if dlg_batch && !device_key.is_empty() {
        batch_map().lock().unwrap().insert(
            device_key.to_string(),
            (decision, dlg_open, std::time::Instant::now() + Duration::from_secs(300)),
        );
    }
    pending_map().lock().unwrap().remove(&token);
    log(&format!(
        "untrusted request from {} ({}): decision={} open_dir={}",
        sender_name, name, decision, dlg_open
    ));
    (decision, dlg_open)
}

// ==================== 接收确认对话框（v1.2.23）====================
// v1.2.20–1.2.22 手绘 CreateWindowExW 消息循环在实机上稳定崩溃（WER 三次
// 记录 0xc0000005 @ USER32+0x81ed：气泡弹出后确认窗未现、进程直接消失）。
// v1.2.23 改用 Windows 标准对话框管理器 DialogBoxIndirectParam + 内存
// DLGTEMPLATE：三按钮 + 批量勾选框 + WM_TIMER 超时自动拒收。消息循环、
// 焦点、默认按钮全由系统对话框管理器接管，不再手写消息泵。
//   是 = 接收并打开文件夹 (accept=true,  open=true)
//   否 = 仅接收           (accept=true,  open=false)
//   取消 = 拒收           (accept=false, open=false)
// 返回 (accept, open_dir, batch)。

const WM_INITDIALOG: u32 = 0x0110;
const IDC_CONFIRM_YES: usize = 1001;
const IDC_CONFIRM_NO: usize = 1002;
const IDC_CONFIRM_CANCEL: usize = 1003;
const IDC_CONFIRM_BATCH: usize = 1004;

type DLGPROC = Option<unsafe extern "system" fn(HWND, u32, usize, isize) -> isize>;

struct ConfirmState {
    accept: std::cell::Cell<bool>,
    open: std::cell::Cell<bool>,
    timeout_ms: u32,
}

/// 编码内存 DLGTEMPLATE（+ 5 个 DLGITEMTEMPLATE），全部按 WORD 流写、
/// 每个 item 起始 DWORD 对齐。控件：正文 Static + 批量勾选 Checkbox +
/// 是/否/取消 三按钮（取消为默认回车键，宁拒勿收）。
fn build_confirm_template(title: &str, body: &str, batch: &str) -> Vec<u16> {
    let mut w: Vec<u16> = Vec::new();
    let mut push_w = |v: &mut Vec<u16>, x: u16| v.push(x);
    let _ = &mut push_w;
    // ---- 头：style, extStyle, cdit, x, y, cx, cy ----
    let dlg_style: u32 = 0x8000_0000 // WS_POPUP
        | 0x00C0_0000 // WS_CAPTION
        | 0x0008_0000 // WS_SYSMENU
        | 0x0000_0080 // DS_MODALFRAME
        | 0x0000_0800 // DS_CENTER（屏幕居中）
        | 0x0000_0040; // DS_SETFONT
    w.push((dlg_style & 0xffff) as u16);
    w.push((dlg_style >> 16) as u16);
    let ext: u32 = 0x0000_0008; // WS_EX_TOPMOST
    w.push((ext & 0xffff) as u16);
    w.push((ext >> 16) as u16);
    w.push(5); // cdit：正文 + 勾选框 + 3 按钮
    for v in [0i16, 0, 190, 116] {
        w.push(v as u16);
    }
    w.push(0x0000); // menu: 无
    w.push(0x0000); // class: 默认对话框类
    for c in title.encode_utf16() {
        w.push(c);
    }
    w.push(0);
    w.push(9); // 字号 pt
    for c in "Microsoft YaHei UI".encode_utf16() {
        w.push(c);
    }
    w.push(0);

    // ---- item 编码 helper（起始 DWORD 对齐）----
    fn align4(w: &mut Vec<u16>) {
        if w.len() % 2 != 0 {
            w.push(0);
        }
    }
    fn item(w: &mut Vec<u16>, style: u32, x: i16, y: i16, cx: i16, cy: i16, id: u16,
            cls_atom: u16, text: &str) {
        align4(w);
        w.push((style & 0xffff) as u16);
        w.push((style >> 16) as u16);
        w.push(0); // extStyle lo
        w.push(0); // extStyle hi
        for v in [x, y, cx, cy] {
            w.push(v as u16);
        }
        w.push(id);
        w.push(0xFFFF);
        w.push(cls_atom);
        for c in text.encode_utf16() {
            w.push(c);
        }
        w.push(0);
        w.push(0x0000); // 无 creation data
    }
    const WS_CHILD: u32 = 0x4000_0000;
    const WS_VISIBLE: u32 = 0x1000_0000;
    const WS_TABSTOP: u32 = 0x0001_0000;
    const WS_GROUP: u32 = 0x0002_0000;
    // 1) 正文 Static
    item(&mut w, WS_CHILD | WS_VISIBLE | WS_GROUP | 0, 12, 8, 166, 46,
         0, 0x0082, body); // 0x82 = Static
    // 2) 批量勾选
    item(&mut w, WS_CHILD | WS_VISIBLE | WS_TABSTOP | 0x0000_0003, 12, 60, 166, 10,
         IDC_CONFIRM_BATCH as u16, 0x0080, batch); // 0x80 = Button（BS_AUTOCHECKBOX）
    // 3) 是 = 接收并打开文件夹
    item(&mut w, WS_CHILD | WS_VISIBLE | WS_TABSTOP | 0x0000_0000, 30, 88, 40, 14,
         IDC_CONFIRM_YES as u16, 0x0080, "是(Y)");
    // 4) 否 = 仅接收
    item(&mut w, WS_CHILD | WS_VISIBLE | WS_TABSTOP | 0x0000_0000, 75, 88, 40, 14,
         IDC_CONFIRM_NO as u16, 0x0080, "否(N)");
    // 5) 取消 = 拒收（默认回车键）
    item(&mut w, WS_CHILD | WS_VISIBLE | WS_TABSTOP | 0x0000_0001, 120, 88, 40, 14,
         IDC_CONFIRM_CANCEL as u16, 0x0080, "取消(C)");
    w
}

fn native_confirm_dialog(
    sender_name: &str,
    name: &str,
    is_text: bool,
    timeout_secs: u64,
    verif: &str,
) -> (bool, bool, bool) {
    let verif_line = if verif.is_empty() {
        String::new()
    } else {
        format!("\n核对码：{}（请与发送方核对）", verif)
    };
    let body = if is_text {
        format!(
            "「{}」想发送一条文本消息到本机{}\n\n是 = 接收并打开文件夹\n否 = 仅接收\n取消 = 拒收\n\n（{} 秒未确认自动拒收）",
            sender_name, verif_line, timeout_secs.max(5)
        )
    } else {
        format!(
            "「{}」想发送文件到本机：\n{}{}\n\n是 = 接收并打开文件夹\n否 = 仅接收\n取消 = 拒收\n\n（{} 秒未确认自动拒收）",
            sender_name, name, verif_line, timeout_secs.max(5)
        )
    };
    let batch_hint = if is_text {
        "同批后续消息都按此次选择（不再逐个询问）"
    } else {
        "同批后续文件都按此次选择（不再逐个询问）"
    };
    let title_w = "微密飞传 - 接收确认".to_string();

    let tmpl = build_confirm_template(&title_w, &body, batch_hint);
    let state = ConfirmState {
        accept: std::cell::Cell::new(false),
        open: std::cell::Cell::new(false),
        timeout_ms: (timeout_secs.max(5).min(3600) as u32).saturating_mul(1000),
    };
    let inst = unsafe { GetModuleHandleW(std::ptr::null()) };
    let id = unsafe {
        DialogBoxIndirectParamW(
            inst,
            tmpl.as_ptr() as *const core::ffi::c_void,
            std::ptr::null_mut(),
            Some(confirm_dlg_proc),
            &state as *const ConfirmState as isize,
        )
    };
    if id == 0 || id == -1 {
        // 模板/创建失败：宁拒勿收
        return (false, false, false);
    }
    let batch = unsafe {
        // 对话框已销毁后不能查控件勾选态——在 WM_COMMAND 里已写入 open/accept；
        // batch 由 dlg_proc 经静态 thread_local 传出
        CONFIRM_BATCH_TAKEN.with(|c| c.get())
    };
    (state.accept.get(), state.open.get(), batch)
}

thread_local! {
    static CONFIRM_BATCH_TAKEN: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

unsafe extern "system" fn confirm_dlg_proc(hwnd: HWND, msg: u32, wp: usize, lp: isize) -> isize {
    match msg {
        WM_INITDIALOG => {
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, lp);
            let st = &*(lp as *const ConfirmState);
            SetTimer(hwnd, 1, st.timeout_ms, 0);
            SetForegroundWindow(hwnd);
            1
        }
        WM_TIMER => {
            // 超时未决：自动拒收（等同点「取消」）
            KillTimer(hwnd, 1);
            EndDialog(hwnd, IDC_CONFIRM_CANCEL as isize);
            1
        }
        WM_COMMAND => {
            let id = wp & 0xffff;
            match id {
                x if x == IDC_CONFIRM_YES as usize
                    || x == IDC_CONFIRM_NO as usize
                    || x == IDC_CONFIRM_CANCEL as usize =>
                {
                    KillTimer(hwnd, 1);
                    let p = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *const ConfirmState;
                    let batch = SendMessageW(
                        GetDlgItem(hwnd, IDC_CONFIRM_BATCH),
                        BM_GETCHECK,
                        0,
                        0,
                    ) as u32
                        == BST_CHECKED;
                    CONFIRM_BATCH_TAKEN.with(|c| c.set(batch));
                    if !p.is_null() {
                        let st = &*p;
                        if x == IDC_CONFIRM_YES as usize {
                            st.accept.set(true);
                            st.open.set(true);
                        } else if x == IDC_CONFIRM_NO as usize {
                            st.accept.set(true);
                            st.open.set(false);
                        }
                    }
                    EndDialog(hwnd, x as isize);
                    1
                }
                _ => 0,
            }
        }
        WM_CLOSE => {
            // Alt+F4 / 关闭按钮：按拒收
            KillTimer(hwnd, 1);
            EndDialog(hwnd, IDC_CONFIRM_CANCEL as isize);
            1
        }
        _ => 0,
    }
}

// ==================== save path / history ====================

fn safe_file_name(name: &str) -> String {
    let mut s: String = name
        .chars()
        .map(|c| match c {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
            _ => c,
        })
        .collect();
    s = s.trim().to_string();
    if s.is_empty() || s == "." || s == ".." {
        s = "unnamed".to_string();
    }
    let chars: Vec<char> = s.chars().collect();
    if chars.len() > 160 {
        s = chars[..160].iter().collect();
    }
    s
}

fn resolve_save_path(dir: &str, name: &str) -> Option<PathBuf> {
    if dir.is_empty() {
        return None;
    }
    let base = PathBuf::from(dir);
    if !base.is_dir() {
        let _ = std::fs::create_dir_all(&base);
    }
    let p = Path::new(name);
    let (stem, ext) = match p.extension() {
        Some(e) => (
            p.file_stem()?.to_string_lossy().to_string(),
            format!(".{}", e.to_string_lossy()),
        ),
        None => (name.to_string(), String::new()),
    };
    let mut cand = base.join(format!("{}{}", stem, ext));
    let mut i = 1;
    while cand.exists() {
        cand = base.join(format!("{}({}){}", stem, i, ext));
        i += 1;
        if i > 9999 {
            return None;
        }
    }
    Some(cand)
}

fn record_history(
    kind: &str,
    name: &str,
    size: u64,
    peer: &str,
    ok: bool,
    text: Option<&str>,
    path: Option<&str>,
    peer_id: Option<&str>,
) {
    let docs = {
        let cfg = CONFIG.lock().unwrap();
        cfg.as_ref()
            .map(|c| c.docs_dir.clone())
            .unwrap_or_default()
    };
    if docs.is_empty() {
        return;
    }
    let p = Path::new(&docs).join("daemon_transfers.jsonl");
    // peerId = 发送方 identityId（UI 会话 key 同源）。缺了它 UI 侧按
    // peerName 兜底聚合，同一设备会裂成两个会话（v1.2.16 实机故障）。
    let obj = serde_json::json!({
        "kind": kind,
        "direction": "in",
        "name": name,
        "text": text,
        "path": path,
        "size": size,
        "peerName": peer,
        "peerId": peer_id,
        "time": now_ms(),
        "ok": ok,
        "via": "daemon",
    });
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(p) {
        let _ = writeln!(f, "{}", obj);
    }
}

fn short_text(t: &str) -> String {
    let mut s: String = t.chars().take(50).collect();
    if t.chars().count() > 50 {
        s.push('…');
    }
    s.replace('\n', " ")
}

// ==================== http ====================

fn find_subsequence(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.len() > haystack.len() {
        return None;
    }
    haystack.windows(needle.len()).position(|w| w == needle)
}

fn url_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Ok(v) = u8::from_str_radix(
                std::str::from_utf8(&b[i + 1..i + 3]).unwrap_or("zz"),
                16,
            ) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        if b[i] == b'+' {
            out.push(b' ');
        } else {
            out.push(b[i]);
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).to_string()
}

/// percent-only decode (headers): '+' stays '+' to match Dart Uri.decodeComponent.
fn url_decode_pct(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Ok(v) = u8::from_str_radix(
                std::str::from_utf8(&b[i + 1..i + 3]).unwrap_or("zz"),
                16,
            ) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).to_string()
}

fn header_get(h: &[(String, String)], name: &str) -> String {
    h.iter()
        .find(|(k, _)| k.eq_ignore_ascii_case(name))
        .map(|(_, v)| v.clone())
        .unwrap_or_default()
}

struct RequestHead {
    method: String,
    path: String,
    query_name: String,
    headers: Vec<(String, String)>,
}

fn read_request_head(stream: &mut TcpStream) -> Option<(RequestHead, Vec<u8>)> {
    let mut buf: Vec<u8> = Vec::with_capacity(4096);
    let mut tmp = [0u8; 4096];
    let head_end;
    loop {
        let n = match stream.read(&mut tmp) {
            Ok(0) => return None,
            Ok(n) => n,
            Err(_) => return None,
        };
        buf.extend_from_slice(&tmp[..n]);
        if let Some(pos) = find_subsequence(&buf, b"\r\n\r\n") {
            head_end = pos;
            break;
        }
        if buf.len() > 64 * 1024 {
            return None;
        }
    }
    let head = String::from_utf8_lossy(&buf[..head_end]).to_string();
    let mut lines = head.split("\r\n");
    let first = lines.next().unwrap_or("");
    let mut parts = first.split_whitespace();
    let method = parts.next()?.to_uppercase();
    let target = parts.next()?.to_string();
    let (path, query) = match target.split_once('?') {
        Some((p, q)) => (p.to_string(), q.to_string()),
        None => (target.clone(), String::new()),
    };
    let query_name = query
        .split('&')
        .find_map(|kv| kv.strip_prefix("name="))
        .map(url_decode)
        .unwrap_or_default();
    let mut headers = Vec::new();
    for l in lines {
        if let Some((k, v)) = l.split_once(':') {
            headers.push((k.trim().to_string(), v.trim().to_string()));
        }
    }
    Some((
        RequestHead {
            method,
            path,
            query_name,
            headers,
        },
        buf[head_end + 4..].to_vec(),
    ))
}

fn write_json(stream: &mut TcpStream, status: u16, body: &serde_json::Value) {
    let mut m = serde_json::Map::new();
    m.insert("ok".into(), body.get("ok").cloned().unwrap_or(serde_json::json!(false)));
    if let Some(v) = body.get("path") {
        if !v.is_null() {
            m.insert("path".into(), v.clone());
        }
    }
    if let Some(v) = body.get("error") {
        if !v.is_null() {
            m.insert("error".into(), v.clone());
        }
    }
    let body = serde_json::to_string(&serde_json::Value::Object(m))
        .unwrap_or_else(|_| "{\"ok\":false}".into());
    let reason = match status {
        200 => "OK",
        403 => "Forbidden",
        404 => "Not Found",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        _ => "ERR",
    };
    let resp = format!(
        "HTTP/1.1 {} {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        status,
        reason,
        body.len(),
        body
    );
    let _ = stream.write_all(resp.as_bytes());
    let _ = stream.flush();
}

fn write_full(stream: &mut TcpStream, status: u16, ctype: &str, body: &[u8]) {
    let reason = match status {
        200 => "OK",
        403 => "Forbidden",
        404 => "Not Found",
        503 => "Service Unavailable",
        _ => "ERR",
    };
    let head = format!(
        "HTTP/1.1 {} {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        status,
        reason,
        ctype,
        body.len()
    );
    let _ = stream.write_all(head.as_bytes());
    let _ = stream.write_all(body);
    let _ = stream.flush();
}

/// read whole body (content-length or chunked) into memory; text paths only.
fn read_body_all(
    stream: &mut TcpStream,
    mut buf: Vec<u8>,
    content_length: Option<u64>,
    chunked: bool,
) -> Vec<u8> {
    if chunked {
        return dechunk(buf, stream);
    }
    if let Some(len) = content_length {
        let need = len as usize;
        while buf.len() < need {
            let mut tmp = [0u8; 64 * 1024];
            match stream.read(&mut tmp) {
                Ok(0) | Err(_) => break,
                Ok(n) => buf.extend_from_slice(&tmp[..n]),
            }
        }
        buf.truncate(need);
    }
    buf
}

/// stream body (content-length or chunked) into file, returns bytes written.
/// HTTP 请求体分块泵（v1.2.18 自 stream_body_to_file 泛化）：逐块回调，
/// 非chunked 按定长、chunked 增量解码。返回写入字节数。
fn stream_body_chunks<F>(
    stream: &mut TcpStream,
    leftover: Vec<u8>,
    content_length: Option<u64>,
    chunked: bool,
    mut on_chunk: F,
) -> std::io::Result<u64>
where
    F: FnMut(&[u8]) -> std::io::Result<()>,
{
    let mut written: u64 = 0;
    if !chunked {
        let Some(len) = content_length else {
            return Ok(0);
        };
        let mut need = len;
        let mut pending = leftover;
        if !pending.is_empty() {
            let take = pending.len().min(need as usize);
            on_chunk(&pending[..take])?;
            written += take as u64;
            need -= take as u64;
            pending.clear();
        }
        let mut tmp = [0u8; 64 * 1024];
        while need > 0 {
            let n = stream.read(&mut tmp)?;
            if n == 0 {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::UnexpectedEof,
                    "eof",
                ));
            }
            let take = (n as u64).min(need);
            on_chunk(&tmp[..take as usize])?;
            written += take;
            need -= take;
        }
        return Ok(written);
    }
    // chunked: incremental decode
    let mut cur = leftover;
    let mut pos = 0usize;
    loop {
        match find_subsequence(&cur[pos..], b"\r\n") {
            Some(rel) => {
                let size_str = String::from_utf8_lossy(&cur[pos..pos + rel]);
                let size = usize::from_str_radix(
                    size_str.trim().split(';').next().unwrap_or("0"),
                    16,
                )
                .unwrap_or(0);
                pos += rel + 2;
                if size == 0 {
                    return Ok(written);
                }
                // ensure chunk data + trailing CRLF available
                while cur.len() - pos < size + 2 {
                    let mut tmp = [0u8; 64 * 1024];
                    let n = stream.read(&mut tmp)?;
                    if n == 0 {
                        return Err(std::io::Error::new(
                            std::io::ErrorKind::UnexpectedEof,
                            "eof",
                        ));
                    }
                    cur.extend_from_slice(&tmp[..n]);
                }
                on_chunk(&cur[pos..pos + size])?;
                written += size as u64;
                pos += size + 2;
                // compact occasionally
                if pos > 4 * 1024 * 1024 {
                    cur.drain(..pos);
                    pos = 0;
                }
            }
            None => {
                // keep searching: grow buffer
                if cur.len() - pos > 1024 * 1024 {
                    // pathologically long size line
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "bad chunk",
                    ));
                }
                let mut tmp = [0u8; 16 * 1024];
                let n = stream.read(&mut tmp)?;
                if n == 0 {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::UnexpectedEof,
                        "eof",
                    ));
                }
                cur.extend_from_slice(&tmp[..n]);
            }
        }
    }
}

fn stream_body_to_file(
    stream: &mut TcpStream,
    leftover: Vec<u8>,
    content_length: Option<u64>,
    chunked: bool,
    out: &Path,
) -> std::io::Result<u64> {
    let mut file = std::fs::File::create(out)?;
    stream_body_chunks(stream, leftover, content_length, chunked, |c| {
        file.write_all(c)
    })
}

/// 把 HTTP 请求体按 WS 二进制帧泵给房间内某个网页客户端
/// （v1.2.18：设备→网页中继，发送方向与 web→设备相反）。
#[allow(clippy::too_many_arguments)]
fn stream_body_to_ws(
    stream: &mut TcpStream,
    leftover: Vec<u8>,
    content_length: Option<u64>,
    chunked: bool,
    tx: &std::sync::mpsc::Sender<Vec<u8>>,
    fid: &str,
    name: &str,
    size: u64,
    from_id: &str,
    from_name: &str,
) -> std::io::Result<u64> {
    let _ = tx.send(ws_frame(
        1,
        serde_json::json!({
            "t": "file-start",
            "from": from_id,
            "fromName": from_name,
            "name": name,
            "size": size,
            "fid": fid,
        })
        .to_string()
        .as_bytes(),
    ));
    let r = stream_body_chunks(stream, leftover, content_length, chunked, |c| {
        let _ = tx.send(ws_frame(2, c));
        Ok(())
    });
    match r {
        Ok(n) => {
            let _ = tx.send(ws_frame(
                1,
                serde_json::json!({"t": "file-done", "fid": fid}).to_string().as_bytes(),
            ));
            Ok(n)
        }
        Err(e) => {
            let _ = tx.send(ws_frame(
                1,
                serde_json::json!({"t": "file-abort", "fid": fid}).to_string().as_bytes(),
            ));
            Err(e)
        }
    }
}

fn dechunk(mut buf: Vec<u8>, stream: &mut TcpStream) -> Vec<u8> {
    let mut out = Vec::new();
    loop {
        let Some(pos) = find_subsequence(&buf, b"\r\n") else {
            let mut tmp = [0u8; 8192];
            match stream.read(&mut tmp) {
                Ok(0) | Err(_) => break,
                Ok(n) => buf.extend_from_slice(&tmp[..n]),
            }
            continue;
        };
        let size_str = String::from_utf8_lossy(&buf[..pos]);
        let size = usize::from_str_radix(size_str.trim(), 16).unwrap_or(0);
        if size == 0 {
            break;
        }
        let start = pos + 2;
        while buf.len() < start + size + 2 {
            let mut tmp = [0u8; 64 * 1024];
            match stream.read(&mut tmp) {
                Ok(0) | Err(_) => break,
                Ok(n) => buf.extend_from_slice(&tmp[..n]),
            }
        }
        if buf.len() < start + size {
            break;
        }
        out.extend_from_slice(&buf[start..start + size]);
        if buf.len() >= start + size + 2 {
            buf.drain(..start + size + 2);
        } else {
            break;
        }
    }
    out
}

fn handle_client(mut stream: TcpStream) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(30)));
    let (head, leftover) = match read_request_head(&mut stream) {
        Some(x) => x,
        None => return,
    };
    let cl = header_get(&head.headers, "content-length");
    let content_length = cl.parse::<u64>().ok();
    let chunked = header_get(&head.headers, "transfer-encoding")
        .to_ascii_lowercase()
        .contains("chunked");

    let (web_on, recv_dir, docs) = {
        let cfg = CONFIG.lock().unwrap();
        match cfg.as_ref() {
            Some(c) => (
                c.web_share_enabled,
                c.receive_dir.clone(),
                c.docs_dir.clone(),
            ),
            None => (false, String::new(), String::new()),
        }
    };
    let receiving = TRANSFER_ON.load(Ordering::Relaxed);
    let remote_ip = stream
        .peer_addr()
        .map(|a| a.ip().to_string())
        .unwrap_or_default();

    // WebSocket 房间（网页版）：与「可被发现」解耦，只受网页快传开关约束
    if head.path == "/ws" {
        if !web_on {
            write_full(&mut stream, 403, "text/plain", b"web share off");
            return;
        }
        handle_ws(stream, &head, leftover);
        return;
    }

    match (head.method.as_str(), head.path.as_str()) {
        ("GET", "/") | ("GET", "/index.html") => {
            if web_on {
                write_full(
                    &mut stream,
                    200,
                    "text/html; charset=utf-8",
                    web_page().as_bytes(),
                );
            } else {
                write_full(&mut stream, 404, "text/plain", b"not found");
            }
        }
        ("GET", "/weimi/ping") => {
            write_full(&mut stream, 200, "application/json", b"{\"ok\":true}");
        }
        ("POST", "/web/upload") => {
            if !receiving {
                write_json(
                    &mut stream,
                    503,
                    &serde_json::json!({"ok": false, "error": "receiving off"}),
                );
                return;
            }
            let from = format!("网页客户端({})", remote_ip);
            let name = safe_file_name(if head.query_name.is_empty() {
                "unnamed"
            } else {
                &head.query_name
            });
            // v1.2.23：网页端与微密/LANDrop 同一套信任确认；本机浏览器
            // (127.0.0.1) 免确认，远程浏览器按 IP 弹确认框（勾选同批 5 分钟免打扰）
            if remote_ip != "127.0.0.1" {
                let confirm = CONFIG
                    .lock()
                    .unwrap()
                    .as_ref()
                    .map(|c| (c.untrusted_confirm, c.untrusted_confirm_secs))
                    .unwrap_or((true, 30));
                let accepted = if confirm.0 {
                    wait_untrusted_confirm(
                        &from,
                        &format!("web-{}", remote_ip),
                        &name,
                        content_length.unwrap_or(0),
                        false,
                        confirm.1,
                        "",
                    )
                    .0
                } else {
                    false
                };
                if !accepted {
                    write_json(
                        &mut stream,
                        403,
                        &serde_json::json!({"ok": false, "error": "rejected"}),
                    );
                    balloon(
                        "微密飞传",
                        &format!(
                            "已拒收：{} 未在信任列表\n（{}）",
                            from,
                            if confirm.0 {
                                format!("{}秒未确认，自动拒收", confirm.1.max(5))
                            } else {
                                "策略为直接拒绝".to_string()
                            }
                        ),
                    );
                    record_history(
                        "file",
                        &name,
                        content_length.unwrap_or(0),
                        &from,
                        false,
                        None,
                        None,
                        Some("web"),
                    );
                    return;
                }
            }
            let Some(save) = resolve_save_path(&recv_dir, &name) else {
                write_json(
                    &mut stream,
                    500,
                    &serde_json::json!({"ok": false, "error": "no dir"}),
                );
                return;
            };
            match stream_body_to_file(&mut stream, leftover, content_length, chunked, &save) {
                Ok(n) => {
                    write_json(
                        &mut stream,
                        200,
                        &serde_json::json!({"ok": true, "path": save.to_string_lossy()}),
                    );
                    balloon(
                        "微密飞传",
                        &format!("收到网页文件：{}\n来自 {}", name, from),
                    );
                    maybe_open_recv_dir(&save);
                    record_history(
                        "file",
                        &name,
                        n,
                        &from,
                        true,
                        None,
                        Some(&save.to_string_lossy()),
                        Some("web"),
                    );
                }
                Err(e) => {
                    let _ = std::fs::remove_file(&save);
                    write_json(
                        &mut stream,
                        500,
                        &serde_json::json!({"ok": false, "error": e.to_string()}),
                    );
                    record_history("file", &name, 0, &from, false, None, None, Some("web"));
                }
            }
        }
        ("POST", "/web/text") => {
            if !receiving {
                write_json(
                    &mut stream,
                    503,
                    &serde_json::json!({"ok": false, "error": "receiving off"}),
                );
                return;
            }
            let from = format!("网页客户端({})", remote_ip);
            // v1.2.23：网页端与微密/LANDrop 同一套信任确认；本机浏览器
            // (127.0.0.1) 免确认，远程浏览器按 IP 弹确认框（勾选同批 5 分钟免打扰）
            if remote_ip != "127.0.0.1" {
                let confirm = CONFIG
                    .lock()
                    .unwrap()
                    .as_ref()
                    .map(|c| (c.untrusted_confirm, c.untrusted_confirm_secs))
                    .unwrap_or((true, 30));
                let accepted = if confirm.0 {
                    wait_untrusted_confirm(
                        &from,
                        &format!("web-{}", remote_ip),
                        "一条文本消息",
                        0,
                        true,
                        confirm.1,
                        "",
                    )
                    .0
                } else {
                    false
                };
                if !accepted {
                    write_json(
                        &mut stream,
                        403,
                        &serde_json::json!({"ok": false, "error": "rejected"}),
                    );
                    balloon(
                        "微密飞传",
                        &format!(
                            "已拒收：{} 未在信任列表\n（{}）",
                            from,
                            if confirm.0 {
                                format!("{}秒未确认，自动拒收", confirm.1.max(5))
                            } else {
                                "策略为直接拒绝".to_string()
                            }
                        ),
                    );
                    record_history(
                        "text",
                        "（已拒收）一条文本",
                        0,
                        &from,
                        false,
                        None,
                        None,
                        Some("web"),
                    );
                    return;
                }
            }
            let body = read_body_all(&mut stream, leftover, content_length, chunked);
            let text = String::from_utf8_lossy(&body).to_string();
            write_json(&mut stream, 200, &serde_json::json!({"ok": true}));
            balloon(
                "微密飞传",
                &format!("收到网页文本：{}\n来自 {}", short_text(&text), from),
            );
            record_history(
                "text",
                &short_text(&text),
                text.chars().count() as u64,
                &from,
                true,
                Some(&text),
                None,
                Some("web"),
            );
        }
        ("POST", "/weimi/send") | ("POST", "/weimi/text") => {
            if !receiving {
                write_json(
                    &mut stream,
                    503,
                    &serde_json::json!({"ok": false, "error": "receiving off"}),
                );
                return;
            }
            let is_text = head.path == "/weimi/text";
            if header_get(&head.headers, "x-weimi-app") != MAGIC {
                write_json(&mut stream, 403, &serde_json::json!({"ok": false}));
                return;
            }
            let sender_id = header_get(&head.headers, "x-sender-id");
            let sender_name = {
                let n = url_decode_pct(&header_get(&head.headers, "x-sender-name"));
                if n.is_empty() {
                    "未知设备".to_string()
                } else {
                    n
                }
            };
            let trusted = trusted_ids(&docs).contains(&sender_id);
            let mut accepted = trusted;
            if !trusted {
                // 内容描述（确认框与拒收记录都要用）
                let (hint, fsize) = if is_text {
                    ("一条文本消息".to_string(), content_length.unwrap_or(0))
                } else {
                    let n = url_decode_pct(&header_get(&head.headers, "x-file-name"));
                    let n = if n.is_empty() { "unnamed".to_string() } else { n };
                    (
                        safe_file_name(&n),
                        header_get(&head.headers, "x-file-size")
                            .parse::<u64>()
                            .unwrap_or(0),
                    )
                };
                let confirm = CONFIG
                    .lock()
                    .unwrap()
                    .as_ref()
                    .map(|c| (c.untrusted_confirm, c.untrusted_confirm_secs))
                    .unwrap_or((true, 30));
                if confirm.0 {
                    // 等 UI 确认（daemon 会拉起主界面），超时自动拒；
                    // open_dir 分量仅托盘三按钮框会产生，网页流忽略（收完
                    // 开目录由 UI 侧/配置管）
                    accepted = wait_untrusted_confirm(
                        &sender_name,
                        &sender_id,
                        &hint,
                        fsize,
                        is_text,
                        confirm.1,
                        "",
                    )
                    .0;
                }
                if !accepted {
                    write_json(
                        &mut stream,
                        403,
                        &serde_json::json!({"ok": false, "error": "rejected"}),
                    );
                    balloon(
                        "微密飞传",
                        &format!(
                            "已拒收：{} 未在信任列表\n（{}）",
                            sender_name,
                            if confirm.0 {
                                format!("{}秒未确认，自动拒收", confirm.1.max(5))
                            } else {
                                "策略为直接拒绝".to_string()
                            }
                        ),
                    );
                    // 拒收留痕：真实内容名/大小进传输记录
                    if is_text {
                        record_history(
                            "text",
                            "（已拒收）一条文本",
                            fsize,
                            &sender_name,
                            false,
                            None,
                            None,
                            Some(&sender_id),
                        );
                    } else {
                        record_history("file", &hint, fsize, &sender_name, false, None, None, Some(&sender_id));
                    }
                    return;
                }
            }
            // v1.2.18：X-Weimi-To 指向本机网页客户端 → 中继进 WS 房间（设备→网页）。
            // 仅信任设备可中继（网页端是本机浏览器，不给未信任设备投递内容）。
            let to_web = header_get(&head.headers, "x-weimi-to");
            if !to_web.is_empty() {
                if !trusted {
                    write_json(
                        &mut stream,
                        403,
                        &serde_json::json!({"ok": false, "error": "untrusted relay"}),
                    );
                    return;
                }
                let target = {
                    let room = ROOM.lock().unwrap();
                    room.iter()
                        .find(|p| p.id == to_web)
                        .map(|p| (p.tx.clone(), p.name.clone()))
                };
                let Some((wtx, webname)) = target else {
                    write_json(
                        &mut stream,
                        404,
                        &serde_json::json!({"ok": false, "error": "web peer offline"}),
                    );
                    return;
                };
                let relay_from = format!("{} → 网页客户端({})", sender_name, webname);
                if is_text {
                    let body = read_body_all(&mut stream, leftover, content_length, chunked);
                    let text = String::from_utf8_lossy(&body).to_string();
                    let _ = wtx.send(ws_frame(
                        1,
                        serde_json::json!({
                            "t": "text",
                            "from": sender_id,
                            "name": sender_name,
                            "text": text,
                        })
                        .to_string()
                        .as_bytes(),
                    ));
                    write_json(&mut stream, 200, &serde_json::json!({"ok": true}));
                    record_history_out(
                        "text",
                        &short_text(&text),
                        text.chars().count() as u64,
                        &relay_from,
                        true,
                        Some(&text),
                        None,
                        Some("web"),
                    );
                } else {
                    let fname = {
                        let n = url_decode_pct(&header_get(&head.headers, "x-file-name"));
                        if n.is_empty() {
                            "unnamed".to_string()
                        } else {
                            n
                        }
                    };
                    let name = safe_file_name(&fname);
                    let fsize = header_get(&head.headers, "x-file-size")
                        .parse::<u64>()
                        .unwrap_or(0);
                    let fid = format!("r{}", now_ms());
                    match stream_body_to_ws(
                        &mut stream,
                        leftover,
                        content_length,
                        chunked,
                        &wtx,
                        &fid,
                        &name,
                        fsize,
                        &sender_id,
                        &sender_name,
                    ) {
                        Ok(n) => {
                            write_json(&mut stream, 200, &serde_json::json!({"ok": true}));
                            record_history_out(
                                "file",
                                &name,
                                n,
                                &relay_from,
                                true,
                                None,
                                None,
                                Some("web"),
                            );
                        }
                        Err(e) => {
                            write_json(
                                &mut stream,
                                500,
                                &serde_json::json!({"ok": false, "error": e.to_string()}),
                            );
                            record_history_out(
                                "file",
                                &name,
                                0,
                                &relay_from,
                                false,
                                None,
                                None,
                                Some("web"),
                            );
                        }
                    }
                }
                return;
            }
            if is_text {
                let body = read_body_all(&mut stream, leftover, content_length, chunked);
                let text = String::from_utf8_lossy(&body).to_string();
                write_json(&mut stream, 200, &serde_json::json!({"ok": true}));
                balloon(
                    "微密飞传",
                    &format!("收到来自 {} 的文本\n{}", sender_name, short_text(&text)),
                );
                record_history(
                    "text",
                    &short_text(&text),
                    text.chars().count() as u64,
                    &sender_name,
                    true,
                    Some(&text),
                    None,
                    Some(&sender_id),
                );
            } else {
                let fname = {
                    let n = url_decode_pct(&header_get(&head.headers, "x-file-name"));
                    if n.is_empty() {
                        "unnamed".to_string()
                    } else {
                        n
                    }
                };
                let name = safe_file_name(&fname);
                let Some(save) = resolve_save_path(&recv_dir, &name) else {
                    write_json(
                        &mut stream,
                        500,
                        &serde_json::json!({"ok": false, "error": "no dir"}),
                    );
                    return;
                };
                match stream_body_to_file(&mut stream, leftover, content_length, chunked, &save) {
                    Ok(n) => {
                        write_json(
                            &mut stream,
                            200,
                            &serde_json::json!({"ok": true, "path": save.to_string_lossy()}),
                        );
                        balloon(
                            "微密飞传",
                            &format!("收到文件：{}\n来自 {}", name, sender_name),
                        );
                        maybe_open_recv_dir(&save);
                        record_history(
                            "file",
                            &name,
                            n,
                            &sender_name,
                            true,
                            None,
                            Some(&save.to_string_lossy()),
                            Some(&sender_id),
                        );
                    }
                    Err(e) => {
                        let _ = std::fs::remove_file(&save);
                        write_json(
                            &mut stream,
                            500,
                            &serde_json::json!({"ok": false, "error": e.to_string()}),
                        );
                        record_history("file", &name, 0, &sender_name, false, None, None, Some(&sender_id));
                    }
                }
            }
        }
        _ => {
            write_full(&mut stream, 404, "text/plain", b"not found");
        }
    }
}

fn web_page() -> String {
    r#"<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
<title>微密飞传 · 网页版</title>
<style>
  * { margin:0; padding:0; box-sizing:border-box; -webkit-tap-highlight-color:transparent; }
  body { font-family:-apple-system,"PingFang SC","Microsoft YaHei",sans-serif;
         background:#f2f5f9; min-height:100vh; display:flex; flex-direction:column; }
  header { background:linear-gradient(135deg,#1e6fd9,#2fa3e8); color:#fff;
           padding:20px 16px 16px; text-align:center; }
  header h1 { font-size:19px; font-weight:600; }
  header p { font-size:12px; opacity:.85; margin-top:3px; }
  main { flex:1; max-width:640px; width:100%; margin:0 auto; padding:20px 16px; }
  .ring { display:flex; flex-wrap:wrap; gap:22px; justify-content:center;
          align-items:center; padding:26px 0; }
  .dev { width:104px; text-align:center; cursor:pointer; user-select:none; }
  .dev .bubble { width:86px; height:86px; margin:0 auto; border-radius:50%;
                 display:flex; align-items:center; justify-content:center;
                 font-size:30px; font-weight:600; color:#fff;
                 background:#2fa3e8; transition:.15s;
                 box-shadow:0 3px 10px rgba(30,111,217,.25); }
  .dev:hover .bubble { transform:scale(1.06); }
  .dev.drag .bubble { transform:scale(1.12); background:#1d9e75; }
  .dev.devapp .bubble { background:#1d9e75; }
  .dev .nm { margin-top:8px; font-size:13px; color:#24405e; word-break:break-all; }
  .dev.self .bubble { background:#5f6b7a; font-size:24px; }
  .dev.self { cursor:default; }
  .empty { text-align:center; color:#7d90a5; font-size:14px; padding:30px 0; }
  .panel { background:#fff; border-radius:14px; padding:14px; margin-top:10px; }
  .panel h3 { font-size:14px; color:#24405e; margin-bottom:8px; }
  textarea { width:100%; height:80px; border:1px solid #d5dfeb; border-radius:10px;
             padding:10px; font-size:14px; resize:vertical; outline:none; }
  .btn { display:inline-block; border:none; border-radius:10px; padding:9px 20px;
         font-size:14px; color:#fff; background:#1e6fd9; cursor:pointer; }
  .btn.gray { background:#eef4fb; color:#1e6fd9; }
  .row { display:flex; gap:10px; justify-content:flex-end; margin-top:10px; }
  ul { list-style:none; margin-top:6px; }
  li { font-size:13px; color:#24405e; padding:9px 11px; border-radius:9px;
       background:#f2f7fd; margin-bottom:6px; word-break:break-all; }
  li .bar { height:4px; background:#d8e6f5; border-radius:2px; margin-top:6px; overflow:hidden; }
  li .bar i { display:block; height:100%; width:0; background:#2fa3e8; transition:width .15s; }
  li.ok { background:#eef9ef; color:#1d7a34; }
  li.err { background:#fdeeee; color:#b23434; }
  .dialog { position:absolute; inset:0; background:rgba(15,35,60,.45);
            display:flex; align-items:center; justify-content:center; z-index:9; }
  .dialog .box { background:#fff; border-radius:14px; padding:18px; width:min(90vw,360px); }
  footer { text-align:center; font-size:11px; color:#93a4b8; padding:10px; }
</style>
</head>
<body>
<header>
  <h1>微密飞传 · 网页版</h1>
  <p>同一 WiFi 下设备互相发现，点设备或拖文件到设备即可发送</p>
</header>
<main>
  <div class="ring" id="ring"></div>
  <div class="empty" id="empty">等待其他设备打开此页面…</div>
  <ul id="list"></ul>
  <div class="panel" id="sendPanel" hidden>
    <h3 id="sendTitle">发送</h3>
    <textarea id="txt" placeholder="输入要发送的文本内容（发文本点下面的按钮）"></textarea>
    <div class="row">
      <button class="btn gray" onclick="closeDialog()">取消</button>
      <button class="btn gray" onclick="pickFiles()">发送文件</button>
      <button class="btn" onclick="doSendText()">发送文本</button>
    </div>
  </div>
  <input type="file" id="file" multiple hidden>
</main>
<footer>微密文件 · 局域网直传，数据不经外部服务器</footer>
<script>
var COLORS = ['白','灰','黑','赤','金','银','蓝','绿'];
var ANIMALS = ['鲸','狼','狐','鹿','鹰','虎','猫','熊','马','龟'];
var ws = null, myId = '', peers = [], myName;
var recvList = {};   // fid -> 接收状态（浏览器作为接收端）
var sendList = {};   // fid -> 发送状态（发给局域网设备，等 daemon 回执）
var targetPeer = null;
var ring = document.getElementById('ring');
var empty = document.getElementById('empty');
var list = document.getElementById('list');

myName = localStorage.getItem('weimi_web_name');
if (!myName) {
  myName = COLORS[Math.floor(Math.random()*COLORS.length)] +
           ANIMALS[Math.floor(Math.random()*ANIMALS.length)];
  localStorage.setItem('weimi_web_name', myName);
}

function connect() {
  var proto = location.protocol === 'https:' ? 'wss' : 'ws';
  ws = new WebSocket(proto + '://' + location.host + '/ws');
  ws.binaryType = 'arraybuffer';
  ws.onopen = function() { ws.send(JSON.stringify({t:'hello', name:myName})); };
  ws.onmessage = onMsg;
  ws.onclose = function() { setTimeout(connect, 3000); };
}
connect();

function onMsg(e) {
  if (e.data instanceof ArrayBuffer) { onBinary(e.data); return; }
  var m = JSON.parse(e.data);
  if (m.t === 'welcome') { myId = m.id; render(m.peers); }
  else if (m.t === 'peers') render(m.peers);
  else if (m.t === 'text') showText(m);
  else if (m.t === 'file-start') startRecv(m);
  else if (m.t === 'file-done') {
    if (sendList[m.fid]) {
      var s = sendList[m.fid];
      done(s.el, '已送达 ' + s.name + ' →「' + s.to + '」', true);
      s.res(); delete sendList[m.fid];
    } else finishRecv(m.fid, true);
  }
  else if (m.t === 'file-abort' || m.t === 'busy') {
    if (sendList[m.fid]) {
      var s = sendList[m.fid];
      done(s.el, '发送失败 ' + s.name + '（对方离线或拒收）', false);
      s.res(); delete sendList[m.fid];
    } else finishRecv(m.fid, false);
  }
}

function render(listPeers) {
  peers = listPeers;
  ring.innerHTML = '';
  // 本浏览器（自己）
  var self = document.createElement('div');
  self.className = 'dev self';
  self.innerHTML = '<div class="bubble">' + esc(myName.charAt(0)) + '</div>' +
                   '<div class="nm">' + esc(myName) + '<br><span style="font-size:11px;color:#93a4b8">点我改名</span></div>';
  self.onclick = renameSelf;
  ring.appendChild(self);
  // 本机 App + 其他浏览器 + 局域网设备
  peers.forEach(function(p) {
    var d = document.createElement('div');
    d.className = 'dev' + (p.dev ? ' devapp' : '');
    var sub = p.self ? '<br><span style="font-size:11px;color:#93a4b8">接收存到本机</span>' : '';
    d.innerHTML = '<div class="bubble">' + esc(p.name.charAt(0)) + '</div>' +
                  '<div class="nm">' + esc(p.name) + sub + '</div>';
    d.onclick = function() { openSend(p.id, p.name); };
    d.ondragover = function(e) { e.preventDefault(); d.classList.add('drag'); };
    d.ondragleave = function() { d.classList.remove('drag'); };
    d.ondrop = function(e) {
      e.preventDefault(); d.classList.remove('drag');
      if (e.dataTransfer.files.length) sendFiles(p.id, e.dataTransfer.files, p.name);
    };
    ring.appendChild(d);
  });
  empty.hidden = peers.length > 0;
}

function esc(s) {
  return String(s).replace(/[&<>"]/g, function(c) {
    return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];
  });
}

function renameSelf() {
  var n = prompt('给自己起个名字', myName);
  if (n && n.trim()) {
    myName = n.trim().slice(0, 20);
    localStorage.setItem('weimi_web_name', myName);
    ws.send(JSON.stringify({t:'rename', name:myName}));
    render(peers);
  }
}

function openSend(pid, pname) {
  targetPeer = {id: pid, name: pname};
  var panel = document.getElementById('sendPanel');
  document.getElementById('sendTitle').textContent = '发送给「' + pname + '」';
  document.getElementById('txt').value = '';
  panel.hidden = false;
  panel.scrollIntoView({behavior:'smooth'});
}

function closeDialog() { document.getElementById('sendPanel').hidden = true; }

function doSendText() {
  var ta = document.getElementById('txt');
  if (!ta.value.trim() || !targetPeer) return;
  if (!ws || ws.readyState !== 1) {
    li('连接已断开，请刷新页面重试', 'err');
    closeDialog();
    return;
  }
  ws.send(JSON.stringify({t:'text', to:targetPeer.id, text:ta.value}));
  li('文本已发送给「' + targetPeer.name + '」', 'ok');
  closeDialog();
}

document.getElementById('file').addEventListener('change', function() {
  if (this.files.length && targetPeer) sendFiles(targetPeer.id, this.files, targetPeer.name);
  this.value = '';
});

function pickFiles() { document.getElementById('file').click(); }

function sendFiles(pid, files, pname) {
  var arr = Array.prototype.slice.call(files);
  (function next() {
    if (!arr.length) return;
    sendOne(pid, arr.shift(), pname).then(next);
  })();
}

function sendOne(pid, f, pname) {
  return new Promise(function(resolve) {
    var el = li('正在发送 ' + f.name + ' → 「' + pname + '」（0%）');
    var bar = document.createElement('div'); bar.className = 'bar';
    var inner = document.createElement('i'); bar.appendChild(inner); el.appendChild(bar);
    var fid = 'f' + Date.now() + Math.floor(Math.random()*1000);
    sendList[fid] = {el:el, res:resolve, name:f.name, to:pname};
    ws.send(JSON.stringify({t:'file-start', to:pid, name:f.name, size:f.size, fid:fid}));
    (function next() {
      var end = Math.min(pos + slice, f.size);
      f.slice(pos, end).arrayBuffer().then(function(buf) {
        ws.send(buf);
        pos = end;
        var pct = Math.round(pos / f.size * 100);
        inner.style.width = pct + '%';
        el.firstChild.textContent = '正在发送 ' + f.name + ' → 「' + pname + '」（' + pct + '%）';
        if (pos < f.size) next();
        else if (pid.indexOf('d:') === 0) {
          el.firstChild.textContent = '已发完 ' + f.name + '，等待对方确认…';
          resolve();
        }
        else { done(el, '已发送 ' + f.name + ' → 「' + pname + '」', true); resolve(); }
      });
    })();
  });
}

function startRecv(m) {
  var el = li('正在接收 ' + m.name + '（来自 ' + (m.fromName || '设备') + '）');
  var bar = document.createElement('div'); bar.className = 'bar';
  var inner = document.createElement('i'); bar.appendChild(inner); el.appendChild(bar);
  recvList[m.fid] = {name:m.name, size:m.size, chunks:[], received:0, el:el, bar:inner};
}

function onBinary(buf) {
  for (var fid in recvList) break;
  var r = recvList[fid];
  if (!r) return;
  r.chunks.push(buf);
  r.received += buf.byteLength;
  if (r.size > 0) r.bar.style.width = Math.round(r.received / r.size * 100) + '%';
  r.el.firstChild.textContent = '正在接收 ' + r.name + '（' +
    Math.round(r.received / r.size * 100) + '%）';
}

function finishRecv(fid, ok) {
  var r = recvList[fid];
  if (!r) return;
  delete recvList[fid];
  if (ok) {
    var blob = new Blob(r.chunks);
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = r.name;
    document.body.appendChild(a); a.click(); a.remove();
    done(r.el, '已接收 ' + r.name + '（已开始下载）', true);
  } else {
    done(r.el, '接收失败 ' + r.name, false);
  }
}

function showText(m) {
  var el = li('收到来自「' + (m.name || '设备') + '」的文本，点此查看');
  el.style.cursor = 'pointer';
  el.onclick = function() {
    var v = prompt('来自「' + (m.name || '设备') + '」的文本（可全选复制）', m.text);
  };
  el.className = 'ok';
}

function li(text, cls) {
  var el = document.createElement('li');
  el.textContent = text;
  if (cls) el.className = cls;
  var t = document.createElement('span');
  var d = new Date();
  var hh = ('0'+d.getHours()).slice(-2), mm = ('0'+d.getMinutes()).slice(-2);
  var ss = ('0'+d.getSeconds()).slice(-2);
  t.textContent = ' ' + hh + ':' + mm + ':' + ss;
  t.style.cssText = 'color:#999;font-size:11px;margin-left:6px';
  el._time = t;
  el.appendChild(t);
  list.appendChild(el);
  return el;
}
function done(el, text, ok) {
  el.textContent = text;
  el.className = ok ? 'ok' : 'err';
  if (el._time) el.appendChild(el._time);
  var bar = el.querySelector('.bar');
  if (bar) bar.remove();
}
</script>
</body>
</html>"#
        .to_string()
}

// ==================== websocket room ====================

const WS_GUID: &str = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

fn sha1(data: &[u8]) -> [u8; 20] {
    let mut h: [u32; 5] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0];
    let ml = (data.len() as u64) * 8;
    let mut msg = data.to_vec();
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&ml.to_be_bytes());
    for chunk in msg.chunks(64) {
        let mut w = [0u32; 80];
        for i in 0..16 {
            w[i] = u32::from_be_bytes([
                chunk[i * 4],
                chunk[i * 4 + 1],
                chunk[i * 4 + 2],
                chunk[i * 4 + 3],
            ]);
        }
        for i in 16..80 {
            w[i] = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]).rotate_left(1);
        }
        let (mut a, mut b, mut c, mut d, mut e) = (h[0], h[1], h[2], h[3], h[4]);
        for (i, wi) in w.iter().enumerate() {
            let (f, k) = match i {
                0..=19 => ((b & c) | ((!b) & d), 0x5A82_7999u32),
                20..=39 => (b ^ c ^ d, 0x6ED9_EBA1),
                40..=59 => ((b & c) | (b & d) | (c & d), 0x8F1B_BCDC),
                _ => (b ^ c ^ d, 0xCA62_C1D6),
            };
            let temp = a
                .rotate_left(5)
                .wrapping_add(f)
                .wrapping_add(e)
                .wrapping_add(k)
                .wrapping_add(*wi);
            e = d;
            d = c;
            c = b.rotate_left(30);
            b = a;
            a = temp;
        }
        h[0] = h[0].wrapping_add(a);
        h[1] = h[1].wrapping_add(b);
        h[2] = h[2].wrapping_add(c);
        h[3] = h[3].wrapping_add(d);
        h[4] = h[4].wrapping_add(e);
    }
    let mut out = [0u8; 20];
    for i in 0..5 {
        out[i * 4..i * 4 + 4].copy_from_slice(&h[i].to_be_bytes());
    }
    out
}

fn b64(data: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in data.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = *chunk.get(1).unwrap_or(&0) as u32;
        let b2 = *chunk.get(2).unwrap_or(&0) as u32;
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 {
            T[(n >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            T[n as usize & 63] as char
        } else {
            '='
        });
    }
    out
}

/// percent-encode（HTTP 头只允许 ASCII；与 Dart Uri.encodeComponent 同规则）
fn pct_encode(s: &str) -> String {
    let mut out = String::new();
    for &b in s.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'!' | b'~' | b'*'
            | b'\'' | b'(' | b')' => out.push(b as char),
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

fn ws_frame(opcode: u8, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(payload.len() + 10);
    out.push(0x80 | opcode);
    let len = payload.len();
    if len < 126 {
        out.push(len as u8);
    } else if len <= u16::MAX as usize {
        out.push(126);
        out.extend_from_slice(&(len as u16).to_be_bytes());
    } else {
        out.push(127);
        out.extend_from_slice(&(len as u64).to_be_bytes());
    }
    out.extend_from_slice(payload);
    out
}

#[derive(Debug)]
enum WsErr {
    Closed,
    Timeout,
}

struct WsConn {
    stream: TcpStream,
    buf: Vec<u8>,
}

impl WsConn {
    fn new(stream: TcpStream, leftover: Vec<u8>) -> Self {
        WsConn { stream, buf: leftover }
    }
    fn fill(&mut self) -> std::io::Result<usize> {
        let mut tmp = [0u8; 16 * 1024];
        let n = self.stream.read(&mut tmp)?;
        if n > 0 {
            self.buf.extend_from_slice(&tmp[..n]);
        }
        Ok(n)
    }
    /// 读一个完整帧（原始首字节 + 未 mask 的 payload）
    fn read_frame(&mut self) -> Result<(u8, Vec<u8>), WsErr> {
        loop {
            if let Some(f) = self.try_parse() {
                return Ok(f);
            }
            match self.fill() {
                Ok(0) => return Err(WsErr::Closed),
                Ok(_) => {}
                Err(e) => {
                    return Err(match e.kind() {
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut => {
                            WsErr::Timeout
                        }
                        _ => WsErr::Closed,
                    });
                }
            }
        }
    }
    fn try_parse(&mut self) -> Option<(u8, Vec<u8>)> {
        if self.buf.len() < 2 {
            return None;
        }
        let b0 = self.buf[0];
        let b1 = self.buf[1];
        let masked = b1 & 0x80 != 0;
        let len7 = (b1 & 0x7f) as usize;
        let mut off = 2usize;
        let len = match len7 {
            126 => {
                if self.buf.len() < 4 {
                    return None;
                }
                let v = u16::from_be_bytes([self.buf[2], self.buf[3]]) as usize;
                off = 4;
                v
            }
            127 => {
                if self.buf.len() < 10 {
                    return None;
                }
                let mut a = [0u8; 8];
                a.copy_from_slice(&self.buf[2..10]);
                off = 10;
                u64::from_be_bytes(a) as usize
            }
            _ => len7,
        };
        if len > 64 * 1024 * 1024 {
            return None; // 协议保护：单帧上限 64MB
        }
        // 布局：header(off) + [mask 4B] + payload(len)。客户端帧必带 mask，
        // mask 紧跟在长度之后、payload 之前——旧代码切 payload 没跳过 mask，
        // 把 masked payload 前 4 字节当 mask、mask+payload 前 6 字节当 payload
        // 去异或，所有客户端帧全被解成乱码 → JSON 解析失败 → 房间永远空
        //（2026-10-23 v1.2.16 实机故障：网页版"等待其他设备"永不出设备）。
        let mut mask: Option<[u8; 4]> = None;
        if masked {
            if self.buf.len() < off + 4 {
                return None;
            }
            mask = Some([
                self.buf[off],
                self.buf[off + 1],
                self.buf[off + 2],
                self.buf[off + 3],
            ]);
            off += 4;
        }
        if self.buf.len() < off + len {
            return None;
        }
        let mut payload = self.buf[off..off + len].to_vec();
        if let Some(mk) = mask {
            for (i, b) in payload.iter_mut().enumerate() {
                *b ^= mk[i % 4];
            }
        }
        self.buf.drain(..off + len);
        Some((b0, payload))
    }
}

struct RoomPeer {
    id: String,
    name: String,
    ip: String,
    tx: std::sync::mpsc::Sender<Vec<u8>>,
}
static ROOM: Mutex<Vec<RoomPeer>> = Mutex::new(Vec::new());
static WEB_SEQ: AtomicU32 = AtomicU32::new(0);

/// 房间成员列表（网页环）：本机 App + Web 访客 + 局域网微密设备
fn room_peers_json(exclude: Option<&str>) -> serde_json::Value {
    let mut arr = Vec::new();
    let self_name = CONFIG
        .lock()
        .unwrap()
        .as_ref()
        .map(|c| c.device_name.clone())
        .unwrap_or_default();
    let self_name = if self_name.is_empty() {
        "本机".to_string()
    } else {
        self_name
    };
    arr.push(serde_json::json!({"id": "app", "name": self_name, "self": true}));
    for p in ROOM.lock().unwrap().iter() {
        if Some(p.id.as_str()) == exclude {
            continue;
        }
        arr.push(serde_json::json!({"id": p.id, "name": p.name}));
    }
    for p in PEERS.lock().unwrap().iter() {
        arr.push(serde_json::json!({"id": format!("d:{}", p.id), "name": p.name, "dev": true}));
    }
    serde_json::Value::Array(arr)
}

fn broadcast_room_peers() {
    let peers = room_peers_json(None);
    let frame = ws_frame(
        1,
        serde_json::json!({"t": "peers", "peers": peers}).to_string().as_bytes(),
    );
    for p in ROOM.lock().unwrap().iter() {
        let _ = p.tx.send(frame.clone());
    }
}

#[derive(Default)]
struct WsInbound {
    to: String, // "app" | "d:<id>" | 网页 peer id
    fid: String,
    name: String,
    size: u64,
    received: u64,
    file: Option<std::fs::File>,
    path: Option<PathBuf>,
    up: Option<TcpStream>,
    done: bool,
    aborted: bool,
}

fn ws_inbound_abort(inb: &mut WsInbound) {
    inb.file = None;
    if let Some(p) = inb.path.take() {
        let _ = std::fs::remove_file(p);
    }
    inb.up = None;
    *inb = WsInbound::default();
}

fn ws_inbound_finish(inb: &mut WsInbound) {
    inb.file = None;
    inb.path = None;
    inb.up = None;
    *inb = WsInbound::default();
}

/// out 方向的传输记录（网页客户端经本机转发给其他设备；v1.2.18 加 peer_id
/// 防止 "A → B" 形式的 peerName 在 Dart 侧裂成独立会话）
fn record_history_out(
    kind: &str,
    name: &str,
    size: u64,
    peer: &str,
    ok: bool,
    text: Option<&str>,
    path: Option<&str>,
    peer_id: Option<&str>,
) {
    let docs = {
        let cfg = CONFIG.lock().unwrap();
        cfg.as_ref()
            .map(|c| c.docs_dir.clone())
            .unwrap_or_default()
    };
    if docs.is_empty() {
        return;
    }
    let p = Path::new(&docs).join("daemon_transfers.jsonl");
    let obj = serde_json::json!({
        "kind": kind,
        "direction": "out",
        "name": name,
        "text": text,
        "path": path,
        "size": size,
        "peerName": peer,
        "peerId": peer_id,
        "time": now_ms(),
        "ok": ok,
        "via": "daemon-web",
    });
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(p) {
        let _ = writeln!(f, "{}", obj);
    }
}

/// daemon 代发文本到局域网设备（WeiMi 协议，出站连接不占端口）
fn device_send_text(devid: &str, text: &str, from_display: &str, sender_id: &str) -> bool {
    let target = PEERS
        .lock()
        .unwrap()
        .iter()
        .find(|p| p.id == devid)
        .map(|p| (p.ip.clone(), p.port));
    let Some((ip, port)) = target else {
        return false;
    };
    let Ok(addr) = format!("{}:{}", ip, port).parse::<std::net::SocketAddr>() else {
        return false;
    };
    let Ok(mut up) = TcpStream::connect_timeout(&addr, Duration::from_secs(5)) else {
        return false;
    };
    let bytes = text.as_bytes();
    let req = format!(
        "POST /weimi/text HTTP/1.1\r\nHost: {}\r\nX-Weimi-App: weimi\r\nX-Sender-Id: {}\r\nX-Sender-Name: {}\r\nX-Text-Length: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        addr,
        sender_id,
        pct_encode(from_display),
        bytes.len(),
        bytes.len()
    );
    if up.write_all(req.as_bytes()).is_err() {
        return false;
    }
    if up.write_all(bytes).is_err() {
        return false;
    }
    let _ = up.set_read_timeout(Some(Duration::from_secs(30)));
    read_upstream_ok(&mut up)
}

/// 读 upstream 应答，判断是否 {"ok":true}
fn read_upstream_ok(up: &mut TcpStream) -> bool {
    let mut resp = Vec::new();
    let mut tmp = [0u8; 4096];
    loop {
        match up.read(&mut tmp) {
            Ok(0) => break,
            Ok(n) => {
                resp.extend_from_slice(&tmp[..n]);
                if resp.len() > 16 * 1024 {
                    break;
                }
            }
            Err(_) => break,
        }
    }
    find_subsequence(&resp, b"\"ok\":true").is_some()
}

/// WS 二进制帧路由：落盘（to=app）/ 转发设备（d:）/ 网页间中转
fn ws_route_binary(
    inb: &mut WsInbound,
    chunk: &[u8],
    tx: &std::sync::mpsc::Sender<Vec<u8>>,
    visitor: &str,
) {
    if inb.to.is_empty() || inb.done || inb.aborted {
        return;
    }
    inb.received += chunk.len() as u64;
    let complete = inb.size > 0 && inb.received >= inb.size;

    if inb.to == "app" {
        if let Some(f) = inb.file.as_mut() {
            let _ = f.write_all(chunk);
        }
        if complete {
            let (name, path, size, fid) = (
                inb.name.clone(),
                inb.path.clone(),
                inb.received,
                inb.fid.clone(),
            );
            inb.file = None;
            inb.path = None;
            let path_str = path
                .as_ref()
                .map(|p| p.to_string_lossy().to_string());
            if let Some(p) = path {
                balloon(
                    "微密飞传",
                    &format!("收到网页文件：{}\n来自 {}", name, visitor),
                );
                maybe_open_recv_dir(&p);
                record_history("file", &name, size, visitor, true, None, path_str.as_deref(), Some("web"));
            }
            let _ = tx.send(ws_frame(
                1,
                serde_json::json!({"t": "file-done", "fid": fid}).to_string().as_bytes(),
            ));
            ws_inbound_finish(inb);
        }
        return;
    }

    if inb.to.starts_with("d:") {
        if let Some(up) = inb.up.as_mut() {
            if up.write_all(chunk).is_err() {
                inb.aborted = true;
            }
        }
        if complete || inb.aborted {
            let ok = if inb.aborted {
                false
            } else {
                let mut up = inb.up.take().unwrap();
                let _ = up.flush();
                let _ = up.set_read_timeout(Some(Duration::from_secs(60)));
                read_upstream_ok(&mut up)
            };
            let (name, fid, got) = (inb.name.clone(), inb.fid.clone(), inb.received);
            let devname = {
                let id = inb.to[2..].to_string();
                PEERS
                    .lock()
                    .unwrap()
                    .iter()
                    .find(|p| p.id == id)
                    .map(|p| p.name.clone())
                    .unwrap_or_default()
            };
            record_history_out(
                "file",
                &name,
                got,
                &format!("{} → {}", visitor, devname),
                ok,
                None,
                None,
                Some("web"),
            );
            if ok {
                let _ = tx.send(ws_frame(
                    1,
                    serde_json::json!({"t": "file-done", "fid": fid}).to_string().as_bytes(),
                ));
            } else {
                let _ = tx.send(ws_frame(
                    1,
                    serde_json::json!({"t": "file-abort", "fid": fid}).to_string().as_bytes(),
                ));
            }
            ws_inbound_finish(inb);
        }
        return;
    }

    // 网页间中转
    let target_tx = {
        let room = ROOM.lock().unwrap();
        room.iter().find(|p| p.id == inb.to).map(|p| p.tx.clone())
    };
    match target_tx {
        Some(ttx) => {
            let _ = ttx.send(ws_frame(2, chunk));
            if complete {
                let _ = ttx.send(ws_frame(
                    1,
                    serde_json::json!({"t": "file-done", "fid": inb.fid}).to_string().as_bytes(),
                ));
                ws_inbound_finish(inb);
            }
        }
        None => {
            let _ = tx.send(ws_frame(
                1,
                serde_json::json!({"t": "file-abort", "fid": inb.fid}).to_string().as_bytes(),
            ));
            ws_inbound_finish(inb);
        }
    }
}

/// WebSocket 会话：握手 → 读写线程 → 消息路由（对齐 UI 版 /ws 协议）
fn handle_ws(stream: TcpStream, head: &RequestHead, leftover: Vec<u8>) {
    let key = header_get(&head.headers, "sec-websocket-key");
    let upgrade = header_get(&head.headers, "upgrade").to_ascii_lowercase();
    if key.is_empty() || !upgrade.contains("websocket") {
        let mut s = stream;
        write_full(&mut s, 400, "text/plain", b"expected websocket");
        return;
    }
    let accept = b64(&sha1(format!("{}{}", key, WS_GUID).as_bytes()));
    let mut stream = stream;
    let resp = format!(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {}\r\n\r\n",
        accept
    );
    if stream.write_all(resp.as_bytes()).is_err() {
        return;
    }
    let _ = stream.set_read_timeout(Some(Duration::from_secs(60)));
    let Ok(mut wr) = stream.try_clone() else { return };
    let (tx, rx) = std::sync::mpsc::channel::<Vec<u8>>();
    // 写线程：mpsc 队列 + 30s 空闲心跳 ping
    std::thread::spawn(move || {
        loop {
            match rx.recv_timeout(Duration::from_secs(30)) {
                Ok(frame) => {
                    if wr.write_all(&frame).is_err() || wr.flush().is_err() {
                        break;
                    }
                }
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                    if wr.write_all(&ws_frame(9, b"hb")).is_err() {
                        break;
                    }
                    let _ = wr.flush();
                }
                Err(_) => break,
            }
        }
    });
    let remote_ip = stream
        .peer_addr()
        .map(|a| a.ip().to_string())
        .unwrap_or_default();
    let mut conn = WsConn::new(stream, leftover);

    let mut peer_id = String::new();
    let mut peer_name = String::new();
    let mut inb = WsInbound::default();
    let mut frag_op = 0u8;
    let mut frag: Vec<u8> = Vec::new();
    let mut expect_pong = false;

    loop {
        let (b0, payload) = match conn.read_frame() {
            Ok(f) => f,
            Err(WsErr::Timeout) => {
                if expect_pong {
                    break;
                }
                if tx.send(ws_frame(9, b"hb")).is_err() {
                    break;
                }
                expect_pong = true;
                continue;
            }
            Err(WsErr::Closed) => break,
        };
        let fin = b0 & 0x80 != 0;
        let op = b0 & 0x0f;
        if op == 8 {
            break; // close
        }
        if op == 9 {
            // ping -> pong
            let _ = tx.send(ws_frame(10, &payload));
            continue;
        }
        if op == 10 {
            expect_pong = false;
            continue;
        }
        // 分片重组
        let (eff_op, data) = if op != 0 {
            if fin {
                (op, payload)
            } else {
                frag_op = op;
                frag = payload;
                continue;
            }
        } else {
            if frag_op == 0 {
                continue;
            }
            frag.extend_from_slice(&payload);
            if !fin {
                continue;
            }
            let d = std::mem::take(&mut frag);
            let o = frag_op;
            frag_op = 0;
            (o, d)
        };

        if eff_op == 2 {
            let visitor = format!("网页客户端({})", peer_name);
            ws_route_binary(&mut inb, &data, &tx, &visitor);
            continue;
        }
        if eff_op != 1 {
            continue;
        }
        let Ok(txt) = std::str::from_utf8(&data) else { continue };
        let Ok(serde_json::Value::Object(m)) =
            serde_json::from_str::<serde_json::Value>(txt)
        else {
            continue;
        };
        let t = m.get("t").and_then(|v| v.as_str()).unwrap_or("");
        match t {
            "hello" => {
                if !peer_id.is_empty() {
                    continue;
                }
                let raw = m.get("name").and_then(|v| v.as_str()).unwrap_or("").trim();
                let mut name = safe_file_name(raw);
                if name.is_empty() || name == "unnamed" {
                    name = "匿名设备".to_string();
                }
                let name: String = name.chars().take(20).collect();
                let id = format!(
                    "w{}{}",
                    WEB_SEQ.fetch_add(1, Ordering::Relaxed),
                    now_ms() % 10000
                );
                peer_id = id.clone();
                peer_name = name.clone();
                ROOM.lock().unwrap().push(RoomPeer {
                    id: id.clone(),
                    name: name.clone(),
                    ip: remote_ip.clone(),
                    tx: tx.clone(),
                });
                let _ = tx.send(ws_frame(
                    1,
                    serde_json::json!({
                        "t": "welcome",
                        "id": id,
                        "self": {"id": id, "name": name},
                        "peers": room_peers_json(Some(&id)),
                    })
                    .to_string()
                    .as_bytes(),
                ));
                broadcast_room_peers();
                log(&format!("ws peer join: {} ({})", name, remote_ip));
            }
            "rename" => {
                let raw = m.get("name").and_then(|v| v.as_str()).unwrap_or("").trim();
                if raw.is_empty() {
                    continue;
                }
                let name: String = safe_file_name(raw).chars().take(20).collect();
                peer_name = name.clone();
                if let Some(p) = ROOM.lock().unwrap().iter_mut().find(|p| p.id == peer_id) {
                    p.name = name;
                }
                broadcast_room_peers();
            }
            "text" => {
                let to = m.get("to").and_then(|v| v.as_str()).unwrap_or("").to_string();
                let text = m
                    .get("text")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                if text.is_empty() {
                    continue;
                }
                let from = format!("网页客户端({})", peer_name);
                if to == "app" {
                    balloon(
                        "微密飞传",
                        &format!("收到网页文本：{}\n来自 {}", short_text(&text), from),
                    );
                    record_history(
                        "text",
                        &short_text(&text),
                        text.chars().count() as u64,
                        &from,
                        true,
                        Some(&text),
                        None,
                        Some("web"),
                    );
                } else if let Some(devid) = to.strip_prefix("d:").map(|s| s.to_string()) {
                    let devname = {
                        PEERS
                            .lock()
                            .unwrap()
                            .iter()
                            .find(|p| p.id == devid)
                            .map(|p| p.name.clone())
                            .unwrap_or_default()
                    };
                    let sender_id = format!("web-{}", remote_ip);
                    let ok = device_send_text(&devid, &text, &from, &sender_id);
                    record_history_out(
                        "text",
                        &short_text(&text),
                        text.chars().count() as u64,
                        &format!("{} → {}", from, devname),
                        ok,
                        Some(&text),
                        None,
                        Some("web"),
                    );
                } else {
                    let target_tx = {
                        let room = ROOM.lock().unwrap();
                        room.iter().find(|p| p.id == to).map(|p| p.tx.clone())
                    };
                    if let Some(ttx) = target_tx {
                        let _ = ttx.send(ws_frame(
                            1,
                            serde_json::json!({
                                "t": "text",
                                "from": peer_id.clone(),
                                "name": peer_name.clone(),
                                "text": text,
                            })
                            .to_string()
                            .as_bytes(),
                        ));
                    }
                }
            }
            "file-start" => {
                if !inb.to.is_empty() {
                    let fid = m.get("fid").and_then(|v| v.as_str()).unwrap_or("");
                    let _ = tx.send(ws_frame(
                        1,
                        serde_json::json!({"t": "busy", "fid": fid}).to_string().as_bytes(),
                    ));
                    continue;
                }
                let to = m.get("to").and_then(|v| v.as_str()).unwrap_or("").to_string();
                let name = safe_file_name(m.get("name").and_then(|v| v.as_str()).unwrap_or("unnamed"));
                let size = m.get("size").and_then(|v| v.as_u64()).unwrap_or(0);
                let fid = m.get("fid").and_then(|v| v.as_str()).unwrap_or("").to_string();
                if to == "app" {
                    if !TRANSFER_ON.load(Ordering::Relaxed) {
                        let _ = tx.send(ws_frame(
                            1,
                            serde_json::json!({"t": "file-abort", "fid": fid}).to_string().as_bytes(),
                        ));
                        continue;
                    }
                    let dir = CONFIG
                        .lock()
                        .unwrap()
                        .as_ref()
                        .map(|c| c.receive_dir.clone())
                        .unwrap_or_default();
                    match resolve_save_path(&dir, &name)
                        .and_then(|p| std::fs::File::create(&p).ok().map(|f| (p, f)))
                    {
                        Some((p, f)) => {
                            inb = WsInbound {
                                to,
                                fid,
                                name,
                                size,
                                received: 0,
                                file: Some(f),
                                path: Some(p),
                                up: None,
                                done: false,
                                aborted: false,
                            };
                        }
                        None => {
                            let _ = tx.send(ws_frame(
                                1,
                                serde_json::json!({"t": "file-abort", "fid": fid}).to_string().as_bytes(),
                            ));
                        }
                    }
                } else if let Some(devid) = to.strip_prefix("d:").map(|s| s.to_string()) {
                    let target = PEERS
                        .lock()
                        .unwrap()
                        .iter()
                        .find(|p| p.id == devid)
                        .map(|p| (p.ip.clone(), p.port));
                    let Some((ip, port)) = target else {
                        let _ = tx.send(ws_frame(
                            1,
                            serde_json::json!({"t": "file-abort", "fid": fid}).to_string().as_bytes(),
                        ));
                        continue;
                    };
                    let addr = format!("{}:{}", ip, port);
                    let up = addr
                        .parse::<std::net::SocketAddr>()
                        .ok()
                        .and_then(|a| TcpStream::connect_timeout(&a, Duration::from_secs(5)).ok());
                    match up {
                        Some(mut up) => {
                            let sender_id = format!("web-{}", remote_ip);
                            let from = format!("网页客户端({})", peer_name);
                            let req = format!(
                                "POST /weimi/send HTTP/1.1\r\nHost: {}\r\nX-Weimi-App: weimi\r\nX-Sender-Id: {}\r\nX-Sender-Name: {}\r\nX-File-Name: {}\r\nX-File-Size: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                                addr,
                                sender_id,
                                pct_encode(&from),
                                pct_encode(&name),
                                size,
                                size
                            );
                            if up.write_all(req.as_bytes()).is_err() {
                                let _ = tx.send(ws_frame(
                                    1,
                                    serde_json::json!({"t": "file-abort", "fid": fid}).to_string().as_bytes(),
                                ));
                                continue;
                            }
                            let _ = up.set_write_timeout(Some(Duration::from_secs(60)));
                            inb = WsInbound {
                                to,
                                fid,
                                name,
                                size,
                                received: 0,
                                file: None,
                                path: None,
                                up: Some(up),
                                done: false,
                                aborted: false,
                            };
                        }
                        None => {
                            let _ = tx.send(ws_frame(
                                1,
                                serde_json::json!({"t": "file-abort", "fid": fid}).to_string().as_bytes(),
                            ));
                        }
                    }
                } else {
                    let target_tx = {
                        let room = ROOM.lock().unwrap();
                        room.iter().find(|p| p.id == to).map(|p| p.tx.clone())
                    };
                    match target_tx {
                        Some(ttx) => {
                            let _ = ttx.send(ws_frame(
                                1,
                                serde_json::json!({
                                    "t": "file-start",
                                    "from": peer_id.clone(),
                                    "fromName": peer_name.clone(),
                                    "name": name,
                                    "size": size,
                                    "fid": fid,
                                })
                                .to_string()
                                .as_bytes(),
                            ));
                            inb = WsInbound {
                                to,
                                fid,
                                name,
                                size,
                                received: 0,
                                file: None,
                                path: None,
                                up: None,
                                done: false,
                                aborted: false,
                            };
                        }
                        None => {
                            let _ = tx.send(ws_frame(
                                1,
                                serde_json::json!({"t": "file-abort", "fid": fid}).to_string().as_bytes(),
                            ));
                        }
                    }
                }
            }
            _ => {}
        }
    }
    // 断开清理
    if !peer_id.is_empty() {
        ROOM.lock().unwrap().retain(|p| p.id != peer_id);
        broadcast_room_peers();
        log(&format!("ws peer left: {} ({})", peer_name, remote_ip));
    }
    if !inb.to.is_empty() && !inb.done {
        ws_inbound_abort(&mut inb);
    }
}

#[cfg(test)]
mod ws_tests {
    use super::*;

    #[test]
    fn sha1_known() {
        // base64(sha1("abc")) 标准测试向量
        assert_eq!(b64(&sha1(b"abc")), "qZk+NkcGgWq6PiVxeFDCbJzQ2J0=");
    }

    #[test]
    fn ws_accept_known() {
        // RFC 6455 示例：key "dGhlIHNhbXBsZSBub25jZQ==" -> "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        let accept = b64(&sha1(format!("{}{}", "dGhlIHNhbXBsZSBub25jZQ==", WS_GUID).as_bytes()));
        assert_eq!(accept, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
    }

    #[test]
    fn ws_frame_small() {
        assert_eq!(ws_frame(1, b"hi"), vec![0x81, 2, b'h', b'i']);
    }

    #[test]
    fn pct_encode_known() {
        assert_eq!(pct_encode("a b"), "a%20b");
        assert_eq!(pct_encode("灰"), "%E7%81%B0");
    }

    #[test]
    fn ws_read_masked_client_frame() {
        // 2026-10-23 实机故障回归：客户端帧必带 mask（RFC 6455），旧 try_parse
        // 切 payload 没跳过 4 字节 mask key，所有客户端帧被解成乱码 →
        // 房间永远空（网页版"等待其他设备"）。本测试用客户端编码逐字节喂入，
        // 必须还原出明文；两个连发帧不得串位。
        // RFC 6455 §5.7 示例：payload "Hello" + mask 0x37fa213d
        // 线上字节：81 85 37 fa 21 3d 7f 9f 4d 51 58
        // 建一条真连接仅为持有 TcpStream；帧数据全部预置在 buf，read_frame
        // 不会触碰网络。
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        std::thread::spawn(move || {
            let (_srv, _) = listener.accept().unwrap();
            std::thread::sleep(std::time::Duration::from_secs(10));
        });
        let stream = std::net::TcpStream::connect(addr).unwrap();
        let mut c = WsConn::new(
            stream,
            vec![0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58],
        );
        let (b0, payload) = c.read_frame().unwrap();
        assert_eq!(b0, 0x81);
        assert_eq!(payload, b"Hello");

        // 连发两帧（长度 126 编码 + 无 mask 服务器风格不适用客户端，仍用 mask）
        let mk = [0x11u8, 0x22, 0x33, 0x44];
        let mk_frame = |text: &str| {
            let p = text.as_bytes();
            let mut f = vec![0x81u8];
            if p.len() < 126 {
                f.push(0x80 | p.len() as u8);
            } else {
                f.push(0x80 | 126);
                f.extend_from_slice(&(p.len() as u16).to_be_bytes());
            }
            f.extend_from_slice(&mk);
            f.extend(p.iter().enumerate().map(|(i, b)| b ^ mk[i % 4]));
            f
        };
        let a = mk_frame("{\"t\":\"hello\",\"name\":\"测试设备\"}");
        let b = mk_frame("{\"t\":\"text\",\"to\":\"app\",\"text\":\"hi\"}");
        c.buf.extend_from_slice(&a);
        c.buf.extend_from_slice(&b);
        let (_, p1) = c.read_frame().unwrap();
        assert_eq!(String::from_utf8(p1).unwrap(), "{\"t\":\"hello\",\"name\":\"测试设备\"}");
        let (_, p2) = c.read_frame().unwrap();
        assert_eq!(String::from_utf8(p2).unwrap(), "{\"t\":\"text\",\"to\":\"app\",\"text\":\"hi\"}");
        assert!(c.buf.is_empty());
    }
}

// ==================== transfer controller ====================

fn transfer_loop() {
    loop {
        {
            let cfg = CONFIG.lock().unwrap();
            let on = cfg
                .as_ref()
                .map(|c| c.discover_enabled)
                .unwrap_or(false);
            if !on {
                drop(cfg);
                if TRANSFER_ON.swap(false, Ordering::Relaxed) {
                    log("transfer released (ui active or discover off)");
                    kick_release();
                }
                std::thread::sleep(Duration::from_millis(800));
                continue;
            }
        }
        if !TRANSFER_ON.swap(true, Ordering::Relaxed) {
            log("transfer starting");
        }
        let announce_socket = UdpSocket::bind(("0.0.0.0", DISCOVERY_PORT));
        let http = bind_http();
        match (announce_socket, http) {
            (Ok(sock), Some((listener, port))) => {
                HTTP_PORT.store(port, Ordering::Relaxed);
                log(&format!("transfer started, http port {}", port));
                let _ = sock.set_broadcast(true);
                let sock = Arc::new(sock);
                {
                    let sock = sock.clone();
                    std::thread::spawn(move || udp_recv_loop(sock));
                }
                std::thread::spawn(move || {
                    for conn in listener.incoming() {
                        if !TRANSFER_ON.load(Ordering::Relaxed) {
                            break;
                        }
                        match conn {
                            Ok(s) => {
                                std::thread::spawn(move || handle_client(s));
                            }
                            Err(_) => break,
                        }
                    }
                });
                // announce loop; exits when flag clears.
                // FIX: re-check CONFIG every tick -- previously ui_active=true
                // could never stop this loop (flag was only cleared by this
                // same thread), so the daemon held UDP/TCP ports forever and
                // the UI never received discovery replies.
                let mut tick: u64 = 0;
                loop {
                    {
                        let cfg = CONFIG.lock().unwrap();
                        // v1.2.17 起 UI（Windows）不再自绑 52345/52346，网页版也由
                        // daemon 承载 → ui_active 不再触发端口让位（否则主界面一开
                        // 网页版就 ERR_CONNECTION_REFUSED）；发现或网页任一开启即
                        // 持有端口（网页版也不随「可被发现」开关连带下线）。
                        let on = cfg
                            .as_ref()
                            .map(|c| c.discover_enabled || c.web_share_enabled)
                            .unwrap_or(false);
                        if !on {
                            TRANSFER_ON.store(false, Ordering::Relaxed);
                        }
                    }
                    if !TRANSFER_ON.load(Ordering::Relaxed) {
                        break;
                    }
                    {
                        let cutoff = now_ms().saturating_sub(15000);
                        PEERS.lock().unwrap().retain(|p| p.last_seen >= cutoff);
                    }
                    if tick % 2 == 0 {
                        broadcast_announce(&sock);
                    }
                    // 网页房间里的设备列表跟随 PEERS 表刷新（5s 一次）
                    if tick % 5 == 0 {
                        broadcast_room_peers();
                    }
                    std::thread::sleep(Duration::from_millis(1000));
                    tick += 1;
                }
                log("transfer stopped");
            }
            (Err(e), _) => {
                log(&format!("udp bind failed: {}", e));
                TRANSFER_ON.store(false, Ordering::Relaxed);
                std::thread::sleep(Duration::from_secs(5));
            }
            (_, None) => {
                log("http bind failed (52345-52365 busy)");
                TRANSFER_ON.store(false, Ordering::Relaxed);
                std::thread::sleep(Duration::from_secs(5));
            }
        }
        // 释放后踢醒阻塞在 recv_from / incoming() 的线程，否则 socket
        // 被卡住的线程握着，端口在 OS 层一直不放
        kick_release();
        std::thread::sleep(Duration::from_millis(500));
    }
}

/// 踢一下本机的发现/接收端口：让阻塞在 recv_from / incoming() 的线程
/// 醒来检查 TRANSFER_ON 后退出，从而 drop socket、释放端口。
fn kick_release() {
    // UDP 52346：loopback 发个无效包唤醒 recv_from
    if let Ok(s) = UdpSocket::bind(("127.0.0.1", 0)) {
        let _ = s.send_to(b"kick", ("127.0.0.1", DISCOVERY_PORT));
    }
    // TCP：连一下 HTTP 监听端口唤醒 accept 线程（连接会被 flag 检查丢弃）
    let http_port = HTTP_PORT.load(Ordering::Relaxed);
    let ports: [u16; 2] = [
        if (HTTP_PORT_BASE..=HTTP_PORT_MAX).contains(&http_port) {
            http_port
        } else {
            HTTP_PORT_BASE
        },
        HTTP_PORT_BASE,
    ];
    for p in ports {
        if let Ok(c) = std::net::TcpStream::connect(("127.0.0.1", p)) {
            drop(c);
            break;
        }
    }
}

fn bind_http() -> Option<(TcpListener, u16)> {
    for port in HTTP_PORT_BASE..=HTTP_PORT_MAX {
        match TcpListener::bind(("0.0.0.0", port)) {
            Ok(l) => {
                if port != HTTP_PORT_BASE {
                    log(&format!(
                        "http port {} busy, using {}",
                        HTTP_PORT_BASE, port
                    ));
                }
                return Some((l, port));
            }
            Err(_) => continue,
        }
    }
    None
}

fn udp_recv_loop(sock: Arc<UdpSocket>) {
    let mut buf = [0u8; 2048];
    loop {
        if !TRANSFER_ON.load(Ordering::Relaxed) {
            return;
        }
        match sock.recv_from(&mut buf) {
            Ok((n, src)) => {
                let text = String::from_utf8_lossy(&buf[..n]).to_string();
                let Ok(serde_json::Value::Object(m)) =
                    serde_json::from_str::<serde_json::Value>(&text)
                else {
                    continue;
                };
                if m.get("app").and_then(|v| v.as_str()) != Some(MAGIC) {
                    continue;
                }
                let cfg = CONFIG.lock().unwrap();
                let Some(c) = cfg.as_ref() else { continue };
                if m.get("id").and_then(|v| v.as_str()) == Some(c.device_id.as_str()) {
                    continue;
                }
                // 记录对端到设备表（announce/reply 都带 httpPort，可定位其接收端口）
                let self_id = c.device_id.clone();
                let self_name = c.device_name.clone();
                let http_port = HTTP_PORT.load(Ordering::Relaxed);
                let id = m.get("id").and_then(|v| v.as_str()).unwrap_or("").to_string();
                let name = m.get("name").and_then(|v| v.as_str()).unwrap_or("").to_string();
                let port = m.get("httpPort").and_then(|v| v.as_u64()).unwrap_or(0) as u16;
                drop(cfg);
                if !id.is_empty() && port != 0 {
                    upsert_peer(&id, &name, &src.ip().to_string(), port);
                }
                // v1.2.18：学习对端的网页客户端清单（announce/reply 都带）
                if !id.is_empty() {
                    if let Some(list) = m.get("webPeers").and_then(|v| v.as_array()) {
                        let items: Vec<(String, String)> = list
                            .iter()
                            .filter_map(|v| {
                                let wid = v.get("id").and_then(|x| x.as_str())?.to_string();
                                let wname =
                                    v.get("name").and_then(|x| x.as_str()).unwrap_or("");
                                Some((wid, wname.to_string()))
                            })
                            .collect();
                        sync_remote_web(&id, &src.ip().to_string(), port, &items);
                    }
                }
                if m.get("action").and_then(|v| v.as_str()) == Some("announce") {
                    let web_peers: Vec<serde_json::Value> = ROOM
                        .lock()
                        .unwrap()
                        .iter()
                        .map(|p| serde_json::json!({"id": p.id, "name": p.name}))
                        .collect();
                    let mut reply = serde_json::json!({
                        "app": MAGIC,
                        "action": "reply",
                        "id": self_id,
                        "name": self_name,
                        "httpPort": http_port,
                        "v": 1,
                    });
                    if !web_peers.is_empty() {
                        reply["webPeers"] = serde_json::Value::Array(web_peers);
                    }
                    let _ = sock.send_to(
                        reply.to_string().as_bytes(),
                        format!("{}:{}", src.ip(), src.port()),
                    );
                }
            }
            Err(_) => {
                std::thread::sleep(Duration::from_millis(200));
            }
        }
    }
}

fn broadcast_announce(sock: &UdpSocket) {
    let (id, name) = {
        let cfg = CONFIG.lock().unwrap();
        match cfg.as_ref() {
            Some(c) => (c.device_id.clone(), c.device_name.clone()),
            None => return,
        }
    };
    let mut body = serde_json::json!({
        "app": MAGIC,
        "action": "announce",
        "id": id,
        "name": name,
        "httpPort": HTTP_PORT.load(Ordering::Relaxed),
        "v": 1,
    });
    // v1.2.18：带上本机网页客户端清单，远端 App/daemon 据此生成虚拟会话
    let web_peers: Vec<serde_json::Value> = ROOM
        .lock()
        .unwrap()
        .iter()
        .map(|p| serde_json::json!({"id": p.id, "name": p.name}))
        .collect();
    if !web_peers.is_empty() {
        body["webPeers"] = serde_json::Value::Array(web_peers);
    }
    let body = body.to_string();
    let mut targets: Vec<String> = vec!["255.255.255.255".into()];
    for ip in local_ipv4s() {
        let parts: Vec<&str> = ip.split('.').collect();
        if parts.len() == 4 {
            let sub = format!("{}.{}.{}.255", parts[0], parts[1], parts[2]);
            if !targets.contains(&sub) {
                targets.push(sub);
            }
        }
    }
    for t in targets {
        let _ = sock.send_to(body.as_bytes(), format!("{}:{}", t, DISCOVERY_PORT));
    }
}

// ==================== config server ====================

#[derive(Deserialize)]
struct PushMsg {
    cmd: String,
    #[serde(default)]
    device_id: String,
    #[serde(default)]
    device_name: String,
    #[serde(default = "default_true")]
    discover_enabled: bool,
    #[serde(default = "default_true")]
    web_share_enabled: bool,
    #[serde(default = "default_true")]
    untrusted_confirm: bool,
    #[serde(default = "default_confirm_secs")]
    untrusted_confirm_secs: u32,
    #[serde(default)]
    open_recv_dir: bool,
    #[serde(default)]
    receive_dir: String,
    #[serde(default)]
    docs_dir: String,
    #[serde(default)]
    exe_path: String,
    #[serde(default)]
    ui_active: bool,
    /// v1.2.19：LANDrop 保活材料（老 UI 不带 → default，保活不激活）
    /// landrop_on 用 Option：老 UI 的 apply 不带此字段时不得把 daemon
    /// 已同步到的开关冲掉（None=不动，Some=设置）
    #[serde(default)]
    landrop_on: Option<bool>,
    #[serde(default)]
    landrop_pk: String,
    /// v1.2.20：LANDrop 身份私钥（托盘收文件 ServerHello 签名用）。
    /// 空 = 老 UI 没同步 → 不动 daemon 里已有的值（与 landrop_pk 同语义）
    #[serde(default)]
    landrop_sk: String,
    #[serde(default)]
    token: String,
    #[serde(default)]
    accept: bool,
    // webSend / webSendText 用
    #[serde(default)]
    to: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    #[allow(dead_code)] // UI 会带 size，daemon 以文件实际大小为准
    size: u64,
    #[serde(default)]
    path: String,
    #[serde(default)]
    text: String,
}

fn default_true() -> bool {
    true
}

fn default_confirm_secs() -> u32 {
    30
}

fn config_server() {
    let listener = match TcpListener::bind(("127.0.0.1", CONFIG_PORT)) {
        Ok(l) => l,
        Err(e) => {
            log(&format!("config port bind failed: {}", e));
            return;
        }
    };
    for conn in listener.incoming() {
        let Ok(mut s) = conn else { continue };
        let _ = s.set_read_timeout(Some(Duration::from_secs(5)));
        let mut raw = Vec::new();
        let mut tmp = [0u8; 4096];
        // 逐行边收边处理：confirm/get_pending 需要在同一连接上应答
        'outer: loop {
            // 处理缓冲里已完整的行
            while let Some(pos) = raw.iter().position(|&b| b == b'\n') {
                let line = String::from_utf8_lossy(&raw[..pos]).to_string();
                raw.drain(..=pos);
                if line.trim().is_empty() {
                    continue;
                }
                let Ok(msg) = serde_json::from_str::<PushMsg>(&line) else {
                    log(&format!(
                        "bad config line: {}",
                        &line[..line.len().min(120)]
                    ));
                    continue;
                };
                match msg.cmd.as_str() {
                    "quit" => {
                        log("quit command received");
                        tray_delete();
                        std::process::exit(0);
                    }
                    "get_pending" => {
                        let map = pending_map().lock().unwrap();
                        let items: Vec<serde_json::Value> = map
                            .iter()
                            .map(|(token, e)| {
                                serde_json::json!({
                                    "token": token,
                                    "from": e.from,
                                    "name": e.name,
                                    "size": e.size,
                                    "isText": e.is_text,
                                })
                            })
                            .collect();
                        drop(map);
                        let resp = serde_json::json!({"ok": true, "pending": items});
                        let _ = s.write_all(format!("{}\n", resp).as_bytes());
                        let _ = s.flush();
                        break 'outer;
                    }
                    "listPeers" => {
                        let peers = PEERS.lock().unwrap();
                        let items: Vec<serde_json::Value> = peers
                            .iter()
                            .map(|p| {
                                serde_json::json!({
                                    "id": p.id,
                                    "name": p.name,
                                    "ip": p.ip,
                                    "httpPort": p.port,
                                })
                            })
                            .collect();
                        drop(peers);
                        // port+ips 供 UI 二维码（网页版地址）使用
                        let resp = serde_json::json!({
                            "ok": true,
                            "peers": items,
                            "port": HTTP_PORT.load(Ordering::Relaxed),
                            "ips": local_ipv4s(),
                        });
                        let _ = s.write_all(format!("{}\n", resp).as_bytes());
                        let _ = s.flush();
                        break 'outer;
                    }
                    "webPeers" => {
                        let mut items: Vec<serde_json::Value> = ROOM
                            .lock()
                            .unwrap()
                            .iter()
                            .map(|p| {
                                serde_json::json!({
                                    "id": p.id,
                                    "name": p.name,
                                    "ip": p.ip,
                                })
                            })
                            .collect();
                        // v1.2.18：远端主机的网页客户端（学习自 announce），UI 侧
                        // 生成 rweb_ 虚拟会话，发送走 HTTP POST + X-Weimi-To 中继
                        for r in REMOTE_WEB.lock().unwrap().iter() {
                            items.push(serde_json::json!({
                                "id": format!("rweb_{}", r.id),
                                "name": format!("网页客户端({})", r.name),
                                "ip": r.host_ip,
                                "port": r.host_port,
                                "remote": true,
                            }));
                        }
                        let resp = serde_json::json!({
                            "ok": true,
                            "webPeers": items,
                            "port": HTTP_PORT.load(Ordering::Relaxed),
                        });
                        let _ = s.write_all(format!("{}\n", resp).as_bytes());
                        let _ = s.flush();
                        break 'outer;
                    }
                    "webSend" => {
                        // UI 聊天窗发给"网页客户端"：daemon 读文件经 WS 推给浏览器。
                        // 异步执行防止大文件阻塞配置通道；UI 侧乐观落记录。
                        let to = msg.to.clone();
                        let name = safe_file_name(&msg.name);
                        let path = PathBuf::from(&msg.path);
                        std::thread::spawn(move || {
                            let target = ROOM
                                .lock()
                                .unwrap()
                                .iter()
                                .find(|p| p.id == to)
                                .map(|p| p.tx.clone());
                            let Some(tx) = target else {
                                log(&format!("webSend: peer {} offline", to));
                                return;
                            };
                            let Ok(mut f) = std::fs::File::open(&path) else {
                                log(&format!(
                                    "webSend: open failed: {}",
                                    path.to_string_lossy()
                                ));
                                return;
                            };
                            let total = f.metadata().map(|m| m.len()).unwrap_or(0);
                            let from_name = CONFIG
                                .lock()
                                .unwrap()
                                .as_ref()
                                .map(|c| c.device_name.clone())
                                .unwrap_or_else(|| "本机".into());
                            let fid = format!("a{}", now_ms());
                            let _ = tx.send(ws_frame(
                                1,
                                serde_json::json!({
                                    "t": "file-start",
                                    "from": "app",
                                    "fromName": from_name,
                                    "name": name,
                                    "size": total,
                                    "fid": fid,
                                })
                                .to_string()
                                .as_bytes(),
                            ));
                            let mut buf = vec![0u8; 512 * 1024];
                            let mut sent: u64 = 0;
                            loop {
                                match f.read(&mut buf) {
                                    Ok(0) => break,
                                    Ok(n) => {
                                        if tx.send(ws_frame(2, &buf[..n])).is_err() {
                                            log("webSend: peer gone mid-send");
                                            return;
                                        }
                                        sent += n as u64;
                                    }
                                    Err(_) => break,
                                }
                            }
                            if total > 0 && sent >= total {
                                let _ = tx.send(ws_frame(
                                    1,
                                    serde_json::json!({"t": "file-done", "fid": fid})
                                        .to_string()
                                        .as_bytes(),
                                ));
                                log(&format!("webSend ok: {} ({} bytes)", name, sent));
                            } else {
                                let _ = tx.send(ws_frame(
                                    1,
                                    serde_json::json!({"t": "file-abort", "fid": fid})
                                        .to_string()
                                        .as_bytes(),
                                ));
                                log(&format!("webSend short: {} sent {}/{}", name, sent, total));
                            }
                        });
                        let resp = serde_json::json!({"ok": true, "async": true});
                        let _ = s.write_all(format!("{}\n", resp).as_bytes());
                        let _ = s.flush();
                        break 'outer;
                    }
                    "webSendText" => {
                        let to = msg.to.clone();
                        let text = msg.text.clone();
                        let from_name = CONFIG
                            .lock()
                            .unwrap()
                            .as_ref()
                            .map(|c| c.device_name.clone())
                            .unwrap_or_else(|| "本机".into());
                        let target = ROOM
                            .lock()
                            .unwrap()
                            .iter()
                            .find(|p| p.id == to)
                            .map(|p| p.tx.clone());
                        let ok = match target {
                            Some(tx) => tx
                                .send(ws_frame(
                                    1,
                                    serde_json::json!({
                                        "t": "text",
                                        "from": "app",
                                        "name": from_name,
                                        "text": text,
                                    })
                                    .to_string()
                                    .as_bytes(),
                                ))
                                .is_ok(),
                            None => false,
                        };
                        let resp = serde_json::json!({"ok": ok});
                        let _ = s.write_all(format!("{}\n", resp).as_bytes());
                        let _ = s.flush();
                        break 'outer;
                    }
                    "version" => {
                        // 版本握手：UI 据此发现常驻的旧版 daemon 并自动重启
                        let resp = serde_json::json!({
                            "ok": true,
                            "version": env!("CARGO_PKG_VERSION"),
                        });
                        let _ = s.write_all(format!("{}\n", resp).as_bytes());
                        let _ = s.flush();
                        break 'outer;
                    }
                    "confirm" => {
                        let map = pending_map().lock().unwrap();
                        let mut found = false;
                        if let Some(e) = map.get(&msg.token) {
                            let (m, cv) = &*e.cell;
                            *m.lock().unwrap() = Some(msg.accept);
                            cv.notify_all();
                            found = true;
                        }
                        drop(map);
                        let resp = serde_json::json!({"ok": true, "found": found});
                        let _ = s.write_all(format!("{}\n", resp).as_bytes());
                        let _ = s.flush();
                        log(&format!(
                            "confirm token={} accept={} found={}",
                            msg.token, msg.accept, found
                        ));
                        break 'outer;
                    }
                    "apply" => {
                        let mut cfg = CONFIG.lock().unwrap();
                        let mut c = cfg.take().unwrap_or_default();
                        if !msg.device_id.is_empty() {
                            c.device_id = msg.device_id;
                        }
                        if !msg.device_name.is_empty() {
                            c.device_name = msg.device_name;
                        }
                        c.discover_enabled = msg.discover_enabled;
                        c.web_share_enabled = msg.web_share_enabled;
                        c.untrusted_confirm = msg.untrusted_confirm;
                        c.untrusted_confirm_secs = msg.untrusted_confirm_secs;
                        c.open_recv_dir = msg.open_recv_dir;
                        if !msg.receive_dir.is_empty() {
                            c.receive_dir = msg.receive_dir;
                        }
                        if !msg.docs_dir.is_empty() {
                            c.docs_dir = msg.docs_dir;
                        }
                        if !msg.exe_path.is_empty() {
                            let icon_changed = c.exe_path != msg.exe_path;
                            c.exe_path = msg.exe_path;
                            if icon_changed {
                                // UI 推来主程序路径：换成真应用图标
                                let icon = load_app_icon(&c.exe_path);
                                tray_update_icon(icon);
                            }
                        }
                        c.ui_active = msg.ui_active;
                        if let Some(v) = msg.landrop_on {
                            c.landrop_on = v;
                        }
                        if !msg.landrop_pk.is_empty() {
                            c.landrop_pk = msg.landrop_pk;
                        }
                        if !msg.landrop_sk.is_empty() {
                            c.landrop_sk = msg.landrop_sk;
                        }
                        log(&format!(
                            "apply: ui_active={} discover={} web={} confirm={} recv_dir={} open_dir={}",
                            c.ui_active,
                            c.discover_enabled,
                            c.web_share_enabled,
                            c.untrusted_confirm,
                            c.receive_dir,
                            c.open_recv_dir
                        ));
                        *cfg = Some(c);
                        drop(cfg);
                        save_config();
                    }
                    _ => {}
                }
            }
            match s.read(&mut tmp) {
                Ok(0) | Err(_) => break,
                Ok(n) => raw.extend_from_slice(&tmp[..n]),
            }
            if raw.len() > 1 << 20 {
                break;
            }
        }
    }
}
// ==================== main ====================

fn main() {
    // single instance
    unsafe {
        let name = to_wide("WeMiDaemonMutex");
        let m = CreateMutexW(std::ptr::null(), 0, name.as_ptr());
        if !m.is_null() {
            if WaitForSingleObject(m, 0) != WAIT_OBJECT_0 {
                log("another daemon running, exit");
                return;
            }
        }
    }
    log("daemon starting");

    load_config();
    std::thread::spawn(config_server);
    std::thread::spawn(transfer_loop);
    std::thread::spawn(landrop_discovery_loop);
    std::thread::spawn(landrop_transfer_loop);
    hotkey_thread();

    unsafe {
        let inst = GetModuleHandleW(std::ptr::null());
        let cls = to_wide("WeMiDaemonWnd");
        let wc = WNDCLASSW {
            style: 0,
            lpfnWndProc: Some(wnd_proc),
            cbClsExtra: 0,
            cbWndExtra: 0,
            hInstance: inst,
            hIcon: std::ptr::null_mut(),
            hCursor: std::ptr::null_mut(),
            hbrBackground: std::ptr::null_mut(),
            lpszMenuName: std::ptr::null(),
            lpszClassName: cls.as_ptr(),
        };
        RegisterClassW(&wc);
        let title = to_wide("WeMiDaemon");
        let hwnd = CreateWindowExW(
            0,
            cls.as_ptr(),
            title.as_ptr(),
            0, // hidden window
            0,
            0,
            0,
            0,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            inst,
            std::ptr::null_mut(),
        );
        if hwnd.is_null() {
            log("CreateWindowExW failed");
            return;
        }
        let tb = RegisterWindowMessageW(to_wide("TaskbarCreated").as_ptr());
        TASKBAR_MSG.store(tb, Ordering::Relaxed);
        let icon = load_app_icon("");
        *TRAY.lock().unwrap() = Some(TrayState { hwnd: hwnd as isize, icon: icon as isize });
        if !tray_add(hwnd, icon) {
            log("Shell_NotifyIconW add failed");
        }
        let _ = SetTimer(hwnd, 1, 60_000, 0);

        let mut msg: MSG = std::mem::zeroed();
        while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) > 0 {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
    tray_delete();
    log("daemon exited");
}

// ==================== LANDrop 传输测试（v1.2.20） ====================

#[cfg(test)]
mod landrop_tests {
    use super::*;

    // —— 最小 LANDrop v2 测试客户端（与 landrop.rs 原语同源） ——

    pub(super) fn t_write_raw(s: &mut TcpStream, data: &[u8]) {
        s.write_all(&[(data.len() >> 8) as u8, data.len() as u8])
            .unwrap();
        s.write_all(data).unwrap();
        s.flush().unwrap();
    }

    pub(super) fn t_read_raw(s: &mut TcpStream) -> Option<Vec<u8>> {
        let mut hdr = [0u8; 2];
        if s.read_exact(&mut hdr).is_err() {
            return None;
        }
        let len = ((hdr[0] as usize) << 8) | hdr[1] as usize;
        let mut buf = vec![0u8; len];
        if s.read_exact(&mut buf).is_err() {
            return None;
        }
        Some(buf)
    }

    pub(super) fn t_send_bytes(s: &mut TcpStream, key: &[u8; 32], nonce: &mut [u8; 12], data: &[u8]) {
        let mut off = 0usize;
        loop {
            let end = (off + LD_MAX_BLOCK).min(data.len());
            let last = end >= data.len();
            let mut plain = vec![if last { 1u8 } else { 0u8 }];
            plain.extend_from_slice(&data[off..end]);
            let ct = ld_seal(key, nonce, &plain);
            t_write_raw(s, &ct);
            ld_nonce_inc(nonce);
            off = end;
            if off >= data.len() {
                break;
            }
        }
    }

    pub(super) fn t_recv_bytes(s: &mut TcpStream, key: &[u8; 32], nonce: &mut [u8; 12]) -> Option<Vec<u8>> {
        let mut out = Vec::new();
        loop {
            let ct = t_read_raw(s)?;
            let pt = ld_open(key, nonce, &ct)?;
            ld_nonce_inc(nonce);
            if pt.is_empty() {
                return None;
            }
            let push = pt[0];
            out.extend_from_slice(&pt[1..]);
            if push == 1 {
                return Some(out);
            }
        }
    }

    /// 全链路 duplex：握手（双向验签 + 会话密钥一致）→ device_info 互换 →
    /// file_send_request（信任免确认）→ 100KB 文件两记录分片 → 落盘校验。
    /// 另验未信任 + confirm_on=false 的拒收路径。
    #[test]
    fn landrop_tray_duplex() {
        // 身份（客户端/服务端各一把）
        let (cpk, csk) = ld_secp_keypair().unwrap();
        let (spk, ssk) = ld_secp_keypair().unwrap();
        // 临时工作目录：docs（信任表/历史）+ recv（落盘）
        let tmp = std::env::temp_dir().join(format!("wm_ld_test_{}", now_ms()));
        let recv = tmp.join("recv");
        std::fs::create_dir_all(&recv).unwrap();
        std::fs::write(
            tmp.join("trusted_devices.json"),
            serde_json::json!({ b64(&cpk): "test-phone" }).to_string(),
        )
        .unwrap();
        // CONFIG：client pk 已信任；先开确认策略（未信任设备会拒收前的短路）
        {
            let mut cfg = CONFIG.lock().unwrap();
            *cfg = Some(Config {
                device_name: "test-pc".to_string(),
                docs_dir: tmp.to_string_lossy().to_string(),
                receive_dir: recv.to_string_lossy().to_string(),
                untrusted_confirm: true,
                untrusted_confirm_secs: 30,
                ..Default::default()
            });
        }
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let addr = listener.local_addr().unwrap();
        let spk_b64 = b64(&spk);
        let ssk_b64 = b64(&ssk);
        let server = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let env = LdEnv {
                docs_dir: {
                    let cfg = CONFIG.lock().unwrap();
                    cfg.as_ref().unwrap().docs_dir.clone()
                },
                receive_dir: {
                    let cfg = CONFIG.lock().unwrap();
                    cfg.as_ref().unwrap().receive_dir.clone()
                },
                confirm_on: true,
                confirm_secs: 30,
                self_pk_b64: spk_b64,
                self_sk_b64: ssk_b64,
                self_name: "test-pc".to_string(),
            };
            handle_landrop_conn(stream, env);
        });

        // —— 客户端连接 + ClientHello ——
        let mut s = TcpStream::connect(addr).unwrap();
        s.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let (ckx_pk, ckx_sk) = ld_kx_keypair();
        let my_sig = ld_secp_sign(&ckx_pk, &csk).unwrap();
        let hello = serde_json::json!({
            "supported_versions": ["v2"],
            "public_key": b64(&cpk),
            "ecdhe": {"public_key": b64(&ckx_pk), "sig": b64(&my_sig)},
        });
        t_write_raw(&mut s, &serde_json::to_vec(&hello).unwrap());
        // ServerHello：验签 + 派生（client 角色）
        let sh_bytes = t_read_raw(&mut s).expect("ServerHello");
        let sh: serde_json::Value = serde_json::from_slice(&sh_bytes).unwrap();
        assert_eq!(sh["version"], "v2");
        let s_ecdhe =
            b64d(sh["ecdhe"]["public_key"].as_str().unwrap()).unwrap();
        let s_sig = b64d(sh["ecdhe"]["sig"].as_str().unwrap()).unwrap();
        assert!(ld_secp_verify(
            s_sig.as_slice().try_into().unwrap(),
            &s_ecdhe,
            &spk
        ));
        let s_ecdhe: [u8; 32] = s_ecdhe.try_into().unwrap();
        let (c_rx, c_tx) = ld_kx_session_keys(true, &ckx_sk, &ckx_pk, &s_ecdhe).unwrap();
        let mut c_rx_nonce = [0u8; 12];
        let mut c_tx_nonce = [0u8; 12];
        // device_info 互换（客户端先发）
        t_send_bytes(
            &mut s,
            &c_tx,
            &mut c_tx_nonce,
            &serde_json::to_vec(&serde_json::json!({
                "type": "device_info",
                "data": {"name": "test-phone", "type": "android"},
            }))
            .unwrap(),
        );
        let di = t_recv_bytes(&mut s, &c_rx, &mut c_rx_nonce).expect("device_info");
        let di: serde_json::Value = serde_json::from_slice(&di).unwrap();
        assert_eq!(di["type"], "device_info");
        assert_eq!(di["data"]["name"], "test-pc");
        // file_send_request（信任 → 免确认直收）
        let content: Vec<u8> = (0..100_000u32).map(|i| (i % 251) as u8).collect();
        let req = serde_json::json!({
            "type": "file_send_request",
            "data": {"files": [{
                "filename": "test.bin",
                "size": content.len(),
                "last_modified": 1700000000,
                "permissions": "644",
            }]},
        });
        t_send_bytes(
            &mut s,
            &c_tx,
            &mut c_tx_nonce,
            &serde_json::to_vec(&req).unwrap(),
        );
        let reply = t_recv_bytes(&mut s, &c_rx, &mut c_rx_nonce).expect("reply");
        let reply: serde_json::Value = serde_json::from_slice(&reply).unwrap();
        assert_eq!(reply["type"], "file_send_request_reply");
        assert_eq!(reply["data"]["accept"], true);
        // 文件记录（100KB → 2 条：65518 + 34482，末片 push=1）
        t_send_bytes(&mut s, &c_tx, &mut c_tx_nonce, &content);
        // 服务端收完即处理；关连接让会话循环退出
        drop(s);
        server.join().unwrap();
        // 落盘校验
        let got = std::fs::read(recv.join("test.bin")).unwrap();
        assert_eq!(got, content);
        // mtime 恢复校验（秒级）
        let mt = std::fs::metadata(recv.join("test.bin")).unwrap().modified().unwrap();
        let want = UNIX_EPOCH + Duration::from_secs(1700000000);
        let delta = if mt >= want {
            mt.duration_since(want).unwrap()
        } else {
            want.duration_since(mt).unwrap()
        };
        assert!(delta < Duration::from_secs(2), "mtime 未恢复: {:?}", delta);

        // —— 未信任 + confirm_on=false → 直接拒收 ——
        let (cpk2, csk2) = ld_secp_keypair().unwrap();
        {
            let mut cfg = CONFIG.lock().unwrap();
            cfg.as_mut().unwrap().untrusted_confirm = false;
        }
        let listener2 = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let addr2 = listener2.local_addr().unwrap();
        let spk_b64 = b64(&spk);
        let ssk_b64 = b64(&ssk);
        let server2 = std::thread::spawn(move || {
            let (stream, _) = listener2.accept().unwrap();
            let env = LdEnv {
                docs_dir: {
                    let cfg = CONFIG.lock().unwrap();
                    cfg.as_ref().unwrap().docs_dir.clone()
                },
                receive_dir: {
                    let cfg = CONFIG.lock().unwrap();
                    cfg.as_ref().unwrap().receive_dir.clone()
                },
                confirm_on: false,
                confirm_secs: 30,
                self_pk_b64: spk_b64,
                self_sk_b64: ssk_b64,
                self_name: "test-pc".to_string(),
            };
            handle_landrop_conn(stream, env);
        });
        let mut s2 = TcpStream::connect(addr2).unwrap();
        s2.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let (ckx_pk2, ckx_sk2) = ld_kx_keypair();
        let my_sig2 = ld_secp_sign(&ckx_pk2, &csk2).unwrap();
        let hello2 = serde_json::json!({
            "supported_versions": ["v2"],
            "public_key": b64(&cpk2),
            "ecdhe": {"public_key": b64(&ckx_pk2), "sig": b64(&my_sig2)},
        });
        t_write_raw(&mut s2, &serde_json::to_vec(&hello2).unwrap());
        let _sh2_bytes = t_read_raw(&mut s2).expect("ServerHello 2");
        let sh2: serde_json::Value = serde_json::from_slice(&_sh2_bytes).unwrap();
        let s_ecdhe2 = b64d(sh2["ecdhe"]["public_key"].as_str().unwrap()).unwrap();
        assert!(ld_secp_verify(
            b64d(sh2["ecdhe"]["sig"].as_str().unwrap())
                .unwrap()
                .as_slice()
                .try_into()
                .unwrap(),
            &s_ecdhe2,
            &spk
        ));
        let s_ecdhe2: [u8; 32] = s_ecdhe2.try_into().unwrap();
        let (c_rx2, c_tx2) =
            ld_kx_session_keys(true, &ckx_sk2, &ckx_pk2, &s_ecdhe2).unwrap();
        let mut c_rx_nonce2 = [0u8; 12];
        let mut c_tx_nonce2 = [0u8; 12];
        let req2 = serde_json::json!({
            "type": "file_send_request",
            "data": {"files": [{"filename": "nope.bin", "size": 3, "last_modified": 0, "permissions": "644"}]},
        });
        t_send_bytes(
            &mut s2,
            &c_tx2,
            &mut c_tx_nonce2,
            &serde_json::to_vec(&req2).unwrap(),
        );
        let reply2 = t_recv_bytes(&mut s2, &c_rx2, &mut c_rx_nonce2).expect("reply 2");
        let reply2: serde_json::Value = serde_json::from_slice(&reply2).unwrap();
        assert_eq!(reply2["type"], "file_send_request_reply");
        assert_eq!(reply2["data"]["accept"], false);
        drop(s2);
        server2.join().unwrap();
        // 拒收不得落盘
        assert!(!recv.join("nope.bin").exists());
        let _ = std::fs::remove_dir_all(&tmp);
    }
}

// ==================== LANDrop 托盘传输跨进程冒烟（v1.2.20） ====================

#[cfg(all(test, windows))]
mod landrop_daemon_tests {
    use super::landrop_tests::{t_read_raw, t_recv_bytes, t_send_bytes, t_write_raw};
    use super::*;
    use std::io::{BufRead, BufReader, Write};
    use std::process::{Child, Command, Stdio};

    /// 起真 daemon 二进制（隔离工作目录）→ apply 托盘配置 → 52637 真实端口
    /// 收发文件。内存级 duplex 已覆盖协议/信任/落盘，这里专验线程启动 +
    /// 端口绑定 + 配置 apply 链路。daemon 起不来（如无桌面会话）则跳过不误挂。
    #[test]
    fn landrop_tray_real_daemon() {
        let exe = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join("release")
            .join("weimi_daemon.exe");
        if !exe.exists() {
            eprintln!("skip: release daemon not built");
            return;
        }
        // 隔离工作目录：daemon 读 current_exe 同目录 daemon_config.json
        let workdir = std::env::temp_dir().join(format!("wm_ld_dmn_{}", now_ms()));
        let recv = workdir.join("recv");
        let docs = workdir.join("docs");
        std::fs::create_dir_all(&recv).unwrap();
        std::fs::create_dir_all(&docs).unwrap();
        // 测试身份：client（手机角色）+ server（daemon 角色）
        let (cpk, csk) = ld_secp_keypair().unwrap();
        let (spk, ssk) = ld_secp_keypair().unwrap();
        std::fs::write(
            docs.join("trusted_devices.json"),
            serde_json::json!({ b64(&cpk): "test-phone" }).to_string(),
        )
        .unwrap();
        let local_exe = workdir.join("weimi_daemon.exe");
        std::fs::copy(&exe, &local_exe).unwrap();
        // 从 daemon 日志读它实际绑定的端口：52637 空闲时绑 52637；被本机其他
        // 同口号工具（实测 F:\Tools\weimi\weimi.exe 占 52637）占着时降级临时
        // 端口——日志方案两种情况都能连通真 daemon，顺带覆盖降级路径。
        let log_path = std::env::temp_dir().join("weimi_daemon.log");
        let log_start: usize = std::fs::metadata(&log_path).map(|m| m.len()).unwrap_or(0) as usize;
        let mut child: Child = Command::new(&local_exe)
            .current_dir(&workdir)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn daemon");
        let cleanup = |c: &mut Child| {
            let _ = c.kill();
            let _ = c.wait();
        };
        // apply：托盘模式（ui_active=false + landrop_on + 身份 sk/pk 配套）
        let apply = serde_json::json!({
            "cmd": "apply",
            "device_id": "test-daemon",
            "device_name": "test-pc",
            "ui_active": false,
            "landrop_on": true,
            "landrop_pk": b64(&spk),
            "landrop_sk": b64(&ssk),
            "docs_dir": docs.to_string_lossy(),
            "receive_dir": recv.to_string_lossy(),
            "untrusted_confirm": false,
            "untrusted_confirm_secs": 30u32,
        });
        if !config_send(&serde_json::to_vec(&apply).unwrap()) {
            eprintln!("skip: daemon config server unreachable");
            cleanup(&mut child);
            let _ = std::fs::remove_dir_all(&workdir);
            return;
        }
        // 等 daemon 日志报 "tray-mode transfer active on <port>"（线程 2s 粒度，
        // 最多 20s；超时说明 daemon 没正常起来——如无桌面会话，跳过不误挂）
        let mut port: Option<u16> = None;
        for _ in 0..100 {
            std::thread::sleep(Duration::from_millis(200));
            if let Ok(s) = std::fs::read_to_string(&log_path) {
                let tail = s.get(log_start..).unwrap_or("");
                for line in tail.lines() {
                    if let Some(rest) = line.split("transfer active on ").nth(1) {
                        if let Ok(p) = rest.trim().parse::<u16>() {
                            port = Some(p);
                            break;
                        }
                    }
                }
            }
            if port.is_some() {
                break;
            }
        }
        let Some(port) = port else {
            eprintln!("skip: daemon landrop transfer not active (no log line)");
            cleanup(&mut child);
            let _ = std::fs::remove_dir_all(&workdir);
            return;
        };
        // —— 客户端：握手 + 发文件（信任免确认） ——
        let mut s = TcpStream::connect(("127.0.0.1", port)).unwrap();
        s.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let (ckx_pk, ckx_sk) = ld_kx_keypair();
        let my_sig = ld_secp_sign(&ckx_pk, &csk).unwrap();
        let hello = serde_json::json!({
            "supported_versions": ["v2"],
            "public_key": b64(&cpk),
            "ecdhe": {"public_key": b64(&ckx_pk), "sig": b64(&my_sig)},
        });
        t_write_raw(&mut s, &serde_json::to_vec(&hello).unwrap());
        let sh_bytes = t_read_raw(&mut s).expect("ServerHello");
        let sh: serde_json::Value = serde_json::from_slice(&sh_bytes).unwrap();
        let s_ecdhe = b64d(sh["ecdhe"]["public_key"].as_str().unwrap()).unwrap();
        assert!(ld_secp_verify(
            b64d(sh["ecdhe"]["sig"].as_str().unwrap())
                .unwrap()
                .as_slice()
                .try_into()
                .unwrap(),
            &s_ecdhe,
            &spk
        ));
        let s_ecdhe: [u8; 32] = s_ecdhe.try_into().unwrap();
        let (c_rx, c_tx) = ld_kx_session_keys(true, &ckx_sk, &ckx_pk, &s_ecdhe).unwrap();
        let mut c_rx_nonce = [0u8; 12];
        let mut c_tx_nonce = [0u8; 12];
        // device_info（客户端先发，服务端也会回）
        t_send_bytes(
            &mut s,
            &c_tx,
            &mut c_tx_nonce,
            &serde_json::to_vec(&serde_json::json!({
                "type": "device_info",
                "data": {"name": "test-phone", "type": "android"},
            }))
            .unwrap(),
        );
        let _di = t_recv_bytes(&mut s, &c_rx, &mut c_rx_nonce).expect("device_info");
        // 文件请求（已信任 → 免确认直收）
        let content: Vec<u8> = (0..70_000u32).map(|i| (i % 241) as u8).collect();
        t_send_bytes(
            &mut s,
            &c_tx,
            &mut c_tx_nonce,
            &serde_json::to_vec(&serde_json::json!({
                "type": "file_send_request",
                "data": {"files": [{
                    "filename": "smoke.bin",
                    "size": content.len(),
                    "last_modified": 1700000000,
                    "permissions": "644",
                }]},
            }))
            .unwrap(),
        );
        let reply = t_recv_bytes(&mut s, &c_rx, &mut c_rx_nonce).expect("reply");
        let reply: serde_json::Value = serde_json::from_slice(&reply).unwrap();
        assert_eq!(reply["type"], "file_send_request_reply");
        assert_eq!(reply["data"]["accept"], true);
        t_send_bytes(&mut s, &c_tx, &mut c_tx_nonce, &content);
        drop(s);
        // 落盘校验（daemon 侧异步收尾，轮询 5s）
        let target = recv.join("smoke.bin");
        let mut got = Vec::new();
        for _ in 0..50 {
            if let Ok(d) = std::fs::read(&target) {
                if d.len() == content.len() {
                    got = d;
                    break;
                }
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        assert_eq!(got, content, "smoke.bin 落盘内容不符");
        // 退出 daemon + 清理
        let _ = config_send(br#"{"cmd":"quit"}"#);
        std::thread::sleep(Duration::from_millis(500));
        cleanup(&mut child);
        let _ = std::fs::remove_dir_all(&workdir);
    }

    fn config_send(line: &[u8]) -> bool {
        let mut s = match TcpStream::connect(("127.0.0.1", CONFIG_PORT)) {
            Ok(s) => s,
            Err(_) => return false,
        };
        if s.write_all(line).is_err() || s.write_all(b"\n").is_err() {
            return false;
        }
        let _ = s.flush();
        let mut ack = String::new();
        let mut reader = BufReader::new(s);
        let _ = reader.read_line(&mut ack);
        true
    }
}
