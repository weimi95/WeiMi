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
use std::sync::atomic::{AtomicBool, AtomicU16, AtomicU32, Ordering};
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
}

static CONFIG: Mutex<Option<Config>> = Mutex::new(None);
static TRANSFER_ON: AtomicBool = AtomicBool::new(false);
static HTTP_PORT: AtomicU16 = AtomicU16::new(HTTP_PORT_BASE);
static TASKBAR_MSG: AtomicU32 = AtomicU32::new(0);

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

/// Wait for the user's decision on an untrusted request (via UI confirm
/// dialog + config channel). True = accept. Timeout/no-UI = reject.
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

    balloon(
        "微密飞传",
        &format!(
            "{} 请求发送：{}\n已拉起微密文件，{}秒内未确认将自动拒收",
            sender_name, name, timeout_secs
        ),
    );
    launch_ui(None);

    let deadline = std::time::Instant::now() + Duration::from_secs(timeout_secs);
    let mut decision = false;
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
    pending_map().lock().unwrap().remove(&token);
    log(&format!(
        "untrusted request from {} ({}): decision={}",
        sender_name, name, decision
    ));
    decision
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
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>微密飞传 · 网页版</title>
<style>
body{margin:0;font-family:system-ui,sans-serif;background:#101418;color:#e8eaed;
 display:flex;align-items:center;justify-content:center;min-height:100vh}
.card{background:#1b2129;border-radius:16px;padding:28px;width:min(420px,92vw);
 box-shadow:0 8px 30px rgba(0,0,0,.4)}
h1{font-size:20px;margin:0 0 6px}
p.tip{font-size:13px;color:#9aa4b0;margin:0 0 18px}
#drop{border:2px dashed #3b4654;border-radius:12px;padding:34px 12px;text-align:center;
 color:#9aa4b0;cursor:pointer;transition:.2s}
#drop.hover{border-color:#5b8def;color:#bcd3ff;background:#1d2430}
#file{display:none}
#txt{width:100%;box-sizing:border-box;margin-top:14px;background:#11161c;border:1px solid #3b4654;
 border-radius:8px;color:#e8eaed;padding:10px;font-size:14px;resize:vertical;min-height:64px}
button{margin-top:12px;width:100%;background:#2f6fed;border:none;border-radius:8px;color:#fff;
 padding:10px;font-size:14px;cursor:pointer}
button:disabled{opacity:.5}
#msg{margin-top:12px;font-size:13px;color:#9aa4b0;min-height:18px;white-space:pre-wrap}
#log{list-style:none;margin:12px 0 0;padding:0;font-size:13px}
#log li{padding:6px 8px;border-radius:6px;margin-bottom:6px;background:#141a21;
 color:#9fd39f;word-break:break-all}
#log li.err{color:#e08c8c}
#log li .t{color:#69737f;font-size:11px;margin-left:6px}
.logo{font-size:34px;text-align:center;margin-bottom:4px}
</style>
</head>
<body>
<div class="card">
  <div class="logo">&#128274;</div>
  <h1>微密飞传 · 网页版</h1>
  <p class="tip">电脑处于托盘模式：文件将直接保存到电脑的接收目录</p>
  <div id="drop">点击选择文件，或拖拽到此处</div>
  <input id="file" type="file" multiple>
  <textarea id="txt" placeholder="或粘贴一段文本…"></textarea>
  <button id="send">发送文本</button>
  <ul id="log"></ul>
</div>
<script>
const drop=document.getElementById('drop'),file=document.getElementById('file'),
 log=document.getElementById('log'),btn=document.getElementById('send'),txt=document.getElementById('txt');
function li(text,cls){
  var el=document.createElement('li');
  el.textContent=text;
  if(cls)el.className=cls;
  var d=new Date();
  var t=document.createElement('span');
  t.className='t';
  t.textContent=('0'+d.getHours()).slice(-2)+':'+('0'+d.getMinutes()).slice(-2)+':'+('0'+d.getSeconds()).slice(-2);
  el._time=t;el.appendChild(t);
  log.appendChild(el);
  return el;
}
function done(el,text,ok){
  el.textContent=text;
  el.className=ok?'':'err';
  if(el._time)el.appendChild(el._time);
}
drop.onclick=()=>file.click();
drop.ondragover=e=>{e.preventDefault();drop.classList.add('hover')};
drop.ondragleave=()=>drop.classList.remove('hover');
drop.ondrop=e=>{e.preventDefault();drop.classList.remove('hover');sendFiles(e.dataTransfer.files)};
file.onchange=()=>sendFiles(file.files);
async function sendFiles(files){
  for(const f of files){
    const el=li('正在发送 '+f.name+' …');
    try{
      const r=await fetch('/web/upload?name='+encodeURIComponent(f.name),{method:'POST',body:f});
      const j=await r.json();
      done(el, j.ok?('已发送 '+f.name):('失败：'+(j.error||r.status)), !!j.ok);
    }catch(e){done(el,'失败：'+e,false)}
  }
  file.value='';
}
btn.onclick=async()=>{
  const t=txt.value.trim();if(!t)return;
  const el=li('正在发送文本 …');
  try{
    const r=await fetch('/web/text',{method:'POST',body:t});
    const j=await r.json();
    if(j.ok)txt.value='';
    done(el, j.ok?'文本已发送':('失败：'+(j.error||r.status)), !!j.ok);
  }catch(e){done(el,'失败：'+e,false)}
};
</script>
</body>
</html>"#
        .to_string()
}

// ==================== transfer controller ====================

fn transfer_loop() {
    loop {
        {
            let cfg = CONFIG.lock().unwrap();
            let on = cfg
                .as_ref()
                .map(|c| !c.ui_active && c.discover_enabled)
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
                    if tick % 2 == 0 {
                        broadcast_announce(&sock);
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
                if m.get("action").and_then(|v| v.as_str()) == Some("announce") {
                    let reply = serde_json::json!({
                        "app": MAGIC,
                        "action": "reply",
                        "id": c.device_id,
                        "name": c.device_name,
                        "httpPort": HTTP_PORT.load(Ordering::Relaxed),
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
                            "apply: ui_active={} discover={} web={} confirm={} recv_dir={}",
                            c.ui_active,
                            c.discover_enabled,
                            c.web_share_enabled,
                            c.untrusted_confirm,
                            c.receive_dir
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
