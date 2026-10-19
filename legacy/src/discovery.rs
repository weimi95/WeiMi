//! UDP 发现：广播 announce + 监听 announce/reply，维护 peers 表。
//! 对齐主程序：255.255.255.255 + 各网段定向广播；收到 announce 单播 reply；
//! 12 秒无 announce 的设备视为离线。

use std::net::UdpSocket;
use std::sync::{Arc, RwLock};
use std::time::{Duration, Instant};

use crate::proto::{Identity, Peer, DISCOVERY_PORT, MAGIC};

const PEER_TTL: Duration = Duration::from_secs(12);
const ANNOUNCE_INTERVAL: Duration = Duration::from_secs(3);

pub struct Discovery {
    pub peers: Arc<RwLock<Vec<Peer>>>,
    _socket: Arc<UdpSocket>,
}
fn local_ipv4s() -> Vec<String> {
    // 用 UDP connect 技巧拿本机出口 IP（不发包），多网卡逐个试
    let mut out = Vec::new();
    for target in ["8.8.8.8:53", "223.5.5.5:53"] {
        if let Ok(s) = UdpSocket::bind("0.0.0.0:0") {
            if s.connect(target).is_ok() {
                if let Ok(a) = s.local_addr() {
                    let ip = a.ip().to_string();
                    if !out.contains(&ip) {
                        out.push(ip);
                    }
                }
            }
        }
    }
    out
}

impl Discovery {
    /// 启动发现服务。receiving 控制是否可被发现（announce 开关）。
    /// notice 用于 peers 变化时唤醒 GUI 线程刷新设备列表。
    pub fn start(
        identity: &Identity,
        http_port: u16,
        receiving: bool,
        notice: Arc<dyn crate::httpd::Notifier>,
    ) -> std::io::Result<Self> {
        let socket = UdpSocket::bind(format!("0.0.0.0:{DISCOVERY_PORT}"))?;
        socket.set_broadcast(true)?;
        let socket = Arc::new(socket);

        let peers: Arc<RwLock<Vec<Peer>>> = Arc::new(RwLock::new(Vec::new()));

        // 监听线程
        {
            let sock = socket.clone();
            let peers = peers.clone();
            let my_id = identity.id.clone();
            let nt = notice.clone();
            std::thread::spawn(move || {
                let mut buf = [0u8; 2048];
                loop {
                    let (n, from) = match sock.recv_from(&mut buf) {
                        Ok(v) => v,
                        Err(_) => continue,
                    };
                    let text = String::from_utf8_lossy(&buf[..n]).into_owned();
                    let msg: serde_json::Value = match serde_json::from_str(&text) {
                        Ok(v) => v,
                        Err(_) => continue,
                    };
                    if msg.get("app").and_then(|v| v.as_str()) != Some(MAGIC) {
                        continue;
                    }
                    let id = msg.get("id").and_then(|v| v.as_str()).unwrap_or("").to_string();
                    if id.is_empty() || id == my_id {
                        continue;
                    }
                    let name = msg
                        .get("name")
                        .and_then(|v| v.as_str())
                        .unwrap_or("未知设备")
                        .to_string();
                    let port = msg
                        .get("httpPort")
                        .and_then(|v| v.as_u64())
                        .unwrap_or(0) as u16;
                    let action = msg.get("action").and_then(|v| v.as_str()).unwrap_or("");
                    let peer = Peer {
                        id: id.clone(),
                        name,
                        ip: from.ip().to_string(),
                        http_port: port,
                        last_seen: Instant::now(),
                    };
                    {
                        let mut list = peers.write().unwrap();
                        list.retain(|p| p.id != id);
                        list.push(peer);
                    }
                    // 收到 announce → 单播 reply 让对方也知道我
                    if action == "announce" {
                        Self::send_msg(&sock, "reply", &my_id, "", http_port, from.ip().to_string(), from.port());
                    }
                    nt.notify();
                }
            });
        }

        // 广播线程（可被发现时每 3s 一轮；同时清理过期 peers）
        if receiving {
            let sock = socket.clone();
            let my_id = identity.id.clone();
            let my_name = identity.name.clone();
            std::thread::spawn(move || loop {
                let targets = Self::broadcast_targets();
                for t in &targets {
                    Self::send_msg(&sock, "announce", &my_id, &my_name, http_port, t.clone(), DISCOVERY_PORT);
                }
                std::thread::sleep(ANNOUNCE_INTERVAL);
            });
        }
        {
            let peers = peers.clone();
            let nt = notice;
            std::thread::spawn(move || loop {
                std::thread::sleep(Duration::from_secs(3));
                let before;
                let after;
                {
                    let mut list = peers.write().unwrap();
                    before = list.len();
                    list.retain(|p| p.last_seen.elapsed() < PEER_TTL);
                    after = list.len();
                }
                if before != after {
                    nt.notify();
                }
            });
        }

        Ok(Self {
            peers,
            _socket: socket,
        })
    }

    fn send_msg(sock: &UdpSocket, action: &str, id: &str, name: &str, http_port: u16, ip: String, port: u16) {
        let identity = Identity {
            id: id.to_string(),
            name: name.to_string(),
        };
        let body = crate::proto::build_announce(&identity, http_port, action);
        let _ = sock.send_to(body.as_bytes(), format!("{ip}:{port}"));
    }

    fn broadcast_targets() -> Vec<String> {
        let mut targets = vec!["255.255.255.255".to_string()];
        for my_ip in local_ipv4s() {
            let parts: Vec<&str> = my_ip.split('.').collect();
            if parts.len() == 4 {
                let sub = format!("{}.{}.{}.255", parts[0], parts[1], parts[2]);
                if !targets.contains(&sub) {
                    targets.push(sub);
                }
            }
        }
        targets
    }

    pub fn peer_list(&self) -> Vec<Peer> {
        self.peers.read().unwrap().clone()
    }
}
