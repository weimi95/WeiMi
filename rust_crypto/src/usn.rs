//! NTFS USN Journal 实时文件索引（方案B：Everything 同源技术）
//!
//! 原理：NTFS 卷内置变更日志 $UsnJrnl，逐条记录文件/目录的创建、删除、重命名。
//! - 首次：FSCTL_ENUM_USN_DATA 全量枚举 journal，建立「目录 FRN 表」（FRN → 父FRN + 目录名），
//!   沿父链递归拼出完整路径，填充 INDEX_PATHS。
//! - 增量：FSCTL_READ_USN_JOURNAL 从上次 USN 位置起读新记录，应用到 FRN 表与 INDEX_PATHS。
//! - 非 NTFS 卷 / journal 不可用 / 记录链断裂：回退 scan_roots 目录遍历（方案A）。
//!
//! 关键简化（内存优化）：FRN 表只存「目录」，不存文件。
//! - 文件路径 = 目录链 + 文件名；USN 每条记录都自带 FileName（相对父目录）与 ParentFRN。
//! - rename 会产生 OLD_NAME + NEW_NAME 两条同 FRN 记录，自带旧/新相对名，无需文件级 FRN 表。
//! - 100 万文件的机器目录数通常 5~15 万，FRN 表内存 ~15MB（文件级 FRN 表要 ~120MB）。
//!
//! FRN = 文件引用号（MFT 记录号），**仅卷内唯一**——不同卷的 FRN 会互相撞号
//! （每个卷的根目录都是 FRN 5），故表 key 为 (盘符, FRN)。
//! NTFS 根目录的 FRN 恒为 5。
//!
//! 仅 Windows 编译（lib.rs 中 `#[cfg(windows)] mod usn;`）；Dart 侧调用须 Platform.isWindows 守卫。

use std::collections::HashMap;
use std::ffi::{c_void, CStr, OsStr, OsString};
use std::fs::File;
use std::io::{BufReader, BufWriter, Read, Write};
use std::os::raw::c_char;
use std::os::windows::ffi::{OsStrExt, OsStringExt};
use std::path::PathBuf;
use std::ptr::null_mut;

use crate::{lock_or_recover, scan_roots, INDEX_PATHS};

/// 目录 FRN 表：(盘符, FRN) → (父 FRN, 目录名)
/// key 带盘符：FRN 仅卷内唯一，跨卷必须靠盘符区分。
pub(crate) type DirTable = HashMap<(char, u64), (u64, String)>;

/// 单卷 USN 状态（持久化到 usn_table.bin，跨启动复用增量位置）
#[derive(Clone, Debug)]
pub(crate) struct VolumeState {
    /// 卷根前缀，如 "C:\"
    pub root: String,
    /// journal 实例 ID。卷的 journal 被禁用重建/磁盘格式化后会变，变了就必须全量重建
    pub journal_id: u64,
    /// 下次增量读取的起始 USN
    pub next_usn: u64,
}

/// 进程级 USN 状态（目录 FRN 表 + 各卷状态）
pub(crate) struct UsnState {
    pub table: DirTable,
    pub volumes: Vec<VolumeState>,
}

impl UsnState {
    fn new() -> Self {
        UsnState {
            table: HashMap::new(),
            volumes: Vec::new(),
        }
    }
}

static USN_STATE: std::sync::Mutex<Option<UsnState>> = std::sync::Mutex::new(None);
/// 已应用的 USN 记录累计数（Dart 侧比对前后差值判断索引是否有变更，决定是否落盘）
static USN_CHANGES: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
/// 待合并的 rename：OLD_NAME 记录先入此表，NEW_NAME 记录消费（FRN → (旧父FRN, 旧名)）
static PENDING_RENAMES: std::sync::LazyLock<std::sync::Mutex<HashMap<u64, (u64, String)>>> =
    std::sync::LazyLock::new(|| std::sync::Mutex::new(HashMap::new()));

// ==================== Win32 FFI（无 windows crate，手写 extern） ====================

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
    fn DeviceIoControl(
        hDevice: *mut c_void,
        dwIoControlCode: u32,
        lpInBuffer: *mut c_void,
        nInBufferSize: u32,
        lpOutBuffer: *mut c_void,
        nOutBufferSize: u32,
        lpBytesReturned: *mut u32,
        lpOverlapped: *mut c_void,
    ) -> i32;
    fn CloseHandle(hObject: *mut c_void) -> i32;
    fn GetVolumeInformationW(
        lpRootPathName: *const u16,
        lpVolumeNameBuffer: *mut u16,
        nVolumeNameSize: u32,
        lpVolumeSerialNumber: *mut u32,
        lpMaximumComponentLength: *mut u32,
        lpFileSystemFlags: *mut u32,
        lpFileSystemNameBuffer: *mut u16,
        nFileSystemNameSize: u32,
    ) -> i32;
    fn GetLastError() -> u32;
}

const GENERIC_READ: u32 = 0x8000_0000;
const FILE_SHARE_READ: u32 = 0x0000_0001;
const FILE_SHARE_WRITE: u32 = 0x0000_0002;
const OPEN_EXISTING: u32 = 3;
const INVALID_HANDLE_VALUE: isize = -1;

const FSCTL_QUERY_USN_JOURNAL: u32 = 0x0009_0068;
const FSCTL_ENUM_USN_DATA: u32 = 0x0009_00B3;
const FSCTL_READ_USN_JOURNAL: u32 = 0x0009_009B;

/// FSCTL_ENUM_USN_DATA 枚举到末尾的正常终止码
const ERROR_HANDLE_EOF: u32 = 38;

/// 只订阅会影响文件名/路径的事件（内容改写等不关我们的事）
const REASON_MASK: u32 = 0x0000_0100 // USN_REASON_FILE_CREATE
    | 0x0000_0200 // USN_REASON_FILE_DELETE
    | 0x0000_1000 // USN_REASON_RENAME_OLD_NAME
    | 0x0000_2000; // USN_REASON_RENAME_NEW_NAME

const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x0000_0010;
/// NTFS 根目录的 MFT 记录号（FRN 恒为 5）
const ROOT_FRN: u64 = 5;
/// USN_RECORD 头长度（V2）：到 FileName 为止
const USN_RECORD_HEADER_LEN: usize = 60;
/// 路径拼接最大深度（防环）
const MAX_PATH_DEPTH: usize = 64;

