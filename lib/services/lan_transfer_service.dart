import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// 局域网传输服务（方案 B：自研轻量协议，对标 Landrop）
///
/// - 发现：UDP 广播（端口 52346），JSON 消息，announce 广播 / reply 单播应答
/// - 传输：HTTP POST 直传（端口 52345），明文原样收发，无加密环节
/// - 纯 Dart 实现（dart:io 的 RawDatagramSocket / HttpServer / HttpClient），
///   无平台通道、无新增第三方依赖，Android / Windows / macOS / Linux 全平台可用
///
/// UDP JSON 协议：
///   {"app":"weimi","action":"announce"|"reply","id":设备ID,"name":设备名,
///    "httpPort":52345,"v":1}
///
/// HTTP 协议：
///   POST /weimi/send
///   Header: X-Weimi-App / X-Sender-Id / X-Sender-Name(URL编码) / X-File-Name(URL编码) /
///           X-File-Size
///   Body: 文件字节流
///   Response: 200 {"ok":true,"path":"..."} / 403 拒收 / 500 失败
class LanTransferService {
  static const int discoveryPort = 52346;
  static const int httpPort = 52345;
  static const String _magic = 'weimi';
  static const String _kDeviceIdKey = 'lan_device_id';
  static const String _kDeviceNameKey = 'lan_device_name';

  // ============ 身份 ============
  String _identityId = '';
  String _selfName = '';

  // ============ 状态 ============
  final Map<String, LanPeer> _peers = {}; // key: deviceId
  bool _receiving = false;
  bool _discovering = false;
  Timer? _announceTimer;
  Timer? _pruneTimer;
  RawDatagramSocket? _udpSocket;
  HttpServer? _httpServer;

  /// 接收文件兜底目录（main.dart 启动时用 path_provider 注入）
  String? fallbackDir;

  final StreamController<LanEvent> _events =
      StreamController<LanEvent>.broadcast();
  Stream<LanEvent> get events => _events.stream;

  /// 收到传入文件请求时的确认回调（UI 弹窗），返回 true 才接收
  Future<bool> Function(IncomingRequest request)? confirmHandler;

  /// 最近一次发送失败的错误详情（诊断用）
  String lastSendError = '';

  LanTransferService._();
  static final LanTransferService instance = LanTransferService._();

  String get selfName => _selfName;
  bool get isReceiving => _receiving;
  List<LanPeer> get peers => _peers.values.toList();

  Future<void> _ensureIdentity() async {
    if (_identityId.isNotEmpty) return;
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

  /// 开启接收（UDP 应答 + HTTP 服务器）。重复调用幂等。
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
      final server =
          await HttpServer.bind(InternetAddress.anyIPv4, httpPort, shared: true);
      server.listen(_onHttpRequest, onError: (_) {});
      _httpServer = server;
    }

    _receiving = true;
    _announceTimer?.cancel();
    _announceTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _broadcastAnnounce());
    _events.add(LanEvent(LanEventType.receivingStarted));
  }

  /// 停止接收（不再广播自己；UDP/HTTP 端口保留以便后续快速重开）
  Future<void> stopReceiving() async {
    if (!_receiving) return;
    _receiving = false;
    _announceTimer?.cancel();
    _announceTimer = null;
    _events.add(LanEvent(LanEventType.receivingStopped));
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
        httpPort: (msg['httpPort'] as int?) ?? httpPort,
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
      'httpPort': httpPort,
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
      'httpPort': httpPort,
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
      if (req.method == 'POST' && req.uri.path == '/weimi/send') {
        await _handleIncomingFile(req);
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

  Future<void> _handleIncomingFile(HttpRequest req) async {
    String h(String name) {
      final v = req.headers.value(name) ?? '';
      if (v.isEmpty) return v;
      try {
        return Uri.decodeComponent(v);
      } catch (_) {
        return v;
      }
    }
    if (h('X-Weimi-App') != _magic) {
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
      return;
    }

    final request = IncomingRequest(
      senderId: h('X-Sender-Id'),
      senderName: h('X-Sender-Name').isEmpty ? '未知设备' : h('X-Sender-Name'),
      fileName:
          _safeFileName(h('X-File-Name').isEmpty ? 'unnamed' : h('X-File-Name')),
      fileSize: int.tryParse(h('X-File-Size')) ?? 0,
    );

    bool accepted = true;
    if (confirmHandler != null) {
      accepted = await confirmHandler!(request);
    }
    if (!accepted) {
      req.response.statusCode = HttpStatus.forbidden;
      req.response.write(json.encode({'ok': false, 'error': 'rejected'}));
      await req.response.close();
      _events.add(LanEvent(LanEventType.incomingRejected,
          name: request.fileName, from: request.senderName));
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
  DateTime lastSeen;

  LanPeer({
    required this.id,
    required this.name,
    required this.ip,
    required this.httpPort,
    required this.lastSeen,
  });
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
}

class LanEvent {
  final LanEventType type;
  final String? name;
  final String? from;
  final String? path;
  final String? error;

  LanEvent(this.type, {this.name, this.from, this.path, this.error});
}
