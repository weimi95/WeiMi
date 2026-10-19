//! 传输链路集成测试：httpd 接收 ↔ sender 发送，协议字段对照主程序 Dart 实现。
//!
//! 覆盖：
//! 1. send_file → 落盘 sha 与源一致（含中文文件名）
//! 2. 重名自动加 (n)
//! 3. 接收关闭 → 503（发送侧文案）
//! 4. 非微密 App（magic 不符）→ 403
//! 5. announce/reply JSON 字段与 Dart 侧一致（app/action/id/name/httpPort/v）
//! 6. percent 编解码 round-trip

use std::io::Write;
use std::sync::Arc;

use weimi_legacy_lib::httpd::{self, NoopNotifier, RecvEvent};
use weimi_legacy_lib::proto::{self, Identity, Peer, DISCOVERY_PORT, MAGIC, PROTO_VERSION};

fn temp_dir(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("weimi_legacy_test_{tag}"));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn start_test_server(dir: &std::path::Path) -> (httpd::HttpServer, Arc<std::sync::Mutex<httpd::RecvState>>, std::sync::mpsc::Receiver<RecvEvent>) {
    let (server, state, rx) = httpd::HttpServer::start(Arc::new(NoopNotifier)).expect("start httpd");
    state.lock().unwrap().recv_dir = dir.to_path_buf();
    (server, state, rx)
}

/// 等一条 Done 事件（带超时）
fn wait_done(rx: &std::sync::mpsc::Receiver<RecvEvent>) -> RecvEvent {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
    while std::time::Instant::now() < deadline {
        if let Ok(ev) = rx.recv_timeout(std::time::Duration::from_secs(1)) {
            if matches!(ev, RecvEvent::Done { .. }) {
                return ev;
            }
        }
    }
    panic!("timeout waiting for Done event");
}

#[test]
fn send_file_lands_byte_identical() {
    let dir = temp_dir("send_file");
    let (server, _state, rx) = start_test_server(&dir);

    let src = dir.join("src.bin");
    let mut f = std::fs::File::create(&src).unwrap();
    let payload: Vec<u8> = (0..512 * 1024u32).map(|i| (i % 251) as u8).collect();
    f.write_all(&payload).unwrap();
    drop(f);

    let identity = Identity {
        id: "test-sender".into(),
        name: "测试发送端".into(),
    };
    httpd::send_file(
        "127.0.0.1",
        server.port,
        &src,
        &identity.id,
        &identity.name,
        &mut |_, _| {},
    )
    .expect("send_file");

    let ev = wait_done(&rx);
    let RecvEvent::Done { path, size, .. } = ev else {
        panic!("expected Done");
    };
    assert_eq!(size, payload.len() as u64);
    let got = std::fs::read(&path).unwrap();
    assert_eq!(got, payload, "received bytes must be identical");
}

#[test]
fn send_file_chinese_name() {
    let dir = temp_dir("send_cn");
    let src_dir = dir.join("src");
    let recv_dir = dir.join("recv");
    std::fs::create_dir_all(&src_dir).unwrap();
    std::fs::create_dir_all(&recv_dir).unwrap();
    let (server, _state, rx) = start_test_server(&recv_dir);

    let src = src_dir.join("中文 文件.txt");
    std::fs::write(&src, "中文内容测试".as_bytes()).unwrap();

    let identity = Identity {
        id: "test-sender".into(),
        name: "测试".into(),
    };
    httpd::send_file(
        "127.0.0.1",
        server.port,
        &src,
        &identity.id,
        &identity.name,
        &mut |_, _| {},
    )
    .expect("send_file");

    let ev = wait_done(&rx);
    let RecvEvent::Done { path, .. } = ev else {
        panic!("expected Done");
    };
    assert_eq!(
        path.file_name().unwrap().to_string_lossy(),
        "中文 文件.txt"
    );
    assert_eq!(std::fs::read(&path).unwrap(), "中文内容测试".as_bytes());
}