/// FSCTL_QUERY_USN_JOURNAL 输出
#[repr(C)]
struct UsnJournalData {
    usn_journal_id: u64,
    first_usn: u64,
    next_usn: u64,
    minimum_usn: u64,
    maximum_usn: u64,
    maximum_size: u64,
    allocation_delta: u64,
}

/// FSCTL_ENUM_USN_DATA 输入
#[repr(C)]
struct MftEnumDataV0 {
    start_file_reference_number: u64,
    low_usn: u64,
    high_usn: u64,
}

/// FSCTL_READ_USN_JOURNAL 输入
#[repr(C)]
struct ReadUsnJournalData {
    start_usn: u64,
    reason_mask: u32,
    return_only_on_close: u32,
    timeout: u64,
    bytes_to_wait_for: u64,
    usn_journal_id: u64,
}

fn to_wide(s: &str) -> Vec<u16> {
    OsStr::new(s).encode_wide().chain(Some(0)).collect()
}

fn from_wide(bytes: &[u8]) -> String {
    let u16s: Vec<u16> = bytes
        .chunks_exact(2)
        .map(|c| u16::from_le_bytes([c[0], c[1]]))
        .collect();
    // USN 文件名可能带尾随 \0，剥掉
    let end = u16s.iter().position(|&c| c == 0).unwrap_or(u16s.len());
    OsString::from_wide(&u16s[..end])
        .to_string_lossy()
        .into_owned()
}

/// 从 "C:\" 或 "C:" 提取盘符（大写单字母）
fn drive_letter(root: &str) -> Option<char> {
    let mut it = root.chars();
    let c = it.next()?.to_ascii_uppercase();
    if c.is_ascii_alphabetic() && matches!(it.next(), Some(':') | None) {
        Some(c)
    } else {
        None
    }
}

/// 打开卷设备 \\.\X:（GENERIC_READ + 共享读写，普通权限可开）
fn open_volume(drive: char) -> Option<*mut c_void> {
    let path = to_wide(&format!("\\\\.\\{}:", drive));
    let h = unsafe {
        CreateFileW(
            path.as_ptr(),
            GENERIC_READ,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            null_mut(),
            OPEN_EXISTING,
            0,
            null_mut(),
        )
    };
    if h as isize == INVALID_HANDLE_VALUE {
        None
    } else {
        Some(h)
    }
}

/// 判断卷文件系统是否为 NTFS
fn is_ntfs(drive: char) -> bool {
    let root = to_wide(&format!("{}:\\", drive));
    let mut fs_name = vec![0u16; 32];
    let ok = unsafe {
        GetVolumeInformationW(
            root.as_ptr(),
            null_mut(),
            0,
            null_mut(),
            null_mut(),
            null_mut(),
            fs_name.as_mut_ptr(),
            fs_name.len() as u32,
        )
    };
    if ok == 0 {
        return false;
    }
    let end = fs_name.iter().position(|&c| c == 0).unwrap_or(fs_name.len());
    OsString::from_wide(&fs_name[..end])
        .to_string_lossy()
        .eq_ignore_ascii_case("NTFS")
}

/// 卷内路径前缀，如 "C:\"
fn root_prefix(root: &str) -> String {
    match drive_letter(root) {
        Some(c) => format!("{}:\\", c),
        None => root.to_string(),
    }
}

// ==================== 目录路径拼接（FRN 链上溯） ====================

/// 由 (盘符, 目录 FRN) 沿父链拼出相对路径（不含盘符，如 "Users\Docs"）。链断裂/成环返回 None。
fn dir_path(table: &DirTable, drive: char, frn: u64) -> Option<String> {
    let mut parts: Vec<&str> = Vec::new();
    let mut cur = frn;
    let mut depth = 0;
    while cur != ROOT_FRN {
        let (parent, name) = table.get(&(drive, cur))?;
        parts.push(name.as_str());
        cur = *parent;
        depth += 1;
        if depth > MAX_PATH_DEPTH {
            return None; // 成环保护
        }
    }
    parts.reverse();
    Some(parts.join("\\"))
}

/// 由「父 FRN + 名字」拼相对路径（父必须是已知目录）。返回 None = 父未知（journal 不一致）
fn child_rel(table: &DirTable, drive: char, parent_frn: u64, name: &str) -> Option<String> {
    if parent_frn == ROOT_FRN {
        return Some(name.to_string());
    }
    let base = dir_path(table, drive, parent_frn)?;
    Some(format!("{}\\{}", base, name))
}

// ==================== USN 记录解析与应用 ====================

/// 从缓冲区 offset 处解析一条 USN_RECORD（V2）。
/// 返回 (记录总长, FRN, 父FRN, Reason, FileAttributes, 文件名)。
/// V3（128 位 FRN，ReFS/大卷）或损坏返回 None，调用方应回退遍历。
fn parse_record(buf: &[u8], off: usize) -> Option<(usize, u64, u64, u32, u32, String)> {
    if off + USN_RECORD_HEADER_LEN > buf.len() {
        return None;
    }
    let rec_len = u32::from_le_bytes(buf.get(off..off + 4)?.try_into().ok()?) as usize;
    let major = u16::from_le_bytes(buf.get(off + 4..off + 6)?.try_into().ok()?);
    if rec_len < USN_RECORD_HEADER_LEN || off + rec_len > buf.len() {
        return None; // 截断/损坏
    }
    if major != 2 {
        return None; // V3 不支持 → 触发回退
    }
    let frn = u64::from_le_bytes(buf.get(off + 8..off + 16)?.try_into().ok()?);
    let parent = u64::from_le_bytes(buf.get(off + 16..off + 24)?.try_into().ok()?);
    let reason = u32::from_le_bytes(buf.get(off + 40..off + 44)?.try_into().ok()?);
    let attrs = u32::from_le_bytes(buf.get(off + 52..off + 56)?.try_into().ok()?);
    let name_len = u16::from_le_bytes(buf.get(off + 56..off + 58)?.try_into().ok()?) as usize;
    let name_off = u16::from_le_bytes(buf.get(off + 58..off + 60)?.try_into().ok()?) as usize;
    if name_off + name_len > rec_len {
        return None;
    }
    let name_bytes = buf.get(off + name_off..off + name_off + name_len)?;
    Some((rec_len, frn, parent, reason, attrs, from_wide(name_bytes)))
}

