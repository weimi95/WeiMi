import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../framework/setting_store.dart';
import 'lan_transfer_service.dart';
import 'receive_notify_service.dart';
import 'rust_crypto.dart';
import 'transfer_history_service.dart';
import 'trusted_devices_service.dart';

/// LANDrop v2 兼容层（收发双端）。
///
/// 协议逆向自 LANDrop 2.7.2（electron asar 主进程 JS 完整可读 + Qt 版常量佐证）：
/// - 发现：UDP 52637。组播 239.192.52.63 + 广播 255.255.255.255 双发 announce；
///   收到 request=true 的查询包时单播应答。设备 20s 过期，我方每 10s 重播保活。
/// - 传输：裸 TCP（端口=发现包里的 port，优先 52637，被占自动换）。握手后
///   交换 supported_message_types / device_info，之后走 JSON 消息
///   （file_send_request / file_send_request_reply / text_send / ack）。
/// - 加密：X25519 kx 会话密钥 + ChaCha20-Poly1305-IETF 逐记录加密，
///   secp256k1 身份密钥签名握手段，BLAKE2b 派生 6 位 verifCode。
///   全部原语在 rust_crypto/src/landrop.rs（libsodium 对拍，见 tests/landrop_vectors.json）。
/// - 信任：TOFU——首次接收弹确认框显示 6 位 verifCode 供核对，勾选信任后
///   按 secp256k1 公钥持久化（TrustedDevices），之后免确认直收。
///
/// 平台取舍：
/// - Android 收组播需 MulticastLock（原生），故 Android 只**发**组播/广播、
///   不收组播；LANDrop 桌面端会应答广播查询（单播回到我方 socket），链路不断。
/// - Windows 上 LANDrop 可能已占用 UDP/TCP 52637：绑定失败自动降级到临时端口，
///   发现包里报真实端口，对端按包内端口连，不受影响。
/// - 只兼容 v2 协议（LANDrop 2.x 唯一在服役版本）。
/// - **进程边界**：本层跑在 Flutter UI 进程里。Windows 守护进程模式（UI 关窗
///   真退出）下 LANDrop 收发随 UI 停止——与 LocalSend 兼容层同边界
///   （守护进程只托管微密飞传 52345/52346，不实现 LANDrop 协议）。
class LandropService {
  static const int port = 52637;
  static const String multicastGroup = '239.192.52.63';
  static const int deviceExpirySecs = 20;
  static const int announceIntervalSecs = 10;
  static const int maxBlockSize = 65518;
  static const String _kIdentitySkKey = 'landrop_identity_sk_b64';

  LandropService._();
  static final LandropService instance = LandropService._();

  // ============ 状态 ============

  /// secp256k1 身份公钥（base64）= 设备 ID（信任列表按它持久化）
  String _identityPkB64 = '';
  String get identityPkB64 => _identityPkB64;

  /// 身份私钥字节（握手签名用，仅进程内）
  Uint8List _identitySk = Uint8List(0);
  Uint8List get identitySkBytes => _identitySk;

  bool _running = false;
  bool get isRunning => _running;

  RawDatagramSocket? _udpSocket;
  int _udpPort = 0;
  ServerSocket? _server;
  int _serverPort = 0;
  final List<Socket> _liveConns = [];

  /// 发现到的 LANDrop 设备（key = 身份公钥 base64）
  final Map<String, LandropDevice> _devices = {};
  List<LandropDevice> get devices => _devices.values.toList();

  Timer? _announceTimer;
  Timer? _pruneTimer;

  final StreamController<LandropEvent> _events =
      StreamController<LandropEvent>.broadcast();
  Stream<LandropEvent> get events => _events.stream;

  /// 最近一次错误（诊断用）
  String lastError = '';

  // ============ 开关与生命周期 ============

  /// 总开关：是否兼容 LANDrop 协议（设置→微密飞传→LANDrop 兼容）。
  /// 关闭后不广播也不收 LANDrop 连接；默认开启。
  static bool get enabled => SettingStore.get<bool>('lan_landrop_enabled', true);

  Future<void> setEnabled(bool v) async {
    await SettingStore.set('lan_landrop_enabled', v);
    if (v) {
      await start();
    } else {
      await stop();
    }
  }

  /// 启动（随飞传接收开关启停，幂等）
  Future<void> start() async {
    if (_running) return;
    if (!enabled) return;
    await _ensureIdentity();
    unawaited(refreshSelfIps());
    _running = true;
    await _startDiscovery();
    await _startServer();
    _announceTimer ??= Timer.periodic(
        const Duration(seconds: announceIntervalSecs), (_) => _announce());
    _pruneTimer ??=
        Timer.periodic(const Duration(seconds: 1), (_) => _pruneDevices());
    // 立即来一轮 announce，不用等周期
    _announce();
    debugPrint('LANDrop: 兼容层已启动（udp=$_udpPort tcp=$_serverPort）');
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _announceTimer?.cancel();
    _announceTimer = null;
    _pruneTimer?.cancel();
    _pruneTimer = null;
    for (final c in _liveConns) {
      try {
        c.destroy();
      } catch (_) {}
    }
    _liveConns.clear();
    _devices.clear();
    _udpSocket?.close();
    _udpSocket = null;
    await _server?.close();
    _server = null;
    _serverPort = 0;
    debugPrint('LANDrop: 兼容层已停止');
  }