#[test]
fn duplicate_name_gets_suffix() {
    let dir = temp_dir("dup");
    let (server, _state, rx) = start_test_server(&dir);

    let identity = Identity {
        id: "test-sender".into(),
        name: "测试".into(),
    };
    for _ in 0..2 {
        let src = dir.join("dup.txt");
        std::fs::write(&src, b"same name").unwrap();
        httpd::send_file(
            "127.0.0.1",
            server.port,
            &src,
            &identity.id,
            &identity.name,
            &mut |_, _| {},
        )
        .expect("send_file");
    }
    // 两个 Done 事件，文件名应不同
    let mut names = Vec::new();
    for _ in 0..2 {
        let ev = wait_done(&rx);
        if let RecvEvent::Done { path, .. } = ev {
            names.push(path.file_name().unwrap().to_string_lossy().into_owned());
        }
    }
    assert_eq!(names.len(), 2);
    assert_ne!(names[0], names[1], "duplicate names must be deduped");
    assert!(
        names.iter().any(|n| n.contains("(1)")),
        "expected (1) suffix, got {names:?}"
    );
}

#[test]
fn receiving_off_returns_503() {
    let dir = temp_dir("off");
    let (server, state, _rx) = start_test_server(&dir);
    state.lock().unwrap().set_receiving(false);

    let src = dir.join("x.txt");
    std::fs::write(&src, b"x").unwrap();
    let r = httpd::send_file(
        "127.0.0.1",
        server.port,
        &src,
        "test-sender",
        "测试",
        &mut |_, _| {},
    );
    let msg = r.unwrap_err();
    assert!(msg.contains("503"), "expected 503 in error, got: {msg}");
}

#[test]
fn wrong_app_magic_returns_403() {
    let dir = temp_dir("magic");
    let (server, _state, _rx) = start_test_server(&dir);

    // 裸 TCP 手写请求，X-Weimi-App 用错 magic
    use std::io::{Read, Write};
    let mut s = std::net::TcpStream::connect(format!("127.0.0.1:{}", server.port)).unwrap();
    let body = b"hello";
    let head = format!(
        "POST /weimi/send HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: {}\r\nX-Weimi-App: not-weimi\r\nX-Sender-Id: x\r\nX-Sender-Name: x\r\nX-File-Name: a.txt\r\nX-File-Size: {}\r\nConnection: close\r\n\r\n",
        body.len(),
        body.len()
    );
    s.write_all(head.as_bytes()).unwrap();
    s.write_all(body).unwrap();
    let mut resp = String::new();
    let _ = s.read_to_string(&mut resp);
    assert!(resp.contains("403"), "expected 403, got: {resp}");
}

#[test]
fn text_send_lands() {
    let dir = temp_dir("text");
    let (server, _state, rx) = start_test_server(&dir);

    httpd::send_text("127.0.0.1", server.port, "你好，飞传", "test-sender", "测试")
        .expect("send_text");
    let ev = wait_done(&rx);
    let RecvEvent::Done { path, .. } = ev else {
        panic!("expected Done");
    };
    let content = std::fs::read_to_string(&path).unwrap();
    // 协议设计：文本消息带来源前缀（与主程序 Dart 一致）
    assert!(content.contains("你好，飞传"), "got: {content}");
    assert!(content.starts_with("[来自: 测试]"), "got: {content}");
}