/// 单条记录应用结果
enum ApplyOutcome {
    Applied,
    /// 记录链断裂（父目录不在表里等），需要全量重建
    Inconsistent,
}

/// 把一条 USN 记录应用到 FRN 表 + paths。prefix 形如 "C:\"，drive 为盘符。
#[allow(clippy::too_many_arguments)]
fn apply_record(
    table: &mut DirTable,
    paths: &mut Vec<String>,
    pending: &mut HashMap<u64, (u64, String)>,
    prefix: &str,
    drive: char,
    rec: (usize, u64, u64, u32, u32, String),
) -> ApplyOutcome {
    let (_len, frn, parent, reason, attrs, name) = rec;
    let is_dir = attrs & FILE_ATTRIBUTE_DIRECTORY != 0;
    let is_create = reason & 0x0000_0100 != 0;
    let is_delete = reason & 0x0000_0200 != 0;
    let is_rename_old = reason & 0x0000_1000 != 0;
    let is_rename_new = reason & 0x0000_2000 != 0;

    if is_rename_old {
        // 先缓存，等 NEW_NAME 消费（NEW 记录必紧随其后）
        pending.insert(frn, (parent, name));
        return ApplyOutcome::Applied;
    }

    if is_rename_new {
        let (old_parent, old_name) = match pending.remove(&frn) {
            Some(v) => v,
            None => return ApplyOutcome::Applied, // 没有配对 OLD（异常），跳过
        };
        let old_rel = match child_rel(table, drive, old_parent, &old_name) {
            Some(r) => r,
            None => return ApplyOutcome::Inconsistent,
        };
        let new_rel = match child_rel(table, drive, parent, &name) {
            Some(r) => r,
            None => return ApplyOutcome::Inconsistent,
        };
        let old_full = format!("{}{}", prefix, old_rel);
        let new_full = format!("{}{}", prefix, new_rel);
        if is_dir && table.contains_key(&(drive, frn)) {
            // 目录改名：更新表条目 + paths 整棵前缀替换
            if let Some(entry) = table.get_mut(&(drive, frn)) {
                entry.0 = parent;
                entry.1 = name;
            }
        }
        // 文件改名/移动（含跨目录）：前缀替换等价于删旧+增新
        rename_paths_prefix(paths, &old_full, &new_full);
        return ApplyOutcome::Applied;
    }

    if is_create {
        let rel = match child_rel(table, drive, parent, &name) {
            Some(r) => r,
            None => return ApplyOutcome::Inconsistent, // 父目录未知 → journal 状态不一致
        };
        if is_dir {
            table.insert((drive, frn), (parent, name));
        }
        paths.push(format!("{}{}", prefix, rel));
        return ApplyOutcome::Applied;
    }

    if is_delete {
        if is_dir {
            match child_rel(table, drive, parent, &name) {
                Some(rel) => {
                    let full = format!("{}{}", prefix, rel);
                    remove_subtree(table, drive, frn);
                    remove_paths_prefix(paths, &full);
                }
                None => {
                    // 父也没了：按名字已拼不出，直接从表删该 FRN 子树
                    remove_subtree(table, drive, frn);
                }
            }
        } else if let Some(rel) = child_rel(table, drive, parent, &name) {
            remove_paths_prefix(paths, &format!("{}{}", prefix, rel));
        }
        return ApplyOutcome::Applied;
    }

    ApplyOutcome::Applied
}

/// 从 FRN 表删除 frn 及其所有后代目录（逐元素全表扫子节点，轮数=树深）
fn remove_subtree(table: &mut DirTable, drive: char, frn: u64) {
    let mut del: Vec<(char, u64)> = vec![(drive, frn)];
    let mut i = 0usize;
    while i < del.len() {
        let target = del[i];
        for (k, v) in table.iter() {
            // 只删同卷条目（FRN 跨卷撞号），且父 FRN 命中当前待删元素
            if k.0 == drive && v.0 == target.1 && !del.contains(k) {
                del.push(*k);
            }
        }
        i += 1;
    }
    for k in del {
        table.remove(&k);
    }
}

/// 删除 paths 中 full 及其子树（full 是目录时）
fn remove_paths_prefix(paths: &mut Vec<String>, full: &str) {
    let with_sep = format!("{}\\", full);
    paths.retain(|p| p.as_str() != full && !p.starts_with(&with_sep));
}

/// paths 前缀替换（目录改名/移动）：old 开头的路径改写成 new 开头
fn rename_paths_prefix(paths: &mut [String], old_full: &str, new_full: &str) {
    let old_with_sep = format!("{}\\", old_full);
    for p in paths.iter_mut() {
        if p.as_str() == old_full {
            *p = new_full.to_string();
        } else if let Some(tail) = p.strip_prefix(old_with_sep.as_str()) {
            *p = format!("{}\\{}", new_full, tail);
        }
    }
}

/// 删除某卷全部 paths 条目（全量重建前清场）
fn clear_volume_paths(paths: &mut Vec<String>, prefix: &str) {
    let with_sep = format!("{}\\", prefix);
    paths.retain(|p| !p.starts_with(&with_sep));
}

// ==================== 卷级同步 ====================

/// 单卷同步结果
enum VolumeSync {
    /// USN 增量/全量完成
    UsnOk,
    /// 回退到目录遍历（非 NTFS / journal 不可用 / 记录不一致）
    Fallback,
}

fn query_journal(h: *mut c_void) -> Option<UsnJournalData> {
    let mut jd = UsnJournalData {
        usn_journal_id: 0,
        first_usn: 0,
        next_usn: 0,
        minimum_usn: 0,
        maximum_usn: 0,
        maximum_size: 0,
        allocation_delta: 0,
    };
    let mut returned: u32 = 0;
    let ok = unsafe {
        DeviceIoControl(
            h,
            FSCTL_QUERY_USN_JOURNAL,
            null_mut(),
            0,
            &mut jd as *mut _ as *mut c_void,
            std::mem::size_of::<UsnJournalData>() as u32,
            &mut returned,
            null_mut(),
        )
    };
    if ok == 0 || (returned as usize) < std::mem::size_of::<UsnJournalData>() {
        return None;
    }
    Some(jd)
}

