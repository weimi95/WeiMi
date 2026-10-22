//! FFI 端到端复现（v1.2.13）：index_build → search → save → free → load → search。
//! 本地无法跑 Flutter，用本测试验证 Dart 侧链路假设：
//! 索引全链路正常时 index_search2 必须能搜到刚建的文件；
//! free 后不 load 直接 search 应返回 -1（Dart 视为空结果）——
//! 这就是「_cachedCount 有值但 Rust INDEX_PATHS 已空」的复现路径。

use rust_crypto::*;
use std::ffi::CString;

fn cstr(s: &str) -> CString {
    CString::new(s).unwrap()
}

/// 走完整 FFI 协议搜一次，返回 (rc, 结果行数)
fn ffi_search(q: &str, flags: u32) -> (i32, Vec<String>) {
    let query = cstr(q);
    let mut len: usize = 0;
    let rc = index_search2(query.as_ptr(), 300, flags, std::ptr::null_mut(), &mut len);
    if rc != 0 || len == 0 {
        return (rc, vec![]);
    }
    let mut buf = vec![0u8; len];
    let mut len2 = len;
    let rc2 = index_search2(query.as_ptr(), 300, flags, buf.as_mut_ptr(), &mut len2);
    if rc2 != 0 {
        return (rc2, vec![]);
    }
    let text = String::from_utf8_lossy(&buf[..len2]).to_string();
    (0, text.split('\n').filter(|s| !s.is_empty()).map(String::from).collect())
}

#[test]
fn e2e_build_search_save_free_load_search() {
    // 造一个小索引根
    let dir = std::env::temp_dir().join("weimi_e2e_idx");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("sub")).unwrap();
    std::fs::write(dir.join("weimi_test.txt"), "x").unwrap();
    std::fs::write(dir.join("sub").join("报告.pdf"), "x").unwrap();
    let root = dir.to_str().unwrap().to_string();

    // 1) build
    let root_c = cstr(&root);
    let roots = [root_c.as_ptr()];
    let n = index_build(roots.as_ptr(), roots.len());
    assert!(n >= 2, "index_build returned {n}");
    assert!(index_count() >= 2);

    // 2) 普通查询（Dart 默认 flags=1：拼音开）
    let (rc, hits) = ffi_search("weimi", 1);
    assert_eq!(rc, 0, "search rc={rc}");
    assert!(
        hits.iter().any(|h| h.contains("weimi_test.txt")),
        "ascii query missed: {hits:?}"
    );
    // 中文查询（文件名含汉字）
    let (rc2, hits2) = ffi_search("报告", 1);
    assert_eq!(rc2, 0);
    assert!(hits2.iter().any(|h| h.contains("报告.pdf")), "han query missed: {hits2:?}");

    // 3) save → free → search（应 -1，模拟 Dart 认为已就绪但 Rust 已空）
    let bin = std::env::temp_dir().join("weimi_e2e_idx.bin");
    let bin_c = cstr(bin.to_str().unwrap());
    assert_eq!(index_save(bin_c.as_ptr()), 0);
    index_free();
    assert_eq!(index_count(), -1, "after free count should be -1");
    let (rc3, _) = ffi_search("weimi", 1);
    assert_eq!(rc3, -1, "search after free should be -1, got {rc3}");

    // 4) load → search 恢复
    assert_eq!(index_load(bin_c.as_ptr()), 0);
    assert!(index_count() >= 2, "count after load = {}", index_count());
    let (rc4, hits4) = ffi_search("weimi", 1);
    assert_eq!(rc4, 0);
    assert!(hits4.iter().any(|h| h.contains("weimi_test.txt")), "after load missed: {hits4:?}");

    // 5) 通配符 / ext 宏 / OR 语法抽查
    let (_, h5) = ffi_search("*.txt", 1);
    assert!(h5.iter().any(|h| h.contains("weimi_test.txt")), "wildcard missed: {h5:?}");
    let (_, h6) = ffi_search("doc:", 1);
    assert!(h6.iter().any(|h| h.contains("报告.pdf")), "macro missed: {h6:?}");

    index_free();
    let _ = std::fs::remove_dir_all(&dir);
    let _ = std::fs::remove_file(&bin);
}
