//! 目录变更实时监视（方案A+：ReadDirectoryChangesW，Everything 式实时增量）
//!
//! 原理：每个盘根一个监视线程，阻塞式 ReadDirectoryChangesW（只订阅
//! FILE_NAME | DIR_NAME，内容修改不关心）。变更条目的**父目录**路径去重后
//! 入 WATCH_EVENTS 池；Dart 侧周期 drain，对每个脏目录调 index_update_dir
//! 做非递归增量合并。缓冲溢出/监视失败 → 该根入 WATCH_OVERFLOWS，Dart 侧
//! 全量重建后 index_watch_start 会重新拉起线程（WATCHING 已移除）。
//!
//! 为什么不用 USN journal：沙箱/安全软件挡 DeviceIoControl 卷句柄（两次翻车），
//! ReadDirectoryChangesW 用的是普通目录句柄，普通权限即可，无此风险。
//! 为什么不用 index_refresh（根 mtime 比对）：Windows 目录 mtime 不随深层
//! 子目录变化传播，盘根 mtime 几乎不变，等于永不刷新（假增量）。

use std::collections::HashSet;
use std::ffi::{c_void, CStr};
use std::os::raw::c_char;
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicUsize;
use std::sync::LazyLock;

use crate::{
    dir_mtime_ns, index_skip_dir, lock_or_recover, wildcard_match, INDEX_DIR_MTIMES,
    INDEX_EXCLUDES, INDEX_PATHS,
};

// ==================== Win32 FFI（无 windows crate，手写 extern，同 usn.rs 风格） ====================

#[link(name = "kernel32")]
extern "system" {
    fn CreateFileW(
        lpFileName: *const u16,
        dwDesiredAccess: u32,
        dwShareMode: u32,
        lpSecurityAttributes: *mut c_void,
        dwCreationDisposition: u32,
        dwFlagsAndAttributes: u32,
        hTemplateFile: *mut c_void,
    ) -> *mut c_void;
    fn ReadDirectoryChangesW(
        hDirectory: *mut c_void,
        lpBuffer: *mut c_void,
        nBufferLength: u32,
        bWatchSubtree: i32,
        dwNotifyFilter: u32,
        lpBytesReturned: *mut u32,
        lpOverlapped: *mut c_void,
        lpCompletionRoutine: *mut c_void,
    ) -> i32;
    fn CloseHandle(hObject: *mut c_void) -> i32;
}

const FILE_LIST_DIRECTORY: u32 = 0x0000_0001;
const FILE_SHARE_READ: u32 = 0x0000_0001;
const FILE_SHARE_WRITE: u32 = 0x0000_0002;
const FILE_SHARE_DELETE: u32 = 0x0000_0004;
const OPEN_EXISTING: u32 = 3;
const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
const INVALID_HANDLE_VALUE: isize = -1;

/// 只订阅文件/目录的创建、删除、改名（内容改写不动文件名索引）
const FILE_NOTIFY_CHANGE_FILE_NAME: u32 = 0x0000_0001;
const FILE_NOTIFY_CHANGE_DIR_NAME: u32 = 0x0000_0002;

/// FILE_NOTIFY_INFORMATION：NextEntryOffset(4) Action(4) FileNameLength(4) FileName[]
const NOTIFY_REC_HEADER_LEN: usize = 12;

// ==================== 事件池 ====================

/// 脏目录路径池（去重在 drain 时做）
static WATCH_EVENTS: LazyLock<std::sync::Mutex<Vec<String>>> =
    LazyLock::new(|| std::sync::Mutex::new(Vec::new()));
/// 监视失效的根（溢出/失败），Dart 侧需全量重建
static WATCH_OVERFLOWS: LazyLock<std::sync::Mutex<Vec<String>>> =
    LazyLock::new(|| std::sync::Mutex::new(Vec::new()));
/// 已启动监视的根（防止重复起线程；线程退出时移除以便重拉）
static WATCHING: LazyLock<std::sync::Mutex<HashSet<String>>> =
    LazyLock::new(|| std::sync::Mutex::new(HashSet::new()));

/// 单目录增量合并的最大条数保护（与 index_build 的 max_entries 一致）
static WATCH_TOTAL: AtomicUsize = AtomicUsize::new(0);
const MAX_ENTRIES: usize = 1_000_000;

fn to_wide(s: &str) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt as _;
    std::ffi::OsStr::new(s).encode_wide().chain(Some(0)).collect()
}

