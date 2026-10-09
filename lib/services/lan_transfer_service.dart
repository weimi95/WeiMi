import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'trusted_devices_service.dart';

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
  int _httpPort = defaultHttpPort;
  Timer? _announceTimer;
  Timer? _pruneTimer;
  RawDatagramSocket? _udpSocket;
  HttpServer? _httpServer;

  /// 接收文件兜底目录（main.dart 启动时用 path_provider 注入）
  String? fallbackDir;

  final StreamController<LanEvent> _events =
      StreamController<LanEvent>.broadcast();
  Stream<LanEvent> get events => _events.stream;

  /// 收到传入请求时的确认回调（UI 弹窗），返回 true 才接收。
  /// 仅前台且对方未信任时调用；信任设备与后台模式不经过此回调。
  Future<bool> Function(IncomingRequest request)? confirmHandler;

  /// 最近一次发送失败的错误详情（诊断用）
  String lastSendError = '';

  LanTransferService._();
  static final LanTransferService instance = LanTransferService._();

  String get selfName => _selfName;
  bool get isReceiving => _receiving;
  bool get backgroundMode => _backgroundMode;
  bool get webShareEnabled => _webShareEnabled;
  int get httpPortActual => _httpPort;
  List<LanPeer> get peers => _peers.values.toList();

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
  }

  /// 网页快传开关（默认开）
  Future<void> setWebShareEnabled(bool v) async {
    _webShareEnabled = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kWebShareKey, v);
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

    if (_udpSocket == null) {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
      );
      socket.broadcastEnabled = true;
      socket.listen(_onUdpDatagram);
      _udpSocket = socket;
    }

    if (_httpServer == null) {
      await _bindHttpServer();
    }

    _receiving = true;
    _announceTimer?.cancel();
    _announceTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _broadcastAnnounce());
    _events.add(LanEvent(LanEventType.receivingStarted));
    _startAndroidForeground();
  }

  /// HTTP 端口被占用时自动 +1（最多试到 52365），announce 带实际端口
  Future<void> _bindHttpServer() async {
    SocketException? lastErr;
    for (int port = defaultHttpPort; port <= maxHttpPort; port++) {
      try {
        _httpServer = await HttpServer.bind(
            InternetAddress.anyIPv4, port,
            shared: true);
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
      _addOrUpdatePeer(peer);
      // 收到 announce：向对方来源端口单播应答，让它也知道我
      if (msg['action'] == 'announce') {
        _sendReply(dg.address.address, dg.port);
      }
    } catch (_) {}
  }

  void _sendReply(String ip, int port) {
    final socket = _udpSocket;
    if (socket == null || port == 0) return;
    final body = utf8.encode(json.encode({
      'app': _magic,
      'action': 'reply',
      'id': _identityId,
      'name': _selfName,
      'httpPort': _httpPort,
      'v': 1,
    }));
    try {
      socket.send(body, InternetAddress(ip), port);
    } catch (_) {}
  }

  Future<void> _broadcastAnnounce() async {
    final socket = _udpSocket;
    if (socket == null || !_receiving) return;
    final body = utf8.encode(json.encode({
      'app': _magic,
      'action': 'announce',
      'id': _identityId,
      'name': _selfName,
      'httpPort': _httpPort,
      'v': 1,
    }));
    // 对每个本机网段的定向广播都发一遍，多网卡/虚拟网卡环境也能被同网段设备发现
    final targets = <String>['255.255.255.255'];
    for (final myIp in await localIPv4s()) {
      final parts = myIp.split('.');
      if (parts.length == 4) {
        final sub = '${parts[0]}.${parts[1]}.${parts[2]}.255';
        if (!targets.contains(sub)) targets.add(sub);
      }
    }
    for (final t in targets) {
      try {
        socket.send(body, InternetAddress(t), discoveryPort);
      } catch (_) {}
    }
  }

  void _addOrUpdatePeer(LanPeer peer) {
    _peers[peer.id] = peer;
    _events.add(LanEvent(LanEventType.peersChanged));
    _pruneTimer ??=
        Timer.periodic(const Duration(seconds: 5), (_) => _prunePeers());
  }

  void _prunePeers() {
    final now = DateTime.now();
    final before = _peers.length;
    _peers.removeWhere((_, p) => now.difference(p.lastSeen).inSeconds > 12);
    if (_peers.length != before) {
      _events.add(LanEvent(LanEventType.peersChanged));
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

  /// 接收决策：信任设备免确认直收；后台模式无法弹窗（非信任拒收）；
  /// 前台未信任走 confirmHandler 弹窗；无 UI 可弹时拒收。
  Future<bool> _decideAccept(
      {required String senderId,
      required Future<bool> Function() ask}) async {
    if (TrustedDevices.instance.isTrustedSync(senderId)) return true;
    if (_backgroundMode) return false;
    return ask();
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

    final accepted = await _decideAccept(
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
      return;
    }

    final savePath = await _resolveSavePath(request.fileName);
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
      _events.add(LanEvent(LanEventType.incomingDone,
          name: request.fileName, from: request.senderName, path: savePath));
    } catch (e) {
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

  /// 走 UI 确认弹窗（仅前台未信任设备）
  Future<bool> handlerAsk(IncomingRequest request) async {
    final handler = confirmHandler;
    if (handler == null) return false;
    return handler(request);
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

    final accepted = await _decideAccept(
      senderId: senderId,
      ask: () async {
        final handler = confirmHandler;
        if (handler == null) return false;
        return handler(IncomingRequest(
          senderId: senderId,
          senderName: senderName,
          fileName: '一条文本消息',
          fileSize: req.contentLength,
        ));
      },
    );
    if (!accepted) {
      req.response.statusCode = HttpStatus.forbidden;
      req.response.write(json.encode({'ok': false, 'error': 'rejected'}));
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
    final from = '网页访客(${req.remoteAddress.address})';
    final name = _safeFileName(req.uri.queryParameters['name'] ?? 'unnamed');
    try {
      final savePath = await _resolveSavePath(name);
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
      _events.add(LanEvent(LanEventType.incomingDone,
          name: name, from: from, path: savePath));
    } catch (e) {
      req.response.statusCode = HttpStatus.internalServerError;
      req.response.write(json.encode({'ok': false, 'error': '$e'}));
      await req.response.close();
      _events.add(LanEvent(LanEventType.incomingFailed,
          name: name, from: from, error: '$e'));
    }
  }

  /// 浏览器发送文本：免确认直接收
  Future<void> _handleWebText(HttpRequest req) async {
    if (!_webShareEnabled) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    final from = '网页访客(${req.remoteAddress.address})';
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
    } catch (e) {
      req.response.statusCode = HttpStatus.internalServerError;
      req.response.write(json.encode({'ok': false, 'error': '$e'}));
      await req.response.close();
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
<title>微密飞传 · 网页快传</title>
<style>
  * { margin:0; padding:0; box-sizing:border-box; -webkit-tap-highlight-color:transparent; }
  body { font-family:-apple-system,"PingFang SC","Microsoft YaHei",sans-serif;
         background:#f2f5f9; min-height:100vh; display:flex; flex-direction:column; }
  header { background:linear-gradient(135deg,#1e6fd9,#2fa3e8); color:#fff;
           padding:22px 16px 18px; text-align:center; }
  header h1 { font-size:20px; font-weight:600; }
  header p { font-size:12px; opacity:.85; margin-top:4px; }
  main { flex:1; max-width:520px; width:100%; margin:0 auto; padding:16px; }
  .drop { background:#fff; border:2px dashed #9db8d6; border-radius:14px;
          padding:34px 16px; text-align:center; cursor:pointer; transition:.2s; }
  .drop.on, .drop:hover { border-color:#1e6fd9; background:#f0f7ff; }
  .drop .ic { font-size:40px; }
  .drop b { display:block; margin-top:8px; font-size:15px; color:#24405e; }
  .drop span { display:block; margin-top:4px; font-size:12px; color:#7d90a5; }
  .card { background:#fff; border-radius:14px; padding:14px; margin-top:14px; }
  .card h3 { font-size:14px; color:#24405e; margin-bottom:8px; }
  textarea { width:100%; height:90px; border:1px solid #d5dfeb; border-radius:10px;
             padding:10px; font-size:14px; resize:vertical; outline:none; }
  textarea:focus { border-color:#2fa3e8; }
  .btn { display:inline-block; border:none; border-radius:10px; padding:10px 22px;
         font-size:14px; color:#fff; background:#1e6fd9; cursor:pointer; }
  .btn:disabled { background:#a9c4e4; }
  .btn.sec { background:#eef4fb; color:#1e6fd9; }
  .row { display:flex; gap:10px; justify-content:flex-end; margin-top:10px; }
  ul { list-style:none; margin-top:10px; }
  li { font-size:13px; color:#24405e; padding:8px 10px; border-radius:8px;
       background:#f2f7fd; margin-bottom:6px; word-break:break-all; }
  li .bar { height:4px; background:#d8e6f5; border-radius:2px; margin-top:6px; overflow:hidden; }
  li .bar i { display:block; height:100%; width:0; background:#2fa3e8; transition:width .15s; }
  li.ok { background:#eef9ef; color:#1d7a34; }
  li.err { background:#fdeeee; color:#b23434; }
  footer { text-align:center; font-size:11px; color:#93a4b8; padding:12px; }
</style>
</head>
<body>
<header>
  <h1>微密飞传 · 网页快传</h1>
  <p>同一 WiFi 下，选择文件或输入文本即可发送到这台设备</p>
</header>
<main>
  <div class="drop" id="drop" onclick="document.getElementById('file').click()">
    <div class="ic">📤</div>
    <b>点按选择文件，或把文件拖到这里</b>
    <span>支持多选，文件将保存到对方设备的接收目录</span>
  </div>
  <input type="file" id="file" multiple hidden>
  <div class="card">
    <h3>发送文本</h3>
    <textarea id="txt" placeholder="输入要发送的文本内容"></textarea>
    <div class="row">
      <button class="btn" onclick="sendText()">发送文本</button>
    </div>
  </div>
  <ul id="list"></ul>
</main>
<footer>微密文件 · 局域网直传，数据不经外部服务器</footer>
<script>
var list = document.getElementById('list');
var drop = document.getElementById('drop');

function li(text, cls) {
  var el = document.createElement('li');
  el.textContent = text;
  if (cls) el.className = cls;
  list.appendChild(el);
  return el;
}
function done(el, text, ok) {
  el.textContent = text;
  el.className = ok ? 'ok' : 'err';
  var bar = el.querySelector('.bar');
  if (bar) bar.remove();
}

document.getElementById('file').addEventListener('change', function() {
  uploadAll(this.files);
  this.value = '';
});

['dragover','dragenter'].forEach(function(ev){
  drop.addEventListener(ev, function(e){ e.preventDefault(); drop.classList.add('on'); });
});
['dragleave','drop'].forEach(function(ev){
  drop.addEventListener(ev, function(e){ e.preventDefault(); drop.classList.remove('on'); });
});
drop.addEventListener('drop', function(e){
  if (e.dataTransfer && e.dataTransfer.files.length) uploadAll(e.dataTransfer.files);
});

function uploadAll(files) {
  var arr = Array.prototype.slice.call(files);
  (function next() {
    if (!arr.length) return;
    uploadOne(arr.shift()).then(next);
  })();
}

function uploadOne(file) {
  return new Promise(function(resolve) {
    var el = li('正在发送 ' + file.name + '（0%）');
    var bar = document.createElement('div');
    bar.className = 'bar';
    var inner = document.createElement('i');
    bar.appendChild(inner);
    el.appendChild(bar);
    var xhr = new XMLHttpRequest();
    xhr.open('POST', '/web/upload?name=' + encodeURIComponent(file.name));
    xhr.upload.onprogress = function(e) {
      if (e.lengthComputable) {
        var pct = Math.round(e.loaded / e.total * 100);
        inner.style.width = pct + '%';
        el.firstChild.textContent = '正在发送 ' + file.name + '（' + pct + '%）';
      }
    };
    xhr.onload = function() {
      if (xhr.status === 200) {
        done(el, '已发送 ' + file.name, true);
      } else {
        done(el, '发送失败 ' + file.name + '（' + xhr.status + '）', false);
      }
      resolve();
    };
    xhr.onerror = function() {
      done(el, '发送失败 ' + file.name + '（网络错误）', false);
      resolve();
    };
    xhr.send(file);
  });
}

function sendText() {
  var ta = document.getElementById('txt');
  var text = ta.value;
  if (!text.trim()) return;
  var btns = document.querySelectorAll('.btn');
  var btn = btns[btns.length - 1];
  btn.disabled = true;
  var el = li('正在发送文本…');
  var xhr = new XMLHttpRequest();
  xhr.open('POST', '/web/text');
  xhr.onload = function() {
    btn.disabled = false;
    if (xhr.status === 200) {
      done(el, '文本已发送', true);
      ta.value = '';
    } else {
      done(el, '发送失败（' + xhr.status + '）', false);
    }
  };
  xhr.onerror = function() {
    btn.disabled = false;
    done(el, '发送失败（网络错误）', false);
  };
  xhr.send(new Blob([text], {type:'text/plain'}));
}
</script>
</body>
</html>''';
  }

  /// 接收文件保存目录：优先「加密文件存放目录」，否则注入的兜底目录  Future<String> _resolveSaveDir() async {
    final prefs = await SharedPreferences.getInstance();
    final vaultDir = prefs.getString('weimi_vault_dir');
    if (vaultDir != null && vaultDir.isNotEmpty) {
      try {
        final d = Directory(vaultDir);
        if (await d.exists()) return vaultDir;
      } catch (_) {}
    }
    final fb = fallbackDir ?? Directory.systemTemp.path;
    final recv = p.join(fb, 'weimi_vault');
    final d = Directory(recv);
    if (!await d.exists()) await d.create(recursive: true);
    return recv;
  }

  Future<String> _resolveSavePath(String fileName) async {
    final dirPath = await _resolveSaveDir();
    final ext = p.extension(fileName);
    final base = p.basenameWithoutExtension(fileName);
    var target = p.join(dirPath, fileName);
    var i = 1;
    while (await File(target).exists()) {
      target = p.join(dirPath, '$base ($i)$ext');
      i++;
    }
    return target;
  }

  // ============ 发送端 ============

  /// 发送一个文件（明文原样直传，与 Landrop 行为一致）。
  Future<bool> sendFile({
    required LanPeer peer,
    required String filePath,
    void Function(int sent, int total)? onProgress,
  }) async {
    lastSendError = '';
    try {
      final sendName = p.basename(filePath);
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
          return true;
        }
        lastSendError =
            '对方返回 ${resp.statusCode}（403=拒收/防火墙拦截，500=对方写入失败）';
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
        req.headers.contentLength = bytes.length;
        req.add(bytes);
        await req.flush();
        final resp = await req.close();
        final body = await resp
            .transform(utf8.decoder)
            .timeout(const Duration(seconds: 30))
            .join();
        if (resp.statusCode == HttpStatus.ok && body.contains('"ok":true')) {
          return true;
        }
        lastSendError = '对方返回 ${resp.statusCode}（403=对方未信任本机/拒收）';
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

  static String _safeFileName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return cleaned.isEmpty ? 'unnamed' : cleaned;
  }
}

// ============ 数据类型 ============

class LanPeer {
  final String id;
  final String name;
  final String ip;
  final int httpPort;
  final bool trusted;
  DateTime lastSeen;

  LanPeer({
    required this.id,
    required this.name,
    required this.ip,
    required this.httpPort,
    this.trusted = false,
    required this.lastSeen,
  });

  LanPeer copyWith({bool? trusted}) => LanPeer(
        id: id,
        name: name,
        ip: ip,
        httpPort: httpPort,
        trusted: trusted ?? this.trusted,
        lastSeen: lastSeen,
      );
}

class IncomingRequest {
  final String senderId;
  final String senderName;
  final String fileName;
  final int fileSize;

  IncomingRequest({
    required this.senderId,
    required this.senderName,
    required this.fileName,
    required this.fileSize,
  });
}

enum LanEventType {
  receivingStarted,
  receivingStopped,
  peersChanged,
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
