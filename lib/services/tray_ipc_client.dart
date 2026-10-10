import 'dart:convert';
import 'dart:io';

import 'ipc_token.dart';

/// 主程序侧 IPC 客户端：连接托盘进程的本地管理端口（127.0.0.1）。
///
/// 主程序自身不跑飞传，所有设备查询 / 发送 / 接收确认 / 信任管理都经此转发给托盘进程。
class LanPeerInfo {
  final String id;
  final String name;
  final String ip;
  final int httpPort;
  final bool trusted;
  LanPeerInfo.fromJson(Map<String, dynamic> j)
      : id = j['id']?.toString() ?? '',
        name = j['name']?.toString() ?? '',
        ip = j['ip']?.toString() ?? '',
        httpPort = j['httpPort'] is int ? j['httpPort'] : 0,
        trusted = j['trusted'] == true;
}

class WebPeerInfo {
  final String id;
  final String name;
  final String ip;
  WebPeerInfo.fromJson(Map<String, dynamic> j)
      : id = j['id']?.toString() ?? '',
        name = j['name']?.toString() ?? '',
        ip = j['ip']?.toString() ?? '';
}

class SelfInfo {
  final String id;
  final String name;
  final String ip;
  final int httpPort;
  final bool webShare;
  SelfInfo.fromJson(Map<String, dynamic> j)
      : id = j['id']?.toString() ?? '',
        name = j['name']?.toString() ?? '',
        ip = j['ip']?.toString() ?? '',
        httpPort = j['httpPort'] is int ? j['httpPort'] : 0,
        webShare = j['webShare'] == true;
}

class PendingConfirmInfo {
  final String id;
  final String senderId;
  final String senderName;
  final String fileName;
  final int fileSize;
  PendingConfirmInfo.fromJson(Map<String, dynamic> j)
      : id = j['id']?.toString() ?? '',
        senderId = j['senderId']?.toString() ?? '',
        senderName = j['senderName']?.toString() ?? '',
        fileName = j['fileName']?.toString() ?? '',
        fileSize = j['fileSize'] is int ? j['fileSize'] : 0;
}

class TrayIpcClient {
  static final TrayIpcClient instance = TrayIpcClient._();
  TrayIpcClient._();

  (int, String)? _endpoint; // (port, token)
  List<WebPeerInfo> _lastWebPeers = [];

  List<WebPeerInfo> get webPeers => _lastWebPeers;
  String lastSendError = '';

  /// 连接托盘（读取共享的端口+token）。托盘未启动返回 false。
  Future<bool> _ready() async {
    if (_endpoint != null) return true;
    final e = await IpcToken.read();
    if (e == null) return false;
    _endpoint = e;
    return true;
  }

  Future<Map<String, dynamic>?> _get(String api) async {
    if (!await _ready()) return null;
    final (port, token) = _endpoint!;
    final c = HttpClient();
    try {
      final req = await c.get('127.0.0.1', port, '/ipc/$api?token=$token');
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) return null;
      return json.decode(body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    } finally {
      c.close(force: true);
    }
  }

  Future<Map<String, dynamic>?> _post(String api, Map<String, dynamic> body) async {
    if (!await _ready()) return null;
    final (port, token) = _endpoint!;
    final c = HttpClient();
    try {
      final req = await c.post('127.0.0.1', port, '/ipc/$api?token=$token');
      req.headers.contentType = ContentType.json;
      req.write(json.encode(body));
      final resp = await req.close();
      final out = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) return null;
      return json.decode(out) as Map<String, dynamic>;
    } catch (_) {
      return null;
    } finally {
      c.close(force: true);
    }
  }

  Future<List<LanPeerInfo>> getPeers() async {
    final d = await _get('peers');
    if (d == null) return [];
    final peers = (d['peers'] as List?) ?? [];
    final web = (d['webPeers'] as List?) ?? [];
    _lastWebPeers = web.map((e) => WebPeerInfo.fromJson(e)).toList();
    return peers.map((e) => LanPeerInfo.fromJson(e)).toList();
  }

  Future<SelfInfo?> getSelf() async {
    final d = await _get('self');
    if (d == null) return null;
    return SelfInfo.fromJson(d);
  }

  Future<List<PendingConfirmInfo>> pollPendingConfirms() async {
    final d = await _get('pending-confirms');
    if (d == null) return [];
    return (d['items'] as List? ?? [])
        .map((e) => PendingConfirmInfo.fromJson(e))
        .toList();
  }

  Future<bool> confirm(String id, bool accept) async {
    final d = await _post('confirm', {'id': id, 'accept': accept});
    return d?['ok'] == true;
  }

  Future<bool> sendFile(String peerId, String filePath) async {
    final d = await _post('send', {'peerId': peerId, 'filePath': filePath});
    lastSendError = d?['error']?.toString() ?? '';
    return d?['ok'] == true;
  }

  Future<bool> sendText(String peerId, String text) async {
    final d = await _post('send', {'peerId': peerId, 'text': text});
    lastSendError = d?['error']?.toString() ?? '';
    return d?['ok'] == true;
  }

  Future<bool> sendWebFile(String webPeerId, String filePath) async {
    final d = await _post('send-web', {'webPeerId': webPeerId, 'filePath': filePath});
    lastSendError = d?['error']?.toString() ?? '';
    return d?['ok'] == true;
  }

  Future<bool> sendWebText(String webPeerId, String text) async {
    final d = await _post('send-web', {'webPeerId': webPeerId, 'text': text});
    lastSendError = d?['error']?.toString() ?? '';
    return d?['ok'] == true;
  }

  Future<bool> setSelfName(String name) async {
    final d = await _post('set', {'name': name});
    return d?['ok'] == true;
  }

  Future<bool> setWebShare(bool on) async {
    final d = await _post('set', {'webShare': on});
    return d?['ok'] == true;
  }

  Future<bool> trust(String peerId, String name, bool add) async {
    final d = await _post('trust', {'peerId': peerId, 'name': name, 'add': add});
    return d?['ok'] == true;
  }
}
