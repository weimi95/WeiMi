import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'lan_transfer_service.dart';
import 'trusted_devices_service.dart';
import 'ipc_token.dart';

/// 托盘进程内的本地 IPC 管理端口（仅绑定 127.0.0.1，本机可达）。
///
/// 主程序（自身不跑飞传）经此端口：
///   - 查在线设备 / 本机信息（GET /ipc/peers、/ipc/self）
///   - 轮询接收确认请求（GET /ipc/pending-confirms）→ 弹框后回传（POST /ipc/confirm）
///   - 代发文件/文本（POST /ipc/send）
///   - 信任管理（POST /ipc/trust）
///
/// 所有请求必须带 token（?token= 或 X-Ipc-Token 头），由托盘启动时写入共享文件，
/// 主程序读取后附带，防止本机其他程序随意调用飞传端口。
class TrayIpcServer {
  static const int _basePort = 52347;
  static const int _maxPort = 52367;
  static const int _confirmTimeoutSec = 30;

  HttpServer? _server;
  int _port = _basePort;
  final Map<String, _PendingConfirm> _pending = {};
  int _pendingSeq = 0;

  int get port => _port;
  bool get isRunning => _server != null;

  /// 启动管理端口，并把接收确认回调接到本 server（入队等主程序决策）。
  Future<void> start() async {
    HttpServer? s;
    SocketException? lastErr;
    for (int port = _basePort; port <= _maxPort; port++) {
      try {
        s = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
        _port = port;
        break;
      } on SocketException catch (e) {
        lastErr = e;
      }
    }
    if (s == null) {
      debugPrint('TrayIpcServer 启动失败: $lastErr');
      return;
    }
    _server = s;
    // 绑定成功后再写入「实际端口 + token」：端口被占用时避免主程序连到错误端口
    await IpcToken.ensure(_port);
    // 接收确认：非信任设备发来时入队，等主程序轮询确认（超时自动拒收）
    LanTransferService.instance.confirmHandler = _handleConfirm;
    _server!.listen(_onRequest, onError: (_) {});
    debugPrint('TrayIpcServer 已启动 :$_port');
  }

  Future<bool> _handleConfirm(IncomingRequest req) async {
    final id = 'c${++_pendingSeq}';
    final completer = Completer<bool>();
    _pending[id] = _PendingConfirm(id, req, completer, DateTime.now());
    Timer(const Duration(seconds: _confirmTimeoutSec), () {
      final pc = _pending.remove(id);
      if (pc != null && !pc.completer.isCompleted) pc.completer.complete(false);
    });
    return completer.future;
  }

