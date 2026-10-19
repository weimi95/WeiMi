//! NWG 图形界面（M3）：加解密页 + 飞传页。
//!
//! 采用官方 `#[derive(NwgUi)]` 模式：事件方法是 `&self` 成员方法，可直接访问控件。
//! 线程模型：GUI 主线程跑事件循环；discovery/httpd/发送各自子线程；
//! 子线程只写 Arc<Mutex<AppState>>，状态变更时 NoticeSender.notice() 唤醒 GUI 线程刷新。
//!
//! 注意：NwgUi 生成的 GuiUi 只实现 Deref（无 DerefMut），且事件方法是 `&self`，
//! 所以可变跨线程状态必须放 Rc<RefCell<..>> / Arc<Mutex<..>> 里，不能放裸字段。

use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use native_windows_derive::NwgUi;
use native_windows_gui as nwg;
use nwg::NativeUi;

use crate::cli::{decrypt_cmd, encrypt_cmd};
use crate::discovery::Discovery;
use crate::httpd::{send_file, send_text, HttpServer, Notifier, RecvEvent, RecvState};
use crate::proto::{default_recv_dir, load_or_create_identity, Identity, Peer};

/// 传输记录行（ListView）
#[derive(Clone)]
struct TransferRow {
    dir: &'static str,
    name: String,
    size: String,
    status: &'static str,
    time: String,
}

/// 跨线程共享状态（所有字段 Send；非 Send 的控件/handler 一律不进这里）
struct AppState {
    identity: Identity,
    http_port: u16,
    recv: Arc<Mutex<RecvState>>,
    events: Receiver<RecvEvent>,
    log: Vec<String>,
    transfers: Vec<TransferRow>,
    send_progress: (u64, u64),
    send_busy: bool,
    recv_progress: Option<(String, u64, u64)>,
    peers: Vec<Peer>,
    // tick 缓存（GUI 线程写读，放 Mutex 里避开 &self 限制）
    last_peer_count: usize,
    last_log_len: usize,
    last_transfer_count: usize,
}

/// GUI 侧共享容器（内部可变性：GuiUi 无 DerefMut）
#[derive(Default)]
struct Shared {
    state: Option<Arc<Mutex<AppState>>>,
    discovery: Option<Discovery>,
}

fn now_str() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let t = (secs + 8 * 3600) % 86400;
    format!("{:02}:{:02}:{:02}", t / 3600, (t % 3600) / 60, t % 60)
}

fn fmt_bytes(n: u64) -> String {
    if n >= 1024 * 1024 * 1024 {
        format!("{:.1} GB", n as f64 / (1024.0 * 1024.0 * 1024.0))
    } else if n >= 1024 * 1024 {
        format!("{:.1} MB", n as f64 / (1024.0 * 1024.0))
    } else if n >= 1024 {
        format!("{:.0} KB", n as f64 / 1024.0)
    } else {
        format!("{n} B")
    }
}

impl AppState {
    fn log(&mut self, msg: &str) {
        self.log.push(format!("[{}] {}", now_str(), msg));
        if self.log.len() > 200 {
            self.log.remove(0);
        }
    }

    fn add_transfer(&mut self, row: TransferRow) {
        self.transfers.insert(0, row);
        if self.transfers.len() > 300 {
            self.transfers.truncate(300);
        }
    }

    fn drain_events(&mut self) {
        while let Ok(ev) = self.events.try_recv() {
            match ev {
                RecvEvent::Started { name, from, size } => {
                    self.recv_progress = Some((name.clone(), 0, size));
                    self.log(&format!(
                        "开始接收「{name}」（来自 {from}，{}）",
                        fmt_bytes(size)
                    ));
                }
                RecvEvent::Progress {
                    name,
                    received,
                    total,
                } => {
                    self.recv_progress = Some((name, received, total));
                }
                RecvEvent::Done {
                    name,
                    from,
                    path,
                    size,
                } => {
                    self.recv_progress = None;
                    self.log(&format!("接收完成「{name}」→ {}", path.display()));
                    self.add_transfer(TransferRow {
                        dir: "收",
                        name,
                        size: fmt_bytes(size),
                        status: "完成",
                        time: now_str(),
                    });
                    let _ = from;
                }
                RecvEvent::Failed { name, from, error } => {
                    self.recv_progress = None;
                    self.log(&format!("接收失败「{name}」（来自 {from}）：{error}"));
                    self.add_transfer(TransferRow {
                        dir: "收",
                        name,
                        size: "-".into(),
                        status: "失败",
                        time: now_str(),
                    });
                }
                RecvEvent::Rejected { name, from } => {
                    self.log(&format!("已拒收「{name}」（来自 {from}）"));
                }
            }
        }
    }
}