#[test]
fn announce_json_matches_dart_fields() {
    // 与主程序 lan_transfer_service.dart 的 announce/reply JSON 逐字段对照：
    // {"app":MAGIC,"action":"announce|reply","id":..,"name":..,"httpPort":..,"v":PROTO_VERSION}
    let identity = Identity {
        id: "id-123".into(),
        name: "经典版测试".into(),
    };
    let json = proto::build_announce(&identity, 52345, "announce");
    let v: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert_eq!(v["app"], MAGIC);
    assert_eq!(v["action"], "announce");
    assert_eq!(v["id"], "id-123");
    assert_eq!(v["name"], "经典版测试");
    assert_eq!(v["httpPort"], 52345);
    assert_eq!(v["v"], PROTO_VERSION as u64);

    let reply = proto::build_announce(&identity, 52346, "reply");
    let v2: serde_json::Value = serde_json::from_str(&reply).unwrap();
    assert_eq!(v2["action"], "reply");

    // 常量与 Dart 一致
    assert_eq!(DISCOVERY_PORT, 52346);
    assert_eq!(proto::DEFAULT_HTTP_PORT, 52345);
    assert_eq!(proto::MAX_HTTP_PORT, 52365);
}

#[test]
fn percent_roundtrip() {
    let raw = "中文 文件名 (1).txt";
    let enc = proto::percent_encode(raw);
    assert!(!enc.contains(' '), "space must be encoded");
    let dec = proto::percent_decode(&enc);
    assert_eq!(dec, raw);
}

#[test]
fn safe_file_name_matches_dart() {
    // 与 Dart _safeFileName 行为逐条对齐：
    // 含 '/' → 分段、过滤 ./..、段内坏字符换 '_'、保留相对子目录
    assert_eq!(proto::safe_file_name("../../etc/passwd"), "etc/passwd");
    assert_eq!(proto::safe_file_name("a/b/c.txt"), "a/b/c.txt");
    assert_eq!(proto::safe_file_name("/"), "unnamed");
    // 不含 '/' → 坏字符换 '_'（Dart 对裸 ".." 同样原样返回，逃逸防护在 httpd 层）
    assert_eq!(proto::safe_file_name(".."), "..");
    assert_eq!(proto::safe_file_name("a\\b\\c.txt"), "a_b_c.txt");
    assert_eq!(proto::safe_file_name("a:b*c?.txt"), "a_b_c_.txt");
    assert_eq!(proto::safe_file_name("普通文件.txt"), "普通文件.txt");
}

#[test]
fn dotdot_filename_cannot_escape() {
    // httpd 层防逃逸：X-File-Name 为 ".." 时落盘路径必须仍在接收目录内
    // （Rust Path 的 file_name() 对 ".." 返 None，天然拼不出上级路径；
    //   starts_with 兜底双保险）
    let dir = temp_dir("dotdot");
    let (server, _state, rx) = start_test_server(&dir);

    use std::io::{Read, Write};
    let mut s = std::net::TcpStream::connect(format!("127.0.0.1:{}", server.port)).unwrap();
    let body = b"evil";
    let head = format!(
        "POST /weimi/send HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: {}\r\nX-Weimi-App: weimi\r\nX-Sender-Id: x\r\nX-Sender-Name: x\r\nX-File-Name: ..\r\nX-File-Size: {}\r\nConnection: close\r\n\r\n",
        body.len(),
        body.len()
    );
    s.write_all(head.as_bytes()).unwrap();
    s.write_all(body).unwrap();
    let mut resp = String::new();
    let _ = s.read_to_string(&mut resp);

    // 无论 200 还是 4xx，都不允许逃逸：等 Done 事件验证路径
    if resp.contains("200") {
        let ev = wait_done(&rx);
        if let RecvEvent::Done { path, .. } = ev {
            assert!(
                path.starts_with(&dir),
                "escaped receive dir: {}",
                path.display()
            );
        }
    }
}

#[test]
fn peer_pruning_by_last_seen() {
    // Peer 的 TTL 逻辑由 discovery 内部持有，这里验证 Peer 结构字段可用
    let p = Peer {
        id: "p1".into(),
        name: "设备1".into(),
        ip: "192.168.1.10".into(),
        http_port: 52345,
        last_seen: std::time::Instant::now(),
    };
    assert!(p.last_seen.elapsed() < std::time::Duration::from_secs(1));
}
