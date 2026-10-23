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
//! - ui_active=true  -> daemon releases UDP/HTTP ports (UI hosts transfer)
//! - ui_active=false -> daemon starts announce + HTTP receive (tray mode)
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
}

static CONFIG: Mutex<Option<Config>> = Mutex::new(None);
static TRANSFER_ON: AtomicBool = AtomicBool::new(false);
static HTTP_PORT: AtomicU16 = AtomicU16::new(HTTP_PORT_BASE);
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
    fn MessageBoxW(hwnd: HWND, text: *const u16, caption: *const u16, typ: u32) -> i32;
    fn EnumThreadWindows(
        tid: u32,
        proc_: unsafe extern "system" fn(HWND, isize) -> i32,
        lparam: isize,
    ) -> i32;
    fn PostMessageW(hwnd: HWND, msg: u32, wp: usize, lp: isize) -> i32;
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

/// Load the app icon: try the configured exe (ExtractIconEx), else .ico beside
/// daemon, else the default application icon.
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

fn pending_map() -> &'static Mutex<HashMap<String, PendingReq>> {
    PENDING.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Wait for the user's decision on an untrusted request. True = accept.
/// - UI 活跃：拉起主程序走 UI 确认框（原有路径）
/// - 托盘模式（UI 未运行）：直接弹**原生 Win32 确认框**，全程不需要主程序；
///   超时自动关框=拒收
fn wait_untrusted_confirm(
    sender_name: &str,
    name: &str,
    size: u64,
    is_text: bool,
    timeout_secs: u32,
) -> bool {
    let timeout_secs: u64 = if timeout_secs < 5 { 5 } else { timeout_secs as u64 };
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
    if ui_active {
        balloon(
            "微密飞传",
            &format!(
                "{} 请求发送：{}\n已拉起微密文件，{}秒内未确认将自动拒收",
                sender_name, name, timeout_secs
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
                "{} 请求发送：{}\n请在弹出的确认框里选择，{}秒内未确认将自动拒收",
                sender_name, name, timeout_secs
            ),
        );
        decision = native_confirm_dialog(sender_name, name, is_text, timeout_secs);
    }
    pending_map().lock().unwrap().remove(&token);
    log(&format!(
        "untrusted request from {} ({}): decision={}",
        sender_name, name, decision
    ));
    decision
}

/// 原生 Win32 确认框（托盘模式专用）：是/否 + 超时自动关闭（=拒收）。
fn native_confirm_dialog(
    sender_name: &str,
    name: &str,
    is_text: bool,
    timeout_secs: u64,
) -> bool {
    const MB_YESNO: u32 = 0x0000_0004;
    const MB_ICONQUESTION: u32 = 0x0000_0020;
    const MB_SYSTEMMODAL: u32 = 0x0000_1000;
    const MB_SETFOREGROUND: u32 = 0x0001_0000;
    const MB_TOPMOST: u32 = 0x0004_0000;
    const IDYES: i32 = 6;
    // WM_CLOSE 已有顶层常量（136 行）
    let body = if is_text {
        format!(
            "「{}」想发送一条文本消息到本机\n\n是否接收？（{}秒未确认自动拒收）",
            sender_name, timeout_secs
        )
    } else {
        format!(
            "「{}」想发送文件到本机：\n{}\n\n是否接收？（{}秒未确认自动拒收）",
            sender_name, name, timeout_secs
        )
    };
    let body_w = to_wide(&body);
    let title_w = to_wide("微密飞传 - 接收确认");
    let answered = Arc::new(AtomicBool::new(false));
    let (res_tx, res_rx) = std::sync::mpsc::channel::<i32>();
    let (tid_tx, tid_rx) = std::sync::mpsc::channel::<u32>();
    let answered2 = answered.clone();
    std::thread::spawn(move || unsafe {
        let _ = tid_tx.send(GetCurrentThreadId());
        let r = MessageBoxW(
            std::ptr::null_mut(),
            body_w.as_ptr(),
            title_w.as_ptr(),
            MB_YESNO | MB_ICONQUESTION | MB_SYSTEMMODAL | MB_SETFOREGROUND | MB_TOPMOST,
        );
        answered2.store(true, Ordering::SeqCst);
        let _ = res_tx.send(r);
    });
    // 拿不到对话框线程 id（异常）直接按拒收处理
    let Ok(tid) = tid_rx.recv_timeout(Duration::from_secs(3)) else {
        return false;
    };
    // 超时关框线程：到点且用户仍未作答 → PostMessage(WM_CLOSE) 关掉对话框
    let answered3 = answered.clone();
    std::thread::spawn(move || unsafe {
        std::thread::sleep(Duration::from_secs(timeout_secs));
        if !answered3.load(Ordering::SeqCst) {
            EnumThreadWindows(tid, close_dialog_cb, 0);
        }
    });
    match res_rx.recv_timeout(Duration::from_secs(timeout_secs + 10)) {
        Ok(r) => r == IDYES,
        Err(_) => false,
    }
}