#[derive(Default, NwgUi)]
pub struct Gui {
    // ---- 非控件字段：跨线程可变状态（内部可变性） ----
    shared: Rc<RefCell<Shared>>,

    #[nwg_control(size: (660, 620), title: "微密文件·经典版")]
    #[nwg_events(OnWindowClose: [Gui::exit])]
    window: nwg::Window,

    #[nwg_control(parent: window, position: (10, 10), size: (634, 546))]
    tabs: nwg::TabsContainer,

    #[nwg_control(parent: tabs, text: "加解密")]
    tab_enc: nwg::Tab,

    #[nwg_control(parent: tab_enc, position: (14, 16), text: "文件:")]
    lbl_file: nwg::Label,

    #[nwg_control(parent: tab_enc, position: (56, 12), size: (440, 22), placeholder_text: Some("选择要加密/解密的 .wemi 文件"))]
    enc_path: nwg::TextInput,

    #[nwg_control(parent: tab_enc, position: (506, 11), size: (80, 24), text: "浏览...")]
    #[nwg_events(OnButtonClick: [Gui::on_browse])]
    btn_browse: nwg::Button,

    #[nwg_control(parent: tab_enc, position: (14, 48), text: "密码:")]
    lbl_pw: nwg::Label,

    #[nwg_control(parent: tab_enc, position: (56, 44), size: (530, 22), password: Some('*'), placeholder_text: Some("文件的加密密码"))]
    enc_password: nwg::TextInput,

    #[nwg_control(parent: tab_enc, position: (14, 80), text: "提示:")]
    lbl_hint: nwg::Label,

    #[nwg_control(parent: tab_enc, position: (56, 76), size: (530, 22), placeholder_text: Some("可选，仅加密时写入文件"))]
    enc_hint: nwg::TextInput,

    #[nwg_control(parent: tab_enc, position: (56, 108), size: (120, 30), text: "加 密")]
    #[nwg_events(OnButtonClick: [Gui::on_encrypt])]
    btn_encrypt: nwg::Button,

    #[nwg_control(parent: tab_enc, position: (186, 108), size: (120, 30), text: "解 密")]
    #[nwg_events(OnButtonClick: [Gui::on_decrypt])]
    btn_decrypt: nwg::Button,

    #[nwg_control(parent: tab_enc, position: (14, 146), text: "操作日志:")]
    lbl_log: nwg::Label,

    #[nwg_control(parent: tab_enc, position: (14, 168), size: (594, 340), readonly: true)]
    log_box: nwg::TextBox,

    #[nwg_control(parent: tabs, text: "飞传")]
    tab_lan: nwg::Tab,

    #[nwg_control(parent: tab_lan, position: (14, 14), size: (120, 22), text: "开启接收", check_state: nwg::CheckBoxState::Checked)]
    #[nwg_events(OnButtonClick: [Gui::on_receive_toggle])]
    chk_receive: nwg::CheckBox,

    #[nwg_control(parent: tab_lan, position: (140, 16), size: (460, 18), text: "接收目录: ")]
    lbl_recv_dir: nwg::Label,

    #[nwg_control(parent: tab_lan, position: (14, 48), text: "设备:")]
    lbl_peer: nwg::Label,

    #[nwg_control(parent: tab_lan, position: (56, 44), size: (380, 24))]
    cmb_peers: nwg::ComboBox<String>,

    #[nwg_control(parent: tab_lan, position: (446, 43), size: (80, 24), text: "刷新")]
    #[nwg_events(OnButtonClick: [Gui::on_refresh_peers])]
    btn_refresh: nwg::Button,