/// 全量枚举 journal（首次或 journal 变化时）。
/// 输出缓冲：前 8 字节 = 下一页起始 FileReferenceNumber（前导 USN），
/// 之后是连续的 USN_RECORD 序列（对照微软官方 EnumUsnData 示例：记录从
/// `&Buffer[sizeof(USN)]` 开始，分页起点取 `*(USN*)Buffer`）。
/// 成功返回最后一条记录的 USN（作为下次增量起点）。
fn enum_full(
    h: *mut c_void,
    table: &mut DirTable,
    paths: &mut Vec<String>,
    prefix: &str,
    drive: char,
) -> Option<u64> {
    let mut start_frn: u64 = 0;
    let buf_size: usize = 64 * 1024;
    let mut buf: Vec<u8> = vec![0u8; buf_size];
    let mut last_usn: u64 = 0;
    let mut pending: HashMap<u64, (u64, String)> = HashMap::new();
    let mut rounds = 0;
    loop {
        rounds += 1;
        if rounds > 8192 {
            return None; // journal 异常大/死循环保护
        }
        let input = MftEnumDataV0 {
            start_file_reference_number: start_frn,
            low_usn: 0,
            high_usn: u64::MAX,
        };
        let mut returned: u32 = 0;
        let ok = unsafe {
            DeviceIoControl(
                h,
                FSCTL_ENUM_USN_DATA,
                &input as *const _ as *mut c_void,
                std::mem::size_of::<MftEnumDataV0>() as u32,
                buf.as_mut_ptr() as *mut c_void,
                buf_size as u32,
                &mut returned,
                null_mut(),
            )
        };
        if ok == 0 {
            // 枚举正常读完的标志是 ERROR_HANDLE_EOF（38），不是错误
            let err = unsafe { GetLastError() };
            if err == ERROR_HANDLE_EOF {
                break;
            }
            return None;
        }
        let got = returned as usize;
        if got <= 8 {
            break; // 只有前导 USN、没有记录 = 枚举结束
        }
        // 前 8 字节 = 下一页起始 FileReferenceNumber
        let next_frn = u64::from_le_bytes(
            buf.get(0..8)
                .and_then(|b| b.try_into().ok())
                .unwrap_or([0u8; 8]),
        );
        let mut off = 8usize; // 跳过前导 USN，从第一条记录开始
        while off + USN_RECORD_HEADER_LEN <= got {
            match parse_record(&buf, off) {
                Some((rec_len, frn, parent, reason, attrs, name)) => {
                    if let Some(b) = buf.get(off + 24..off + 32) {
                        last_usn = u64::from_le_bytes(b.try_into().unwrap_or([0; 8]));
                    }
                    match apply_record(
                        table,
                        paths,
                        &mut pending,
                        prefix,
                        drive,
                        (rec_len, frn, parent, reason, attrs, name),
                    ) {
                        ApplyOutcome::Inconsistent => return None,
                        ApplyOutcome::Applied => {
                            USN_CHANGES.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                        }
                    }
                    off += rec_len;
                }
                None => return None, // V3 或损坏 → 回退
            }
        }
        if next_frn <= start_frn {
            break; // 没有进展，防死循环
        }
        start_frn = next_frn;
        if got < buf_size {
            break; // 不满一页，读完了
        }
    }
    Some(last_usn)
}

/// 增量读取 journal（从 start_usn 起）。输出缓冲前 8 字节 = 下次起始 USN。
/// 成功返回新的 next_usn。
fn read_incremental(
    h: *mut c_void,
    start_usn: u64,
    journal_id: u64,
    table: &mut DirTable,
    paths: &mut Vec<String>,
    prefix: &str,
    drive: char,
) -> Option<u64> {
    let buf_size: usize = 64 * 1024;
    let mut buf: Vec<u8> = vec![0u8; buf_size];
    let mut cur = start_usn;
    let mut pending: HashMap<u64, (u64, String)> = HashMap::new();
    let mut rounds = 0;
    loop {
        rounds += 1;
        if rounds > 1024 {
            return None;
        }
        let input = ReadUsnJournalData {
            start_usn: cur,
            reason_mask: REASON_MASK,
            return_only_on_close: 0,
            timeout: 0,
            bytes_to_wait_for: 0,
            usn_journal_id: journal_id,
        };
        let mut returned: u32 = 0;
        let ok = unsafe {
            DeviceIoControl(
                h,
                FSCTL_READ_USN_JOURNAL,
                &input as *const _ as *mut c_void,
                std::mem::size_of::<ReadUsnJournalData>() as u32,
                buf.as_mut_ptr() as *mut c_void,
                buf_size as u32,
                &mut returned,
                null_mut(),
            )
        };
        if ok == 0 {
            // journal 被删/未激活等 → 回退
            return None;
        }
        let got = returned as usize;
        if got < 8 {
            break;
        }
        // READ 输出前 8 字节 = 下次起始 USN
        let next_start = u64::from_le_bytes(buf.get(0..8)?.try_into().ok()?);
        let mut off = 8usize;
        while off + USN_RECORD_HEADER_LEN <= got {
            match parse_record(&buf, off) {
                Some((rec_len, frn, parent, reason, attrs, name)) => {
                    match apply_record(
                        table,
                        paths,
                        &mut pending,
                        prefix,
                        drive,
                        (rec_len, frn, parent, reason, attrs, name),
                    ) {
                        ApplyOutcome::Inconsistent => return None,
                        ApplyOutcome::Applied => {
                            USN_CHANGES.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                        }
                    }
                    off += rec_len;
                }
                None => return None, // V3 → 回退
            }
        }
        if next_start <= cur {
            break; // 无进展，防死循环
        }
        cur = next_start;
        if got < buf_size {
            break;
        }
    }
    Some(cur)
}

