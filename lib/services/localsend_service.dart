import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'lan_transfer_service.dart';
import 'receive_notify_service.dart';
import 'transfer_history_service.dart';

/// LocalSend v2 协议兼容层（与微密自研飞传平行叠加，互不影响）。
///
/// 协议来源：github.com/localsend/protocol（v2）
/// - 发现：UDP 组播 224.0.0.167:53317，announce（alias/deviceModel/
///   deviceType/fingerprint/announce）周期广播；应答双通道：
///   ① HTTP POST /api/localsend/v2/register（首选，换 InfoDto）
///   ② UDP 单播 announce:false（fallback）
/// - 信息：GET /api/localsend/v2/info?fingerprint=xxx
/// - 传输：POST /api/localsend/v2/prepare-upload（元数据，老 App 叫
///   /send-request）→ POST /api/localsend/v2/upload?sessionId&fileId&token
///   （二进制流）→ POST /api/localsend/v2/cancel?sessionId
///
/// 设计取舍：
/// - **我方恒明文 HTTP**（register/info 的 protocol 报 'http'，对端据此用
///   明文连我）；**对端可能是 HTTPS**——LocalSend App 默认开启加密且
///   "HTTPS only"（自签证书，指纹即设备身份）。客户端按 register 响应/
///   announce 里的 protocol 字段选 scheme，自签证书直接接受（局域网威胁
///   模型与微密飞传明文传输一致；LocalSend 自身也是指纹信任而非 CA 信任）。
///   对方开启 PIN 时 prepare-upload 返回 401，属明确边界。
/// - **Android 免原生**：Android 收组播需 MulticastLock（原生代码+权限），
///   故 Android 发现 LocalSend 设备走协议 3.2 的 legacy HTTP 扫描
///   （向本机各网段 IP:53317 POST register，http/https 各试一次），
///   组播只发不收。PC 端组播收发都走。扫描是出站请求，不受防火墙入站规则影响。
/// - 微密作为 LocalSend 设备被发现：靠组播 announce（入站 UDP 53317，
///   防火墙需放行，见 firewall_service 的 53317 规则）。
/// - 端点兼容：现行协议（v2.1+，2024-03 起）叫 /prepare-upload，之前的老
///   App 叫 /send-request——服务端两个都收，客户端先试新的、404 回退旧的。
/// - fileType 按协议用 MIME（image/jpeg 等），非枚举。
class LocalSendService {
  static const String lsGroup = '224.0.0.167';
  static const int lsPort = 53317;
  static const String _apiBase = '/api/localsend/v2';
  static const String _kFingerprintKey = 'localsend_fingerprint';

  LocalSendService._();
  static final LocalSendService instance = LocalSendService._();

  // ============ 状态 ============
  String _fingerprint = '';
  /// 组播接收 socket（53317，尽力而为；被占时仅丢组播接收，扫描兜底）
  RawDatagramSocket? _mcastSocket;
  /// 组播发送 socket（临时端口，恒定可用）
  RawDatagramSocket? _sendSocket;
  HttpServer? _server;
  /// 53317 被占时会向后探端口，这里记实际绑定端口（InfoDto/announce 必须报
  /// 真实端口，否则对端按默认 53317 连会连错——甚至连到本机真 LocalSend）
  int _serverPort = lsPort;
  Timer? _announceTimer;
  Timer? _scanTimer;
  bool _running = false;
  bool _scanning = false;
  DateTime _lastScan = DateTime.fromMillisecondsSinceEpoch(0);

  /// 进行中的会话（接收侧）：sessionId -> 文件清单+token
  final Map<String, _LsSession> _sessions = {};

  /// 最近一次错误（诊断用）
  String lastError = '';

  final StreamController<String> _events = StreamController<String>.broadcast();
  /// 兼容层事件流（'scanDone' 等，UI 可忽略）
  Stream<String> get events => _events.stream;

  bool get isRunning => _running;

  String get fingerprint => _fingerprint;

  // ============ 身份 ============

  String get _alias => LanTransferService.instance.selfName;