    #[nwg_control(parent: tab_lan, position: (14, 82), size: (130, 30), text: "发送文件...")]
    #[nwg_events(OnButtonClick: [Gui::on_send_file])]
    btn_send_file: nwg::Button,

    #[nwg_control(parent: tab_lan, position: (154, 82), size: (130, 30), text: "发送文本...")]
    #[nwg_events(OnButtonClick: [Gui::on_open_text_dialog])]
    btn_send_text: nwg::Button,

    #[nwg_control(parent: tab_lan, position: (14, 124), text: "进度:")]
    lbl_prog: nwg::Label,

    #[nwg_control(parent: tab_lan, position: (56, 120), size: (440, 20))]
    progress: nwg::ProgressBar,

    #[nwg_control(parent: tab_lan, position: (506, 122), size: (100, 18))]
    lbl_progress: nwg::Label,

    #[nwg_control(parent: tab_lan, position: (14, 152), text: "传输记录:")]
    lbl_rec: nwg::Label,

    #[nwg_control(parent: tab_lan, position: (14, 174), size: (594, 330), list_style: nwg::ListViewStyle::Detailed, ex_flags: nwg::ListViewExFlags::FULL_ROW_SELECT | nwg::ListViewExFlags::GRID)]
    list_transfers: nwg::ListView,

    // ---- 事件唤醒：子线程（httpd/discovery）有状态变更时 notice 一次 ----
    #[nwg_control(parent: window)]
    #[nwg_events(OnNotice: [Gui::on_notice])]
    notice: nwg::Notice,

    #[nwg_control(parent: window)]
    status_bar: nwg::StatusBar,

    // ---- 发送文本小窗（初始隐藏，OnWindowClose 只藏不退） ----
    #[nwg_control(size: (380, 190), title: "发送文本", flags: "WINDOW")]
    #[nwg_events(OnWindowClose: [Gui::close_text_dialog])]
    text_dlg: nwg::Window,

    #[nwg_control(parent: text_dlg, position: (10, 10), size: (344, 100))]
    text_input: nwg::TextBox,

    #[nwg_control(parent: text_dlg, position: (170, 120), size: (90, 28), text: "发送")]
    #[nwg_events(OnButtonClick: [Gui::on_send_text])]
    text_ok: nwg::Button,

    #[nwg_control(parent: text_dlg, position: (270, 120), size: (90, 28), text: "取消")]
    #[nwg_events(OnButtonClick: [Gui::close_text_dialog])]
    text_cancel: nwg::Button,
}

impl Gui {
    /// 取 AppState 的 Arc 克隆（避免 MutexGuard 生命周期绑定临时值）
    fn state_arc(&self) -> Arc<Mutex<AppState>> {
        self.shared
            .borrow()
            .state
            .as_ref()
            .expect("state not set")
            .clone()
    }

    fn with_disc<T>(&self, f: impl FnOnce(&Discovery) -> T) -> Option<T> {
        let b = self.shared.borrow();
        b.discovery.as_ref().map(f)
    }

    fn exit(&self) {
        nwg::stop_thread_dispatch();
    }

    fn on_notice(&self) {
        self.tick();
    }

    fn on_browse(&self) {
        let mut dialog = Default::default();
        let r = nwg::FileDialog::builder()
            .title("选择文件")
            .action(nwg::FileDialogAction::Open)
            .filters("所有文件 (*.*)\0*.*\0微密加密 (*.wemi;*.kyl)\0*.wemi;*.kyl\0\0")
            .build(&mut dialog);
        if let Err(e) = r {
            let state = self.state_arc();
            state.lock().unwrap().log(&format!("打开文件对话框失败: {e}"));
            return;
        }
        if dialog.run(Some(&self.window)) {
            match dialog.get_selected_item() {
                Ok(p) => self.enc_path.set_text(&p.to_string_lossy()),
                Err(e) => {
                    let state = self.state_arc();
                    state.lock().unwrap().log(&format!("读取所选文件失败: {e}"));
                }
            }
        }
    }