/// 同步单个卷：USN 增量优先，任何异常回退目录遍历。
/// 锁顺序固定：USN_STATE → INDEX_PATHS（无反向加锁，不会死错）。
///
/// QUERY_USN_JOURNAL 失败（部分安全软件/沙箱会拦）不直接回退：
/// 仍尝试 ENUM 全量（ENUM 不需要 journal_id），journal_id 记 0（不可增量），
/// 下次 sync 会因 id 不匹配再走全量 ENUM——退化为「每次全量枚举」也远快于目录遍历。
fn sync_volume(root: &str, full_rebuild: bool) -> VolumeSync {
    let drive = match drive_letter(root) {
        Some(c) => c,
        None => return VolumeSync::Fallback,
    };
    if !is_ntfs(drive) {
        return VolumeSync::Fallback;
    }
    let h = match open_volume(drive) {
        Some(h) => h,
        None => return VolumeSync::Fallback,
    };
    // QUERY 失败时用假数据（journal_id=0 表示未知，禁止增量）
    let jd_opt = query_journal(h);
    let fake_jd = UsnJournalData {
        usn_journal_id: 0,
        first_usn: 0,
        next_usn: 0,
        minimum_usn: 0,
        maximum_usn: 0,
        maximum_size: 0,
        allocation_delta: 0,
    };
    let jd_ref: &UsnJournalData = jd_opt.as_ref().unwrap_or(&fake_jd);
    let prefix = root_prefix(root);
    let mut state = lock_or_recover(&USN_STATE);
    let st = state.get_or_insert_with(UsnState::new);
    let mut pg = lock_or_recover(&INDEX_PATHS);
    let paths = match pg.as_mut() {
        Some(v) => v,
        None => {
            drop(pg);
            unsafe { CloseHandle(h) };
            return VolumeSync::Fallback;
        }
    };
    let vol_idx = st.volumes.iter().position(|v| v.root == prefix);
    // 决定增量还是全量：QUERY 失败 / journal ID 变了 / 无记录 / next_usn 越界 → 全量
    let can_incremental = !full_rebuild
        && vol_idx
            .map(|i| {
                let v = &st.volumes[i];
                v.journal_id != 0
                    && v.journal_id == jd_ref.usn_journal_id
                    && v.next_usn >= jd_ref.first_usn
                    && v.next_usn <= jd_ref.next_usn
            })
            .unwrap_or(false);

    let result = if can_incremental {
        let i = vol_idx.unwrap();
        let prev_next = st.volumes[i].next_usn;
        match read_incremental(
            h,
            prev_next,
            jd_ref.usn_journal_id,
            &mut st.table,
            paths,
            &prefix,
            drive,
        ) {
            Some(n) => {
                st.volumes[i].next_usn = n;
                VolumeSync::UsnOk
            }
            None => {
                // 增量失败：清掉该卷状态，走全量重建
                st.volumes.retain(|v| v.root != prefix);
                rebuild_volume_full(h, jd_ref, st, paths, &prefix, drive)
            }
        }
    } else {
        rebuild_volume_full(h, jd_ref, st, paths, &prefix, drive)
    };
    drop(pg);
    unsafe { CloseHandle(h) };
    result
}

/// 全量重建单卷（journal 变化/首次/增量失败）。FRN 跨卷撞号，只清本卷目录。
fn rebuild_volume_full(
    h: *mut c_void,
    jd: &UsnJournalData,
    st: &mut UsnState,
    paths: &mut Vec<String>,
    prefix: &str,
    drive: char,
) -> VolumeSync {
    clear_volume_paths(paths, prefix);
    st.table.retain(|(d, _), _| *d != drive);
    match enum_full(h, &mut st.table, paths, prefix, drive) {
        Some(last_usn) => {
            // 下次从枚举到的最后位置继续；空 journal 时退回 query 到的末尾
            let next = if last_usn > 0 { last_usn } else { jd.next_usn };
            if let Some(v) = st.volumes.iter_mut().find(|v| v.root == *prefix) {
                v.journal_id = jd.usn_journal_id;
                v.next_usn = next;
            } else {
                st.volumes.push(VolumeState {
                    root: prefix.to_string(),
                    journal_id: jd.usn_journal_id,
                    next_usn: next,
                });
            }
            VolumeSync::UsnOk
        }
        None => VolumeSync::Fallback,
    }
}

/// 非 NTFS 卷的兜底：目录遍历合并进 INDEX_PATHS（沿用方案A）
fn fallback_scan(root: &str) {
    let path = PathBuf::from(root);
    if !path.exists() {
        return;
    }
    let (local_paths, _dirs) = scan_roots(&[path]);
    let mut pg = lock_or_recover(&INDEX_PATHS);
    if let Some(v) = pg.as_mut() {
        v.extend(local_paths);
    }
}

// ==================== 对外 FFI ====================

