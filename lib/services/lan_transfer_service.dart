import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../framework/setting_store.dart';
import 'landrop_service.dart';
import 'localsend_service.dart';
import 'trusted_devices_service.dart';
import 'transfer_history_service.dart';
import 'receive_notify_service.dart';
import 'daemon_service.dart';
import 'sent_file_archiver.dart';

/// 微密飞传服务（方案 B：自研轻量协议，对标 Landrop）
///
/// - 发现：UDP 广播（端口 52346），JSON 消息，announce 广播 / reply 单播应答
/// - 传输：HTTP POST 直传（端口 52345 起，被占用自动 +1），明文原样收发
/// - 纯 Dart 实现（dart:io 的 RawDatagramSocket / HttpServer / HttpClient），
///   无平台通道、无新增第三方依赖，Android / Windows / macOS / Linux 全平台可用
/// - Android 后台保活：接收开启时拉起前台服务（WeiMiTransferService）
///
/// UDP JSON 协议：
///   {"app":"weimi","action":"announce"|"reply","id":设备ID,"name":设备名,
///    "httpPort":实际HTTP端口,"v":1}
///
/// HTTP 协议：
///   POST /weimi/send   文件
///   POST /weimi/text   文本（UTF-8）
///   Header: X-Weimi-App / X-Sender-Id / X-Sender-Name(URL编码) /
///           X-File-Name(URL编码) / X-File-Size | X-Text-Length
///   Response: 200 {"ok":true,...} / 403 拒收 / 500 失败
///
/// 网页快传（Snapdrop 式）：
///   GET  /              网页快传首页（浏览器打开即可发文件/文本给本机）
///   POST /web/upload?name=文件名   浏览器上传文件（免确认直接收）
///   POST /web/text      浏览器发送文本
///   开关：web_share_enabled（默认开），关闭后 GET / 返回 404
class LanTransferService {
  static const int discoveryPort = 52346;
  static const int defaultHttpPort = 52345;
  static const int maxHttpPort = defaultHttpPort + 20;
  static const String _magic = 'weimi';
  static const String _kDeviceIdKey = 'lan_device_id';
  static const String _kDeviceNameKey = 'lan_device_name';
  static const String _kWebShareKey = 'web_share_enabled';
  static const String _kReceiveDirKey = 'lan_receive_dir';
  static const String _kDiscoverKey = 'lan_discover_enabled';
  /// WS 房间里 App 虚拟设备的固定 id
  static const String kAppPeerId = 'app';
  static const MethodChannel _fgsChannel =
      MethodChannel('com.weimi95.weimi/transfer');

  // ============ 身份 ============
  String _identityId = '';
  String _selfName = '';

  // ============ 状态 ============
  final Map<String, LanPeer> _peers = {}; // key: deviceId
  bool _receiving = false;
  bool _discovering = false;
  bool _backgroundMode = false;
  bool _webShareEnabled = true;
  String _receiveDir = '';
  bool _discoverEnabled = true;
  // Snapdrop 式 WS 房间：浏览器客户端表
  final Map<String, WebPeer> _webPeers = {};
  int _webPeerSeq = 0;
  // 每个 WS 连接当前正在接收的文件状态（file-start 后的 binary 帧流）
  final Map<WebSocket, _WebInbound> _webInbound = {};
  // App 正在接收的网页文件（同一时刻只允许一个，避免写盘竞争）
  _WebInbound? _appInbound;
  int _httpPort = defaultHttpPort;
  Timer? _announceTimer;
  Timer? _pruneTimer;
  Timer? _manualKeepAliveTimer;
  // 精简版（Windows）：轮询 daemon 拿微密设备列表 + 合并历史，替代 UI 自绑端口
  Timer? _daemonPollTimer;
  RawDatagramSocket? _udpSocket;
  HttpServer? _httpServer;

  // ============ 手动添加对端 IP（跨网段方案 A，v1.2.13） ============
  /// 用户手动添加的 IP（可带 ":端口" 覆盖三种协议默认端口）。
  /// 广播/组播不跨路由器，跨网段唯一通路是单播——手动 IP 让
  /// 「微密 announce / LANDrop query / LocalSend register」都改成
  /// 向该 IP 单播，从而发现并保活对端。
  List<String> _manualIps = [];
  bool _manualProbing = false;

  /// 接收文件兜底目录（main.dart 启动时用 path_provider 注入）
  String? fallbackDir;

  final StreamController<LanEvent> _events =
      StreamController<LanEvent>.broadcast();
  Stream<LanEvent> get events => _events.stream;

  /// 供 LocalSend 兼容层等外部模块发射事件（events 是只读 Stream）。
  void emitEvent(LanEvent event) => _events.add(event);

  /// 收到传入请求时的确认回调（UI 弹窗），返回 true 才接收。
  /// 仅前台且对方未信任时调用；信任设备与后台模式不经过此回调。
  /// 返回 IncomingDecision：accepted=本次是否接收；batchDefault=用户勾选了
  /// 「同批后续文件也按此处理」（确认框复选框，默认勾选）。
  Future<IncomingDecision> Function(IncomingRequest request)? confirmHandler;

  /// 最近一次发送失败的错误详情（诊断用）
  String lastSendError = '';

  LanTransferService._();
  static final LanTransferService instance = LanTransferService._();

  String get identityId => _identityId;
  String get selfName => _selfName;
  bool get isReceiving => _receiving;
  bool get backgroundMode => _backgroundMode;
  bool get webShareEnabled => _webShareEnabled;
  int get httpPortActual => _httpPort;
  List<LanPeer> get peers => _peers.values.toList();
  List<WebPeer> get webPeers => _webPeers.values.toList();

  /// App 退到后台时置 true（HomePage 生命周期驱动）：
  /// 此时无法弹确认框 —— 信任设备直收、非信任设备拒收。
  set backgroundMode(bool v) => _backgroundMode = v;

  Future<void> _ensureIdentity() async {
    if (_identityId.isNotEmpty) return;
    await TrustedDevices.instance.load();
    final prefs = await SharedPreferences.getInstance();
    String? id = prefs.getString(_kDeviceIdKey);
    if (id == null || id.isEmpty) {
      id = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      await prefs.setString(_kDeviceIdKey, id);
    }
    _identityId = id;
    final name = prefs.getString(_kDeviceNameKey);
    _selfName =
        (name == null || name.isEmpty) ? Platform.localHostname : name;
    _webShareEnabled = prefs.getBool(_kWebShareKey) ?? true;
    _receiveDir = prefs.getString(_kReceiveDirKey) ?? '';
    _discoverEnabled = prefs.getBool(_kDiscoverKey) ?? true;
  }

