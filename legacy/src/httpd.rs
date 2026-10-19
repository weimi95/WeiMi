//! HTTP 接收服务：TcpListener 手写 HTTP/1.1 最小实现。
//! 端点对齐主程序：POST /weimi/send（文件）、POST /weimi/text（文本）。
//! 纯 std，无第三方 HTTP 框架——经典版从简，XP 兼容。

use std::fs::File;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread;

use native_windows_gui::NoticeSender;

use crate::proto::{dedup_path, default_recv_dir, percent_decode, safe_file_name};

/// 接收事件（GUI 线程通过 channel 收）
#[derive(Debug, Clone)]
pub enum RecvEvent {
    Started {
        name: String,
        from: String,
        size: u64,
    },
    Progress {
        name: String,
        received: u64,
        total: u64,
    },
    Done {
        name: String,
        from: String,
        path: PathBuf,
        size: u64,
    },
    Failed {
        name: String,
        from: String,
        error: String,
    },
    Rejected {
        name: String,
        from: String,
    },
}

pub struct HttpServer {
    pub port: u16,
    _handle: thread::JoinHandle<()>,
}

/// 端口探测：52345 起，被占用自动 +1（最多到 52365，对齐主程序）
pub fn bind_first_available() -> Option<(TcpListener, u16)> {
    for port in crate::proto::DEFAULT_HTTP_PORT..=crate::proto::MAX_HTTP_PORT {
        if let Ok(l) = TcpListener::bind(format!("0.0.0.0:{port}")) {
            return Some((l, port));
        }
    }
    None
}

/// 接收服务可调状态（GUI 的接收开关/目录设置通过它改）
pub struct RecvState {
    pub receiving: bool,
    pub recv_dir: PathBuf,
}

impl RecvState {
    pub fn set_receiving(&mut self, v: bool) {
        self.receiving = v;
    }
}

/// GUI 唤醒抽象：GUI 传 NWG NoticeSender，测试传 Noop。
/// 独立成 trait 是为了让 httpd/discovery 不直接依赖 NWG 类型（测试可构造）。
pub trait Notifier: Send + Sync {
    fn notify(&self);
}

impl Notifier for NoticeSender {
    fn notify(&self) {
        NoticeSender::notice(self);
    }
}

pub struct NoopNotifier;
impl Notifier for NoopNotifier {
    fn notify(&self) {}
}

impl HttpServer {
    /// 启动接收服务。每处理完一个文件/文本推一条事件并 notify 一次（唤醒 GUI 刷新）。
    /// receiving 初始为 true；调用方可用返回的 Arc<Mutex<..>> 改开关。
    pub fn start(
        notice: Arc<dyn Notifier>,
    ) -> std::io::Result<(Self, Arc<Mutex<RecvState>>, Receiver<RecvEvent>)> {
        let (tx, rx) = channel();
        let (listener, port) = match bind_first_available() {
            Some(v) => v,
            None => {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::AddrInUse,
                    "52345-52365 全部被占用",
                ))
            }
        };
        let state = Arc::new(Mutex::new(RecvState {
            receiving: true,
            recv_dir: default_recv_dir(),
        }));
        let state_clone = state.clone();

        let handle = thread::spawn(move || {
            for stream in listener.incoming() {
                match stream {
                    Ok(s) => {
                        let st = state_clone.clone();
                        let ev = tx.clone();
                        let nt = notice.clone();
                        thread::spawn(move || {
                            let _ = handle_conn(s, &st, &ev);
                            nt.notify();
                        });
                    }
                    Err(_) => continue,
                }
            }
        });

        Ok((HttpServer { port, _handle: handle }, state, rx))
    }
}