/// USN 增量同步（NTFS 卷走 USN journal，其他卷回退目录遍历）。
/// roots: 卷根列表（如 ["C:\\", "D:\\"]）。返回 INDEX_PATHS 总条数，负数错误。
/// 索引未建立（未 build/load）返回 -3。
#[no_mangle]
pub extern "C" fn usn_sync(roots_ptr: *const *const c_char, num_roots: usize) -> i64 {
    ffi_catch!({
    let mut roots: Vec<String> = Vec::new();
    unsafe {
        if roots_ptr.is_null() {
            return -1;
        }
        let ptrs = std::slice::from_raw_parts(roots_ptr, num_roots);
        for &rp in ptrs {
            let cs = CStr::from_ptr(rp);
            let s = cs.to_string_lossy().to_string();
            if !s.is_empty() {
                roots.push(s);
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
    // 确保 USN 状态已初始化
    {
        let mut st = lock_or_recover(&USN_STATE);
        st.get_or_insert_with(UsnState::new);
    }
    // 待合并 rename 每次 sync 重新配对
    lock_or_recover(&PENDING_RENAMES).clear();

    for root in &roots {
        let drive = match drive_letter(root) {
            Some(c) => c,
            None => continue,
        };
        if !is_ntfs(drive) {
            fallback_scan(root);
            continue;
        }
        if let VolumeSync::Fallback = sync_volume(root, false) {
            fallback_scan(root);
        }
    }
    let g = lock_or_recover(&INDEX_PATHS);
    match g.as_ref() {
        Some(v) => v.len() as i64,
        None => -3,
    }
})
}

/// 全量 USN 重建（journal 变化/索引文件损坏时紧接 index_build 调用）
#[no_mangle]
pub extern "C" fn usn_rebuild(roots_ptr: *const *const c_char, num_roots: usize) -> i64 {
    ffi_catch!({
    // 先清空旧卷状态，强制每卷走 enum_full 全量
    {
        let mut st = lock_or_recover(&USN_STATE);
        if let Some(s) = st.as_mut() {
            s.volumes.clear();
        }
    }
    usn_sync(roots_ptr, num_roots)
})
}

const USN_MAGIC: [u8; 4] = [0x57, 0x4d, 0x55, 0x53]; // "WMUS"

/// 落盘 USN 状态（目录 FRN 表 + 各卷 journal 位置）
#[no_mangle]
pub extern "C" fn usn_table_save(file_ptr: *const c_char) -> i32 {
    ffi_catch!({
    let cpath = unsafe { CStr::from_ptr(file_ptr) };
    let path = cpath.to_string_lossy().to_string();
    let f = match File::create(&path) {
        Ok(f) => f,
        Err(_) => return -2,
    };
    let mut w = BufWriter::new(f);
    let st = lock_or_recover(&USN_STATE);
    let st = match st.as_ref() {
        Some(s) => s,
        None => return -1,
    };
    if w.write_all(&USN_MAGIC).is_err() {
        let _ = w.flush();
        return -3;
    }
    if w.write_all(&1u32.to_le_bytes()).is_err() {
        let _ = w.flush();
        return -3;
    }
    // 卷状态
    if w.write_all(&(st.volumes.len() as u64).to_le_bytes()).is_err() {
        let _ = w.flush();
        return -3;
    }
    for v in &st.volumes {
        let b = v.root.as_bytes();
        if w.write_all(&(b.len() as u32).to_le_bytes()).is_err()
            || w.write_all(b).is_err()
            || w.write_all(&v.journal_id.to_le_bytes()).is_err()
            || w.write_all(&v.next_usn.to_le_bytes()).is_err()
        {
            let _ = w.flush();
            return -3;
        }
    }
    // 目录 FRN 表
    if w.write_all(&(st.table.len() as u64).to_le_bytes()).is_err() {
        let _ = w.flush();
        return -3;
    }
    for ((drive, frn), (parent, name)) in &st.table {
        let nb = name.as_bytes();
        let db = [*drive as u8];
        if w.write_all(&db).is_err()
            || w.write_all(&frn.to_le_bytes()).is_err()
            || w.write_all(&parent.to_le_bytes()).is_err()
            || w.write_all(&(nb.len() as u32).to_le_bytes()).is_err()
            || w.write_all(nb).is_err()
        {
            let _ = w.flush();
            return -3;
        }
    }
    match w.flush() {
        Ok(_) => 0,
        Err(_) => -3,
    }
})
}

/// 从落盘文件恢复 USN 状态（成功返回 0）
#[no_mangle]
pub extern "C" fn usn_table_load(file_ptr: *const c_char) -> i32 {
    ffi_catch!({
    let cpath = unsafe { CStr::from_ptr(file_ptr) };
    let path = cpath.to_string_lossy().to_string();
    let f = match File::open(&path) {
        Ok(f) => f,
        Err(_) => return -2,
    };
    let mut r = BufReader::new(f);
    let mut magic = [0u8; 4];
    if r.read_exact(&mut magic).is_err() || magic != USN_MAGIC {
        return -4;
    }
    let mut ver = [0u8; 4];
    if r.read_exact(&mut ver).is_err() {
        return -4;
    }
    let mut nbuf = [0u8; 8];
    // 卷状态
    if r.read_exact(&mut nbuf).is_err() {
        return -4;
    }
    let vc = u64::from_le_bytes(nbuf);
    let mut volumes = Vec::with_capacity(vc as usize);
    for _ in 0..vc {
        let mut lb = [0u8; 4];
        if r.read_exact(&mut lb).is_err() {
            return -4;
        }
        let l = u32::from_le_bytes(lb) as usize;
        let mut buf = vec![0u8; l];
        if r.read_exact(&mut buf).is_err() {
            return -4;
        }
        let root = String::from_utf8_lossy(&buf).into_owned();
        let mut u8b = [0u8; 8];
        if r.read_exact(&mut u8b).is_err() {
            return -4;
        }
        let journal_id = u64::from_le_bytes(u8b);
        if r.read_exact(&mut u8b).is_err() {
            return -4;
        }
        let next_usn = u64::from_le_bytes(u8b);
        volumes.push(VolumeState {
            root,
            journal_id,
            next_usn,
        });
    }
    // 目录 FRN 表
    if r.read_exact(&mut nbuf).is_err() {
        return -4;
    }
    let tc = u64::from_le_bytes(nbuf);
    let mut table: DirTable = HashMap::with_capacity(tc as usize);
    for _ in 0..tc {
        let mut db = [0u8; 1];
        if r.read_exact(&mut db).is_err() {
            return -4;
        }
        let drive = db[0] as char;
        let mut u8b = [0u8; 8];
        if r.read_exact(&mut u8b).is_err() {
            return -4;
        }
        let frn = u64::from_le_bytes(u8b);
        if r.read_exact(&mut u8b).is_err() {
            return -4;
        }
        let parent = u64::from_le_bytes(u8b);
        let mut lb = [0u8; 4];
        if r.read_exact(&mut lb).is_err() {
            return -4;
        }
        let l = u32::from_le_bytes(lb) as usize;
        let mut buf = vec![0u8; l];
        if r.read_exact(&mut buf).is_err() {
            return -4;
        }
        let name = String::from_utf8_lossy(&buf).into_owned();
        table.insert((drive, frn), (parent, name));
    }
    *lock_or_recover(&USN_STATE) = Some(UsnState { table, volumes });
    0
})
}

/// 当前是否具备 USN 索引状态（已 load 或已 sync）
#[no_mangle]
pub extern "C" fn usn_table_ready() -> i32 {
    ffi_catch!({
    let st = lock_or_recover(&USN_STATE);
    match st.as_ref() {
        Some(s) if !s.table.is_empty() || !s.volumes.is_empty() => 1,
        _ => 0,
    }
})
}

/// 已应用的 USN 记录累计数（sync 前后取差值即本次变更量）
#[no_mangle]
pub extern "C" fn usn_changes() -> u64 {
    ffi_catch!({
    USN_CHANGES.load(std::sync::atomic::Ordering::Relaxed)
})
}

/// 释放 USN 状态内存
#[no_mangle]
pub extern "C" fn usn_table_free() {
    ffi_catch!({
    *lock_or_recover(&USN_STATE) = None;
    lock_or_recover(&PENDING_RENAMES).clear();
})
}

/// 卷是否为 NTFS 且 USN journal 可用（Dart 侧展示索引模式用）
#[no_mangle]
pub extern "C" fn usn_volume_supported(root_ptr: *const c_char) -> i32 {
    ffi_catch!({
    let croot = unsafe { CStr::from_ptr(root_ptr) };
    let root = croot.to_string_lossy().to_string();
    let drive = match drive_letter(&root) {
        Some(c) => c,
        None => return 0,
    };
    if !is_ntfs(drive) {
        return 0;
    }
    let h = match open_volume(drive) {
        Some(h) => h,
        None => return 0,
    };
    let ok = query_journal(h).is_some();
    unsafe { CloseHandle(h) };
    if ok {
        1
    } else {
        0
    }
})
}

// ==================== 单元测试（纯逻辑，无需真实卷） ====================

#[cfg(test)]
mod tests {
    use super::*;

    fn p() -> String {
        "C:\\".to_string()
    }

    #[test]
    fn test_parse_record_v2() {
        // 手工构造一条 V2 USN_RECORD：create 目录 "Users"，parent=5
        let name: Vec<u16> = "Users".encode_utf16().collect();
        let name_bytes: Vec<u8> = name.iter().flat_map(|c| c.to_le_bytes()).collect();
        let rec_len = USN_RECORD_HEADER_LEN + name_bytes.len();
        let mut buf = vec![0u8; rec_len];
        buf[0..4].copy_from_slice(&(rec_len as u32).to_le_bytes());
        buf[4..6].copy_from_slice(&2u16.to_le_bytes()); // MajorVersion
        buf[6..8].copy_from_slice(&0u16.to_le_bytes());
        buf[8..16].copy_from_slice(&123u64.to_le_bytes()); // FRN
        buf[16..24].copy_from_slice(&ROOT_FRN.to_le_bytes()); // parent
        buf[24..32].copy_from_slice(&999u64.to_le_bytes()); // USN
        buf[40..44].copy_from_slice(&0x0000_0100u32.to_le_bytes()); // FILE_CREATE
        buf[52..56].copy_from_slice(&FILE_ATTRIBUTE_DIRECTORY.to_le_bytes());
        buf[56..58].copy_from_slice(&(name_bytes.len() as u16).to_le_bytes());
        buf[58..60].copy_from_slice(&(USN_RECORD_HEADER_LEN as u16).to_le_bytes());
        buf[USN_RECORD_HEADER_LEN..].copy_from_slice(&name_bytes);

        let (len, frn, parent, reason, attrs, n) = parse_record(&buf, 0).unwrap();
        assert_eq!(len, rec_len);
        assert_eq!(frn, 123);
        assert_eq!(parent, ROOT_FRN);
        assert_eq!(reason, 0x0000_0100);
        assert!(attrs & FILE_ATTRIBUTE_DIRECTORY != 0);
        assert_eq!(n, "Users");
    }

    #[test]
    fn test_parse_record_v3_rejected() {
        let mut buf = vec![0u8; 128];
        buf[0..4].copy_from_slice(&128u32.to_le_bytes());
        buf[4..6].copy_from_slice(&3u16.to_le_bytes()); // V3
        assert!(parse_record(&buf, 0).is_none());
    }

    #[test]
    fn test_apply_create_dir_and_file() {
        let mut table = DirTable::new();
        let mut paths: Vec<String> = Vec::new();
        let mut pending = HashMap::new();

        let r = apply_record(
            &mut table,
            &mut paths,
            &mut pending,
            &p(),
            'C',
            (0, 100, ROOT_FRN, 0x0000_0100, FILE_ATTRIBUTE_DIRECTORY, "Users".into()),
        );
        assert!(matches!(r, ApplyOutcome::Applied));
        assert_eq!(paths, vec!["C:\\Users".to_string()]);
        assert!(table.contains_key(&('C', 100)));

        let r = apply_record(
            &mut table,
            &mut paths,
            &mut pending,
            &p(),
            'C',
            (0, 200, 100, 0x0000_0100, 0, "a.txt".into()),
        );
        assert!(matches!(r, ApplyOutcome::Applied));
        assert_eq!(paths.len(), 2);
        assert_eq!(paths[1], "C:\\Users\\a.txt");
    }

    #[test]
    fn test_apply_delete_dir_subtree() {
        let mut table = DirTable::new();
        let mut paths: Vec<String> = Vec::new();
        let mut pending = HashMap::new();
        apply_record(&mut table, &mut paths, &mut pending, &p(), 'C',
            (0, 100, ROOT_FRN, 0x100, FILE_ATTRIBUTE_DIRECTORY, "Users".into()));
        apply_record(&mut table, &mut paths, &mut pending, &p(), 'C',
            (0, 110, 100, 0x100, FILE_ATTRIBUTE_DIRECTORY, "Docs".into()));
        apply_record(&mut table, &mut paths, &mut pending, &p(), 'C',
            (0, 200, 110, 0x100, 0, "b.txt".into()));
        assert_eq!(paths.len(), 3);

        // 删除目录 Users → 子树全清
        let r = apply_record(
            &mut table, &mut paths, &mut pending, &p(), 'C',
            (0, 100, ROOT_FRN, 0x200, FILE_ATTRIBUTE_DIRECTORY, "Users".into()),
        );
        assert!(matches!(r, ApplyOutcome::Applied));
        assert!(paths.is_empty());
        assert!(!table.contains_key(&('C', 100)));
        assert!(!table.contains_key(&('C', 110)));
    }

    #[test]
    fn test_apply_rename_dir_prefix() {
        let mut table = DirTable::new();
        let mut paths: Vec<String> = Vec::new();
        let mut pending = HashMap::new();
        apply_record(&mut table, &mut paths, &mut pending, &p(), 'C',
            (0, 100, ROOT_FRN, 0x100, FILE_ATTRIBUTE_DIRECTORY, "Users".into()));
        apply_record(&mut table, &mut paths, &mut pending, &p(), 'C',
            (0, 200, 100, 0x100, 0, "a.txt".into()));
        assert_eq!(paths, vec!["C:\\Users".to_string(), "C:\\Users\\a.txt".to_string()]);

        // rename Users → 用户（OLD 先 NEW 后）
        apply_record(&mut table, &mut paths, &mut pending, &p(), 'C',
            (0, 100, ROOT_FRN, 0x1000, FILE_ATTRIBUTE_DIRECTORY, "Users".into()));
        apply_record(&mut table, &mut paths, &mut pending, &p(), 'C',
            (0, 100, ROOT_FRN, 0x2000, FILE_ATTRIBUTE_DIRECTORY, "用户".into()));
        assert_eq!(paths, vec!["C:\\用户".to_string(), "C:\\用户\\a.txt".to_string()]);
        assert_eq!(table.get(&('C', 100)).unwrap().1, "用户");
    }

    #[test]
    fn test_apply_rename_file() {
        let mut table = DirTable::new();
        let mut paths: Vec<String> = Vec::new();
        let mut pending = HashMap::new();
        apply_record(&mut table, &mut paths, &mut pending, &p(), 'C',
            (0, 100, ROOT_FRN, 0x100, FILE_ATTRIBUTE_DIRECTORY, "Users".into()));
        apply_record(&mut table, &mut paths, &mut pending, &p(), 'C',
            (0, 200, 100, 0x100, 0, "a.txt".into()));
        // 文件改名 a.txt → b.txt
        apply_record(&mut table, &mut paths, &mut pending, &p(), 'C',
            (0, 200, 100, 0x1000, 0, "a.txt".into()));
        apply_record(&mut table, &mut paths, &mut pending, &p(), 'C',
            (0, 200, 100, 0x2000, 0, "b.txt".into()));
        assert_eq!(paths, vec!["C:\\Users".to_string(), "C:\\Users\\b.txt".to_string()]);
    }

    #[test]
    fn test_cross_volume_same_frn_isolated() {
        // C: 和 D: 同时存在 FRN=100 的目录，互不覆盖
        let mut table = DirTable::new();
        let mut paths: Vec<String> = Vec::new();
        let mut pending = HashMap::new();
        apply_record(&mut table, &mut paths, &mut pending, &p(), 'C',
            (0, 100, ROOT_FRN, 0x100, FILE_ATTRIBUTE_DIRECTORY, "c_dir".into()));
        apply_record(&mut table, &mut paths, &mut pending, "D:\\", 'D',
            (0, 100, ROOT_FRN, 0x100, FILE_ATTRIBUTE_DIRECTORY, "d_dir".into()));
        assert_eq!(table.len(), 2);
        assert_eq!(table.get(&('C', 100)).unwrap().1, "c_dir");
        assert_eq!(table.get(&('D', 100)).unwrap().1, "d_dir");
        assert_eq!(paths, vec!["C:\\c_dir".to_string(), "D:\\d_dir".to_string()]);
        // 删 C: 的子树不动 D:
        remove_subtree(&mut table, 'C', 100);
        assert!(table.contains_key(&('D', 100)));
    }

    #[test]
    fn test_inconsistent_when_parent_unknown() {
        let mut table = DirTable::new();
        let mut paths: Vec<String> = Vec::new();
        let mut pending = HashMap::new();
        // 父 999 不在表里 → Inconsistent
        let r = apply_record(
            &mut table, &mut paths, &mut pending, &p(), 'C',
            (0, 200, 999, 0x100, 0, "x.txt".into()),
        );
        assert!(matches!(r, ApplyOutcome::Inconsistent));
    }

    #[test]
    fn test_remove_paths_prefix() {
        let mut paths = vec![
            "C:\\Users".to_string(),
            "C:\\Users\\a.txt".to_string(),
            "C:\\UsersX".to_string(),
            "C:\\Windows\\x".to_string(),
        ];
        remove_paths_prefix(&mut paths, "C:\\Users");
        assert_eq!(paths, vec!["C:\\UsersX".to_string(), "C:\\Windows\\x".to_string()]);
    }

    #[test]
    fn test_rename_paths_prefix() {
        let mut paths = vec![
            "C:\\Users".to_string(),
            "C:\\Users\\a.txt".to_string(),
            "C:\\UsersX".to_string(),
        ];
        rename_paths_prefix(&mut paths, "C:\\Users", "C:\\U");
        assert_eq!(paths[0], "C:\\U");
        assert_eq!(paths[1], "C:\\U\\a.txt");
        assert_eq!(paths[2], "C:\\UsersX"); // 不受影响
    }

    #[test]
    fn test_dir_path_cycle_guard() {
        let mut table = DirTable::new();
        // 成环：100 的 parent 是 101，101 的 parent 是 100
        table.insert(('C', 100), (101, "a".into()));
        table.insert(('C', 101), (100, "b".into()));
        assert!(dir_path(&table, 'C', 100).is_none());
    }

    #[test]
    fn test_drive_letter() {
        assert_eq!(drive_letter("C:\\"), Some('C'));
        assert_eq!(drive_letter("d:"), Some('D'));
        assert_eq!(drive_letter("/home"), None);
    }

    #[test]
    fn test_from_wide() {
        let bytes: Vec<u8> = "测试.txt".encode_utf16().flat_map(|c| c.to_le_bytes()).collect();
        assert_eq!(from_wide(&bytes), "测试.txt");
        // 带尾随 \0
        let mut b2 = bytes.clone();
        b2.extend_from_slice(&0u16.to_le_bytes());
        assert_eq!(from_wide(&b2), "测试.txt");
    }

    #[test]
    fn test_remove_subtree_multi_level() {
        let mut table = DirTable::new();
        // C:\a\b\c 三层
        table.insert(('C', 100), (ROOT_FRN, "a".into()));
        table.insert(('C', 110), (100, "b".into()));
        table.insert(('C', 120), (110, "c".into()));
        remove_subtree(&mut table, 'C', 100);
        assert!(table.is_empty());
    }
}