  Future<void> _onRequest(HttpRequest req) async {
    final token = await IpcToken.read();
    final reqToken = req.uri.queryParameters['token'] ??
        req.headers.value('x-ipc-token');
    if (token == null || reqToken != token) {
      _json(req, 403, {'error': 'unauthorized'});
      return;
    }
    try {
      final path = req.uri.path;
      if (req.method == 'GET' && path == '/ipc/peers') {
        final svc = LanTransferService.instance;
        _json(req, 200, {
          'peers': svc.peers.map(_peerToJson).toList(),
          'webPeers': svc.webPeers.map(_webPeerToJson).toList(),
        });
      } else if (req.method == 'GET' && path == '/ipc/self') {
        final svc = LanTransferService.instance;
        _json(req, 200, {
          'id': svc.identityId,
          'name': svc.selfName,
          'ip': await svc.localIPv4() ?? '',
          'httpPort': svc.httpPortActual,
          'webShare': svc.webShareEnabled,
        });
      } else if (req.method == 'GET' && path == '/ipc/pending-confirms') {
        _json(req, 200, {
          'items': _pending.values
              .map((pc) => {
                    'id': pc.id,
                    'senderId': pc.req.senderId,
                    'senderName': pc.req.senderName,
                    'fileName': pc.req.fileName,
                    'fileSize': pc.req.fileSize,
                  })
              .toList(),
        });
      } else if (req.method == 'POST' && path == '/ipc/confirm') {
        final body = await _readJson(req);
        final id = body['id']?.toString() ?? '';
        final accept = body['accept'] == true;
        final pc = _pending.remove(id);
        if (pc == null) {
          _json(req, 404, {'ok': false, 'error': 'not found'});
        } else {
          if (!pc.completer.isCompleted) pc.completer.complete(accept);
          _json(req, 200, {'ok': true});
        }
      } else if (req.method == 'POST' && path == '/ipc/send') {
        final body = await _readJson(req);
        final peerId = body['peerId']?.toString() ?? '';
        final peer = LanTransferService.instance.peers
            .where((e) => e.id == peerId)
            .firstOrNull;
        if (peer == null) {
          _json(req, 404, {'ok': false, 'error': 'peer not found'});
          return;
        }
        final bool ok;
        if (body['text'] != null) {
          ok = await LanTransferService.instance
              .sendText(peer: peer, text: body['text']);
        } else if (body['filePath'] != null) {
          ok = await LanTransferService.instance
              .sendFile(peer: peer, filePath: body['filePath']);
        } else {
          _json(req, 400, {'ok': false, 'error': 'missing text/filePath'});
          return;
        }
        _json(req, 200, {'ok': ok, 'error': LanTransferService.instance.lastSendError});
      } else if (req.method == 'POST' && path == '/ipc/trust') {
        final body = await _readJson(req);
        final peerId = body['peerId']?.toString() ?? '';
        final name = body['name']?.toString() ?? '';
        final add = body['add'] == true;
        if (peerId.isEmpty) {
          _json(req, 400, {'ok': false});
          return;
        }
        if (add) {
          await TrustedDevices.instance.add(peerId, name);
        } else {
          await TrustedDevices.instance.remove(peerId);
        }
        _json(req, 200, {'ok': true});
      } else if (req.method == 'POST' && path == '/ipc/send-web') {
        final body = await _readJson(req);
        final webPeerId = body['webPeerId']?.toString() ?? '';
        final w = LanTransferService.instance.webPeers
            .where((e) => e.id == webPeerId)
            .firstOrNull;
        if (w == null) {
          _json(req, 404, {'ok': false, 'error': 'web peer not found'});
          return;
        }
        final bool ok;
        if (body['text'] != null) {
          ok = await LanTransferService.instance.sendWebText(w, body['text']);
        } else if (body['filePath'] != null) {
          ok = await LanTransferService.instance.sendWebFile(w, body['filePath']);
        } else {
          _json(req, 400, {'ok': false, 'error': 'missing text/filePath'});
          return;
        }
        _json(req, 200,
            {'ok': ok, 'error': LanTransferService.instance.lastSendError});
      } else if (req.method == 'POST' && path == '/ipc/set') {
        final body = await _readJson(req);
        if (body['name'] != null) {
          await LanTransferService.instance.setSelfName(body['name']);
        }
        if (body['webShare'] != null) {
          await LanTransferService.instance
              .setWebShareEnabled(body['webShare'] == true);
        }
        _json(req, 200, {'ok': true});
      } else {
        _json(req, 404, {'error': 'not found'});
      }
    } catch (e) {
      _json(req, 500, {'error': '$e'});
    }
  }

  Map<String, dynamic> _peerToJson(LanPeer p) => {
        'id': p.id,
        'name': p.name,
        'ip': p.ip,
        'httpPort': p.httpPort,
        'trusted': p.trusted,
      };

  Map<String, dynamic> _webPeerToJson(WebPeer w) => {
        'id': w.id,
        'name': w.name,
        'ip': w.ip,
      };

  Future<Map<String, dynamic>> _readJson(HttpRequest req) async {
    try {
      final s = await utf8.decodeStream(req);
      if (s.isEmpty) return <String, dynamic>{};
      return json.decode(s) as Map<String, dynamic>;
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  void _json(HttpRequest req, int code, Map<String, dynamic> body) {
    try {
      req.response
        ..statusCode = code
        ..headers.contentType = ContentType.json
        ..write(json.encode(body))
        ..close();
    } catch (_) {}
  }

  Future<void> stop() async {
    LanTransferService.instance.confirmHandler = null;
    await _server?.close(force: true);
    _server = null;
  }
}

class _PendingConfirm {
  final String id;
  final IncomingRequest req;
  final Completer<bool> completer;
  final DateTime created;
  _PendingConfirm(this.id, this.req, this.completer, this.created);
}