fn handle_conn(mut stream: TcpStream, state: &Arc<Mutex<RecvState>>, ev: &Sender<RecvEvent>) -> std::io::Result<()> {
    stream.set_nodelay(true).ok();
    let mut reader = BufReader::new(stream.try_clone()?);

    // 读请求行 + 头
    let mut request_line = String::new();
    reader.read_line(&mut request_line)?;
    let parts: Vec<&str> = request_line.trim().split_whitespace().collect();
    if parts.len() < 2 {
        return Ok(());
    }
    let method = parts[0].to_uppercase();
    let path = parts[1].to_string();

    let mut headers: Vec<(String, String)> = Vec::new();
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line)? == 0 {
            break;
        }
        let t = line.trim_end_matches(['\r', '\n']).to_string();
        if t.is_empty() {
            break;
        }
        if let Some(idx) = t.find(':') {
            headers.push((
                t[..idx].trim().to_lowercase(),
                t[idx + 1..].trim().to_string(),
            ));
        }
    }
    let header = |name: &str| -> Option<String> {
        headers
            .iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.clone())
    };

    let respond = |stream: &mut TcpStream, code: u16, body: &str| {
        let reason = match code {
            200 => "OK",
            403 => "Forbidden",
            404 => "Not Found",
            500 => "Internal Server Error",
            503 => "Service Unavailable",
            _ => "Error",
        };
        let _ = write!(stream, "HTTP/1.1 {code} {reason}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
        let _ = stream.flush();
    };

    if method != "POST" {
        respond(&mut stream, 404, "{\"ok\":false}");
        return Ok(());
    }

    let (receiving, recv_dir) = {
        let st = state.lock().unwrap();
        (st.receiving, st.recv_dir.clone())
    };
    if !receiving {
        let fname = safe_file_name(&percent_decode(
            &header("x-file-name").unwrap_or_default(),
        ));
        let from = header("x-sender-name")
            .map(|v| percent_decode(&v))
            .unwrap_or_else(|| "未知设备".into());
        let _ = ev.send(RecvEvent::Rejected {
            name: if fname.is_empty() { "unnamed".into() } else { fname },
            from,
        });
        respond(&mut stream, 503, "{\"ok\":false,\"error\":\"receiving off\"}");
        return Ok(());
    }

    match path.as_str() {
        "/weimi/send" => {
            if header("x-weimi-app").as_deref() != Some(crate::proto::MAGIC) {
                respond(&mut stream, 403, "{\"ok\":false}");
                return Ok(());
            }
            let sender_name = header("x-sender-name")
                .map(|v| percent_decode(&v))
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| "未知设备".into());
            let file_name = safe_file_name(&percent_decode(
                &header("x-file-name").unwrap_or_default(),
            ));
            let file_name = if file_name.is_empty() { "unnamed".to_string() } else { file_name };
            let file_size: u64 = header("x-file-size")
                .and_then(|v| v.parse().ok())
                .unwrap_or(0);
            let content_len: u64 = header("content-length")
                .and_then(|v| v.parse().ok())
                .unwrap_or(0);

            let _ = ev.send(RecvEvent::Started {
                name: file_name.clone(),
                from: sender_name.clone(),
                size: file_size,
            });

            std::fs::create_dir_all(&recv_dir).ok();
            let target = dedup_path(&recv_dir.join(&file_name));
            // 防逃逸：safe_file_name 与 Dart 一致不过滤裸 ".."，这里兜底——
            // 最终路径必须仍在接收目录内，否则拒收（400）
            if !target.starts_with(&recv_dir) {
                respond(&mut stream, 400, "{\"ok\":false,\"error\":\"bad name\"}");
                return Ok(());
            }
            // 文件名可能含相对子目录（safe_file_name 保留段结构），父目录要先建
            if let Some(parent) = target.parent() {
                std::fs::create_dir_all(parent).ok();
            }
            let mut file = match File::create(&target) {
                Ok(f) => f,
                Err(e) => {
                    let _ = ev.send(RecvEvent::Failed {
                        name: file_name.clone(),
                        from: sender_name.clone(),
                        error: format!("无法创建文件: {e}"),
                    });
                    respond(&mut stream, 500, "{\"ok\":false}");
                    return Ok(());
                }
            };

            // 按 Content-Length 逐块收（不信任头里的 X-File-Size）
            let mut remaining = content_len;
            let mut buf = [0u8; 64 * 1024];
            let mut received: u64 = 0;
            let mut last_progress = 0u64;
            loop {
                if remaining == 0 {
                    break;
                }
                let want = remaining.min(buf.len() as u64) as usize;
                let n = match reader.read(&mut buf[..want]) {
                    Ok(0) => break,
                    Ok(n) => n,
                    Err(_) => break,
                };
                if file.write_all(&buf[..n]).is_err() {
                    break;
                }
                received += n as u64;
                remaining -= n as u64;
                // 进度事件节流：每 512KB 或收完推一次
                if received - last_progress >= 512 * 1024 || remaining == 0 {
                    last_progress = received;
                    let _ = ev.send(RecvEvent::Progress {
                        name: file_name.clone(),
                        received,
                        total: file_size,
                    });
                }
            }
            let _ = file.flush();

            let body = format!(
                "{{\"ok\":true,\"path\":{}}}",
                serde_json::Value::String(target.to_string_lossy().into_owned())
            );
            respond(&mut stream, 200, &body);
            let _ = ev.send(RecvEvent::Done {
                name: file_name,
                from: sender_name,
                path: target,
                size: received,
            });
            Ok(())
        }
        "/weimi/text" => {
            if header("x-weimi-app").as_deref() != Some(crate::proto::MAGIC) {
                respond(&mut stream, 403, "{\"ok\":false}");
                return Ok(());
            }
            let sender_name = header("x-sender-name")
                .map(|v| percent_decode(&v))
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| "未知设备".into());
            let content_len: u64 = header("content-length")
                .and_then(|v| v.parse().ok())
                .unwrap_or(0);
            let mut body = vec![0u8; content_len.min(4 * 1024 * 1024) as usize];
            let mut got = 0usize;
            while got < body.len() {
                match reader.read(&mut body[got..]) {
                    Ok(0) => break,
                    Ok(n) => got += n,
                    Err(_) => break,
                }
            }
            let text = String::from_utf8_lossy(&body[..got]).into_owned();
            std::fs::create_dir_all(&recv_dir).ok();
            let target = dedup_path(&recv_dir.join("飞传文本.txt"));
            let with_meta = format!("[来自: {sender_name}]\n{text}");
            let _ = std::fs::write(&target, with_meta);
            respond(&mut stream, 200, "{\"ok\":true}");
            let _ = ev.send(RecvEvent::Done {
                name: "飞传文本".into(),
                from: sender_name,
                path: target,
                size: got as u64,
            });
            Ok(())
        }
        _ => {
            respond(&mut stream, 404, "{\"ok\":false}");
            Ok(())
        }
    }
}