  /// 网页快传开关（默认开）
  Future<void> setWebShareEnabled(bool v) async {
    _webShareEnabled = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kWebShareKey, v);
  }

  /// 飞传接收保存目录（独立设置，与「加密文件存放目录」无关；
  /// 未指定时用 defaultReceiveDir()）
  String get receiveDir => _receiveDir;

  Future<void> setReceiveDir(String dir) async {
    _receiveDir = dir.trim();
    final prefs = await SharedPreferences.getInstance();
    if (_receiveDir.isEmpty) {
      await prefs.remove(_kReceiveDirKey);
    } else {
      await prefs.setString(_kReceiveDirKey, _receiveDir);
    }
  }

  /// 可被发现：是否广播/应答 UDP 52346。关闭后其他设备搜不到本机，
  /// 但 HTTP 接收端口保留，直接传/网页版仍能收到。
  bool get discoverEnabled => _discoverEnabled;

  Future<void> setDiscoverEnabled(bool v) async {
    _discoverEnabled = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kDiscoverKey, v);
    } catch (_) {}
    if (v) {
      await startDiscovery();
    } else {
      _discovering = false;
      await stopReceiving();
    }
  }

  /// 启动/托盘常驻时按设置决定是否开启发现（幂等）
  Future<void> applyDiscoverSetting() async {
    await _ensureIdentity();
    if (_discoverEnabled) {
      await startDiscovery();
    } else {
      _discovering = false;
      await stopReceiving();
    }
  }

  Future<void> setSelfName(String name) async {
    _selfName = name.trim().isEmpty ? Platform.localHostname : name.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDeviceNameKey, _selfName);
    if (_receiving) await _broadcastAnnounce();
  }

  /// 本机所有候选局域网 IPv4。
  /// 过滤常见虚拟网卡（ZeroTier/VPN/WSL/Docker 等），并按「最可能是真实局域网」排序。
  Future<List<String>> localIPv4s() async {
    final virtual = RegExp(
      r'zerotier|vgate|virtual|vmware|vbox|hyper-?v|wsl|docker|vpn|tap|tun|teredo|bluetooth',
      caseSensitive: false,
    );
    final out = <String>[];
    try {
      final ifs = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final ni in ifs) {
        if (virtual.hasMatch(ni.name)) continue;
        for (final a in ni.addresses) {
          if (!a.isLoopback &&
              !a.address.startsWith('169.254') &&
              !out.contains(a.address)) {
            out.add(a.address);
          }
        }
      }
    } catch (_) {}
    // 排序：192.168 段最常见排最前，其次 10. 段，再 172. 段
    int rank(String ip) {
      if (ip.startsWith('192.168.')) return 0;
      if (ip.startsWith('10.')) return 1;
      return 2;
    }
    out.sort((a, b) => rank(a).compareTo(rank(b)));
    return out;
  }

  /// 本机主局域网 IPv4（多网卡时选最可能是真实局域网的）
  Future<String?> localIPv4() async {
    final all = await localIPv4s();
    return all.isEmpty ? null : all.first;
  }

  // ============ 接收端 ============

  /// 开启接收（UDP 应答 + HTTP 服务器 + Android 前台服务）。重复调用幂等。
  Future<void> startReceiving() async {
    if (_receiving) return;
    await _ensureIdentity();
    // LocalSend v2 兼容层随接收开关启停（组播 announce + 53317 server）。
    // 各协议启动相互隔离：任一失败只记日志，不拖垮后续步骤与设备列表
    // （v1.2.15 实机教训：串行无容错时一个 bind 抛异常 → 整页设备空白）。
    try {
      await LocalSendService.instance.start();
    } catch (e) {
      debugPrint('微密飞传：LocalSend 兼容层启动失败（不影响其他协议）: $e');
    }
    // LANDrop v2 兼容层随接收开关启停（UDP 52637 发现 + TCP 服务）
    try {
      await LandropService.instance.start();
    } catch (e) {
      debugPrint('微密飞传：LANDrop 兼容层启动失败（不影响其他协议）: $e');
    }

    if (_udpSocket == null) {
      if (Platform.isWindows) {
        // 精简版：Windows 由 daemon 永久持有 52346/52345，UI 不再占用这两个端口
        // （彻底消灭双进程抢端口）。UDP 改绑临时端口，仅用于「手动 IP/网段」的
        // 定向探测；常规网络发现改由 _pollDaemon 轮询 daemon listPeers。
        try {
          final socket = await RawDatagramSocket.bind(
            InternetAddress.anyIPv4,
            0, // 临时端口
            reuseAddress: true,
          );
          socket.broadcastEnabled = true;
          socket.listen(_onUdpDatagram);
          _udpSocket = socket;
        } catch (e) {
          // 临时端口绑不上极罕见：手动 IP 探测不可用，但不影响 daemon 轮询发现
          debugPrint('微密飞传：临时 UDP 端口绑定失败（手动 IP 探测不可用）: $e');
        }
        // 通告 daemon 实际占用的端口（52345），供对端回传文件到本机
        _httpPort = defaultHttpPort;
      } else {
        final socket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          discoveryPort,
          reuseAddress: true,
        );
        socket.broadcastEnabled = true;
        socket.listen(_onUdpDatagram);
        _udpSocket = socket;
      }
    }

    // Windows：接收/发现端口由 daemon 持有，UI 不绑 HTTP（52345）
    if (_httpServer == null && !Platform.isWindows) {
      await _bindHttpServer();
    }

    _receiving = true;
    _announceTimer?.cancel();
    _announceTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _broadcastAnnounce());
    // 手动添加的对端 IP/网段（跨网段方案 A）：载入 + 保活 + 首轮延迟探测
    await loadManualIps();
    _startManualKeepAlive();
    if (_manualIps.isNotEmpty) {
      Future<void>.delayed(const Duration(seconds: 3), () async {
        for (final raw in List.of(_manualIps)) {
          final e = parseManualEntry(raw);
          if (e != null) await probeManualEntry(e);
        }
      });
    }
    // 精简版（Windows）：daemon 永久持有发现/接收端口，UI 轮询设备列表 +
    // 合并 daemon 期间收到的文件，常规网络发现不再由 UI 自绑端口完成。
    if (Platform.isWindows) {
      _daemonPollTimer?.cancel();
      _daemonPollTimer =
          Timer.periodic(const Duration(seconds: 2), (_) => _pollDaemon());
      _pollDaemon(); // 立即拉一次
    }
    _events.add(LanEvent(LanEventType.receivingStarted));
    _startAndroidForeground();
  }

  /// HTTP 端口被占用时自动 +1（最多试到 52365），announce 带实际端口。
  /// Windows 先等 52345 空出来（daemon 交接），绑不上再扫备用端口。
  Future<void> _bindHttpServer() async {
    final isWin = Platform.isWindows;
    if (isWin) {
      for (var i = 0; i < 20; i++) {
        try {
          _httpServer = await HttpServer.bind(
              InternetAddress.anyIPv4, defaultHttpPort,
              shared: false);
          _httpPort = defaultHttpPort;
          _httpServer!.listen(_onHttpRequest, onError: (_) {});
          return;
        } on SocketException {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
    }
    SocketException? lastErr;
    for (int port = defaultHttpPort; port <= maxHttpPort; port++) {
      try {
        _httpServer = await HttpServer.bind(
            InternetAddress.anyIPv4, port,
            shared: !isWin);
        _httpPort = port;
        if (port != defaultHttpPort) {
          debugPrint('微密飞传：端口 $defaultHttpPort 被占用，改用 $port');
        }
        _httpServer!.listen(_onHttpRequest, onError: (_) {});
        return;
      } on SocketException catch (e) {
        lastErr = e;
      }
    }
    throw lastErr ?? SocketException('无可用的 HTTP 端口（52345-52365）');
  }

  /// Android 前台服务（后台保活）。失败不阻塞接收。
  Future<void> _startAndroidForeground() async {
    if (!Platform.isAndroid) return;
    try {
      await _fgsChannel.invokeMethod('startForeground');
    } catch (e) {
      debugPrint('startForeground failed: $e');
    }
  }

  Future<void> _stopAndroidForeground() async {
    if (!Platform.isAndroid) return;
    try {
      await _fgsChannel.invokeMethod('stopForeground');
    } catch (e) {
      debugPrint('stopForeground failed: $e');
    }
  }

  /// 停止接收（不再广播自己；UDP/HTTP 端口保留以便后续快速重开）
  Future<void> stopReceiving() async {
    if (!_receiving) return;
    _receiving = false;
    _announceTimer?.cancel();
    _announceTimer = null;
    _manualKeepAliveTimer?.cancel();
    _manualKeepAliveTimer = null;
    _daemonPollTimer?.cancel();
    _daemonPollTimer = null;
    await LocalSendService.instance.stop();
    await LandropService.instance.stop();
    _events.add(LanEvent(LanEventType.receivingStopped));
    _stopAndroidForeground();
  }

  void _onUdpDatagram(RawSocketEvent ev) {
    final socket = _udpSocket;
    if (socket == null || ev != RawSocketEvent.read) return;
    final dg = socket.receive();
    if (dg == null) return;
    try {
      final msg = json.decode(utf8.decode(dg.data)) as Map<String, dynamic>;
      if (msg['app'] != _magic) return;
      if (msg['id'] == _identityId) return; // 自己
      final peer = LanPeer(
        id: msg['id'] as String,
        name: (msg['name'] as String?) ?? '未知设备',
        ip: dg.address.address,
        httpPort: (msg['httpPort'] as int?) ?? defaultHttpPort,
        trusted: TrustedDevices.instance.isTrustedSync(msg['id'] as String),
        lastSeen: DateTime.now(),
      );
      addOrUpdatePeer(peer);
      // v1.2.18：学习对端的网页客户端清单 → rweb_ 虚拟会话
      //（发送时 POST 到对端 httpPort 带 X-Weimi-To，由对端转进其 WS 房间）
      final wpList = msg['webPeers'];
      if (wpList is List) {
        final seen = <String>{};
        for (final w in wpList.whereType<Map>()) {
          final wid = (w['id'] as String?) ?? '';
          if (wid.isEmpty) continue;
          seen.add(wid);
          final wname = ((w['name'] as String?) ?? '').trim();
          addOrUpdatePeer(LanPeer(
            id: 'rweb_$wid',
            name: '网页客户端(${wname.isEmpty ? '匿名' : wname})',
            ip: dg.address.address,
            httpPort: (msg['httpPort'] as int?) ?? defaultHttpPort,
            trusted: false,
            lastSeen: DateTime.now(),
          ));
        }
        // 该主机最新清单里没有的 = 浏览器已关闭，移除
        final gone = _peers.keys
            .where((k) =>
                k.startsWith('rweb_') &&
                _peers[k]!.ip == dg.address.address &&
                !seen.contains(k.substring(5)))
            .toList();
        for (final k in gone) {
          _peers.remove(k);
        }
        if (gone.isNotEmpty) _events.add(LanEvent(LanEventType.peersChanged));
      }
      // 收到 announce：向对方来源端口单播应答，让它也知道我
      if (msg['action'] == 'announce') {
        _sendReply(dg.address.address, dg.port);
      }
    } catch (_) {}
  }

  void _sendReply(String ip, int port) {
    final socket = _udpSocket;
    if (socket == null || port == 0) return;
    final body = utf8.encode(json.encode(_announcePacket('reply')));
    try {
      socket.send(body, InternetAddress(ip), port);
    } catch (_) {}
  }

  /// announce/reply 包体（v1.2.18：带本机网页客户端清单，远端据此生成
  /// rweb_ 虚拟会话；对端旧版本忽略未知字段，向后兼容）。
  Map<String, dynamic> _announcePacket(String action) {
    final packet = <String, dynamic>{
      'app': _magic,
      'action': action,
      'id': _identityId,
      'name': _selfName,
      'httpPort': _httpPort,
      'v': 1,
    };
    if (_webPeers.isNotEmpty) {
      packet['webPeers'] = _webPeers.values
          .map((w) => {'id': w.id, 'name': w.name})
          .toList();
    }
    return packet;
  }

  Future<void> _broadcastAnnounce() async {
    final socket = _udpSocket;
    if (socket == null || !_receiving) return;
    final body = utf8.encode(json.encode(_announcePacket('announce')));
    // 255.255.255.255 + 本机各私网网段的定向广播 + 手动添加的对方网段
    // 定向广播：多网卡/虚拟网卡环境（有线+WiFi+VPN/VM）下 255.255.255.255
    // 的出口由系统选，经常到不了对方网段；定向广播按目标 IP 明确走对应
    // 网卡（v1.2.13 与 LANDrop 兼容层统一收编到 [directedBroadcastIps]）；
    // 手动网段（跨路由器）同样靠定向广播单播通路发现（方案 A）。
    // 精简版（Windows）：常规网络广播由 daemon 完成，UI 只发手动网段定向广播，
    // 避免从临时端口重复广播；Android 仍由 UI 全量广播。
    final targets = <String>[];
    if (!Platform.isWindows) {
      targets.add('255.255.255.255');
      for (final b in directedBroadcastIps(await localIPv4s())) {
        if (!targets.contains(b)) targets.add(b);
      }
    }
    for (final b in _manualSubnetBroadcasts()) {
      if (!targets.contains(b)) targets.add(b);
    }
    for (final t in targets) {
      try {
        socket.send(body, InternetAddress(t), discoveryPort);
      } catch (_) {}
    }
  }

  /// 精简版（Windows）：从 daemon 拉取微密设备列表（daemon 永久持有发现端口，
  /// 收到 announce/reply 即入表），并入本机 _peers；同时合并 daemon 期间收到的
  /// 文件，让聊天/历史实时可见。UI 自身不再绑 52346/52345。
  Future<void> _pollDaemon() async {
    if (!Platform.isWindows) return;
    try {
      final peers = await DaemonService.listPeers();
      for (final p in peers) {
        final id = (p['id'] as String?) ?? '';
        if (id.isEmpty || id == _identityId) continue;
        addOrUpdatePeer(LanPeer(
          id: id,
          name: (p['name'] as String?) ?? '未知设备',
          ip: (p['ip'] as String?) ?? '',
          httpPort: (p['httpPort'] as int?) ?? defaultHttpPort,
          trusted: TrustedDevices.instance.isTrustedSync(id),
          lastSeen: DateTime.now(),
        ));
      }
    } catch (_) {}
    // 网页客户端（连进 daemon 网页版的浏览器）也作为会话对象并入：
    // id 加 ws_ 前缀与设备 peer 区分，发文件/文本走 daemon 52349 转推。
    // v1.2.18：远端主机的网页客户端（rweb_ 前缀，daemon 学习自 announce）
    // 直接 POST 到对端 httpPort 带 X-Weimi-To 中继，不再经本机 daemon。
    try {
      final wp = await DaemonService.webPeersInfo();
      if (wp != null) {
        final port = (wp['port'] as int?) ?? defaultHttpPort;
        final list = wp['webPeers'];
        if (list is List) {
          for (final p in list.whereType<Map>()) {
            var id = (p['id'] as String?) ?? '';
            if (id.isEmpty) continue;
            final name = ((p['name'] as String?) ?? '').trim();
            final remote = p['remote'] == true;
            String peerId;
            var httpPort = port;
            if (remote) {
              peerId = id; // daemon 已带 rweb_ 前缀
              httpPort = (p['port'] as int?) ?? defaultHttpPort;
            } else {
              peerId = 'ws_$id';
            }
            addOrUpdatePeer(LanPeer(
              id: peerId,
              name: remote
                  ? name
                  : '网页客户端(${name.isEmpty ? '匿名' : name})',
              ip: (p['ip'] as String?) ?? '',
              httpPort: httpPort,
              trusted: false,
              lastSeen: DateTime.now(),
            ));
          }
        }
      }
    } catch (_) {}
    try {
      await DaemonService.mergeDaemonHistory();
    } catch (_) {}
  }

  /// 本机各私网 IPv4（192.168/10/172.16-31）推算的 /24 定向广播地址。
  /// 广播类发现（微密 announce / LANDrop 兼容层 query+announce）共用：
  /// 只发 255.255.255.255 在多网卡机器上会选错出口网卡，导致同网段设备
  /// 发现不了（v1.2.13：电脑端发现不了其他电脑 LANDrop 的根因之一）。
  /// [myIps] 传 [localIPv4s] 的结果（已过滤虚拟网卡）。
  static List<String> directedBroadcastIps(List<String> myIps) {
    final out = <String>[];
    for (final myIp in myIps) {
      final parts = myIp.split('.');
      if (parts.length != 4) continue;
      final a = int.tryParse(parts[0]);
      final b = int.tryParse(parts[1]);
      if (a == null || b == null) continue;
      final isPrivate =
          (a == 192 && b == 168) || a == 10 || (a == 172 && b >= 16 && b <= 31);
      if (!isPrivate) continue; // 公网 IP 推 .255 定向广播无意义
      final sub = '${parts[0]}.${parts[1]}.${parts[2]}.255';
      if (!out.contains(sub)) out.add(sub);
    }
    return out;
  }

  // ============ 手动添加对端 IP / 网段（跨网段方案 A，v1.2.13） ============
  /// 参考飞鸽传书「设置 → 系统设置 → 添加网段」：跨网段（不同路由器）时
  /// 广播/组播都不过路由器，唯一通路是单播。两种录入格式：
  /// - 单 IP：`192.168.2.50` 或 `192.168.2.50:52346`（冒号端口对三种
  ///   协议的默认端口一并生效，留空则各用各的默认端口）
  /// - 网段：`192.168.2` 或 `192.168.2.0/24`（向 192.168.2.255 定向
  ///   广播发现整个网段，DHCP 换 IP 不掉）
  /// 飞鸽经验「双方都要添加对方网段，只加一边看不到」：微密协议收到
  /// announce 会单播应答，单方添加理论上即可被发现；但对方若要反向
  /// 发现我们，同样得添加我方网段——故建议双方都加。
  List<String> get manualIps => List.unmodifiable(_manualIps);

  /// 从 SharedPreferences 载入手动条目（启动/开接收时调用）。
  Future<void> loadManualIps() async {
    final prefs = await SharedPreferences.getInstance();
    _manualIps = prefs.getStringList('manual_peer_ips') ?? [];
  }

  /// 手动连接条目（class 而非 record typedef——Dart record 无命名构造函数）。
  static ManualEntry? parseManualEntry(String entry) {
    final s = entry.trim();
    if (s.isEmpty) return null;
    // 网段：x.x.x.0/24 或 x.x.x
    if (s.contains('/')) {
      final parts = s.split('/');
      if (parts.length != 2) return null;
      final mask = int.tryParse(parts[1]);
      if (mask != 24) return null;
      final seg = parts[0].split('.');
      if (seg.length != 4) return null;
      if (seg[3] != '0') return null; // 只接受 .0/24 形式
      final head = seg.take(3).toList();
      for (final x in head) {
        final n = int.tryParse(x);
        if (n == null || n < 0 || n > 255) return null;
      }
      final sub = head.join('.');
      return ManualEntry(
        isSubnet: true,
        raw: sub,
        subnet: sub,
        broadcast: '$sub.255',
      );
    }
    if (!s.contains(':')) {
      final seg = s.split('.');
      if (seg.length == 3) {
        for (final x in seg) {
          final n = int.tryParse(x);
          if (n == null || n < 0 || n > 255) return null;
        }
        return ManualEntry(
          isSubnet: true,
          raw: s,
          subnet: s,
          broadcast: '$s.255',
        );
      }
    }
    // 单 IP（可带 :端口）
    final idx = s.lastIndexOf(':');
    if (idx > 0) {
      final ip = s.substring(0, idx);
      final port = int.tryParse(s.substring(idx + 1));
      if (port == null || port < 1 || port > 65535) return null;
      if (!_isIPv4(ip)) return null;
      return ManualEntry(isSubnet: false, raw: '$ip:$port', ip: ip, port: port);
    }
    if (!_isIPv4(s)) return null;
    return ManualEntry(isSubnet: false, raw: s, ip: s);
  }

  static bool _isIPv4(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return false;
    for (final seg in parts) {
      final n = int.tryParse(seg);
      if (n == null || n < 0 || n > 255) return false;
      if (seg.length > 1 && seg.startsWith('0')) return false; // 禁前导零
    }
    return true;
  }

  /// 添加手动条目：持久化 + 立即探测一次。返回结果文案（UI 提示）。
  Future<String> addManualIp(String entry) async {
    final parsed = parseManualEntry(entry);
    if (parsed == null) {
      return '格式不正确。单 IP：192.168.2.50（可加 :端口）；网段：192.168.2 或 192.168.2.0/24';
    }
    if (_manualIps.contains(parsed.raw)) return '该条目已在列表中';
    _manualIps.add(parsed.raw);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('manual_peer_ips', _manualIps);
    _startManualKeepAlive();
    final found = await probeManualEntry(parsed);
    if (found.isNotEmpty) return '已发现：${found.join('、')}';
    return parsed.isSubnet
        ? '已添加网段 ${parsed.subnet}，暂未发现设备（确认对端在线、两个网段网络互通）'
        : '已添加，但暂未收到响应（确认对端已开启接收且网络可达）';
  }

  /// 移除手动条目（传列表里的原文）。
  Future<void> removeManualIp(String raw) async {
    _manualIps.remove(raw);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('manual_peer_ips', _manualIps);
    if (_manualIps.isEmpty) {
      _manualKeepAliveTimer?.cancel();
      _manualKeepAliveTimer = null;
    }
  }

  /// 微密 announce UDP 包（单播/定向广播共用）。
  List<int> _announceBody() => utf8.encode(json.encode({
        'app': _magic,
        'action': 'announce',
        'id': _identityId,
        'name': _selfName,
        'httpPort': _httpPort,
        'v': 1,
      }));

  /// 探测一个手动条目，返回新发现的设备描述列表。
  /// - host：向 IP 单播 announce + LANDrop query + LocalSend register
  /// - subnet：向 x.x.x.255 定向广播 announce + LANDrop query
  ///   （LocalSend 无广播发现，跨网段请用单 IP 形式）
  /// 等待约 2s 收集应答后差集统计。
  Future<List<String>> probeManualEntry(ManualEntry e) async {
    if (_manualProbing) return const [];
    _manualProbing = true;
    try {
      // 局部函数不能加 final（CI 实证：Can't have modifier 'final' here）
      bool match(String ip) =>
          e.isSubnet ? ip.startsWith('${e.subnet}.') : ip == e.ip;
      final before = <String>{
        for (final p in _peers.values)
          if (match(p.ip)) p.id,
        for (final d in LandropService.instance.devices)
          if (match(d.address)) 'ld:${d.publicKey}',
      };
      final sock = _udpSocket;
      if (sock != null) {
        final target = e.isSubnet ? e.broadcast! : e.ip!;
        final port = e.isSubnet
            ? discoveryPort
            : (e.port ?? discoveryPort);
        try {
          sock.send(_announceBody(), InternetAddress(target), port);
        } catch (_) {}
      }
      try {
        LandropService.instance.queryManual(e.isSubnet ? e.broadcast! : e.ip!);
      } catch (_) {}
      if (!e.isSubnet) {
        try {
          await LocalSendService.instance.registerManual(e.ip!, port: e.port);
        } catch (_) {}
      }
      await Future<void>.delayed(const Duration(milliseconds: 2000));
      final found = <String>[];
      for (final p in _peers.values) {
        if (match(p.ip) && !before.contains(p.id)) {
          found.add(p.isLocalSend ? 'LocalSend 设备「${p.name}」' : '微密设备「${p.name}」');
        }
      }
      for (final d in LandropService.instance.devices) {
        if (match(d.address) && !before.contains('ld:${d.publicKey}')) {
          found.add('LANDrop 设备「${d.name}」');
        }
      }
      return found;
    } finally {
      _manualProbing = false;
    }
  }

  /// 网段条目的定向广播地址清单（供 _broadcastAnnounce 合并目标）。
  List<String> _manualSubnetBroadcasts() {
    final out = <String>[];
    for (final raw in _manualIps) {
      final e = parseManualEntry(raw);
      if (e != null && e.isSubnet && !out.contains(e.broadcast)) {
        out.add(e.broadcast!);
      }
    }
    return out;
  }

  /// 手动条目保活：跨网段没有广播/组播，必须周期单播续命，否则设备
  /// 12s（微密 prune）/20s（LANDrop 过期）后就掉线。
  void _startManualKeepAlive() {
    if (_manualKeepAliveTimer != null) return;
    if (_manualIps.isEmpty) return;
    _manualKeepAliveTimer ??= Timer.periodic(
        const Duration(seconds: 15), (_) => _manualKeepAlive());
  }

  Future<void> _manualKeepAlive() async {
    if (_manualIps.isEmpty) return;
    final sock = _udpSocket;
    for (final raw in List.of(_manualIps)) {
      final e = parseManualEntry(raw);
      if (e == null) continue;
      if (sock != null) {
        final target = e.isSubnet ? e.broadcast! : e.ip!;
        final port = e.isSubnet ? discoveryPort : (e.port ?? discoveryPort);
        try {
          sock.send(_announceBody(), InternetAddress(target), port);
        } catch (_) {}
      }
      try {
        LandropService.instance.queryManual(e.isSubnet ? e.broadcast! : e.ip!);
      } catch (_) {}
      if (!e.isSubnet) {
        try {
          await LocalSendService.instance.registerManual(e.ip!, port: e.port);
        } catch (_) {}
      }
    }
  }

  /// 登记/刷新设备。同一物理设备可能同时跑着微密+LocalSend 两个 App，
  /// 按 IP 合并成一条：微密项优先，LocalSend 链路挂上来，旧 LS 条目移除。
  void addOrUpdatePeer(LanPeer peer) {
    // ① 自研协议设备到达：若已有同 IP 的 LocalSend 条目（对方先被组播发现），
    // 把它的 LocalSend 链路继承过来，然后移除旧条目——合并为一条 weimi 记录。
    if (peer.protocol == 'weimi') {
      final dup = _findPeer(
          (p) => p.protocol == 'localsend' && p.ip == peer.ip);
      if (dup != null) {
        _peers.remove(dup.id);
        peer = peer.copyWith(lsPort: dup.httpPort, lsHttps: dup.https);
      }
    }
    _peers[peer.id] = peer;
    // ② 兜底归一化：同 IP 微密+LS 并存（任何时序竞态残留）一律合并
    _normalizeByIp();
    _events.add(LanEvent(LanEventType.peersChanged));
    // v1.2.18：设备进出场同步给已打开的网页端（房间成员含局域网设备）
    _broadcastWebPeers();
    _pruneTimer ??=
        Timer.periodic(const Duration(seconds: 5), (_) => _prunePeers());
  }

  LanPeer? _findPeer(bool Function(LanPeer) test) {
    for (final p in _peers.values) {
      if (test(p)) return p;
    }
    return null;
  }

  /// LocalSend 兼容层登记设备用：按 IP 合并。
  /// 铁律：**微密项永远优先**——同一 IP 只要存在微密条目，LocalSend 就
  /// 只以链路（lsPort/lsHttps）形式挂在它上面，绝不新增独立条目。
  /// - 同 IP 已有微密设备 → 只挂/更新 LocalSend 链路并续命（无论该微密条目
  ///   此前是否已挂过链路——已挂过就只刷新，不能再穿帮新增条目，
  ///   这正是 v1.0.70 修复的「双条」bug：LS announce 约 2s 一次，
  ///   只匹配「无链路 weimi」会让每条 announce 都新建一条纯 LS 条目）；
  /// - 同 IP 已有 LocalSend 条目 → 刷新（对端只装真 LocalSend App 的场景）；
  /// - 都没有 → 新增 LocalSend 设备。
  /// 另外：微密条目被 LS announce 刷新 lastSeen = 跨协议续命，
  /// 手机微密侧 announce 因省电延迟时合并条目也不会被 prune 掉。
  void attachLocalSendLink({
    required String ip,
    required int port,
    required bool https,
    String? name,
    String? fingerprint,
  }) {
    final weimi = _findPeer((p) => p.protocol == 'weimi' && p.ip == ip);
    if (weimi != null) {
      var merged = weimi;
      if (!weimi.hasLocalSendLink || weimi.lsPort != port) {
        merged = weimi.copyWith(lsPort: port, lsHttps: https);
      }
      merged.lastSeen = DateTime.now();
      _peers[weimi.id] = merged;
      _events.add(LanEvent(LanEventType.peersChanged));
      return;
    }
    final ls = _findPeer((p) => p.protocol == 'localsend' && p.ip == ip);
    if (ls != null) {
      ls.lastSeen = DateTime.now();
      _peers[ls.id] = ls;
      _events.add(LanEvent(LanEventType.peersChanged));
      return;
    }
    final fp = (fingerprint == null || fingerprint.isEmpty) ? ip : fingerprint;
    addOrUpdatePeer(LanPeer(
      id: 'ls_$fp',
      name: name ?? 'LocalSend 设备',
      ip: ip,
      httpPort: port,
      lastSeen: DateTime.now(),
      protocol: 'localsend',
      https: https,
    ));
  }

  /// 兜底归一化：同一 IP 不允许微密条目与 LocalSend 条目并存——
  /// 微密项优先保留，LocalSend 链路挂上去，纯 LS 条目移除；
  /// lastSeen 取两者较新（防把刚被 LS 续过命的微密项变旧遭 prune）。
  /// 正常路径（attachLocalSendLink / addOrUpdatePeer）已保证不产生重复，
  /// 这里防御时序竞态与历史脏数据，在 peers 变更入口统一调用。
  void _normalizeByIp() {
    if (_peers.length < 2) return;
    var changed = false;
    for (final w in _peers.values
        .where((p) => p.protocol == 'weimi' && !p.id.startsWith('rweb_'))
        .toList()) {
      final ls = _findPeer((p) => p.protocol == 'localsend' && p.ip == w.ip);
      if (ls == null) continue;
      _peers.remove(ls.id);
      var merged = w;
      if (!w.hasLocalSendLink || w.lsPort != ls.httpPort) {
        merged = w.copyWith(lsPort: ls.httpPort, lsHttps: ls.https);
      }
      if (ls.lastSeen.isAfter(merged.lastSeen)) merged.lastSeen = ls.lastSeen;
      _peers[w.id] = merged;
      changed = true;
    }
    if (changed) _events.add(LanEvent(LanEventType.peersChanged));
  }

  void _prunePeers() {
    final now = DateTime.now();
    final before = _peers.length;
    // rweb_ 虚拟会话跟随对端 announce 刷新，单独放宽到 40s（对端停止
    // announce 或清单里移除时由 _onUdpDatagram 同步删除，这里只兜底）
    _peers.removeWhere((k, p) =>
        !k.startsWith('rweb_') && now.difference(p.lastSeen).inSeconds > 12);
    _peers.removeWhere((k, p) =>
        k.startsWith('rweb_') && now.difference(p.lastSeen).inSeconds > 40);
    if (_peers.length != before) {
      _events.add(LanEvent(LanEventType.peersChanged));
      _broadcastWebPeers();
    }
  }

  // ============ 接收端：HTTP 处理 ============

  Future<void> _onHttpRequest(HttpRequest req) async {
    try {
      // ============ 网页快传（Snapdrop 式） ============
      if (req.method == 'GET' &&
          (req.uri.path == '/' || req.uri.path == '/index.html')) {
        if (_webShareEnabled) {
          req.response.headers.contentType = ContentType.html;
          req.response.headers.add('Cache-Control', 'no-cache');
          req.response.write(_webSharePage());
        } else {
          req.response.statusCode = HttpStatus.notFound;
        }
        await req.response.close();
        return;
      }
      // Snapdrop 式 WebSocket 房间
      if (req.uri.path == '/ws') {
        await _handleWebSocket(req);
        return;
      }
      if (req.method == 'POST' && req.uri.path == '/web/upload') {
        await _guardReceiving(req, _handleWebUpload);
        return;
      }
      if (req.method == 'POST' && req.uri.path == '/web/text') {
        await _guardReceiving(req, _handleWebText);
        return;
      }
      // ============ App 间传输 ============
      if (req.method == 'POST' && req.uri.path == '/weimi/send') {
        await _guardReceiving(req, _handleIncomingFile);
        return;
      }
      if (req.method == 'POST' && req.uri.path == '/weimi/text') {
        await _guardReceiving(req, _handleIncomingText);
        return;
      }
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
    } catch (e) {
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        req.response.write(json.encode({'ok': false, 'error': '$e'}));
        await req.response.close();
      } catch (_) {}
    }
  }

  /// 接收开关关闭时拒收所有上传（端口保留供快速重开，但不收新数据）
  Future<void> _guardReceiving(
      HttpRequest req, Future<void> Function(HttpRequest) handler) async {
    if (!_receiving) {
      req.response.statusCode = HttpStatus.serviceUnavailable;
      req.response.write(json.encode({'ok': false, 'error': 'receiving off'}));
      await req.response.close();
      return;
    }
    await handler(req);
  }

  String _header(HttpRequest req, String name) {    final v = req.headers.value(name) ?? '';
    if (v.isEmpty) return v;
    try {
      return Uri.decodeComponent(v);
    } catch (_) {
      return v;
    }
  }

  /// 未信任请求的确认等待秒数（设置可调，下限 5 秒防误设 0）。
  static int confirmTimeoutSecs() {
    final v = SettingStore.get<int>('lan_untrusted_timeout', 30);
    return v < 5 ? 5 : v;
  }

  /// 接收决策（LocalSend 兼容层复用）：信任设备免确认直收；
  /// 未信任设备按设置 lan_untrusted_mode：
  /// - confirm（默认）：弹确认框等待 lan_untrusted_timeout 秒，超时自动拒收
  /// - reject：直接拒收
  /// 未信任批次授权（双向，老板拍板）：
  /// - 接收：确认通过且用户勾选「同批后续也按此处理」后 2 分钟内同设备免再确认
  /// - 拒收：用户勾选后拒收的，2 分钟内同设备直接拒、不再弹框打扰
  /// （手机一次共享多文件 = 逐个/并发 POST，同批只该确认一次）
  final Map<String, DateTime> _batchGrantedUntil = {};
  final Map<String, DateTime> _batchRejectedUntil = {};

  /// single-flight：同设备并发连发多个文件时复用同一次确认。
  /// 手机分享 N 个文件 = N 个 POST 几乎同时到达，只弹一个框，
  /// 全部文件共用用户的这一次决定（=「这一批」的语义）。
  final Map<String, Future<IncomingDecision>> _pendingAsks = {};

  Future<bool> decideAccept(
      {required String senderId,
      required Future<IncomingDecision> Function() ask}) async {
    final d = await decideAcceptDecision(senderId: senderId, ask: ask);
    return d.accepted;
  }

  /// 完整决定版（LANDrop 兼容层需要 trust 标记来持久化信任设备）。
  /// 其余语义与 decideAccept 完全一致。
  Future<IncomingDecision> decideAcceptDecision(
      {required String senderId,
      required Future<IncomingDecision> Function() ask}) async {
    if (TrustedDevices.instance.isTrustedSync(senderId)) {
      return const IncomingDecision(accepted: true, batchDefault: false);
    }
    final now = DateTime.now();
    // 顺手清过期项，防长期膨胀
    _batchGrantedUntil.removeWhere((_, v) => now.isAfter(v));
    _batchRejectedUntil.removeWhere((_, v) => now.isAfter(v));
    final rejected = _batchRejectedUntil[senderId];
    if (rejected != null && now.isBefore(rejected)) {
      return const IncomingDecision(accepted: false, batchDefault: true);
    }
    final granted = _batchGrantedUntil[senderId];
    if (granted != null && now.isBefore(granted)) {
      return const IncomingDecision(accepted: true, batchDefault: false);
    }
    final mode = SettingStore.get<String>('lan_untrusted_mode', 'confirm');
    if (mode == 'reject') {
      return const IncomingDecision(accepted: false, batchDefault: true);
    }
    // single-flight：同设备已有一个请求在等用户确认时，后续请求复用其结果
    final pending = _pendingAsks[senderId];
    if (pending != null) return pending;
    final fut = _askOnce(senderId, ask);
    _pendingAsks[senderId] = fut;
    try {
      return await fut;
    } finally {
      if (_pendingAsks[senderId] == fut) _pendingAsks.remove(senderId);
    }
  }

  Future<IncomingDecision> _askOnce(
      String senderId, Future<IncomingDecision> Function() ask) async {
    IncomingDecision decision;
    try {
      decision = await ask().timeout(
          Duration(seconds: confirmTimeoutSecs()),
          // 超时 = 用户没操作（框可能因窗口未恢复而没被看见），
          // 只拒本条、不拉黑：拉黑会让后续请求也静默失败（v1.2.13）
          onTimeout: () =>
              const IncomingDecision(accepted: false, batchDefault: false));
    } catch (e) {
      // ask 抛异常（窗口恢复失败/对话框挂载失败等）= 系统侧问题，
      // 同样只拒本条不拉黑，避免故障被放大成 2 分钟静默拒收
      debugPrint('lan: confirm ask failed: $e');
      decision = const IncomingDecision(accepted: false, batchDefault: false);
    }
    if (decision.batchDefault) {
      final until = DateTime.now().add(const Duration(minutes: 2));
      if (decision.accepted) {
        _batchGrantedUntil[senderId] = until;
      } else {
        _batchRejectedUntil[senderId] = until;
      }
    }
    return decision;
  }

  /// 某设备当前是否还有进行中的文件接收（按 senderName 计数）。
  /// 供接收完成通知做整批聚合：一批文件的最后一个完成后才汇总提示。
  final Map<String, int> _activeIncomingByName = {};

  bool hasActiveIncomingByName(String senderName) =>
      (_activeIncomingByName[senderName] ?? 0) > 0;

  /// 外部兼容层（LANDrop）登记进行中的接收（供通知整批聚合判批）
  void beginIncomingByName(String senderName) {
    _activeIncomingByName[senderName] =
        (_activeIncomingByName[senderName] ?? 0) + 1;
  }

  void endIncomingByName(String senderName) =>
      _decActiveIncomingByName(senderName);

  void _decActiveIncomingByName(String senderName) {
    final n = (_activeIncomingByName[senderName] ?? 1) - 1;
    if (n <= 0) {
      _activeIncomingByName.remove(senderName);
    } else {
      _activeIncomingByName[senderName] = n;
    }
  }

  Future<void> _handleIncomingFile(HttpRequest req) async {
    if (_header(req, 'X-Weimi-App') != _magic) {
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
      return;
    }

    final request = IncomingRequest(
      senderId: _header(req, 'X-Sender-Id'),
      senderName:
          _header(req, 'X-Sender-Name').isEmpty ? '未知设备' : _header(req, 'X-Sender-Name'),
      fileName:
          _safeFileName(_header(req, 'X-File-Name').isEmpty ? 'unnamed' : _header(req, 'X-File-Name')),
      fileSize: int.tryParse(_header(req, 'X-File-Size')) ?? 0,
    );

    final accepted = await decideAccept(
      senderId: request.senderId,
      ask: () => handlerAsk(request),
    );
    if (!accepted) {
      req.response.statusCode = HttpStatus.forbidden;
      req.response.write(json.encode({'ok': false, 'error': 'rejected'}));
      await req.response.close();
      _events.add(LanEvent(LanEventType.incomingRejected,
          name: request.fileName,
          from: request.senderName,
          trusted: TrustedDevices.instance.isTrustedSync(request.senderId)));
      // 拒收也要留痕：通知 + 传输记录（点开传输记录能看到谁想发什么）
      ReceiveNotifyService.instance.rejected(request.fileName, request.senderName);
      await TransferHistoryService.instance.add(TransferRecord(
        id: '${DateTime.now().microsecondsSinceEpoch}_inr',
        kind: 'file',
        direction: 'in',
        name: request.fileName,
        size: request.fileSize,
        peerName: request.senderName,
        peerKey: request.senderId,
        time: DateTime.now(),
        ok: false,
        note: '未信任，已拒收',
      ));
      return;
    }

    // v1.2.18：X-Weimi-To → 中继给本机网页客户端（设备→网页文件流：
    // file-start + 二进制帧 + file-done，网页端 JS 已有通用接收通路）
    final toWeb = req.headers.value('x-weimi-to') ?? '';
    if (toWeb.isNotEmpty) {
      final target = _webPeers[toWeb];
      if (target == null) {
        req.response.statusCode = HttpStatus.notFound;
        req.response.write(json.encode({'ok': false, 'error': 'web peer offline'}));
        await req.response.close();
        return;
      }
      final fid = 'r${DateTime.now().millisecondsSinceEpoch}';
      _safeAdd(target.socket, json.encode({
        't': 'file-start',
        'from': request.senderId,
        'fromName': request.senderName,
        'name': request.fileName,
        'size': request.fileSize,
        'fid': fid,
      }));
      try {
        await for (final chunk in req) {
          _safeAdd(target.socket, chunk);
        }
        _safeAdd(target.socket, json.encode({'t': 'file-done', 'fid': fid}));
        req.response.statusCode = HttpStatus.ok;
        req.response.write(json.encode({'ok': true}));
      } catch (e) {
        _safeAdd(target.socket, json.encode({'t': 'file-abort', 'fid': fid}));
        req.response.statusCode = HttpStatus.internalServerError;
        req.response.write(json.encode({'ok': false, 'error': '$e'}));
      }
      await req.response.close();
      return;
    }

    final savePath = await resolveSavePath(request.fileName);
    _activeIncomingByName[request.senderName] =
        (_activeIncomingByName[request.senderName] ?? 0) + 1;
    _events.add(LanEvent(LanEventType.incomingStarted,
        name: request.fileName, from: request.senderName));

    try {
      final sink = File(savePath).openWrite();
      try {
        // 手动逐块写入（IOSink 不是 StreamConsumer<Uint8List>，不能用 pipe）
        await for (final chunk in req) {
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      req.response.statusCode = HttpStatus.ok;
      req.response.write(json.encode({'ok': true, 'path': savePath}));
      await req.response.close();
      _decActiveIncomingByName(request.senderName);
      _events.add(LanEvent(LanEventType.incomingDone,
          name: request.fileName, from: request.senderName, path: savePath));
      ReceiveNotifyService.instance
          .fileDone(request.fileName, request.senderName, savePath);
      await TransferHistoryService.instance.add(TransferRecord(
        id: '${DateTime.now().microsecondsSinceEpoch}_in',
        kind: 'file',
        direction: 'in',
        name: request.fileName,
        path: savePath,
        size: request.fileSize,
        peerName: request.senderName,
        peerKey: request.senderId,
        time: DateTime.now(),
        ok: true,
      ));
    } catch (e) {
      _decActiveIncomingByName(request.senderName);
      try {
        final f = File(savePath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
      req.response.statusCode = HttpStatus.internalServerError;
      req.response.write(json.encode({'ok': false, 'error': '$e'}));
      await req.response.close();
      _events.add(LanEvent(LanEventType.incomingFailed,
          name: request.fileName, from: request.senderName, error: '$e'));
    }
  }

  /// 走 UI 确认弹窗（仅前台未信任设备）。
  /// UI 启动竞态（HTTP 服务已起、confirmHandler 尚未挂上）时短暂等待重试；
  /// 最终仍拿不到 handler = 拒收但**不拉黑**——用户根本没被问到，
  /// 不该顺带把该设备静默拒 2 分钟（v1.2.13：修复「有时不弹框、
  /// 且随后 2 分钟内怎么发都失败」的报障）。
  Future<IncomingDecision> handlerAsk(IncomingRequest request) async {
    for (var i = 0; i < 10; i++) {
      final handler = confirmHandler;
      if (handler != null) return handler(request);
      await Future.delayed(const Duration(milliseconds: 300));
    }
    debugPrint('lan: confirmHandler missing after retries, reject (no blacklist)');
    return const IncomingDecision(accepted: false, batchDefault: false);
  }

  Future<void> _handleIncomingText(HttpRequest req) async {
    if (_header(req, 'X-Weimi-App') != _magic) {
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
      return;
    }
    final senderId = _header(req, 'X-Sender-Id');
    final senderName = _header(req, 'X-Sender-Name').isEmpty
        ? '未知设备'
        : _header(req, 'X-Sender-Name');

    final accepted = await decideAccept(
      senderId: senderId,
      ask: () => handlerAsk(IncomingRequest(
        senderId: senderId,
        senderName: senderName,
        fileName: '一条文本消息',
        fileSize: req.contentLength,
      )),
    );
    if (!accepted) {
      req.response.statusCode = HttpStatus.forbidden;
      req.response.write(json.encode({'ok': false, 'error': 'rejected'}));
      await req.response.close();
      ReceiveNotifyService.instance.rejected('一条文本消息', senderName);
      await TransferHistoryService.instance.add(TransferRecord(
        id: '${DateTime.now().microsecondsSinceEpoch}_intr',
        kind: 'text',
        direction: 'in',
        name: '（已拒收）来自 $senderName 的文本',
        size: req.contentLength,
        peerName: senderName,
        peerKey: senderId,
        time: DateTime.now(),
        ok: false,
        note: '未信任，已拒收',
      ));
      return;
    }

    // v1.2.18：X-Weimi-To → 中继给本机网页客户端（设备→网页，
    // 与 daemon 的 /weimi/text 中继行为一致）
    final toWeb = req.headers.value('x-weimi-to') ?? '';
    if (toWeb.isNotEmpty) {
      final target = _webPeers[toWeb];
      if (target == null) {
        req.response.statusCode = HttpStatus.notFound;
        req.response.write(json.encode({'ok': false, 'error': 'web peer offline'}));
        await req.response.close();
        return;
      }
      final bytes = <int>[];
      await for (final chunk in req) {
        bytes.addAll(chunk);
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      _safeAdd(target.socket, json.encode({
        't': 'text', 'from': senderId, 'name': senderName, 'text': text,
      }));
      req.response.statusCode = HttpStatus.ok;
      req.response.write(json.encode({'ok': true}));
      await req.response.close();
      return;
    }

    try {
      final bytes = <int>[];
      await for (final chunk in req) {
        bytes.addAll(chunk);
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      req.response.statusCode = HttpStatus.ok;
      req.response.write(json.encode({'ok': true}));
      await req.response.close();
      _events.add(LanEvent(LanEventType.incomingText,
          from: senderName, content: text));
      ReceiveNotifyService.instance.textDone(senderName, text);
      await TransferHistoryService.instance.add(TransferRecord(
        id: '${DateTime.now().microsecondsSinceEpoch}_int',
        kind: 'text',
        direction: 'in',
        name: text,
        text: text,
        size: text.length,
        peerName: senderName,
        peerKey: senderId,
        time: DateTime.now(),
        ok: true,
      ));
    } catch (e) {
      req.response.statusCode = HttpStatus.internalServerError;
      req.response.write(json.encode({'ok': false, 'error': '$e'}));
      await req.response.close();
    }
  }

  // ============ 网页快传处理 ============

  /// 浏览器上传文件：免确认直接收（老板拍板），重名自动加序号
  Future<void> _handleWebUpload(HttpRequest req) async {
    if (!_webShareEnabled) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    final from = '网页访客(${req.connectionInfo?.remoteAddress.address ?? "未知"})';
    final name = _safeFileName(req.uri.queryParameters['name'] ?? 'unnamed');
    try {
      final savePath = await resolveSavePath(name);
      _activeIncomingByName[from] = (_activeIncomingByName[from] ?? 0) + 1;
      _events.add(LanEvent(LanEventType.incomingStarted,
          name: name, from: from));
      final sink = File(savePath).openWrite();
      try {
        await for (final chunk in req) {
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      req.response.headers.contentType = ContentType.json;
      req.response.statusCode = HttpStatus.ok;
      req.response.write(json.encode({'ok': true, 'path': savePath}));
      await req.response.close();
      _decActiveIncomingByName(from);
      _events.add(LanEvent(LanEventType.incomingDone,
          name: name, from: from, path: savePath));
      ReceiveNotifyService.instance.fileDone(name, from, savePath);
      await TransferHistoryService.instance.add(TransferRecord(
        id: '${DateTime.now().microsecondsSinceEpoch}_web',
        kind: 'file',
        direction: 'in',
        name: name,
        path: savePath,
        size: req.contentLength,
        peerName: from,
        peerKey: 'web',
        time: DateTime.now(),
        ok: true,
      ));
    } catch (e) {
      _decActiveIncomingByName(from);
      req.response.statusCode = HttpStatus.internalServerError;
      req.response.write(json.encode({'ok': false, 'error': '$e'}));
      await req.response.close();
      _events.add(LanEvent(LanEventType.incomingFailed,
          name: name, from: from, error: '$e'));
      await TransferHistoryService.instance.add(TransferRecord(
        id: '${DateTime.now().microsecondsSinceEpoch}_web',
        kind: 'file',
        direction: 'in',
        name: name,
        size: 0,
        peerName: from,
        peerKey: 'web',
        time: DateTime.now(),
        ok: false,
      ));
    }
  }

  /// 浏览器发送文本：免确认直接收
  Future<void> _handleWebText(HttpRequest req) async {
    if (!_webShareEnabled) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    final from = '网页访客(${req.connectionInfo?.remoteAddress.address ?? "未知"})';
    try {
      final bytes = <int>[];
      await for (final chunk in req) {
        bytes.addAll(chunk);
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      req.response.headers.contentType = ContentType.json;
      req.response.statusCode = HttpStatus.ok;
      req.response.write(json.encode({'ok': true}));
      await req.response.close();
      _events.add(LanEvent(LanEventType.incomingText, from: from, content: text));
      ReceiveNotifyService.instance.textDone(from, text);
      await TransferHistoryService.instance.add(TransferRecord(
        id: '${DateTime.now().microsecondsSinceEpoch}_webt',
        kind: 'text',
        direction: 'in',
        name: text,
        text: text,
        size: text.length,
        peerName: from,
        peerKey: 'web',
        time: DateTime.now(),
        ok: true,
      ));
    } catch (e) {
      req.response.statusCode = HttpStatus.internalServerError;
      req.response.write(json.encode({'ok': false, 'error': '$e'}));
      await req.response.close();
    }
  }

  // ============ Snapdrop 式 WebSocket 房间 ============
  //
  // 协议（JSON 文本帧 + 裸二进制帧）：
  //   客户端→服务端: {t:'hello',name} / {t:'rename',name} / {t:'text',to,text}
  //                 {t:'file-start',to,name,size,fid} + 若干 binary 帧（累计到 size 为止）
  //   服务端→客户端: {t:'welcome',id,self,peers} / {t:'peers',peers}
  //                 {t:'text',from,name,text} / {t:'file-start',from,name,size,fid}
  //                 {t:'file-done',fid} / {t:'file-abort',fid} / {t:'busy',fid}
  //   to='app' 表示发给本机 App（虚拟设备，直接走现有接收管线）

  Future<void> _handleWebSocket(HttpRequest req) async {
    // 网页版只受「网页快传」开关约束，与「可被发现」(UDP 广播) 解耦
    if (!_webShareEnabled) {
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
      return;
    }
    WebSocket socket;
    try {
      socket = await WebSocketTransformer.upgrade(req);
    } catch (_) {
      return;
    }
    final peerIp = req.connectionInfo?.remoteAddress.address ?? '';
    WebPeer? peer;
    socket.listen(
      (data) {
        try {
          if (data is String) {
            peer = _onWebTextFrame(socket, peer, peerIp, data);
          } else if (data is List<int>) {
            _onWebBinaryFrame(peer, data);
          }
        } catch (_) {}
      },
      onDone: () => _removeWebPeer(peer),
      onError: (_) => _removeWebPeer(peer),
      cancelOnError: true,
    );
  }

  /// 处理 WS 文本帧，返回（可能新建的）peer
  WebPeer? _onWebTextFrame(
      WebSocket socket, WebPeer? peer, String ip, String raw) {
    final msg = json.decode(raw) as Map<String, dynamic>;
    final t = msg['t'] as String?;

    if (t == 'hello') {
      if (peer != null) return peer;
      final name = _safeFileName((msg['name'] as String?) ?? '').trim();
      _webPeerSeq++;
      peer = WebPeer(
        id: 'w$_webPeerSeq${DateTime.now().millisecondsSinceEpoch % 10000}',
        name: name.isEmpty ? '匿名设备' : name,
        socket: socket,
        ip: ip,
      );
      _webPeers[peer.id] = peer;
      final self = {'id': peer.id, 'name': peer.name};
      _safeAdd(socket, json.encode({
        't': 'welcome',
        'id': peer.id,
        'self': self,
        'peers': _roomPeers(exclude: peer.id),
      }));
      _broadcastWebPeers();
      return peer;
    }

    if (peer == null) return null;

    switch (t) {
      case 'rename':
        final name = _safeFileName((msg['name'] as String?) ?? '').trim();
        if (name.isNotEmpty) {
          peer!.name = name;
          _broadcastWebPeers();
        }
        break;
      case 'text':
        final to = msg['to'] as String?;
        final text = (msg['text'] as String?) ?? '';
        if (text.isEmpty) break;
        if (to == kAppPeerId) {
          _onAppIncomingText('网页访客(${peer!.name})', text);
        } else if (to != null && to.startsWith('d:')) {
          // v1.2.18：网页→局域网设备（本机中继 POST，对齐 daemon 行为）
          final dev = _peers[to.substring(2)];
          if (dev != null) {
            unawaited(_deviceSendTextRaw(
              dev,
              '网页客户端(${peer!.name})',
              'web-${peer.ip}',
              text,
            ));
          }
        } else {
          final target = _webPeers[to];
          if (target != null) {
            _safeAdd(target.socket, json.encode({
              't': 'text', 'from': peer!.id, 'name': peer.name, 'text': text,
            }));
          }
        }
        break;
      case 'file-start':
        final to = msg['to'] as String?;
        final name = _safeFileName((msg['name'] as String?) ?? 'unnamed');
        final size = (msg['size'] as num?)?.toInt() ?? 0;
        final fid = (msg['fid'] as String?) ?? '';
        final inbound = _WebInbound(
          fid: fid, name: name, size: size, fromName: peer!.name,
          from: peer.id, to: to ?? '', received: 0,
        );
        if (to == kAppPeerId) {
          if (_appInbound != null) {
            _safeAdd(socket, json.encode({'t': 'busy', 'fid': fid}));
            break;
          }
          _startAppInbound(inbound).then((savePath) {
            if (savePath != null) {
              _safeAdd(socket, json.encode({'t': 'file-done', 'fid': fid}));
            } else {
              _safeAdd(socket, json.encode({'t': 'file-abort', 'fid': fid}));
            }
          });
        } else if (to != null && to.startsWith('d:')) {
          // v1.2.18：网页→局域网设备文件（本机中继，边收边 POST）
          final dev = _peers[to.substring(2)];
          if (dev == null) {
            _safeAdd(socket, json.encode({'t': 'file-abort', 'fid': fid}));
            break;
          }
          unawaited(_openDeviceRelay(inbound, dev, '网页客户端(${peer!.name})',
              'web-${peer.ip}', socket));
        } else {
          final target = _webPeers[to];
          if (target == null) {
            _safeAdd(socket, json.encode({'t': 'file-abort', 'fid': fid}));
            break;
          }
          _safeAdd(target.socket, json.encode({
            't': 'file-start', 'from': peer.id, 'name': name, 'fromName': peer.name,
            'size': size, 'fid': fid,
          }));
          _webInbound[target.socket] = inbound;
        }
        // 挂到发送方连接上，后续 binary 帧按此路由
        _webInbound[socket] = inbound;
        break;
      default:
        break;
    }
    return peer;
  }

  /// 处理 WS 二进制帧（按 file-start 挂的 inbound 状态转发/落盘）
  void _onWebBinaryFrame(WebPeer? sender, List<int> chunk) {
    if (sender == null) return;
    final inbound = _webInbound[sender.socket];
    if (inbound == null || inbound.aborted) return;
    inbound.received += chunk.length;

    if (inbound.to == kAppPeerId) {
      // 写入 App 接收文件
      final sink = inbound.sink;
      if (sink != null) {
        sink.add(chunk);
        if (inbound.size > 0 && inbound.received >= inbound.size) {
          inbound.done = true;
        }
      }
    } else if (inbound.to.startsWith('d:')) {
      // v1.2.18：网页→设备中继，边收边 POST 给设备
      final req = inbound.upReq;
      if (req == null || inbound.done) return;
      req.add(chunk);
      if (inbound.size > 0 && inbound.received >= inbound.size) {
        inbound.done = true;
        unawaited(_finishDeviceRelay(inbound, sender));
      }
    } else {
      final target = _webPeers[inbound.to];
      if (target == null) {
        inbound.aborted = true;
        _cleanupInbound(inbound);
        return;
      }
      _safeAdd(target.socket, chunk);
      if (inbound.size > 0 && inbound.received >= inbound.size) {
        _safeAdd(target.socket,
            json.encode({'t': 'file-done', 'fid': inbound.fid}));
        _cleanupInbound(inbound);
      }
    }
  }

  /// 网页→设备文件中继：打开对设备的 POST 上行（file-start 时调用）。
  /// 失败即向网页端回 file-abort。
  Future<void> _openDeviceRelay(
    _WebInbound inbound,
    LanPeer dev,
    String fromName,
    String senderId,
    WebSocket senderSocket,
  ) async {
    HttpClient? client;
    try {
      client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);
      final req = await client
          .postUrl(Uri.parse('http://${dev.ip}:${dev.httpPort}/weimi/send'));
      req.headers.set('X-Weimi-App', _magic);
      req.headers.set('X-Sender-Id', senderId);
      req.headers.set('X-Sender-Name', Uri.encodeComponent(fromName));
      req.headers.set('X-File-Name', Uri.encodeComponent(inbound.name));
      req.headers.set('X-File-Size', '${inbound.size}');
      req.headers.contentLength = inbound.size;
      inbound.upClient = client;
      inbound.upReq = req;
      // size==0 的空文件：没有后续 binary 帧，直接收尾
      if (inbound.size == 0) {
        inbound.done = true;
        await _finishDeviceRelay(inbound, null);
      }
    } catch (e) {
      client?.close(force: true);
      _safeAdd(senderSocket,
          json.encode({'t': 'file-abort', 'fid': inbound.fid}));
      _cleanupInbound(inbound);
    }
  }

  /// 网页→设备文件中继收尾：关上行、读应答、回 file-done/abort。
  Future<void> _finishDeviceRelay(
      _WebInbound inbound, WebPeer? sender) async {
    final req = inbound.upReq;
    final client = inbound.upClient;
    inbound.upReq = null;
    var ok = false;
    if (req != null) {
      try {
        await req.flush();
        final resp = await req.close().timeout(const Duration(seconds: 60));
        final body =
            await resp.transform(utf8.decoder).timeout(const Duration(seconds: 30)).join();
        ok = resp.statusCode == HttpStatus.ok && body.contains('"ok":true');
      } catch (_) {
        ok = false;
      }
    }
    client?.close(force: true);
    if (sender != null) {
      _safeAdd(sender.socket, json.encode({
        't': ok ? 'file-done' : 'file-abort',
        'fid': inbound.fid,
      }));
    }
    _cleanupInbound(inbound);
  }

  /// 网页→设备文本中继：POST /weimi/text（对齐 daemon 的 device_send_text）
  Future<bool> _deviceSendTextRaw(
      LanPeer dev, String fromName, String senderId, String text) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    try {
      final bytes = utf8.encode(text);
      final req = await client
          .postUrl(Uri.parse('http://${dev.ip}:${dev.httpPort}/weimi/text'));
      req.headers.set('X-Weimi-App', _magic);
      req.headers.set('X-Sender-Id', senderId);
      req.headers.set('X-Sender-Name', Uri.encodeComponent(fromName));
      req.headers.set('X-Text-Length', '${bytes.length}');
      req.headers.contentLength = bytes.length;
      req.add(bytes);
      await req.flush();
      final resp = await req.close().timeout(const Duration(seconds: 30));
      final body = await resp.transform(utf8.decoder).join();
      return resp.statusCode == HttpStatus.ok && body.contains('"ok":true');
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// App 接收网页文件：开 sink、收齐后关流并走记录/事件。返回落盘路径（失败 null）。
  Future<String?> _startAppInbound(_WebInbound inbound) async {
    if (_appInbound != null) return null;
    _appInbound = inbound;
    final from = '网页访客(${inbound.fromName})';
    String? savePath;
    try {
      savePath = await resolveSavePath(inbound.name);
      final sink = File(savePath).openWrite();
      inbound.sink = sink;
      if (inbound.size == 0) inbound.done = true; // 空文件直接完成
      _events.add(LanEvent(LanEventType.incomingStarted,
          name: inbound.name, from: from));
      // 等 binary 帧写满（done 标记由 _onWebBinaryFrame 置位）
      const tick = Duration(milliseconds: 100);
      int waited = 0;
      while (!(inbound.done || inbound.aborted) && waited < 3600 * 1000) {
        await Future.delayed(tick);
        waited += 100;
      }
      await sink.flush();
      await sink.close();
      if (inbound.aborted || !inbound.done) {
        try {
          final f = File(savePath);
          if (await f.exists()) await f.delete();
        } catch (_) {}
        return null;
      }
      _events.add(LanEvent(LanEventType.incomingDone,
          name: inbound.name, from: from, path: savePath));
      ReceiveNotifyService.instance.fileDone(inbound.name, from, savePath);
      await TransferHistoryService.instance.add(TransferRecord(
        id: '${DateTime.now().microsecondsSinceEpoch}_ws',
        kind: 'file',
        direction: 'in',
        name: inbound.name,
        path: savePath,
        size: inbound.size,
        peerName: from,
        peerKey: 'web',
        time: DateTime.now(),
        ok: true,
      ));
      return savePath;
    } catch (e) {
      _events.add(LanEvent(LanEventType.incomingFailed,
          name: inbound.name, from: from, error: '$e'));
      return null;
    } finally {
      _cleanupInbound(inbound);
      _appInbound = null;
    }
  }

  void _cleanupInbound(_WebInbound inbound) {
    _webInbound.removeWhere((_, v) => v == inbound);
    if (inbound.sink != null && !inbound.done && !inbound.aborted) {
      try {
        inbound.sink!.close();
      } catch (_) {}
    }
  }

  void _onAppIncomingText(String from, String text) {
    _events.add(LanEvent(LanEventType.incomingText, from: from, content: text));
    ReceiveNotifyService.instance.textDone(from, text);
    TransferHistoryService.instance.add(TransferRecord(
      id: '${DateTime.now().microsecondsSinceEpoch}_wst',
      kind: 'text',
      direction: 'in',
      name: text,
      text: text,
      size: text.length,
      peerName: from,
      peerKey: 'web',
      time: DateTime.now(),
      ok: true,
    ));
  }

  /// 主动断开某个网页客户端（设备列表长按/右击菜单「断开连接」用，v1.2.13）
  void removeWebPeer(WebPeer peer) => _removeWebPeer(peer);

  void _removeWebPeer(WebPeer? peer) {
    if (peer == null) return;
    _webPeers.remove(peer.id);
    _webInbound.remove(peer.socket);
    try {
      peer.socket.close();
    } catch (_) {}
    _broadcastWebPeers();
  }

  /// 房间成员列表（含 App 虚拟设备 + 局域网微密设备），exclude 排除某个浏览器。
  /// v1.2.18：设备带 d: 前缀 + dev 标记（对齐 daemon 网页版），网页端可
  /// 直接发文本/文件给任意局域网设备（由本机中继 POST）。
  List<Map<String, String>> _roomPeers({String? exclude}) {
    final out = <Map<String, String>>[
      {'id': kAppPeerId, 'name': _selfName},
    ];
    for (final w in _webPeers.values) {
      if (w.id != exclude) out.add({'id': w.id, 'name': w.name});
    }
    for (final p in _peers.values) {
      if (p.id.startsWith('rweb_')) continue; // 远端网页客户端不进本机房间
      out.add({'id': 'd:${p.id}', 'name': p.name, 'dev': '1'});
    }
    return out;
  }

  void _broadcastWebPeers() {
    final peers = _roomPeers();
    for (final w in List<WebPeer>.from(_webPeers.values)) {
      _safeAdd(w.socket, json.encode({'t': 'peers', 'peers': peers}));
    }
    _events.add(LanEvent(LanEventType.webPeersChanged));
  }

  void _safeAdd(WebSocket socket, Object data) {
    try {
      if (socket.readyState == WebSocket.open) socket.add(data);
    } catch (_) {}
  }

  /// App 发文件给网页客户端（512KB 分块）
  Future<bool> sendWebFile(WebPeer peer, String filePath,
      {void Function(int sent, int total)? onProgress}) async {
    lastSendError = '';
    try {
      final f = File(filePath);
      if (!await f.exists()) {
        lastSendError = '本地文件不存在: $filePath';
        return false;
      }
      final sendName = p.basename(filePath);
      final total = await f.length();
      final fid = 'a${DateTime.now().microsecondsSinceEpoch}';
      _safeAdd(peer.socket, json.encode({
        't': 'file-start', 'to': peer.id, 'name': sendName,
        'size': total, 'fid': fid,
      }));
      int sent = 0;
      await for (final chunk in f.openRead()) {
        _safeAdd(peer.socket, chunk);
        sent += chunk.length;
        if (onProgress != null) onProgress(sent, total);
      }
      _safeAdd(peer.socket, json.encode({'t': 'file-done', 'fid': fid}));
      // v1.2.24：file_picker 临时拷贝归档进「已发送」，聊天记录永久有效
      final archivedPath = await SentFileArchiver.archive(filePath);
      await TransferHistoryService.instance.add(TransferRecord(
        id: '${DateTime.now().microsecondsSinceEpoch}_wsout',
        kind: 'file',
        direction: 'out',
        name: sendName,
        path: archivedPath,
        size: total,
        peerName: '网页客户端(${peer.name})',
        peerKey: 'web',
        time: DateTime.now(),
        ok: true,
      ));
      return true;
    } catch (e) {
      lastSendError = '$e';
      return false;
    }
  }

  /// App 发文本给网页客户端
  Future<bool> sendWebText(WebPeer peer, String text) async {
    lastSendError = '';
    try {
      _safeAdd(peer.socket, json.encode({
        't': 'text', 'from': kAppPeerId, 'name': _selfName, 'text': text,
      }));
      await TransferHistoryService.instance.add(TransferRecord(
        id: '${DateTime.now().microsecondsSinceEpoch}_wsot',
        kind: 'text',
        direction: 'out',
        name: text,
        text: text,
        size: text.length,
        peerName: '网页客户端(${peer.name})',
        peerKey: 'web',
        time: DateTime.now(),
        ok: true,
      ));
      return true;
    } catch (e) {
      lastSendError = '$e';
      return false;
    }
  }

  /// 网页快传首页（单文件、零外部资源、手机/电脑浏览器都可用）。
  /// 用 raw string，JS 里的 $ 不做 Dart 插值。
  String _webSharePage() {
    return r'''<!DOCTYPE html>
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
var recvList = {};   // fid -> {name,size,chunks,received,el,bar}
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
  else if (m.t === 'file-done') finishRecv(m.fid, true);
  else if (m.t === 'file-abort' || m.t === 'busy') finishRecv(m.fid, false);
}

function render(listPeers) {
  peers = listPeers;
  ring.innerHTML = '';
  // 本机（自己）
  var self = document.createElement('div');
  self.className = 'dev self';
  self.innerHTML = '<div class="bubble">' + esc(myName.charAt(0)) + '</div>' +
                   '<div class="nm">' + esc(myName) + '<br><span style="font-size:11px;color:#93a4b8">点我改名</span></div>';
  self.onclick = renameSelf;
  ring.appendChild(self);
  // 其他设备（含本机 App「微密文件」）
  peers.forEach(function(p) {
    var d = document.createElement('div');
    d.className = 'dev';
    d.innerHTML = '<div class="bubble">' + esc(p.name.charAt(0)) + '</div>' +
                  '<div class="nm">' + esc(p.name) + '</div>';
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
    var pos = 0, slice = 512 * 1024;
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
</html>''';
  }

  /// 默认接收目录（未单独指定时用，独立于「加密文件存放目录」）：
  /// Android → 公共 Download 下（文件管理器可见，无需 SAF）
  /// 桌面 → 文档目录下
  String defaultReceiveDir() {
    const name = '微密飞传接收';
    if (Platform.isAndroid) {
      return '/storage/emulated/0/Download/$name';
    }
    final fb = fallbackDir ?? Directory.systemTemp.path;
    return p.join(fb, name);
  }

  /// 接收文件保存目录：只看「接收保存目录」这一项设置；
  /// 未指定（或目录不可用）时落到独立默认目录，不再跟随「加密文件存放目录」
  Future<String> _resolveSaveDir() async {
    final rd = _receiveDir.trim();
    if (rd.isNotEmpty) {
      try {
        final d = Directory(rd);
        if (!await d.exists()) await d.create(recursive: true);
        return rd;
      } catch (_) {
        // 目录不可用（被删/无权限）→ 落默认
      }
    }
    final def = defaultReceiveDir();
    try {
      final d = Directory(def);
      if (!await d.exists()) await d.create(recursive: true);
    } catch (_) {}
    return def;
  }

  /// 当前生效的接收目录（设置页展示用）
  Future<String> effectiveReceiveDir() => _resolveSaveDir();

  /// 解析保存路径（接收目录 + 冲突加 (n) 后缀）。LocalSend 兼容层复用。
  /// fileName 可含相对路径（文件夹传输），落盘前确保父目录存在。
  Future<String> resolveSavePath(String fileName) async {
    final dirPath = await _resolveSaveDir();
    final ext = p.extension(fileName);
    final base = p.basenameWithoutExtension(fileName);
    final relDir = p.dirname(fileName);
    final targetDir = relDir == '.' ? dirPath : p.join(dirPath, relDir);
    var target = p.join(targetDir, p.basename(fileName));
    var i = 1;
    while (await File(target).exists()) {
      target = p.join(targetDir, '$base ($i)$ext');
      i++;
    }
    // 文件夹传输：子目录此时才可能存在，创建之
    if (relDir != '.') {
      try {
        final d = Directory(targetDir);
        if (!await d.exists()) await d.create(recursive: true);
      } catch (_) {}
    }
    return target;
  }

  // ============ 发送端 ============

  /// 发文件给网页客户端（Windows daemon 模式）：daemon 进程侧读文件经 WS
  /// 推给浏览器，异步执行（无逐字节进度，落记录为已受理）。
  Future<bool> _sendWebPeerFile({
    required LanPeer peer,
    required String filePath,
    bool recordHistory = true,
  }) async {
    lastSendError = '';
    try {
      final f = File(filePath);
      if (!await f.exists()) {
        lastSendError = '本地文件不存在: $filePath';
        return false;
      }
      final sendName = p.basename(filePath);
      final total = await f.length();
      final ok = await DaemonService.webSendFile(
        to: peer.id.substring(3),
        path: filePath,
        name: sendName,
      );
      if (ok && recordHistory) {
        // v1.2.24：file_picker 临时拷贝归档进「已发送」
        final archivedPath = await SentFileArchiver.archive(filePath);
        await TransferHistoryService.instance.add(TransferRecord(
          id: '${DateTime.now().microsecondsSinceEpoch}_wso',
          kind: 'file',
          direction: 'out',
          name: sendName,
          path: archivedPath,
          size: total,
          peerName: peer.name,
          // 网页会话统一 key 'web'：peer.id 是 'ws_<WS会话id>'，浏览器每次
          // 刷新都变，用它落记录会把同一网页端裂成多个会话
          peerKey: 'web',
          time: DateTime.now(),
          ok: true,
        ));
      }
      if (!ok) lastSendError = '网页客户端不在线或 daemon 未响应';
      return ok;
    } catch (e) {
      lastSendError = '$e';
      return false;
    }
  }

  /// 发文本给网页客户端（Windows daemon 模式）。
  Future<bool> _sendWebPeerText({
    required LanPeer peer,
    required String text,
  }) async {
    lastSendError = '';
    try {
      final ok = await DaemonService.webSendText(
        to: peer.id.substring(3),
        text: text,
      );
      if (ok) {
        await TransferHistoryService.instance.add(TransferRecord(
          id: '${DateTime.now().microsecondsSinceEpoch}_wsot',
          kind: 'text',
          direction: 'out',
          name: text,
          text: text,
          size: text.length,
          peerName: peer.name,
          peerKey: 'web', // 网页会话统一 key（同上）
          time: DateTime.now(),
          ok: true,
        ));
      } else {
        lastSendError = '网页客户端不在线或 daemon 未响应';
      }
      return ok;
    } catch (e) {
      lastSendError = '$e';
      return false;
    }
  }

  /// 发送一个文件（明文原样直传，与 Landrop 行为一致）。
  /// [relativeName]：文件夹传输时传相对路径（'文件夹/子目录/文件'），
  /// 接收端按此路径落盘；单文件传 basename。
  /// [recordHistory]：文件夹传输由调用方汇总记一条，置 false 免逐条记。
  Future<bool> sendFile({
    required LanPeer peer,
    required String filePath,
    String? relativeName,
    bool recordHistory = true,
    void Function(int sent, int total)? onProgress,
  }) async {
    lastSendError = '';
    // Windows daemon 模式：网页客户端（ws_ 前缀）不经直连，走 daemon 52349 转推
    if (Platform.isWindows && peer.id.startsWith('ws_')) {
      return _sendWebPeerFile(peer: peer, filePath: filePath, recordHistory: recordHistory);
    }
    // v1.2.18：远端主机的网页客户端（rweb_ 前缀）→ POST 到对端 httpPort
    // 带 X-Weimi-To: <房间id>，由对端转进其 WS 房间（手机/电脑通用直连）
    final isRemoteWeb = peer.id.startsWith('rweb_');
    try {
      final sendName = relativeName ?? p.basename(filePath);
      final f = File(filePath);
      if (!await f.exists()) {
        lastSendError = '本地文件不存在: $filePath';
        return false;
      }
      final total = await f.length();

      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);
      try {
        final req = await client
            .postUrl(Uri.parse('http://${peer.ip}:${peer.httpPort}/weimi/send'));
        req.headers.set('X-Weimi-App', _magic);
        req.headers.set('X-Sender-Id', _identityId);
        // HTTP 头只允许 ASCII：中文设备名/文件名必须 URL 编码，接收端解码
        req.headers.set('X-Sender-Name', Uri.encodeComponent(_selfName));
        req.headers.set('X-File-Name', Uri.encodeComponent(sendName));
        req.headers.set('X-File-Size', '$total');
        if (isRemoteWeb) req.headers.set('X-Weimi-To', peer.id.substring(5));
        req.headers.contentLength = total;

        int sent = 0;
        await for (final chunk in f.openRead()) {
          req.add(chunk);
          sent += chunk.length;
          if (onProgress != null) onProgress(sent, total);
        }
        await req.flush();
        final resp = await req.close();
        final body = await resp
            .transform(utf8.decoder)
            .timeout(const Duration(seconds: 60))
            .join();
        if (resp.statusCode == HttpStatus.ok && body.contains('"ok":true')) {
          if (recordHistory) {
            // v1.2.24：file_picker 临时拷贝归档进「已发送」
            final archivedPath = await SentFileArchiver.archive(filePath);
            await TransferHistoryService.instance.add(TransferRecord(
              id: '${DateTime.now().microsecondsSinceEpoch}_out',
              kind: 'file',
              direction: 'out',
              name: sendName,
              path: archivedPath,
              size: total,
              peerName: peer.name,
              // 网页会话统一 key 'web'（浏览器刷新会变房间 id，别拿它落记录）
              peerKey: isRemoteWeb ? 'web' : peer.id,
              time: DateTime.now(),
              ok: true,
            ));
          }
          return true;
        }
        lastSendError =
            '对方返回 ${resp.statusCode}（403=拒收/防火墙拦截，500=对方写入失败）';
        if (recordHistory) {
          await TransferHistoryService.instance.add(TransferRecord(
            id: '${DateTime.now().microsecondsSinceEpoch}_out',
            kind: 'file',
            direction: 'out',
            name: sendName,
            path: filePath,
            size: total,
            peerName: peer.name,
            peerKey: isRemoteWeb ? 'web' : peer.id,
            time: DateTime.now(),
            ok: false,
          ));
        }
        return false;
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      lastSendError = '$e';
      return false;
    }
  }

  /// 发送一段文本（UTF-8）。
  Future<bool> sendText({
    required LanPeer peer,
    required String text,
  }) async {
    lastSendError = '';
    // Windows daemon 模式：网页客户端（ws_ 前缀）走 daemon 52349 转推
    if (Platform.isWindows && peer.id.startsWith('ws_')) {
      return _sendWebPeerText(peer: peer, text: text);
    }
    // v1.2.18：远端主机的网页客户端 → X-Weimi-To 中继（对端转进其 WS 房间）
    final isRemoteWeb = peer.id.startsWith('rweb_');
    try {
      final bytes = utf8.encode(text);
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);
      try {
        final req = await client
            .postUrl(Uri.parse('http://${peer.ip}:${peer.httpPort}/weimi/text'));
        req.headers.set('X-Weimi-App', _magic);
        req.headers.set('X-Sender-Id', _identityId);
        req.headers.set('X-Sender-Name', Uri.encodeComponent(_selfName));
        req.headers.set('X-Text-Length', '${bytes.length}');
        if (isRemoteWeb) req.headers.set('X-Weimi-To', peer.id.substring(5));
        req.headers.contentLength = bytes.length;
        req.add(bytes);
        await req.flush();
        final resp = await req.close();
        final body = await resp
            .transform(utf8.decoder)
            .timeout(const Duration(seconds: 30))
            .join();
        if (resp.statusCode == HttpStatus.ok && body.contains('"ok":true')) {
          await TransferHistoryService.instance.add(TransferRecord(
            id: '${DateTime.now().microsecondsSinceEpoch}_outt',
            kind: 'text',
            direction: 'out',
            name: text,
            text: text,
            size: text.length,
            peerName: peer.name,
            peerKey: isRemoteWeb ? 'web' : peer.id,
            time: DateTime.now(),
            ok: true,
          ));
          return true;
        }
        lastSendError = '对方返回 ${resp.statusCode}（403=对方未信任本机/拒收）';
        await TransferHistoryService.instance.add(TransferRecord(
          id: '${DateTime.now().microsecondsSinceEpoch}_outt',
          kind: 'text',
          direction: 'out',
          name: text,
          text: text,
          size: text.length,
          peerName: peer.name,
          peerKey: isRemoteWeb ? 'web' : peer.id,
          time: DateTime.now(),
          ok: false,
        ));
        return false;
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      lastSendError = '$e';
      return false;
    }
  }

  // ============ 发现 ============

  /// 开始扫描（打开传输页时调用）：开启接收并立即广播一轮 announce
  Future<void> startDiscovery() async {
    await startReceiving();
    if (_discovering) return;
    _discovering = true;
    await _broadcastAnnounce();
  }

  /// 停止扫描（离开传输页时调用；接收开关由 startReceiving/stopReceiving 单独控制）
  void stopDiscovery() {
    _discovering = false;
  }

  /// 清洗文件名；含 '/' 时按相对路径处理（v1.0.68 文件夹传输）：
  /// 逐段拍平非法字符，丢弃空段与 '.'/'..'（防目录穿越），保留层级。
  static String _safeFileName(String name) {
    if (name.contains('/')) {
      final segs = name
          .split('/')
          .map((s) => s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim())
          .where((s) => s.isNotEmpty && s != '.' && s != '..')
          .toList();
      return segs.isEmpty ? 'unnamed' : segs.join('/');
    }
    final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return cleaned.isEmpty ? 'unnamed' : cleaned;
  }
}

// ============ 数据类型 ============

/// 手动连接条目（跨网段方案 A，v1.2.13）。class 而非 record typedef——
/// Dart record 无命名构造函数，跨文件传递必炸编译。
class ManualEntry {
  /// true=网段模式（向 broadcast 定向广播发现）；false=单 IP 模式。
  final bool isSubnet;
  /// 持久化原文（列表唯一 key）：host='IP' 或 'IP:端口'；subnet='x.x.x'。
  final String raw;
  /// host 模式：目标 IP。
  final String? ip;
  /// host 模式：端口覆盖（null=各协议用各自默认端口）。
  final int? port;
  /// subnet 模式：网段前三段，如 '192.168.2'。
  final String? subnet;
  /// subnet 模式：定向广播地址，如 '192.168.2.255'。
  final String? broadcast;

  ManualEntry({
    required this.isSubnet,
    required this.raw,
    this.ip,
    this.port,
    this.subnet,
    this.broadcast,
  });
}

class LanPeer {
  final String id;
  final String name;
  final String ip;
  final int httpPort;
  final bool trusted;
  DateTime lastSeen;
  /// 协议：'weimi'=微密自研飞传；'localsend'=LocalSend v2 兼容设备；
  /// 'landrop'=LANDrop v2 兼容设备（纯 LANDrop 物理设备才单独立项）。
  /// 合并显示后一台物理设备只有一条记录：同 IP 同时跑着微密+LocalSend 的
  /// 设备以 weimi 条目为主，LocalSend 链路信息挂在 [lsPort]/[lsHttps] 上；
  /// LANDrop 链路信息（如有）挂在 [ldPort]/[ldPkB64] 上。
  final String protocol;
  /// LocalSend 设备的传输 scheme（App 默认 HTTPS only，自签证书）。
  /// 微密设备用不到（恒 false）。
  final bool https;
  /// 该设备（IP）上的 LocalSend 链路端口；null=该设备没有 LocalSend 链路。
  /// 仅 protocol='weimi' 的合并条目会非空。
  final int? lsPort;
  /// LocalSend 链路是否走 HTTPS（对端 App 默认开）。
  final bool lsHttps;
  /// 该设备（IP）上的 LANDrop 链路 TCP 端口；null=没有 LANDrop 链路。
  final int? ldPort;
  /// LANDrop 设备身份公钥 base64（= 信任列表 key；LANDrop 信任按它持久化）。
  final String? ldPkB64;

  LanPeer({
    required this.id,
    required this.name,
    required this.ip,
    required this.httpPort,
    this.trusted = false,
    required this.lastSeen,
    this.protocol = 'weimi',
    this.https = false,
    this.lsPort,
    this.lsHttps = false,
    this.ldPort,
    this.ldPkB64,
  });

  bool get isLocalSend => protocol == 'localsend';

  /// 是否同时具备 LocalSend 链路（合并条目：主链路微密 + LocalSend 兜底）。
  bool get hasLocalSendLink => lsPort != null;

  /// 纯 LANDrop 设备条目（无微密/LocalSend 主链路的物理设备）。
  bool get isLandrop => protocol == 'landrop';

  /// 是否同时具备 LANDrop 链路（合并条目附加信息）。
  bool get hasLandropLink => ldPort != null;

  LanPeer copyWith({bool? trusted, int? lsPort, bool? lsHttps}) => LanPeer(
        id: id,
        name: name,
        ip: ip,
        httpPort: httpPort,
        trusted: trusted ?? this.trusted,
        lastSeen: lastSeen,
        protocol: protocol,
        https: https,
        lsPort: lsPort ?? this.lsPort,
        lsHttps: lsHttps ?? this.lsHttps,
        ldPort: ldPort,
        ldPkB64: ldPkB64,
      );
}

/// 接收确认结果（确认框返回值）。
/// - accepted：本次是否接收
/// - batchDefault：用户勾选了「同批后续文件也按此处理」（复选框默认勾选），
///   service 据此为同一设备记 2 分钟双向批次授权（收/拒都不再逐条打扰）
/// 注：不能用 record typedef（Dart record 无命名构造函数，编译期报
/// Couldn't find constructor），必须用 class。
class IncomingDecision {
  final bool accepted;
  final bool batchDefault;
  /// 用户勾选了「信任该设备」（仅 trustable 请求有意义）
  final bool trust;

  const IncomingDecision({
    required this.accepted,
    required this.batchDefault,
    this.trust = false,
  });
}

class IncomingRequest {
  final String senderId;
  final String senderName;
  final String fileName;
  final int fileSize;
  /// 是否可在确认框里勾选「信任该设备」（LANDrop：按 secp256k1 身份公钥持久化）
  final bool trustable;
  /// 6 位 verifCode（LANDrop TOFU 核对用；非 LANDrop 来源为 null）
  final String? verifCode;

  IncomingRequest({
    required this.senderId,
    required this.senderName,
    required this.fileName,
    required this.fileSize,
    this.trustable = false,
    this.verifCode,
  });
}

/// WS 房间里的一个浏览器客户端
class WebPeer {
  final String id;
  String name;
  final WebSocket socket;
  final String ip;

  WebPeer({
    required this.id,
    required this.name,
    required this.socket,
    required this.ip,
  });
}

/// 一次进行中的 WS 文件传输状态（发送方连接持有；to=app 时同时挂在 _appInbound）
class _WebInbound {
  final String fid;
  final String name;
  final int size;
  final String fromName;
  final String from;
  final String to;
  int received;
  bool done = false;
  bool aborted = false;
  IOSink? sink;
  // v1.2.18：to=d:<id> 网页→设备中继的 HTTP 上行
  HttpClient? upClient;
  HttpClientRequest? upReq;

  _WebInbound({
    required this.fid,
    required this.name,
    required this.size,
    required this.fromName,
    required this.from,
    required this.to,
    this.received = 0,
  });
}

enum LanEventType {
  receivingStarted,
  receivingStopped,
  peersChanged,
  webPeersChanged,
  incomingStarted,
  incomingDone,
  incomingFailed,
  incomingRejected,
  incomingText,
}

class LanEvent {
  final LanEventType type;
  final String? name;
  final String? from;
  final String? path;
  final String? error;
  final String? content;
  final bool trusted;

  LanEvent(this.type,
      {this.name, this.from, this.path, this.error, this.content, this.trusted = false});
}