/// 单根监视线程主体
fn watch_root(root: String) {

    // 根必须以分隔符结尾（拼接相对路径用）
    let sep = std::path::MAIN_SEPARATOR;
    let root = if root.ends_with(sep) {
        root
    } else {
        format!("{}{}", root, sep)
    };
    let wide = to_wide(&root);
    let handle = unsafe {
        CreateFileW(
            wide.as_ptr(),
            FILE_LIST_DIRECTORY,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            std::ptr::null_mut(),
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS,
            std::ptr::null_mut(),
        )
    };
    if (handle as isize) == INVALID_HANDLE_VALUE {
        lock_or_recover(&WATCH_OVERFLOWS).push(root.clone());
        lock_or_recover(&WATCHING).remove(&root);
        return;
    }
    loop {
        let mut buf = [0u8; 64 * 1024];
        let mut returned: u32 = 0;
        let ok = unsafe {
            ReadDirectoryChangesW(
                handle,
                buf.as_mut_ptr() as *mut c_void,
                buf.len() as u32,
                1, // bWatchSubtree = TRUE（递归监视整棵子树）
                FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME,
                &mut returned,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        if ok == 0 || returned == 0 {
            // 监视失效（句柄被关/缓冲溢出等）：标记根溢出，退出线程，
            // Dart 全量重建后 index_watch_start 会重新拉起
            lock_or_recover(&WATCH_OVERFLOWS).push(root.clone());
            break;
        }
        // 解析通知链
        let recs = &buf[..returned as usize];
        let mut offset = 0usize;
        {
            let mut events = lock_or_recover(&WATCH_EVENTS);
            while offset + NOTIFY_REC_HEADER_LEN <= recs.len() {
                let rec = &recs[offset..];
                let next = u32::from_ne_bytes([rec[0], rec[1], rec[2], rec[3]]) as usize;
                let name_len =
                    u32::from_ne_bytes([rec[8], rec[9], rec[10], rec[11]]) as usize;
                let chars = name_len / 2;
                if offset + NOTIFY_REC_HEADER_LEN + name_len > recs.len() {
                    break;
                }
                let name_u16: Vec<u16> = (0..chars)
                    .map(|i| {
                        u16::from_ne_bytes([rec[12 + i * 2], rec[13 + i * 2]])
                    })
                    .collect();
                let rel = String::from_utf16_lossy(&name_u16);
                let full = format!("{}{}", root, rel);
                // 脏目录 = 变更条目的父目录
                if let Some(parent) = Path::new(&full).parent() {
                    let dir = parent.to_string_lossy().to_string();
                    if !dir.is_empty() {
                        events.push(dir);
                    }
                }
                if next == 0 {
                    break;
                }
                offset += next;
            }
        }
    }
    unsafe {
        CloseHandle(handle);
    }
    lock_or_recover(&WATCHING).remove(&root);
}

/// 启动目录变更监视（每个根一个线程；重复调用幂等）
#[no_mangle]
pub extern "C" fn index_watch_start(
    roots_ptr: *const *const c_char,
    num_roots: usize,
) -> i32 {
    ffi_catch!({
    if roots_ptr.is_null() {
        return -1;
    }
    let mut started = 0i32;
    unsafe {
        let ptrs = std::slice::from_raw_parts(roots_ptr, num_roots);
        for &rp in ptrs {
            let s = CStr::from_ptr(rp).to_string_lossy().to_string();
            if s.is_empty() || !Path::new(&s).is_dir() {
                continue;
            }
            let sep = std::path::MAIN_SEPARATOR;
            let root = if s.ends_with(sep) {
                s
            } else {
                format!("{}{}", s, sep)
            };
            let mut watching = lock_or_recover(&WATCHING);
            if watching.contains(&root) {
                continue;
            }
            watching.insert(root.clone());
            drop(watching);
            let root_clone = root.clone();
            std::thread::Builder::new()
                .name(format!("wemi-watch-{}", root))
                .spawn(move || watch_root(root_clone))
                .ok();
            started += 1;
        }
    }
    started
})
}

/// 取走并清空事件池（两段式：第一次 out_ptr 传 null 拿长度）。
/// 格式：每行一条，'U' + 目录路径（增量合并）或 'O' + 根路径（需全量重建），'\n' 结尾。
#[no_mangle]
pub extern "C" fn index_watch_drain(out_ptr: *mut u8, out_len: *mut usize) -> i32 {
    ffi_catch!({
    if out_len.is_null() {
        return -3;
    }
    // 两段式第一段（out_ptr=null）只算长度，不动队列；
    // 第二段才真正取走。注意与 index_search 不同，本函数有副作用，
    // 第一段绝不能 drain（否则第二段拿到空队列）。
    unsafe {
        if out_ptr.is_null() {
            let mut total = 0usize;
            for r in lock_or_recover(&WATCH_OVERFLOWS).iter() {
                total += r.len() + 2;
            }
            let ev = lock_or_recover(&WATCH_EVENTS);
            let mut seen: HashSet<&String> = ev.iter().collect();
            for d in seen.drain() {
                total += d.len() + 2;
            }
            drop(ev);
            *out_len = total;
            return 0;
        }
    }
    let mut payload = String::new();
    for r in lock_or_recover(&WATCH_OVERFLOWS).drain(..) {
        payload.push('O');
        payload.push_str(&r);
        payload.push('\n');
    }
    {
        let mut ev = lock_or_recover(&WATCH_EVENTS);
        ev.sort();
        ev.dedup();
        for d in ev.drain(..) {
            payload.push('U');
            payload.push_str(&d);
            payload.push('\n');
        }
    }
    let out = payload.as_bytes();
    unsafe {
        let cap = *out_len;
        let n = out.len().min(cap);
        std::ptr::copy_nonoverlapping(out.as_ptr(), out_ptr, n);
        *out_len = n;
    }
    0
})
}

/// 单目录增量合并：移除该目录下的旧索引条目，非递归重扫该目录并入。
/// 子目录自身的变更由监视器单独上报，这里只管直接文件。
/// 返回 0 成功；目录不存在/非目录 -2；被排除跳过 1。
#[no_mangle]
pub extern "C" fn index_update_dir(path_ptr: *const c_char) -> i32 {
    ffi_catch!({
    if path_ptr.is_null() {
        return -1;
    }
    let p = unsafe { CStr::from_ptr(path_ptr) }
        .to_string_lossy()
        .to_string();
    let path = PathBuf::from(&p);
    if !path.is_dir() {
        return -2;
    }
    let key = path.to_string_lossy().to_string();
    let lower_key = key.to_lowercase();

    // 排除检查：目录命中排除列表/内置跳过名单 → 不动索引。
    // 匹配用「目录路径 + 分隔符」：模式如 \\temp\\ 要能命中以 \\temp 结尾的目录本身
    // （其下文件路径才形如 ...\\temp\\x.txt 被排除）
    {
        let with_sep = format!("{}{}", lower_key, std::path::MAIN_SEPARATOR);
        let ex = lock_or_recover(&INDEX_EXCLUDES);
        if let Some(list) = ex.as_ref() {
            if list.iter().any(|pat| {
                wildcard_match(pat.as_bytes(), with_sep.as_bytes())
                    || wildcard_match(pat.as_bytes(), lower_key.as_bytes())
            }) {
                return 1;
            }
        }
    }
    if let Some(name) = path.file_name() {
        if index_skip_dir(&name.to_string_lossy()) {
            return 1;
        }
    }

    // 移除该目录下的旧条目（索引只存文件路径，目录本身不在列表里）
    let sep = std::path::MAIN_SEPARATOR;
    let prefix = format!("{}{}", key, sep);
    {
        let mut pg = lock_or_recover(&INDEX_PATHS);
        if let Some(v) = pg.as_mut() {
            v.retain(|x| !x.starts_with(&prefix));
        }
    }

    // 非递归重扫该目录的直接文件（子目录不入索引，靠其自身事件触发）
    let excludes: Vec<String> = INDEX_EXCLUDES
        .lock()
        .unwrap()
        .as_ref()
        .cloned()
        .unwrap_or_default();
    let mut local: Vec<String> = Vec::new();
    if let Ok(rd) = std::fs::read_dir(&path) {
        for e in rd.flatten() {
            let Ok(ft) = e.file_type() else { continue };
            if ft.is_symlink() || ft.is_dir() {
                continue;
            }
            let fp = e.path().to_string_lossy().to_string();
            let fl = fp.to_lowercase();
            if excludes
                .iter()
                .any(|pat| wildcard_match(pat.as_bytes(), fl.as_bytes()))
            {
                continue;
            }
            local.push(fp);
        }
    }
    {
        let mut pg = lock_or_recover(&INDEX_PATHS);
        if let Some(v) = pg.as_mut() {
            // 上限保护：超出 max_entries 就不再并入
            let room = MAX_ENTRIES.saturating_sub(v.len());
            local.truncate(room);
            v.extend(local);
        }
    }

    // 目录 mtime 刷新（保持 map 一致，供全量重建前的比对面）
    if let Some(mt) = dir_mtime_ns(&path) {
        let mut dm = lock_or_recover(&INDEX_DIR_MTIMES);
        if let Some(m) = dm.as_mut() {
            m.insert(key, mt);
        }
    }
    WATCH_TOTAL.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    0
})
}