    fn on_encrypt(&self) {
        let path = self.enc_path.text();
        let pw = self.enc_password.text();
        let hint = self.enc_hint.text();
        if path.trim().is_empty() || pw.is_empty() {
            nwg::modal_error_message(&self.window, "无法加密", "请先选择文件并输入密码。");
            return;
        }
        let output = format!("{}.wemi", path.trim_end_matches(".wemi"));
        let hint_opt = if hint.trim().is_empty() {
            None
        } else {
            Some(hint)
        };
        {
            let state = self.state_arc();
            state
                .lock()
                .unwrap()
                .log(&format!("开始加密「{path}」..."));
        }
        let state = self.state_arc();
        std::thread::spawn(move || {
            let r = encrypt_cmd(&path, &output, pw.as_bytes(), hint_opt.as_deref());
            let mut st = state.lock().unwrap();
            match r {
                Ok(()) => st.log(&format!("已加密 → {output}")),
                Err(e) => st.log(&format!("加密失败：{e}")),
            }
        });
    }

    fn on_decrypt(&self) {
        let path = self.enc_path.text();
        let pw = self.enc_password.text();
        if path.trim().is_empty() || pw.is_empty() {
            nwg::modal_error_message(&self.window, "无法解密", "请先选择文件并输入密码。");
            return;
        }
        let stripped = path.trim_end_matches(".wemi");
        let output = if stripped == path {
            format!("{path}.dec")
        } else {
            stripped.to_string()
        };
        {
            let state = self.state_arc();
            state
                .lock()
                .unwrap()
                .log(&format!("开始解密「{path}」..."));
        }
        let state = self.state_arc();
        std::thread::spawn(move || {
            let r = decrypt_cmd(&path, &output, pw.as_bytes());
            let mut st = state.lock().unwrap();
            match r {
                Ok(()) => st.log(&format!("已解密 → {output}")),
                Err(e) => st.log(&format!("解密失败：{e}")),
            }
        });
    }

    fn on_receive_toggle(&self) {
        let on = self.chk_receive.check_state() == nwg::CheckBoxState::Checked;
        let state = self.state_arc();
        state.lock().unwrap().recv.lock().unwrap().set_receiving(on);
        let mut st = state.lock().unwrap();
        st.log(if on {
            "已开启接收（局域网设备可以发送文件到本机）"
        } else {
            "已关闭接收"
        });
    }

    fn on_refresh_peers(&self) {
        self.refresh_peers();
    }

    fn selected_peer(&self) -> Option<Peer> {
        let idx = self.cmb_peers.selection()?;
        let state = self.state_arc();
        let peer = state.lock().unwrap().peers.get(idx).cloned();
        peer
    }

    fn on_send_file(&self) {
        let Some(peer) = self.selected_peer() else {
            nwg::modal_error_message(
                &self.window,
                "无法发送",
                "请先在设备列表中选择一个在线设备。",
            );
            return;
        };
        {
            let state = self.state_arc();
            if state.lock().unwrap().send_busy {
                nwg::modal_info_message(&self.window, "请稍候", "上一个文件还在发送中。");
                return;
            }
        }
        let mut dialog = Default::default();
        let r = nwg::FileDialog::builder()
            .title("选择要发送的文件")
            .action(nwg::FileDialogAction::Open)
            .filters("所有文件 (*.*)\0*.*\0\0")
            .build(&mut dialog);
        if let Err(e) = r {
            let state = self.state_arc();
            state.lock().unwrap().log(&format!("打开文件对话框失败: {e}"));
            return;
        }
        if !dialog.run(Some(&self.window)) {
            return;
        }
        let path = match dialog.get_selected_item() {
            Ok(p) => PathBuf::from(p),
            Err(e) => {
                let state = self.state_arc();
                state
                    .lock()
                    .unwrap()
                    .log(&format!("读取所选文件失败: {e}"));
                return;
            }
        };
        let (ip, port, sid, sname) = {
            let state = self.state_arc();
            let st = state.lock().unwrap();
            (
                peer.ip.clone(),
                peer.http_port,
                st.identity.id.clone(),
                st.identity.name.clone(),
            )
        };
        let fname = path
            .file_name()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default();
        let fsize = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
        {
            let state = self.state_arc();
            let mut st = state.lock().unwrap();
            st.send_busy = true;
            st.log(&format!(
                "开始发送「{fname}」→ {}（{}）",
                peer.name,
                fmt_bytes(fsize)
            ));
        }
        let state = self.state_arc();
        std::thread::spawn(move || {
            let mut last = 0u64;
            let r = send_file(&ip, port, &path, &sid, &sname, &mut |sent, total| {
                if sent - last > 256 * 1024 || sent == total {
                    last = sent;
                    state.lock().unwrap().send_progress = (sent, total);
                }
            });
            let mut st = state.lock().unwrap();
            st.send_busy = false;
            st.send_progress = (0, 0);
            match r {
                Ok(()) => {
                    st.log(&format!("已发送「{fname}」"));
                    st.add_transfer(TransferRow {
                        dir: "发",
                        name: fname,
                        size: fmt_bytes(fsize),
                        status: "完成",
                        time: now_str(),
                    });
                }
                Err(e) => {
                    st.log(&format!("发送失败「{fname}」：{e}"));
                    st.add_transfer(TransferRow {
                        dir: "发",
                        name: fname,
                        size: fmt_bytes(fsize),
                        status: "失败",
                        time: now_str(),
                    });
                }
            }
        });
    }