/// EnumThreadWindows 回调：给对话框发 WM_CLOSE（返回 0 停止枚举）。
unsafe extern "system" fn close_dialog_cb(hwnd: HWND, _l: isize) -> i32 {
    PostMessageW(hwnd, WM_CLOSE, 0, 0);
    0
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
        "direction": "in",
        "name": name,
        "text": text,
        "path": path,
        "size": size,
        "peerName": peer,
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
fn stream_body_to_file(
    stream: &mut TcpStream,
    leftover: Vec<u8>,
    content_length: Option<u64>,
    chunked: bool,
    out: &Path,
) -> std::io::Result<u64> {
    let mut file = std::fs::File::create(out)?;
    let mut written: u64 = 0;
    if !chunked {
        let Some(len) = content_length else {
            return Ok(0);
        };
        let mut need = len;
        let mut pending = leftover;
        if !pending.is_empty() {
            let take = pending.len().min(need as usize);
            file.write_all(&pending[..take])?;
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
            file.write_all(&tmp[..take as usize])?;
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
                file.write_all(&cur[pos..pos + size])?;
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
            let from = format!("网页访客({})", remote_ip);
            let name = safe_file_name(if head.query_name.is_empty() {
                "unnamed"
            } else {
                &head.query_name
            });
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
                    );
                }
                Err(e) => {
                    let _ = std::fs::remove_file(&save);
                    write_json(
                        &mut stream,
                        500,
                        &serde_json::json!({"ok": false, "error": e.to_string()}),
                    );
                    record_history("file", &name, 0, &from, false, None, None);
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
            let from = format!("网页访客({})", remote_ip);
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
                    // 等 UI 确认（daemon 会拉起主界面），超时自动拒
                    accepted = wait_untrusted_confirm(
                        &sender_name,
                        &hint,
                        fsize,
                        is_text,
                        confirm.1,
                    );
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
                        );
                    } else {
                        record_history("file", &hint, fsize, &sender_name, false, None, None);
                    }
                    return;
                }
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
                        );
                    }
                    Err(e) => {
                        let _ = std::fs::remove_file(&save);
                        write_json(
                            &mut stream,
                            500,
                            &serde_json::json!({"ok": false, "error": e.to_string()}),
                        );
                        record_history("file", &name, 0, &sender_name, false, None, None);
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
        let total = off + len + if masked { 4 } else { 0 };
        if self.buf.len() < total {
            return None;
        }
        let mut payload = self.buf[off..off + len].to_vec();
        if masked {
            let mk = [
                self.buf[off + len],
                self.buf[off + len + 1],
                self.buf[off + len + 2],
                self.buf[off + len + 3],
            ];
            for (i, b) in payload.iter_mut().enumerate() {
                *b ^= mk[i % 4];
            }
        }
        self.buf.drain(..total);
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

/// out 方向的传输记录（网页访客经本机转发给其他设备）
fn record_history_out(
    kind: &str,
    name: &str,
    size: u64,
    peer: &str,
    ok: bool,
    text: Option<&str>,
    path: Option<&str>,
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
                record_history("file", &name, size, visitor, true, None, path_str.as_deref());
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
            let visitor = format!("网页访客({})", peer_name);
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
                let from = format!("网页访客({})", peer_name);
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
                            let from = format!("网页访客({})", peer_name);
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
                        let on = cfg
                            .as_ref()
                            .map(|c| !c.ui_active && c.discover_enabled)
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
                if m.get("action").and_then(|v| v.as_str()) == Some("announce") {
                    let reply = serde_json::json!({
                        "app": MAGIC,
                        "action": "reply",
                        "id": self_id,
                        "name": self_name,
                        "httpPort": http_port,
                        "v": 1,
                    });
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
    let body = serde_json::json!({
        "app": MAGIC,
        "action": "announce",
        "id": id,
        "name": name,
        "httpPort": HTTP_PORT.load(Ordering::Relaxed),
        "v": 1,
    })
    .to_string();
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
                        let room = ROOM.lock().unwrap();
                        let items: Vec<serde_json::Value> = room
                            .iter()
                            .map(|p| {
                                serde_json::json!({
                                    "id": p.id,
                                    "name": p.name,
                                    "ip": p.ip,
                                })
                            })
                            .collect();
                        drop(room);
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

    std::thread::spawn(config_server);
    std::thread::spawn(transfer_loop);
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