  String get _deviceType =>
      Platform.isAndroid || Platform.isIOS ? 'mobile' : 'desktop';

  String get _deviceModel {
    try {
      final v = Platform.operatingSystemVersion;
      return v.length > 40 ? v.substring(0, 40) : v;
    } catch (_) {
      return 'WeiMi';
    }
  }

  Future<void> _ensureFingerprint() async {
    if (_fingerprint.isNotEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    var fp = prefs.getString(_kFingerprintKey);
    if (fp == null || fp.isEmpty) {
      final rnd = Random.secure();
      fp = List.generate(32, (_) => rnd.nextInt(256))
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      await prefs.setString(_kFingerprintKey, fp);
    }
    _fingerprint = fp;
  }

  // ============ InfoDto / RegisterDto ============

  Map<String, dynamic> infoDto() => {
        'alias': _alias,
        'version': '2.0',
        'deviceModel': _deviceModel,
        'deviceType': _deviceType,
        'fingerprint': _fingerprint,
        'port': _serverPort,
        'protocol': 'http',
        // download API（协议 5.2/5.3 反向下载）未实现，诚实报 false
        'download': false,
      };

  Map<String, dynamic> registerDto() => {
        'alias': _alias,
        'version': '2.0',
        'deviceModel': _deviceModel,
        'deviceType': _deviceType,
        'fingerprint': _fingerprint,
        'port': _serverPort,
        'protocol': 'http',
        'download': false,
      };

  // ============ 生命周期 ============

  /// 启动：组播 announce + 53317 server（随飞传接收开关启停）
  Future<void> start() async {
    if (_running) return;
    await _ensureFingerprint();
    _running = true;
    await _startServer();
    _startMulticast();
    _announceTimer ??= Timer.periodic(
        const Duration(seconds: 3), (_) => _sendAnnounce());
    _scanTimer ??= Timer.periodic(
        const Duration(seconds: 45), (_) => scanOnce());
    // 立即来一轮 announce + 扫描，不用等周期
    _sendAnnounce();
    scanOnce();
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _announceTimer?.cancel();
    _announceTimer = null;
    _scanTimer?.cancel();
    _scanTimer = null;
    _mcastSocket?.close();
    _mcastSocket = null;
    _sendSocket?.close();
    _sendSocket = null;
    await _server?.close(force: true);
    _server = null;
    _serverPort = lsPort;
    _sessions.clear();
  }

  // ============ 组播发现 ============

  void _startMulticast() {
    () async {
      // 发送 socket：绑临时端口即可向组播群发（协议只要求能发到群，
      // 对端首选应答走 TCP register）。同时监听自身端口——对端的 UDP
      // 回退应答是单播到 announce 的源端口，不听就丢。
      try {
        final send = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        send.listen((ev) => _onDatagram(send, ev));
        _sendSocket = send;
      } catch (e) {
        lastError = '组播发送 socket 启动失败: $e';
      }
      // 接收 socket：53317。Windows 不复用地址（reuseAddress:true 在
      // Windows 上会与同机真 LocalSend App 争抢单播投递——它的 UDP 回退
      // 应答可能被我们收走或反之，与飞传发现端口同型坑，见
      // lan_transfer_service 的 Windows 分支）；绑不上（对方已占）就放弃
      // 组播接收，announce 发送与 HTTP 扫描兜底，不影响可用性。
      // macOS/Linux：组播接收本就依赖 SO_REUSEADDR 多实例共享，保持 reuse。
      try {
        final socket = Platform.isWindows
            ? await RawDatagramSocket.bind(
                InternetAddress.anyIPv4,
                lsPort,
                reuseAddress: false,
              )
            : await RawDatagramSocket.bind(
                InternetAddress.anyIPv4,
                lsPort,
                reuseAddress: true,
              );
        // joinMulticast 第二参是 NetworkInterface（不是 InternetAddress），
        // 逐网卡 join，多网卡/虚拟网卡环境都能收
        final ifaces = await NetworkInterface.list();
        for (final iface in ifaces) {
          try {
            socket.joinMulticast(InternetAddress(lsGroup), iface);
          } catch (_) {}
        }
        socket.listen((ev) => _onDatagram(socket, ev));
        _mcastSocket = socket;
      } catch (e) {
        // 端口被同机 LocalSend 占用等原因：组播接收不可用，扫描兜底
        lastError = '组播接收启动失败（将被 HTTP 扫描兜底）: $e';
      }
    }();
  }

  Future<void> _sendAnnounce() async {
    final socket = _sendSocket;
    if (socket == null || !_running) return;
    final body = utf8.encode(json.encode({
      'alias': _alias,
      'version': '2.0',
      'deviceModel': _deviceModel,
      'deviceType': _deviceType,
      'fingerprint': _fingerprint,
      'port': _serverPort,
      'protocol': 'http',
      'download': false,
      'announce': true,
    }));
    try {
      socket.send(body, InternetAddress(lsGroup), lsPort);
    } catch (_) {}
  }

  void _onDatagram(RawDatagramSocket socket, RawSocketEvent ev) {
    if (ev != RawSocketEvent.read) return;
    final dg = socket.receive();
    if (dg == null) return;
    try {
      final msg = json.decode(utf8.decode(dg.data)) as Map<String, dynamic>;
      final fp = msg['fingerprint'] as String?;
      if (fp == null || fp.isEmpty || fp == _fingerprint) return; // 自己
      final ip = dg.address.address;
      // announce 里带对方真实端口与 scheme（协议规定），没有才按默认
      final peerPort = (msg['port'] as int?) ?? lsPort;
      final peerHttps = (msg['protocol'] as String?) == 'https';
      if (msg['announce'] == true) {
        // 双应答：① HTTP register（首选，拿 InfoDto 真实端口/scheme）
        _registerTo(ip, peerPort, preferHttps: peerHttps);
        // ② UDP 单播 fallback
        _sendMcastReply(ip, dg.port);
      } else {
        // fallback 应答：同样带 port/protocol 字段
        _addLocalSendPeer(
            fp: fp, name: (msg['alias'] as String?) ?? 'LocalSend 设备',
            ip: ip, port: peerPort, https: peerHttps);
      }
    } catch (_) {}
  }

  void _sendMcastReply(String ip, int port) {
    final socket = _sendSocket;
    if (socket == null || port == 0) return;
    final body = utf8.encode(json.encode({
      'alias': _alias,
      'version': '2.0',
      'deviceModel': _deviceModel,
      'deviceType': _deviceType,
      'fingerprint': _fingerprint,
      'port': _serverPort,
      'protocol': 'http',
      'download': false,
      'announce': false,
    }));
    try {
      socket.send(body, InternetAddress(ip), port);
    } catch (_) {}
  }

  // ============ HTTP 扫描（协议 3.2 legacy：Android 免原生兜底） ============

  /// 扫描一轮本机各网段 /24 的 53317 端口（POST register 探测）。
  /// 节流：距上次不足 8 秒直接跳过；传输页打开/周期 45s 驱动。
  /// 说明：组播 announce + 对端 register 回连已覆盖多数网络；本扫描是
  /// 路由器屏蔽组播（AP 隔离/访客网络）时的兜底，故频率取保守值省电。
  Future<void> scanOnce({bool force = false}) async {
    if (!_running || _scanning) return;
    if (!force && DateTime.now().difference(_lastScan).inSeconds < 8) return;
    _scanning = true;
    _lastScan = DateTime.now();
    try {
      final myIps = await LanTransferService.instance.localIPv4s();
      final targets = <String>[];
      for (final myIp in myIps) {
        final parts = myIp.split('.');
        if (parts.length != 4) continue;
        for (var h = 2; h <= 254; h++) {
          final ip = '${parts[0]}.${parts[1]}.${parts[2]}.$h';
          if (ip != myIp && !targets.contains(ip)) targets.add(ip);
        }
      }
      // 分批 48 并发，防 Android 上连接数爆炸
      for (var i = 0; i < targets.length; i += 48) {
        if (!_running) break;
        final batch = targets.skip(i).take(48).toList();
        await Future.wait(batch.map((ip) => _registerTo(ip, lsPort)));
      }
    } finally {
      _scanning = false;
    }
    _events.add('scanDone');
  }

  /// POST /api/localsend/v2/register 到指定地址，200 则登记为 LocalSend 设备。
  /// [preferHttps]：组播发现时对方 announce 已带 protocol 字段，直接按它连；
  /// 盲扫（legacy HTTP 扫描）时不知道，先 http 再 https 各试一次
  /// （LocalSend App 默认 "HTTPS only"，默认配置下只有 https 能通）。
  /// 真正以哪个 scheme 通信以响应 DTO 的 protocol 字段为准。
  Future<void> _registerTo(String ip, int port, {bool preferHttps = false}) async {
    final schemes =
        preferHttps ? const ['https', 'http'] : const ['http', 'https'];
    for (final scheme in schemes) {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 2);
      if (scheme == 'https') {
        _allowSelfSigned(client);
      }
      try {
        final req = await client.postUrl(
            Uri.parse('$scheme://$ip:$port$_apiBase/register'));
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(json.encode(registerDto())));
        final resp = await req.close();
        final body = await resp
            .transform(utf8.decoder)
            .timeout(const Duration(seconds: 3))
            .join();
        if (resp.statusCode == 200) {
          final dto = json.decode(body) as Map<String, dynamic>;
          final fp = dto['fingerprint'] as String?;
          if (fp != null && fp.isNotEmpty && fp != _fingerprint) {
            _addLocalSendPeer(
                fp: fp,
                name: (dto['alias'] as String?) ?? 'LocalSend 设备',
                ip: ip,
                port: (dto['port'] as int?) ?? port,
                https: (dto['protocol'] as String?) == 'https');
          }
          return;
        }
      } catch (_) {
        // 扫描场景绝大多数目标不该响应，静默
      } finally {
        client.close(force: true);
      }
    }
  }

  /// LocalSend 的 HTTPS 用自签证书（指纹即设备身份，协议设计如此），
  /// 局域网传输与既有微密飞传明文同威胁模型——接受自签。
  void _allowSelfSigned(HttpClient client) {
    client.badCertificateCallback = (_, __, ___) => true;
  }

  /// POST 一段 JSON 到 LocalSend 对端（prepare-upload/send-request 回退用）
  Future<HttpClientResponse> _postJson(HttpClient client, LanPeer peer,
      String scheme, String endpoint, List<int> bodyBytes) async {
    final req = await client.postUrl(
        Uri.parse('$scheme://${peer.ip}:${peer.httpPort}$endpoint'));
    req.headers.contentType = ContentType.json;
    req.add(bodyBytes);
    return req.close();
  }

  void _addLocalSendPeer(
      {required String fp,
      required String name,
      required String ip,
      required int port,
      bool https = false}) {
    LanTransferService.instance.addOrUpdatePeer(LanPeer(
      id: 'ls_$fp',
      name: name,
      ip: ip,
      httpPort: port,
      lastSeen: DateTime.now(),
      protocol: 'localsend',
      https: https,
    ));
  }

  // ============ 53317 HTTP server（LocalSend v2 路由） ============

  Future<void> _startServer() async {
    HttpServer? server;
    Object? lastErr;
    // 53317 被占时向后探 5 个（InfoDto.port 会回报真实端口；
    // 组播发现场景对方只连默认端口，属协议局限，尽力而为）
    for (var port = lsPort; port < lsPort + 5 && server == null; port++) {
      try {
        server = await HttpServer.bind(InternetAddress.anyIPv4, port,
            shared: false);
      } on SocketException catch (e) {
        lastErr = e;
      }
    }
    if (server == null) {
      lastError = 'LocalSend 端口 $lsPort 绑定失败: $lastErr';
      return;
    }
    _serverPort = server.port;
    server.autoCompress = false;
    server.listen(_onHttpRequest, onError: (_) {});
    _server = server;
  }

  Future<void> _onHttpRequest(HttpRequest req) async {
    try {
      final path = req.uri.path;
      if (!path.startsWith(_apiBase)) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      if (!LanTransferService.instance.isReceiving) {
        req.response.statusCode = HttpStatus.serviceUnavailable;
        req.response.write(json.encode({'error': 'receiving off'}));
        await req.response.close();
        return;
      }
      final sub = path.substring(_apiBase.length);
      switch (req.method) {
        case 'GET':
          if (sub == '/info') {
            await _handleInfo(req);
          } else {
            req.response.statusCode = HttpStatus.notFound;
            await req.response.close();
          }
          break;
        case 'POST':
          if (sub == '/register') {
            await _handleRegister(req);
          } else if (sub == '/prepare-upload' || sub == '/send-request') {
            // /prepare-upload 是现行协议名，/send-request 是 2024-03 之前
            // 老版本 LocalSend App 用的名字——两个都收保证互通
            await _handleSendRequest(req);
          } else if (sub == '/upload') {
            await _handleUpload(req);
          } else if (sub == '/cancel') {
            await _handleCancel(req);
          } else {
            req.response.statusCode = HttpStatus.notFound;
            await req.response.close();
          }
          break;
        default:
          req.response.statusCode = HttpStatus.methodNotAllowed;
          await req.response.close();
      }
    } catch (e) {
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        req.response.write(json.encode({'error': '$e'}));
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<void> _handleInfo(HttpRequest req) async {
    final fp = req.uri.queryParameters['fingerprint'];
    if (fp != null && fp == _fingerprint) {
      req.response.statusCode = 412; // Precondition Failed: self-discovered
      req.response.write(json.encode({'error': 'Self-discovered'}));
      await req.response.close();
      return;
    }
    req.response.statusCode = HttpStatus.ok;
    req.response.headers.contentType = ContentType.json;
    req.response.write(json.encode(infoDto()));
    await req.response.close();
  }

  Future<void> _handleRegister(HttpRequest req) async {
    final body = await _readJson(req);
    if (body == null) {
      req.response.statusCode = HttpStatus.badRequest;
      req.response.write(json.encode({'error': 'malformed body'}));
      await req.response.close();
      return;
    }
    final fp = body['fingerprint'] as String?;
    if (fp == null || fp.isEmpty) {
      req.response.statusCode = HttpStatus.badRequest;
      req.response.write(json.encode({'error': 'fingerprint required'}));
      await req.response.close();
      return;
    }
    if (fp == _fingerprint) {
      req.response.statusCode = 412;
      req.response.write(json.encode({'error': 'Self-discovered'}));
      await req.response.close();
      return;
    }
    final ip = req.connectionInfo?.remoteAddress.address ?? '';
    _addLocalSendPeer(
        fp: fp,
        name: (body['alias'] as String?) ?? 'LocalSend 设备',
        ip: ip,
        port: (body['port'] as int?) ?? lsPort,
        https: (body['protocol'] as String?) == 'https');
    req.response.statusCode = HttpStatus.ok;
    req.response.headers.contentType = ContentType.json;
    req.response.write(json.encode(infoDto()));
    await req.response.close();
  }

  Future<Map<String, dynamic>?> _readJson(HttpRequest req) async {
    try {
      final bytes = <int>[];
      await for (final c in req) {
        bytes.addAll(c);
      }
      return json.decode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  // ============ 接收：send-request / upload / cancel ============

  Future<void> _handleSendRequest(HttpRequest req) async {
    final body = await _readJson(req);
    if (body == null) {
      req.response.statusCode = HttpStatus.badRequest;
      req.response.write(json.encode({'error': 'malformed body'}));
      await req.response.close();
      return;
    }
    final info = (body['info'] as Map<String, dynamic>?) ?? {};
    final senderId = 'ls_${info['fingerprint'] ?? ''}';
    final senderName = (info['alias'] as String?) ?? 'LocalSend 设备';
    final filesRaw = (body['files'] as Map<String, dynamic>?) ?? {};
    if (filesRaw.isEmpty) {
      req.response.statusCode = HttpStatus.badRequest;
      req.response.write(json.encode({'error': 'no files'}));
      await req.response.close();
      return;
    }

    // 解析文件清单
    final files = <String, _LsFile>{};
    var totalSize = 0;
    for (final entry in filesRaw.entries) {
      final m = entry.value as Map<String, dynamic>;
      final fileName = _safeFileName((m['fileName'] as String?) ?? 'unnamed');
      final size = (m['size'] as int?) ?? 0;
      totalSize += size;
      files[entry.key] = _LsFile(
        id: entry.key,
        fileName: fileName,
        size: size,
        token: _randomToken(),
      );
    }

    // 合并确认（复用微密飞传的信任/确认/批次豁免逻辑）
    final names = files.values.map((f) => f.fileName).take(3).join('、');
    final more = files.length > 3 ? ' 等 ${files.length} 个' : '';
    final accepted = await LanTransferService.instance.decideAccept(
      senderId: senderId,
      ask: () async {
        final handler = LanTransferService.instance.confirmHandler;
        if (handler == null) return false;
        return handler(IncomingRequest(
          senderId: senderId,
          senderName: senderName,
          fileName: '$names$more',
          fileSize: totalSize,
        ));
      },
    );
    if (!accepted) {
      req.response.statusCode = HttpStatus.forbidden;
      req.response.write(json.encode({'error': 'rejected'}));
      await req.response.close();
      ReceiveNotifyService.instance.rejected('$names$more', senderName);
      await TransferHistoryService.instance.add(TransferRecord(
        id: '${DateTime.now().microsecondsSinceEpoch}_lsr',
        kind: 'file',
        direction: 'in',
        name: '$names$more',
        size: totalSize,
        peerName: senderName,
        time: DateTime.now(),
        ok: false,
        note: 'LocalSend 未信任，已拒收',
      ));
      return;
    }

    final sessionId = _randomToken();
    _sessions[sessionId] = _LsSession(
      senderId: senderId,
      senderName: senderName,
      ip: req.connectionInfo?.remoteAddress.address ?? '',
      files: files,
      createdAt: DateTime.now(),
    );
    _cleanSessions();

    req.response.statusCode = HttpStatus.ok;
    req.response.headers.contentType = ContentType.json;
    req.response.write(json.encode({
      'sessionId': sessionId,
      'files': {
        for (final f in files.values) f.id: f.token,
      },
    }));
    await req.response.close();
  }

  Future<void> _handleUpload(HttpRequest req) async {
    final q = req.uri.queryParameters;
    final sessionId = q['sessionId'] ?? '';
    final fileId = q['fileId'] ?? '';
    final token = q['token'] ?? '';
    final session = _sessions[sessionId];
    final file = session?.files[fileId];
    final clientIp = req.connectionInfo?.remoteAddress.address ?? '';
    if (session == null ||
        file == null ||
        file.token != token ||
        file.done ||
        (session.ip.isNotEmpty && clientIp != session.ip)) {
      req.response.statusCode = HttpStatus.forbidden;
      req.response.write(json.encode({'error': 'invalid session/token'}));
      await req.response.close();
      return;
    }

    final savePath =
        await LanTransferService.instance.resolveSavePath(file.fileName);
    LanTransferService.instance.emitEvent(LanEvent(LanEventType.incomingStarted,
        name: file.fileName, from: session.senderName));

    try {
      final sink = File(savePath).openWrite();
      try {
        await for (final chunk in req) {
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      file.done = true;
      req.response.statusCode = HttpStatus.ok;
      req.response.write(json.encode({'status': 'ok'}));
      await req.response.close();
      LanTransferService.instance.emitEvent(LanEvent(LanEventType.incomingDone,
          name: file.fileName, from: session.senderName, path: savePath));
      ReceiveNotifyService.instance
          .fileDone(file.fileName, session.senderName, savePath);
      await TransferHistoryService.instance.add(TransferRecord(
        id: '${DateTime.now().microsecondsSinceEpoch}_lsin',
        kind: 'file',
        direction: 'in',
        name: file.fileName,
        path: savePath,
        size: file.size,
        peerName: session.senderName,
        time: DateTime.now(),
        ok: true,
      ));
    } catch (e) {
      try {
        final f = File(savePath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
      req.response.statusCode = HttpStatus.internalServerError;
      req.response.write(json.encode({'error': '$e'}));
      await req.response.close();
      LanTransferService.instance.emitEvent(LanEvent(
          LanEventType.incomingFailed,
          name: file.fileName,
          from: session.senderName,
          error: '$e'));
    }
  }

  Future<void> _handleCancel(HttpRequest req) async {
    final sessionId = req.uri.queryParameters['sessionId'] ?? '';
    _sessions.remove(sessionId);
    req.response.statusCode = HttpStatus.ok;
    req.response.write(json.encode({'status': 'ok'}));
    await req.response.close();
  }

  void _cleanSessions() {
    final now = DateTime.now();
    _sessions.removeWhere((_, s) =>
        now.difference(s.createdAt).inMinutes > 10 ||
        s.files.values.every((f) => f.done));
  }

  // ============ 发送：v2 client ============

  /// 发送文件到 LocalSend 设备（send-request → 逐个 upload）。
  /// 返回成功个数；lastError 带失败详情。
  Future<int> sendFiles({
    required LanPeer peer,
    required List<String> filePaths,
    void Function(String fileName, int sent, int total)? onProgress,
  }) async {
    lastError = '';
    if (filePaths.isEmpty) return 0;
    final scheme = peer.https ? 'https' : 'http';
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    if (peer.https) _allowSelfSigned(client);
    try {
      // 1) send-request
      final filesMap = <String, dynamic>{};
      for (var i = 0; i < filePaths.length; i++) {
        final path = filePaths[i];
        final f = File(path);
        if (!await f.exists()) continue;
        final name = p.basename(path);
        filesMap['f$i'] = {
          'id': 'f$i',
          'fileName': name,
          'size': await f.length(),
          'fileType': _fileTypeOf(name),
        };
      }
      if (filesMap.isEmpty) {
        lastError = '本地文件不存在';
        return 0;
      }
      // 端点兼容：现行协议叫 /prepare-upload，2024-03 之前的老 LocalSend App
      // 叫 /send-request——先试新的，404 回退老的（body 需重发）
      final bodyBytes = utf8.encode(json.encode({
        'info': {
          'alias': _alias,
          'version': '2.0',
          'deviceModel': _deviceModel,
          'deviceType': _deviceType,
          'fingerprint': _fingerprint,
          'port': _serverPort,
          'protocol': 'http',
          'download': false,
        },
        'files': filesMap,
      }));
      var endpoint = '$_apiBase/prepare-upload';
      var resp = await _postJson(client, peer, scheme, endpoint, bodyBytes);
      if (resp.statusCode == 404) {
        await resp.drain<void>();
        endpoint = '$_apiBase/send-request';
        resp = await _postJson(client, peer, scheme, endpoint, bodyBytes);
      }
      final respText = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) {
        if (resp.statusCode == 403) {
          lastError = '对方拒收（未确认或开启了 PIN）';
        } else if (resp.statusCode == 401) {
          lastError = '对方开启了 PIN 码，暂不支持';
        } else if (resp.statusCode == 204) {
          lastError = '对方未接受任何文件';
        } else {
          lastError = '对方返回 ${resp.statusCode}';
        }
        return 0;
      }
      final respBody = json.decode(respText) as Map<String, dynamic>;
      final sessionId = respBody['sessionId'] as String;
      final tokens =
          (respBody['files'] as Map<String, dynamic>).cast<String, String>();

      // 2) 逐个 upload（filesMap 的 key 'f<i>' 即 filePaths 下标，跳过不存在文件也保持对齐）
      var ok = 0;
      for (final entry in filesMap.entries) {
        final id = entry.key;
        final token = tokens[id];
        if (token == null) continue;
        final idx = int.parse(id.substring(1));
        if (idx < 0 || idx >= filePaths.length) continue;
        final file = File(filePaths[idx]);
        if (!await file.exists()) continue;
        final fileName = (entry.value as Map<String, dynamic>)['fileName']
            as String;
        final total = await file.length();
        final upReq = await client.postUrl(Uri.parse(
            '$scheme://${peer.ip}:${peer.httpPort}$_apiBase/upload'
            '?sessionId=${Uri.encodeQueryComponent(sessionId)}'
            '&fileId=${Uri.encodeQueryComponent(id)}'
            '&token=${Uri.encodeQueryComponent(token)}'));
        upReq.headers.contentType = ContentType.binary;
        upReq.contentLength = total;
        int sent = 0;
        await for (final chunk in file.openRead()) {
          upReq.add(chunk);
          sent += chunk.length;
          if (onProgress != null) onProgress(fileName, sent, total);
        }
        await upReq.flush();
        final upResp = await upReq.close();
        await upResp.drain<void>();
        if (upResp.statusCode == 200) {
          ok++;
          await TransferHistoryService.instance.add(TransferRecord(
            id: '${DateTime.now().microsecondsSinceEpoch}_lsout',
            kind: 'file',
            direction: 'out',
            name: fileName,
            path: file.path,
            size: total,
            peerName: peer.name,
            time: DateTime.now(),
            ok: true,
          ));
        } else {
          await TransferHistoryService.instance.add(TransferRecord(
            id: '${DateTime.now().microsecondsSinceEpoch}_lsout',
            kind: 'file',
            direction: 'out',
            name: fileName,
            path: file.path,
            size: total,
            peerName: peer.name,
            time: DateTime.now(),
            ok: false,
          ));
          lastError = '上传 $fileName 失败（${upResp.statusCode}）';
          break; // 一个失败即中止（会话可能已失效）
        }
      }
      return ok;
    } catch (e) {
      lastError = '$e';
      return 0;
    } finally {
      client.close(force: true);
    }
  }

  // ============ 工具 ============

  static String _randomToken() {
    final rnd = Random.secure();
    return List.generate(16, (_) => rnd.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  static String _safeFileName(String name) {
    var n = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    n = n.replaceAll('..', '_');
    if (n.trim().isEmpty) n = 'unnamed';
    return n.length > 120 ? n.substring(n.length - 120) : n;
  }

  /// LocalSend 协议的 fileType 是 MIME 类型（规范自 v2 起即如此，
  /// 2023-04 "use mime" 提交确认），不是 image/video 枚举。
  static String _fileTypeOf(String fileName) {
    final ext = p.extension(fileName).replaceFirst('.', '').toLowerCase();
    const mime = <String, String>{
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'gif': 'image/gif',
      'webp': 'image/webp',
      'bmp': 'image/bmp',
      'heic': 'image/heic',
      'heif': 'image/heif',
      'mp4': 'video/mp4',
      'mov': 'video/quicktime',
      'avi': 'video/x-msvideo',
      'mkv': 'video/x-matroska',
      'webm': 'video/webm',
      'm4v': 'video/mp4',
      '3gp': 'video/3gpp',
      'ts': 'video/mp2t',
      'flv': 'video/x-flv',
      'wmv': 'video/x-ms-wmv',
      'mp3': 'audio/mpeg',
      'wav': 'audio/wav',
      'flac': 'audio/flac',
      'aac': 'audio/aac',
      'm4a': 'audio/mp4',
      'ogg': 'audio/ogg',
      'pdf': 'application/pdf',
    };
    return mime[ext] ?? 'application/octet-stream';
  }
}

// ============ 内部数据结构 ============

class _LsFile {
  final String id;
  final String fileName;
  final int size;
  final String token;
  bool done = false;

  _LsFile({
    required this.id,
    required this.fileName,
    required this.size,
    required this.token,
  });
}

class _LsSession {
  final String senderId;
  final String senderName;
  final String ip;
  final Map<String, _LsFile> files;
  final DateTime createdAt;

  _LsSession({
    required this.senderId,
    required this.senderName,
    required this.ip,
    required this.files,
    required this.createdAt,
  });
}