    fn on_open_text_dialog(&self) {
        if self.selected_peer().is_none() {
            nwg::modal_error_message(
                &self.window,
                "无法发送",
                "请先在设备列表中选择一个在线设备。",
            );
            return;
        }
        self.text_input.set_text("");
        self.text_dlg.set_visible(true);
        self.text_dlg.set_focus();
    }

    fn close_text_dialog(&self) {
        self.text_dlg.set_visible(false);
    }

    fn on_send_text(&self) {
        let Some(peer) = self.selected_peer() else {
            nwg::modal_error_message(&self.window, "无法发送", "请先选择设备。");
            return;
        };
        let text = self.text_input.text();
        if text.trim().is_empty() {
            nwg::modal_error_message(&self.window, "无法发送", "请输入要发送的文本。");
            return;
        }
        let (ip, port, sid, sname) = {
            let state = self.state_arc();
            let st = state.lock().unwrap();
            (
                peer.ip.clone(),
                peer.http_port,
                st.identity.id.clone(),
                st.identity.name.clone(),
            )
        };
        self.close_text_dialog();
        let state = self.state_arc();
        std::thread::spawn(move || {
            let r = send_text(&ip, port, &text, &sid, &sname);
            let mut st = state.lock().unwrap();
            match r {
                Ok(()) => st.log("文本已发送"),
                Err(e) => st.log(&format!("文本发送失败：{e}")),
            }
        });
    }

    fn refresh_peers(&self) {
        let peers = self
            .with_disc(|d| d.peer_list())
            .unwrap_or_default();
        {
            let state = self.state_arc();
            state.lock().unwrap().peers = peers.clone();
        }
        let items: Vec<String> = peers
            .iter()
            .map(|p| format!("{} ({})", p.name, p.ip))
            .collect();
        self.cmb_peers.set_collection(items);
        if !peers.is_empty() {
            self.cmb_peers.set_selection(Some(0));
        }
    }