  // ============ 身份 ============

  String get _selfName => LanTransferService.instance.selfName;

  /// 对外暴露的设备名/类型（会话内 device_info 回应用）
  String get selfDeviceName => _selfName;
  String get selfDeviceType => _deviceType;

  String get _deviceType {
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'desktop';
  }

  /// 身份密钥对持久化（SharedPreferences，sk base64；pk 由 sk 反推）。
  Future<void> _ensureIdentity() async {
    if (_identityPkB64.isNotEmpty) return;
    await TrustedDevices.instance.load(); // 信任列表判免确认用
    final prefs = await SharedPreferences.getInstance();
    var skB64 = prefs.getString(_kIdentitySkKey);
    if (skB64 == null || skB64.isEmpty) {
      final kp = RustCrypto.landropSecpKeypair();
      skB64 = base64.encode(kp.sk);
      await prefs.setString(_kIdentitySkKey, skB64);
    }
    final sk = base64.decode(skB64);
    _identitySk = Uint8List.fromList(sk);
    final pk = RustCrypto.landropSecpPkFromSk(sk);
    _identityPkB64 = base64.encode(pk);
  }

  // ============ 发现层 ============

  Future<void> _startDiscovery() async {
    // 优先绑 52637（与 LANDrop 同号，组播/广播查询与应答都走它）；
    // 被占（同机装着真 LANDrop）→ 降级临时端口，功能不受影响。
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        reuseAddress: false,
      );
    } on SocketException {
      try {
        socket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          0,
          reuseAddress: false,
        );
      } catch (e) {
        lastError = 'UDP 绑定失败: $e';
        debugPrint('LANDrop: $lastError');
        return;
      }
    }
    _udpSocket = socket;
    _udpPort = socket.port;
    socket.broadcastEnabled = true;
    socket.listen(_onDiscoveryDatagram);
    // 加入组播组（Android 无 MulticastLock 会失败，忽略——靠广播查询+单播应答）。
    // 注意 API 名是 joinMulticast（无 Group 后缀），第二参是 NetworkInterface，
    // 逐网卡 join，多网卡/虚拟网卡环境都能收。
    if (!Platform.isAndroid) {
      try {
        final ifaces = await NetworkInterface.list();
        for (final iface in ifaces) {
          try {
            socket.joinMulticast(InternetAddress(multicastGroup), iface);
          } catch (_) {}
        }
      } catch (e) {
        debugPrint('LANDrop: 加入组播组失败（不影响广播链路）: $e');
      }
    }
  }

  void _onDiscoveryDatagram(RawSocketEvent event) {
    final sock = _udpSocket;
    if (sock == null) return;
    final datagram = sock.receive();
    if (datagram == null) return;
    Map<String, dynamic> packet;
    try {
      packet = json.decode(utf8.decode(datagram.data)) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final fromIp = datagram.address.address;
    final pk = (packet['public_key'] as String?) ?? '';
    if (pk.isEmpty) return;
    // 自己的包不处理（组播回环 + 广播自发；IP 未刷新时用公钥兜底判自）
    if (_isSelfIp(fromIp) || pk == _identityPkB64) return;

    final isRequest = packet['request'] == true;
    final discoverable = packet['discoverable'] == true;
    if (isRequest) {
      // 对方在主动查询 → 单播应答（LANDrop 对广播/组播查询都回单播）
      _sendDiscoveryPacket(to: fromIp, port: datagram.port);
      return;
    }
    if (!discoverable) {
      // 对方关掉了可被发现 → 摘除
      if (_devices.remove(pk) != null) _events.add(LandropEvent.devicesChanged);
      return;
    }
    final info = (packet['device_info'] as Map<String, dynamic>?) ?? {};
    final dev = LandropDevice(
      publicKey: pk,
      name: (info['name'] as String?) ?? '未知设备',
      type: (info['type'] as String?) ?? '',
      address: fromIp,
      port: (packet['port'] as num?)?.toInt() ?? port,
      lastSeen: DateTime.now(),
    );
    final prev = _devices[pk];
    _devices[pk] = dev;
    if (prev == null ||
        prev.address != dev.address ||
        prev.port != dev.port ||
        prev.name != dev.name) {
      _events.add(LandropEvent.devicesChanged);
    }
  }

  bool _isSelfIp(String ip) {
    // 本地 IP 列表（ LanTransferService 已过滤虚拟网卡）
    final locals = _selfIpsCache;
    return locals.contains(ip);
  }

  List<String> _selfIpsCache = [];

  /// 发现包 JSON（与 LANDrop G 完全一致）
  Map<String, dynamic> _discoveryPacket() => {
        'request': false,
        'supported_versions': ['v2'],
        'public_key': _identityPkB64,
        'port': _serverPort,
        'device_info': {'name': _selfName, 'type': _deviceType},
        'discoverable': true,
      };

  void _sendDiscoveryPacket({required String to, required int port}) {
    final sock = _udpSocket;
    if (sock == null) return;
    try {
      sock.send(utf8.encode(json.encode(_discoveryPacket())),
          InternetAddress(to), port);
    } catch (_) {}
  }

  /// 周期广播：组播 + 广播双发（LANDrop 设备 20s 过期，10s 一次保活）
  void _announce() {
    final sock = _udpSocket;
    if (sock == null || !_running) return;
    final data = utf8.encode(json.encode(_discoveryPacket()));
    try {
      sock.send(data, InternetAddress(multicastGroup), port);
    } catch (_) {}
    try {
      sock.send(data, InternetAddress('255.255.255.255'), port);
    } catch (_) {}
  }

  void _pruneDevices() {
    final deadline =
        DateTime.now().subtract(const Duration(seconds: deviceExpirySecs));
    final before = _devices.length;
    _devices.removeWhere((_, d) => d.lastSeen.isBefore(deadline));
    if (_devices.length != before) _events.add(LandropEvent.devicesChanged);
  }

  /// 刷新本机 IP 缓存（发现自判回环用）
  Future<void> refreshSelfIps() async {
    _selfIpsCache = await LanTransferService.instance.localIPv4s();
  }

  // ============ TCP 服务（接收端） ============

  Future<void> _startServer() async {
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, port,
          shared: false);
    } on SocketException {
      try {
        _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0,
            shared: false);
      } catch (e) {
        lastError = 'TCP 绑定失败: $e';
        debugPrint('LANDrop: $lastError');
        return;
      }
    }
    _serverPort = _server!.port;
    _server!.listen(_onConnection, onError: (_) {});
  }

  void _onConnection(Socket conn) {
    _liveConns.add(conn);
    unawaited(_handleConn(conn).whenComplete(() {
      _liveConns.remove(conn);
      try {
        conn.destroy();
      } catch (_) {}
    }));
  }

  Future<void> _handleConn(Socket conn) async {
    _LandropSession? session;
    try {
      session = _LandropSession(conn, isClient: false);
      await session.handshake();
      await session.listen();
    } catch (e) {
      debugPrint('LANDrop: 连接处理失败: $e');
    } finally {
      try {
        conn.destroy();
      } catch (_) {}
    }
  }

  // ============ 接收决策 / 落盘 ============

  /// 处理 file_send_request（session 内调用）
  Future<void> _handleFileSendRequest(
      _LandropSession session, List<dynamic> files) async {
    final pk = session.peerPkB64;
    final senderName = session.peerDeviceName;
    if (files.isEmpty) {
      await session.replyFileSendRequest(false);
      return;
    }
    final first = files.first as Map<String, dynamic>;
    final totalSize =
        files.fold<int>(0, (s, f) => s + ((f as Map)['size'] as num? ?? 0).toInt());

    // 信任设备免确认直收
    final trusted = TrustedDevices.instance.isTrustedSync(pk);
    IncomingDecision decision;
    if (trusted) {
      decision = const IncomingDecision(accepted: true, batchDefault: false);
    } else {
      decision = await LanTransferService.instance.decideAcceptDecision(
        senderId: pk,
        ask: () async {
          final handler = LanTransferService.instance.confirmHandler;
          if (handler == null) {
            return const IncomingDecision(accepted: false, batchDefault: true);
          }
          return handler(IncomingRequest(
            senderId: pk,
            senderName: senderName,
            fileName: files.length == 1
                ? _safeName((first['filename'] as String?) ?? '未命名文件')
                : '${files.length} 个文件',
            fileSize: totalSize,
            trustable: true,
            verifCode: session.verifCode,
          ));
        },
      );
      // 勾选信任 → 按身份公钥持久化
      if (decision.accepted && decision.trust) {
        await TrustedDevices.instance.add(pk, senderName);
      }
    }

    if (!decision.accepted) {
      await session.replyFileSendRequest(false);
      ReceiveNotifyService.instance
          .rejected(files.length == 1 ? _safeName((first['filename'] as String?) ?? '文件') : '${files.length} 个文件', senderName);
      for (final f in files) {
        final m = f as Map<String, dynamic>;
        await TransferHistoryService.instance.add(TransferRecord(
          id: '${DateTime.now().microsecondsSinceEpoch}_ldinr',
          kind: 'file',
          direction: 'in',
          name: _safeName((m['filename'] as String?) ?? '未命名文件'),
          size: (m['size'] as num? ?? 0).toInt(),
          peerName: senderName,
          time: DateTime.now(),
          ok: false,
          note: '未信任，已拒收',
        ));
      }
      return;
    }

    await session.replyFileSendRequest(true);
    // 逐文件收流
    for (final f in files) {
      final m = f as Map<String, dynamic>;
      final rawName = (m['filename'] as String?) ?? '未命名文件';
      final name = _safeName(rawName);
      final size = (m['size'] as num? ?? 0).toInt();
      final lastModified = (m['last_modified'] as num? ?? 0).toInt();
      final permissions = (m['permissions'] as String?) ?? '';
      await _receiveOneFile(session, senderName, name, size, lastModified,
          permissions);
    }
  }

  Future<void> _receiveOneFile(
    _LandropSession session,
    String senderName,
    String name,
    int size,
    int lastModified,
    String permissions,
  ) async {
    final savePath = await LanTransferService.instance.resolveSavePath(name);
    LanTransferService.instance.beginIncomingByName(senderName);
    RandomAccessFile? raf;
    try {
      raf = await File(savePath).open(mode: FileMode.write);
      var remaining = size;
      while (remaining > 0) {
        final chunk = await session.recvBytes();
        if (chunk == null) {
          throw Exception('对端中途断开（$name 还差 $remaining 字节）');
        }
        await raf.writeFrom(chunk);
        remaining -= chunk.length;
      }
      await raf.close();
      raf = null;
      // 恢复 mtime / 权限（与 LANDrop 行为一致）
      if (lastModified > 0) {
        try {
          await File(savePath).setLastModified(
              DateTime.fromMillisecondsSinceEpoch(lastModified * 1000));
        } catch (_) {}
      }
      if (permissions.isNotEmpty && !Platform.isWindows) {
        _chmod(permissions, savePath);
      }
      LanTransferService.instance.endIncomingByName(senderName);
      ReceiveNotifyService.instance.fileDone(name, senderName, savePath);
      await TransferHistoryService.instance.add(TransferRecord(
        id: '${DateTime.now().microsecondsSinceEpoch}_ldin',
        kind: 'file',
        direction: 'in',
        name: name,
        path: savePath,
        size: size,
        peerName: senderName,
        time: DateTime.now(),
        ok: true,
      ));
    } catch (e) {
      if (raf != null) {
        try {
          await raf.close();
        } catch (_) {}
      }
      LanTransferService.instance.endIncomingByName(senderName);
      try {
        final f = File(savePath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
      ReceiveNotifyService.instance.rejected(name, senderName);
      await TransferHistoryService.instance.add(TransferRecord(
        id: '${DateTime.now().microsecondsSinceEpoch}_ldinf',
        kind: 'file',
        direction: 'in',
        name: name,
        size: size,
        peerName: senderName,
        time: DateTime.now(),
        ok: false,
        note: '传输失败: $e',
      ));
      rethrow;
    }
  }

  void _chmod(String octal, String path) {
    try {
      final mode = int.parse(octal, radix: 8);
      Process.run('chmod', [mode.toRadixString(8), path]);
    } catch (_) {}
  }

  // ============ 发送端 ============

  /// 发送文件到一台 LANDrop 设备。
  /// 流程（与 specSendFiles/LANDrop class p 一致）：
  /// TCP 连接 → ClientHello/ServerHello → 交换 supported_message_types/
  /// device_info → file_send_request → 等 reply → 按序流式发文件记录。
  /// [files] 的 filename 可含 '/'（文件夹传输的相对路径）。
  /// [onVerifCode] 握手成功后回调（未信任设备时调用方应立即展示供双方核对）；
  /// [onProgress] 回调 (当前文件名, 已发总字节, 总字节)。
  Future<LandropSendResult> sendFilesToDevice(
    LandropDevice device,
    List<LandropSendFile> files, {
    void Function(String verifCode)? onVerifCode,
    void Function(String currentFile, int sentTotal, int totalBytes)?
        onProgress,
  }) async {
    await _ensureIdentity();
    if (files.isEmpty) {
      return const LandropSendResult(ok: false, error: '没有可发送的文件');
    }
    // 预检并汇总元信息（file_send_request 要带全部文件属性）
    final metas = <_SendFileMeta>[];
    var totalBytes = 0;
    for (final f in files) {
      final file = File(f.path);
      if (!await file.exists()) {
        return LandropSendResult(ok: false, error: '文件不存在：${f.path}');
      }
      final st = await file.stat();
      metas.add(_SendFileMeta(
        path: f.path,
        filename: f.filename,
        size: st.size,
        lastModified: st.modified.millisecondsSinceEpoch ~/ 1000,
        permissions: _octalMode(st.mode),
      ));
      totalBytes += st.size;
    }

    Socket socket;
    try {
      socket = await Socket.connect(device.address, device.port,
          timeout: const Duration(seconds: 10));
    } catch (e) {
      return LandropSendResult(ok: false, error: '连接失败：$e');
    }
    final session = _LandropSession(socket, isClient: true);
    try {
      await session.handshakeAsClient();
      onVerifCode?.call(session.verifCode);
      await session.exchangeSupportedMessageTypes();
      await session.exchangeDeviceInfo();
      await session.sendJson({
        'type': 'file_send_request',
        'data': {
          'files': [
            for (final m in metas)
              {
                'filename': m.filename,
                'size': m.size,
                'last_modified': m.lastModified,
                'permissions': m.permissions,
              }
          ],
          'supported_compressions': ['none'],
          'ios_live_photos': [],
        },
      });
      final reply = await session.recvJson();
      if (reply == null) {
        return LandropSendResult(
            ok: false,
            error: '对端无响应',
            verifCode: session.verifCode,
            peerName: session.peerDeviceName);
      }
      if (reply['type'] != 'file_send_request_reply' ||
          (reply['data'] as Map<String, dynamic>?)?['accept'] != true) {
        // 对端拒收：记账留痕
        for (final m in metas) {
          await _recordOut(m, ok: false, note: '对方拒收', peerName: device.name);
        }
        return LandropSendResult(
            ok: false,
            rejected: true,
            error: '对方拒收',
            verifCode: session.verifCode,
            peerName: session.peerDeviceName);
      }
      // 逐文件流式发送（≤65518/条自动分片，末片 push=1；空文件不发记录）
      var sent = 0;
      for (final m in metas) {
        final raf = await File(m.path).open();
        try {
          var remaining = m.size;
          while (remaining > 0) {
            final chunk = await raf.read(
                remaining < LandropService.maxBlockSize
                    ? remaining
                    : LandropService.maxBlockSize);
            if (chunk.isEmpty) throw Exception('文件读取中断：${m.filename}');
            await session.sendBytes(chunk);
            sent += chunk.length;
            remaining -= chunk.length;
            onProgress?.call(m.filename, sent, totalBytes);
          }
        } finally {
          await raf.close();
        }
        await _recordOut(m, ok: true, peerName: session.peerDeviceName);
      }
      // 等对端读完关闭（LANDrop 收完即 FIN；最多等 3s）
      await session.waitPeerClose(const Duration(seconds: 3));
      return LandropSendResult(
          ok: true, verifCode: session.verifCode, peerName: session.peerDeviceName);
    } catch (e) {
      return LandropSendResult(
          ok: false,
          error: '$e',
          verifCode: session.verifCode,
          peerName: session.peerDeviceName);
    } finally {
      try {
        socket.destroy();
      } catch (_) {}
    }
  }

  /// 发送文本到一台 LANDrop 设备（text_send + 等 ack）。
  Future<LandropSendResult> sendTextToDevice(
    LandropDevice device,
    String text, {
    void Function(String verifCode)? onVerifCode,
  }) async {
    await _ensureIdentity();
    if (text.trim().isEmpty) {
      return const LandropSendResult(ok: false, error: '空文本');
    }
    Socket socket;
    try {
      socket = await Socket.connect(device.address, device.port,
          timeout: const Duration(seconds: 10));
    } catch (e) {
      return LandropSendResult(ok: false, error: '连接失败：$e');
    }
    final session = _LandropSession(socket, isClient: true);
    try {
      await session.handshakeAsClient();
      onVerifCode?.call(session.verifCode);
      await session.exchangeSupportedMessageTypes();
      await session.exchangeDeviceInfo();
      await session.sendJson({'type': 'text_send', 'data': {'text': text}});
      final ack = await session.recvJson();
      final ok = ack != null &&
          ack['type'] == 'ack' &&
          (ack['data'] as Map<String, dynamic>?)?['ack'] == true;
      if (ok) {
        await TransferHistoryService.instance.add(TransferRecord(
          id: '${DateTime.now().microsecondsSinceEpoch}_ldouttxt',
          kind: 'text',
          direction: 'out',
          name: '发送给 ${device.name} 的文本',
          text: text.length > 2000 ? '${text.substring(0, 2000)}…' : text,
          size: text.length,
          peerName: device.name,
          time: DateTime.now(),
          ok: true,
        ));
      }
      return LandropSendResult(
          ok: ok,
          error: ok ? '' : '对端未确认',
          verifCode: session.verifCode,
          peerName: session.peerDeviceName);
    } catch (e) {
      return LandropSendResult(
          ok: false,
          error: '$e',
          verifCode: session.verifCode,
          peerName: session.peerDeviceName);
    } finally {
      try {
        socket.destroy();
      } catch (_) {}
    }
  }

  Future<void> _recordOut(_SendFileMeta m,
      {required bool ok, String? note, required String peerName}) async {
    await TransferHistoryService.instance.add(TransferRecord(
      id: '${DateTime.now().microsecondsSinceEpoch}_ldout',
      kind: 'file',
      direction: 'out',
      name: m.filename,
      size: m.size,
      peerName: peerName,
      time: DateTime.now(),
      ok: ok,
      note: note,
    ));
  }

  /// 文件 mode → 八进制权限串（LANDrop permissions 字段）。
  /// Windows 的 stat mode 无意义，统一 '644'（对端 Windows 也忽略该字段）。
  String _octalMode(int mode) {
    if (Platform.isWindows || mode == 0) return '644';
    final s = (mode & 0xFFF).toRadixString(8);
    return s.isEmpty ? '644' : s;
  }

  /// 文件名净化：去路径穿越（'..'）、去前导 '/'、统一正斜杠。
  /// LANDrop 文件夹传输的 filename 形如 "文件夹/子目录/文件.txt"。
  String _safeName(String raw) {
    final parts = raw.split('/').where((s) {
      final t = s.trim();
      return t.isNotEmpty && t != '.' && t != '..';
    });
    final joined = parts.join('/');
    return joined.isEmpty ? '未命名文件' : joined;
  }
}

// ==================== 会话（握手 + 帧 + 消息） ====================

class _LandropSession {
  final Socket socket;
  final bool isClient;
  Uint8List _recvBuf = Uint8List(0);

  late Uint8List _rxKey;
  late Uint8List _txKey;
  final Uint8List _rxNonce = Uint8List(12);
  final Uint8List _txNonce = Uint8List(12);

  String peerPkB64 = '';
  String peerDeviceName = 'LANDrop 设备';
  String peerDeviceType = '';
  String _verifCode = '';

  /// 6 位 verifCode（TOFU 核对）
  String get verifCode => _verifCode;

  _LandropSession(this.socket, {required this.isClient}) {
    _attachReader();
  }

  // ---------- 帧层 ----------

  Future<void> _writeRaw(Uint8List data) async {
    final hdr = Uint8List(2);
    hdr[0] = (data.length >> 8) & 0xff;
    hdr[1] = data.length & 0xff;
    socket.add(hdr);
    socket.add(data);
    await socket.flush();
  }

  /// 读一个完整记录（2B 大端长度 + 密文）。对流式到达做缓冲拼接。
  /// 单记录上限 65535（push 1 + 明文 65518 + tag 16），超过按协议违例拒绝，防无上限缓冲。
  Future<Uint8List?> _readRaw() async {
    while (true) {
      if (_recvBuf.length >= 2) {
        final len = (_recvBuf[0] << 8) | _recvBuf[1];
        // 单记录明文 = 1B push + 数据（≤maxBlockSize），密文 +16B tag → 上限 maxBlockSize+17
        if (len > LandropService.maxBlockSize + 17) {
          throw Exception('LANDrop: 记录超长（$len），协议违例');
        }
        if (_recvBuf.length >= len + 2) {
          final out = Uint8List.sublistView(_recvBuf, 2, len + 2);
          _recvBuf = Uint8List.sublistView(_recvBuf, len + 2);
          return out;
        }
      }
      final chunk = await _readSome();
      if (chunk == null) return null;
      final merged = Uint8List(_recvBuf.length + chunk.length);
      merged.setRange(0, _recvBuf.length, _recvBuf);
      merged.setRange(_recvBuf.length, merged.length, chunk);
      _recvBuf = merged;
    }
  }

  // 单订阅读取器：整个连接只 listen 一次，数据块进队列，_readSome 按需取。
  // （反复 listen/cancel 依赖 socket 内部缓冲，语义不保险；队列模式确定）。
  final List<Uint8List> _chunks = [];
  Completer<void>? _dataAvailable;
  bool _streamClosed = false;
  StreamSubscription<Uint8List>? _sub;

  void _attachReader() {
    _sub = socket.listen((d) {
      _chunks.add(d);
      final c = _dataAvailable;
      _dataAvailable = null;
      c?.complete();
    }, onError: (_) => _markClosed(), onDone: () => _markClosed(),
        cancelOnError: true);
  }

  void _markClosed() {
    _streamClosed = true;
    final c = _dataAvailable;
    _dataAvailable = null;
    c?.complete();
  }

  Future<Uint8List?> _readSome() async {
    while (_chunks.isEmpty && !_streamClosed) {
      _dataAvailable = Completer<void>();
      await _dataAvailable!.future;
    }
    if (_chunks.isEmpty) return null;
    return _chunks.removeAt(0);
  }

  // ---------- 消息层 ----------

  /// 加密发送一条消息（>65518 自动分片，末片 push=1；与 LANDrop 完全一致）
  Future<void> sendBytes(Uint8List data) async {
    var offset = 0;
    do {
      final isLast = offset + LandropService.maxBlockSize >= data.length;
      final end = isLast ? data.length : offset + LandropService.maxBlockSize;
      final chunk = Uint8List.sublistView(data, offset, end);
      final plain = Uint8List(1 + chunk.length);
      plain[0] = isLast ? 1 : 0;
      plain.setRange(1, 1 + chunk.length, chunk);
      final ct = RustCrypto.landropSeal(_txKey, _txNonce, plain);
      await _writeRaw(ct);
      RustCrypto.landropNonceIncrement(_txNonce);
      offset = end;
    } while (offset < data.length);
  }

  /// 解密接收一条完整消息（跨记录累积到 push=1）。null = 对端关闭。
  Future<Uint8List?> recvBytes() async {
    final out = <int>[];
    while (true) {
      final ct = await _readRaw();
      if (ct == null) return null;
      final plain = RustCrypto.landropOpen(_rxKey, _rxNonce, ct);
      RustCrypto.landropNonceIncrement(_rxNonce);
      if (plain.isEmpty) throw Exception('LANDrop: 异常的空记录');
      final push = plain[0];
      out.addAll(Uint8List.sublistView(plain, 1));
      if (push == 1) return Uint8List.fromList(out);
    }
  }

  Future<void> sendJson(Map<String, dynamic> msg) =>
      sendBytes(utf8.encode(json.encode(msg)) as Uint8List);

  Future<Map<String, dynamic>?> recvJson() async {
    final bytes = await recvBytes();
    if (bytes == null) return null;
    try {
      return json.decode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  // ---------- 握手 ----------

  /// 服务端握手：收 ClientHello → 验签 → 发 ServerHello → 派生会话密钥
  Future<void> handshake() async {
    final helloBytes = await _readRaw();
    if (helloBytes == null) throw Exception('ClientHello 未到达');
    final hello = json.decode(utf8.decode(helloBytes)) as Map<String, dynamic>;
    final versions = (hello['supported_versions'] as List?) ?? [];
    if (!versions.contains('v2')) throw Exception('对端不支持 v2');
    final pkB64 = (hello['public_key'] as String?) ?? '';
    if (pkB64.isEmpty) throw Exception('ClientHello 缺 public_key');
    final ecdhe = (hello['ecdhe'] as Map<String, dynamic>?) ?? {};
    final ecdhePk = base64.decode((ecdhe['public_key'] as String?) ?? '');
    final sig = base64.decode((ecdhe['sig'] as String?) ?? '');
    if (ecdhePk.length != 32 || sig.length != 64) throw Exception('ClientHello ecdhe 字段异常');
    // 验签：sig = secp256k1_sign(blake2b-256(ecdhe.pk), 对端 sk)
    if (!RustCrypto.landropSecpVerify(sig, ecdhePk, base64.decode(pkB64))) {
      throw Exception('ClientHello 验签失败');
    }
    // 生成我方 kx 密钥对并签名
    final kx = RustCrypto.landropKxKeypair();
    final mySig = RustCrypto.landropSecpSign(
        kx.pk, LandropService.instance.identitySkBytes);
    final serverHello = {
      'version': 'v2',
      'public_key': LandropService.instance.identityPkB64,
      'ecdhe': {
        'public_key': base64.encode(kx.pk),
        'sig': base64.encode(mySig),
      },
    };
    await _writeRaw(utf8.encode(json.encode(serverHello)) as Uint8List);
    _deriveSessionKeys(kx, ecdhePk, pkB64);
  }

  void _deriveSessionKeys(
      ({Uint8List pk, Uint8List sk}) kx, Uint8List peerEcdhePk, String peerPk) {
    final keys = RustCrypto.landropKxSessionKeys(
      isClient: false,
      ownSk: kx.sk,
      ownPk: kx.pk,
      peerPk: peerEcdhePk,
    );
    _rxKey = keys.rx;
    _txKey = keys.tx;
    peerPkB64 = peerPk;
    // server 角色：kSc=tx, kCs=rx（与 LANDrop class we 一致）
    _verifCode = RustCrypto.landropVerifCode(kSc: _txKey, kCs: _rxKey);
  }

  /// 客户端握手：发 ClientHello → 收 ServerHello 验签 → 派生会话密钥
  /// （与 LANDrop class p.connect 完全一致；specSendFiles 对拍通过）
  Future<void> handshakeAsClient() async {
    final kx = RustCrypto.landropKxKeypair();
    final mySig = RustCrypto.landropSecpSign(
        kx.pk, LandropService.instance.identitySkBytes);
    final clientHello = {
      'supported_versions': ['v2'],
      'public_key': LandropService.instance.identityPkB64,
      'ecdhe': {
        'public_key': base64.encode(kx.pk),
        'sig': base64.encode(mySig),
      },
    };
    await _writeRaw(utf8.encode(json.encode(clientHello)) as Uint8List);
    final helloBytes = await _readRaw();
    if (helloBytes == null) throw Exception('ServerHello 未到达');
    final hello = json.decode(utf8.decode(helloBytes)) as Map<String, dynamic>;
    if (hello['version'] != 'v2') throw Exception('对端不支持 v2');
    final pkB64 = (hello['public_key'] as String?) ?? '';
    if (pkB64.isEmpty) throw Exception('ServerHello 缺 public_key');
    final ecdhe = (hello['ecdhe'] as Map<String, dynamic>?) ?? {};
    final ecdhePk = base64.decode((ecdhe['public_key'] as String?) ?? '');
    final sig = base64.decode((ecdhe['sig'] as String?) ?? '');
    if (ecdhePk.length != 32 || sig.length != 64) {
      throw Exception('ServerHello ecdhe 字段异常');
    }
    // 验签：sig = secp256k1_sign(blake2b-256(ecdhe.pk), 对端 sk)
    if (!RustCrypto.landropSecpVerify(sig, ecdhePk, base64.decode(pkB64))) {
      throw Exception('ServerHello 验签失败');
    }
    final keys = RustCrypto.landropKxSessionKeys(
      isClient: true,
      ownSk: kx.sk,
      ownPk: kx.pk,
      peerPk: ecdhePk,
    );
    _rxKey = keys.rx;
    _txKey = keys.tx;
    peerPkB64 = pkB64;
    // client 角色：kSc=rx, kCs=tx（与 LANDrop class p 一致）
    _verifCode = RustCrypto.landropVerifCode(kSc: _rxKey, kCs: _txKey);
  }

  /// 客户端：交换 supported_message_types（先发后收）
  Future<void> exchangeSupportedMessageTypes() async {
    await sendJson({
      'type': 'supported_message_types',
      'data': {
        'types': [
          'ack',
          'supported_message_types',
          'device_info',
          'file_send_request',
          'file_send_request_reply',
          'text_send',
        ]
      },
    });
    final mt = await recvJson();
    if (mt == null || mt['type'] != 'supported_message_types') {
      throw Exception('对端不回 supported_message_types');
    }
  }

  /// 客户端：交换 device_info（先发后收，存对端名字）
  Future<void> exchangeDeviceInfo() async {
    await sendJson({
      'type': 'device_info',
      'data': {
        'name': LandropService.instance.selfDeviceName,
        'type': LandropService.instance.selfDeviceType,
      },
    });
    final di = await recvJson();
    if (di == null || di['type'] != 'device_info') {
      throw Exception('对端不回 device_info');
    }
    final data = (di['data'] as Map<String, dynamic>?) ?? {};
    peerDeviceName = (data['name'] as String?) ?? 'LANDrop 设备';
    peerDeviceType = (data['type'] as String?) ?? '';
  }

  /// 等待对端关闭连接（收完即关）或超时（LANDrop 服务端读完所有
  /// 文件记录后主动 FIN；异常路径下靠超时兜底，不阻塞返回）。
  Future<void> waitPeerClose(Duration timeout) async {
    try {
      await socket.done.timeout(timeout);
    } catch (_) {}
  }

  // ---------- 消息循环（服务端） ----------

  Future<void> listen() async {
    while (true) {
      final msg = await recvJson();
      if (msg == null) return; // 对端关闭
      final type = msg['type'] as String?;
      final data = (msg['data'] as Map<String, dynamic>?) ?? {};
      switch (type) {
        case 'supported_message_types':
          // 对端先发：存它的，回我们的（LANDrop handleSupportedMessageTypes 语义）
          await sendJson({
            'type': 'supported_message_types',
            'data': {
              'types': [
                'ack',
                'supported_message_types',
                'device_info',
                'file_send_request',
                'file_send_request_reply',
                'text_send',
              ]
            },
          });
          break;
        case 'device_info':
          peerDeviceName = (data['name'] as String?) ?? 'LANDrop 设备';
          peerDeviceType = (data['type'] as String?) ?? '';
          await sendJson({
            'type': 'device_info',
            'data': {
              'name': LandropService.instance.selfDeviceName,
              'type': LandropService.instance.selfDeviceType,
            },
          });
          break;
        case 'file_send_request':
          final files = (data['files'] as List?) ?? [];
          await LandropService.instance
              ._handleFileSendRequest(this, files);
          break;
        case 'text_send':
          await _handleTextSend((data['text'] as String?) ?? '');
          break;
        default:
          // ack / 未知：回 ack:false（LANDrop 同行为）
          await sendJson({'type': 'ack', 'data': {'ack': false}});
          break;
      }
    }
  }

  Future<void> _handleTextSend(String text) async {
    await sendJson({'type': 'ack', 'data': {'ack': true}});
    ReceiveNotifyService.instance.textDone(peerDeviceName, text);
    await TransferHistoryService.instance.add(TransferRecord(
      id: '${DateTime.now().microsecondsSinceEpoch}_ldtxt',
      kind: 'text',
      direction: 'in',
      name: '来自 $peerDeviceName 的文本',
      text: text.length > 2000 ? '${text.substring(0, 2000)}…' : text,
      size: text.length,
      peerName: peerDeviceName,
      time: DateTime.now(),
      ok: true,
    ));
  }

  Future<void> replyFileSendRequest(bool accept) async {
    await sendJson({
      'type': 'file_send_request_reply',
      'data': {'accept': accept, 'compression': 'none'},
    });
    if (!accept) {
      // LANDrop 拒收后关闭连接。先 flush 保 reply 到达，再优雅关闭（FIN）。
      try {
        await socket.flush();
        await socket.close();
      } catch (_) {}
    }
  }

  /// 供发送端（阶段 3）读取解密后的一条消息
  Future<Map<String, dynamic>?> recvMessage() => recvJson();
}

// ==================== 数据模型 ====================

class LandropDevice {
  final String publicKey; // 身份公钥 base64
  final String name;
  final String type;
  final String address;
  final int port;
  final DateTime lastSeen;

  LandropDevice({
    required this.publicKey,
    required this.name,
    required this.type,
    required this.address,
    required this.port,
    required this.lastSeen,
  });

  /// 是否已信任（按身份公钥）
  bool get trusted => TrustedDevices.instance.isTrustedSync(publicKey);
}

class LandropEvent {
  final String kind; // 'devicesChanged' / 'incomingStarted' / 'incomingDone' ...
  final String? name;
  final String? from;
  final String? path;

  LandropEvent(this.kind, {this.name, this.from, this.path});

  static final devicesChanged = LandropEvent('devicesChanged');
}

/// 待发送文件（filename 可含 '/' = 文件夹相对路径，LANDrop 协议支持）
class LandropSendFile {
  final String path;
  final String filename;
  const LandropSendFile({required this.path, required this.filename});
}

/// 发送元信息（file_send_request 用）
class _SendFileMeta {
  final String path;
  final String filename;
  final int size;
  final int lastModified;
  final String permissions;
  const _SendFileMeta({
    required this.path,
    required this.filename,
    required this.size,
    required this.lastModified,
    required this.permissions,
  });
}

/// 发送结果
class LandropSendResult {
  final bool ok;
  /// 对端明确拒收（区别于连接失败等错误）
  final bool rejected;
  final String error;
  /// 6 位 verifCode（未信任设备时调用方应展示供双方核对）
  final String verifCode;
  /// 对端设备名（device_info 交换得来）
  final String peerName;

  const LandropSendResult({
    required this.ok,
    this.rejected = false,
    this.error = '',
    this.verifCode = '',
    this.peerName = '',
  });
}