// ---------- 发送端 ----------

/// POST 一个文件到对端。on_progress(sent, total)。
pub fn send_file(
    ip: &str,
    port: u16,
    file_path: &std::path::Path,
    sender_id: &str,
    sender_name: &str,
    on_progress: &mut dyn FnMut(u64, u64),
) -> Result<(), String> {
    use std::io::Read;
    let meta = std::fs::metadata(file_path).map_err(|e| format!("读取文件失败: {e}"))?;
    let total = meta.len();
    let send_name = file_path
        .file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "unnamed".into());

    let addr: std::net::SocketAddr = match format!("{ip}:{port}").parse() {
        Ok(a) => a,
        Err(e) => return Err(format!("地址无效: {e}")),
    };
    let mut stream = TcpStream::connect_timeout(&addr, std::time::Duration::from_secs(10))
        .map_err(|e| format!("连接 {ip}:{port} 失败: {e}（对方可能不在线或被防火墙拦截）"))?;
    stream.set_nodelay(true).ok();

    let req_head = format!(
        "POST /weimi/send HTTP/1.1\r\nHost: {ip}:{port}\r\nContent-Length: {total}\r\nX-Weimi-App: {}\r\nX-Sender-Id: {}\r\nX-Sender-Name: {}\r\nX-File-Name: {}\r\nX-File-Size: {total}\r\nConnection: close\r\n\r\n",
        crate::proto::MAGIC,
        crate::proto::percent_encode(sender_id),
        crate::proto::percent_encode(sender_name),
        crate::proto::percent_encode(&send_name),
    );
    stream
        .write_all(req_head.as_bytes())
        .map_err(|e| format!("发送请求头失败: {e}"))?;

    let mut f = File::open(file_path).map_err(|e| format!("打开文件失败: {e}"))?;
    let mut buf = [0u8; 64 * 1024];
    let mut sent = 0u64;
    loop {
        let n = f.read(&mut buf).map_err(|e| format!("读取文件失败: {e}"))?;
        if n == 0 {
            break;
        }
        stream.write_all(&buf[..n]).map_err(|e| format!("发送数据失败: {e}"))?;
        sent += n as u64;
        on_progress(sent, total);
    }
    stream.flush().ok();

    // 读响应（只要状态行含 200 且 body 有 "ok":true）
    let mut resp = String::new();
    let _ = stream.read_to_string(&mut resp);
    let status_line = resp.lines().next().unwrap_or("");
    if status_line.contains(" 200 ") && resp.contains("\"ok\":true") {
        Ok(())
    } else if status_line.contains(" 403 ") {
        Err("对方拒收（403）".into())
    } else if status_line.contains(" 503 ") {
        Err("对方未开启接收（503）".into())
    } else {
        Err(format!("对方返回异常: {}", status_line.trim()))
    }
}

/// 发一段文本
pub fn send_text(ip: &str, port: u16, text: &str, sender_id: &str, sender_name: &str) -> Result<(), String> {
    let addr: std::net::SocketAddr = match format!("{ip}:{port}").parse() {
        Ok(a) => a,
        Err(e) => return Err(format!("地址无效: {e}")),
    };
    let mut stream = TcpStream::connect_timeout(&addr, std::time::Duration::from_secs(10))
        .map_err(|e| format!("连接失败: {e}"))?;
    let body = text.as_bytes();
    let req_head = format!(
        "POST /weimi/text HTTP/1.1\r\nHost: {ip}:{port}\r\nContent-Length: {}\r\nX-Weimi-App: {}\r\nX-Sender-Id: {}\r\nX-Sender-Name: {}\r\nConnection: close\r\n\r\n",
        body.len(),
        crate::proto::MAGIC,
        crate::proto::percent_encode(sender_id),
        crate::proto::percent_encode(sender_name),
    );
    stream.write_all(req_head.as_bytes()).map_err(|e| format!("发送失败: {e}"))?;
    stream.write_all(body).map_err(|e| format!("发送失败: {e}"))?;
    stream.flush().ok();
    let mut resp = String::new();
    let _ = stream.read_to_string(&mut resp);
    if resp.contains("\"ok\":true") {
        Ok(())
    } else {
        Err("对方未接收".into())
    }
}