    /// Notice 唤醒：把状态变更刷进控件
    fn tick(&self) {
        // peers 数量变化 → 全量刷新设备列表
        let peer_count = self.with_disc(|d| d.peer_list().len()).unwrap_or(0);
        {
            let state = self.state_arc();
            let mut st = state.lock().unwrap();
            if peer_count != st.last_peer_count {
                st.last_peer_count = peer_count;
                drop(st);
                self.refresh_peers();
            }
        }

        // 事件 drain + 日志/记录/进度
        let (new_logs, new_transfers, recv_prog, send_prog, busy, last_log_len, last_transfer_count) = {
            let state = self.state_arc();
            let mut st = state.lock().unwrap();
            st.drain_events();
            (
                st.log.clone(),
                st.transfers.clone(),
                st.recv_progress.clone(),
                st.send_progress,
                st.send_busy,
                st.last_log_len,
                st.last_transfer_count,
            )
        };

        if new_logs.len() != last_log_len {
            for line in &new_logs[last_log_len.min(new_logs.len())..] {
                self.log_box.appendln(line);
            }
            let state = self.state_arc();
            state.lock().unwrap().last_log_len = new_logs.len();
        }

        if new_transfers.len() > last_transfer_count {
            for row in &new_transfers[last_transfer_count..] {
                self.list_transfers.insert_items_row(
                    None,
                    &[row.dir, &row.name, &row.size, row.status, &row.time],
                );
            }
            let state = self.state_arc();
            state.lock().unwrap().last_transfer_count = new_transfers.len();
        }

        if let Some((_, received, total)) = recv_prog {
            let pct = if total > 0 {
                (received as f32 / total as f32 * 100.0) as i32
            } else {
                0
            };
            self.progress.set_pos(pct.clamp(0, 100) as u32);
            self.lbl_progress.set_text(&format!("收 {}%", pct.clamp(0, 100)));
        } else if busy {
            let (sent, total) = send_prog;
            let pct = if total > 0 {
                (sent as f32 / total as f32 * 100.0) as i32
            } else {
                0
            };
            self.progress.set_pos(pct.clamp(0, 100) as u32);
            self.lbl_progress.set_text(&format!("发 {}%", pct.clamp(0, 100)));
        } else {
            self.progress.set_pos(0);
            self.lbl_progress.set_text("");
        }
    }
}

pub fn run_gui() {
    nwg::init().expect("Failed to init NWG");
    nwg::Font::set_global_family("Microsoft YaHei UI").expect("Failed to set font");

    let identity = load_or_create_identity();

    // 先建 UI：Notice 控件就绪后才能拿 NoticeSender 给子线程用
    let gui = Gui::build_ui(Default::default()).expect("Failed to build UI");
    let notice_sender: Arc<dyn Notifier> = Arc::new(gui.notice.sender());

    let (server, recv_state, events) = match HttpServer::start(notice_sender.clone()) {
        Ok(v) => v,
        Err(e) => {
            nwg::modal_error_message(
                &gui.window,
                "启动失败",
                &format!("无法启动接收服务：{e}\n请检查 52345-52365 端口是否被其他程序占用。"),
            );
            return;
        }
    };
    let port = server.port;
    let discovery = match Discovery::start(&identity, port, true, notice_sender.clone()) {
        Ok(d) => d,
        Err(_) => {
            nwg::modal_error_message(
                &gui.window,
                "启动失败",
                "无法绑定 UDP 52346 发现端口（可能被另一个微密实例占用）。",
            );
            return;
        }
    };

    let state = Arc::new(Mutex::new(AppState {
        identity,
        http_port: port,
        recv: recv_state,
        events,
        log: Vec::new(),
        transfers: Vec::new(),
        send_progress: (0, 0),
        send_busy: false,
        recv_progress: None,
        peers: Vec::new(),
        last_peer_count: usize::MAX, // 首次 tick 必刷新一次设备列表
        last_log_len: 0,
        last_transfer_count: 0,
    }));

    {
        let mut b = gui.shared.borrow_mut();
        b.state = Some(state);
        b.discovery = Some(discovery);
    }

    // ListView 列
    for (i, (title, w)) in [
        ("方向", 50),
        ("名称", 280),
        ("大小", 90),
        ("状态", 70),
        ("时间", 60),
    ]
    .into_iter()
    .enumerate()
    {
        gui.list_transfers.insert_column(nwg::InsertListViewColumn {
            index: Some(i as i32),
            fmt: None,
            width: Some(w),
            text: Some(title.into()),
        });
    }
    gui.list_transfers.set_headers_enabled(true);

    {
        let st = gui.state_arc();
        let st = st.lock().unwrap();
        gui.status_bar.set_text(
            0,
            &format!(
                "设备: {} | 端口: {} | 接收目录: {}",
                st.identity.name,
                st.http_port,
                default_recv_dir().display()
            ),
        );
        gui.lbl_recv_dir
            .set_text(&format!("接收目录: {}", default_recv_dir().display()));
        gui.log_box
            .appendln(&format!("[{}] 微密文件·经典版已启动", now_str()));
    }

    nwg::dispatch_thread_events();
}
