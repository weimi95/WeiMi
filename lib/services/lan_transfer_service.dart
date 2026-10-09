import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'trusted_devices_service.dart';
import 'transfer_history_service.dart';

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
      await TransferHistoryService.instance.add(TransferRecord(
        id: '${DateTime.now().microsecondsSinceEpoch}_in',
        kind: 'file',
        direction: 'in',
        name: request.fileName,
        path: savePath,
        size: request.fileSize,
        peerName: request.senderName,
        time: DateTime.now(),
        ok: true,
      ));
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
      await TransferHistoryService.instance.add(TransferRecord(
        id: '${DateTime.now().microsecondsSinceEpoch}_int',
        kind: 'text',
        direction: 'in',
        name: text,
        text: text,
        size: text.length,
        peerName: senderName,
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
      await TransferHistoryService.instance.add(TransferRecord(
        id: '${DateTime.now().microsecondsSinceEpoch}_web',
        kind: 'file',
        direction: 'in',
        name: name,
        path: savePath,
        size: req.contentLength,
        peerName: from,
        time: DateTime.now(),
        ok: true,
      ));
    } catch (e) {
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
      await TransferHistoryService.instance.add(TransferRecord(
        id: '${DateTime.now().microsecondsSinceEpoch}_webt',
        kind: 'text',
        direction: 'in',
        name: text,
        text: text,
        size: text.length,
        peerName: from,
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
    if (!_webShareEnabled || !_receiving) {
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

  /// App 接收网页文件：开 sink、收齐后关流并走记录/事件。返回落盘路径（失败 null）。
  Future<String?> _startAppInbound(_WebInbound inbound) async {
    if (_appInbound != null) return null;
    _appInbound = inbound;
    final from = '网页访客(${inbound.fromName})';
    String? savePath;
    try {
      savePath = await _resolveSavePath(inbound.name);
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
      await TransferHistoryService.instance.add(TransferRecord(
        id: '${DateTime.now().microsecondsSinceEpoch}_ws',
        kind: 'file',
        direction: 'in',
        name: inbound.name,
        path: savePath,
        size: inbound.size,
        peerName: from,
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
    TransferHistoryService.instance.add(TransferRecord(
      id: '${DateTime.now().microsecondsSinceEpoch}_wst',
      kind: 'text',
      direction: 'in',
      name: text,
      text: text,
      size: text.length,
      peerName: from,
      time: DateTime.now(),
      ok: true,
    ));
  }

  void _removeWebPeer(WebPeer? peer) {
    if (peer == null) return;
    _webPeers.remove(peer.id);
    _webInbound.remove(peer.socket);
    try {
      peer.socket.close();
    } catch (_) {}
    _broadcastWebPeers();
  }

  /// 房间成员列表（含 App 虚拟设备），exclude 排除某个浏览器
  List<Map<String, String>> _roomPeers({String? exclude}) {
    final out = <Map<String, String>>[
      {'id': kAppPeerId, 'name': _selfName},
    ];
    for (final w in _webPeers.values) {
      if (w.id != exclude) out.add({'id': w.id, 'name': w.name});
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
      await peer.socket.flush();
      _safeAdd(peer.socket, json.encode({'t': 'file-done', 'fid': fid}));
      await TransferHistoryService.instance.add(TransferRecord(
        id: '${DateTime.now().microsecondsSinceEpoch}_wsout',
        kind: 'file',
        direction: 'out',
        name: sendName,
        path: filePath,
        size: total,
        peerName: '网页客户端(${peer.name})',
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
      await peer.socket.flush();
      await TransferHistoryService.instance.add(TransferRecord(
        id: '${DateTime.now().microsecondsSinceEpoch}_wsot',
        kind: 'text',
        direction: 'out',
        name: text,
        text: text,
        size: text.length,
        peerName: '网页客户端(${peer.name})',
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
<title>微密飞传 · 网页快传</title>
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
  <h1>微密飞传 · 网页快传</h1>
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
  list.appendChild(el);
  return el;
}
function done(el, text, ok) {
  el.textContent = text;
  el.className = ok ? 'ok' : 'err';
  var bar = el.querySelector('.bar');
  if (bar) bar.remove();
}
</script>
</body>
</html>''';
  }

  /// 接收文件保存目录：优先「加密文件存放目录」，否则注入的兜底目录
  Future<String> _resolveSaveDir() async {
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
          await TransferHistoryService.instance.add(TransferRecord(
            id: '${DateTime.now().microsecondsSinceEpoch}_out',
            kind: 'file',
            direction: 'out',
            name: sendName,
            path: filePath,
            size: total,
            peerName: peer.name,
            time: DateTime.now(),
            ok: true,
          ));
          return true;
        }
        lastSendError =
            '对方返回 ${resp.statusCode}（403=拒收/防火墙拦截，500=对方写入失败）';
        await TransferHistoryService.instance.add(TransferRecord(
          id: '${DateTime.now().microsecondsSinceEpoch}_out',
          kind: 'file',
          direction: 'out',
          name: sendName,
          path: filePath,
          size: total,
          peerName: peer.name,
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
          await TransferHistoryService.instance.add(TransferRecord(
            id: '${DateTime.now().microsecondsSinceEpoch}_outt',
            kind: 'text',
            direction: 'out',
            name: text,
            text: text,
            size: text.length,
            peerName: peer.name,
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
