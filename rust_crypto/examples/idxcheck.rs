// 索引体检：读落盘 disk_index.bin，搜关键词打印命中（验证真文件是否在索引里）
use std::ffi::CString;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let path = args
        .get(1)
        .cloned()
        .unwrap_or_else(|| r"F:\Tools\weimi\data\disk_index.bin".to_string());
    let query = args.get(2).cloned().unwrap_or_else(|| "v1.2.20".to_string());
    let limit: usize = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(200);

    let cpath = CString::new(path.clone()).unwrap();
    let rc = rust_crypto::index_load(cpath.as_ptr());
    println!("index_load({}) rc={}", path, rc);
    if rc != 0 {
        return;
    }
    let total = rust_crypto::index_count();
    println!("total entries = {} (cap 1000000)", total);
    let cq = CString::new(query.clone()).unwrap();
    let mut len: usize = 0;
    let rc = unsafe {
        rust_crypto::index_search(cq.as_ptr(), limit, std::ptr::null_mut(), &mut len)
    };
    println!("search '{}' rc={} bytes={}", query, rc, len);
    if rc != 0 || len == 0 {
        return;
    }
    let mut buf = vec![0u8; len];
    let rc = unsafe {
        rust_crypto::index_search(cq.as_ptr(), limit, buf.as_mut_ptr(), &mut len)
    };
    if rc != 0 {
        return;
    }
    let s = String::from_utf8_lossy(&buf[..len]).to_string();
    let lines: Vec<&str> = s.lines().collect();
    println!("hits = {}", lines.len());
    for l in &lines {
        println!("{}", l);
    }
}
