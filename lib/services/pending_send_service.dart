import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'landrop_service.dart';
import 'lan_transfer_service.dart';

/// 离线预发送队列（Flix 1.5.1/1.7.0 风格）：
/// 设备离线时把文件/文本排进它的会话，设备上线后自动发出。
///
/// - JSON 持久化（应用文档目录 pending_sends.json），内存缓存
/// - 入队：聊天窗口对离线设备点发送时
/// - 出队（自动）：飞传页轮询发现设备上线 / 打开聊天窗口时，flushFor 尝试发送
/// - 发送成功即移除并计入传输记录（发送 API 自带记账）；失败保留，下次上线再试
class PendingSendService {
  PendingSendService._();
  static final PendingSendService instance = PendingSendService._();

  final List<PendingSend> _items = [];
  bool _loaded = false;
  String? _filePath;
  final Set<String> _flushing = {}; // 正在 flush 的 peerKey（防并发重发）

  Future<String> _resolveFilePath() async {
    if (_filePath != null) return _filePath!;
    final docs = await getApplicationDocumentsDirectory();
    _filePath = p.join(docs.path, 'pending_sends.json');
    return _filePath!;
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = File(await _resolveFilePath());
      if (await f.exists()) {
        final list = json.decode(await f.readAsString()) as List<dynamic>;
        _items
          ..clear()
          ..addAll(list.map((e) => PendingSend.fromJson(e)));
      }
    } catch (_) {
      _items.clear();
    }
  }

  Future<void> _persist() async {
    try {
      final f = File(await _resolveFilePath());
      await f.writeAsString(json.encode(_items.map((e) => e.toJson()).toList()));
    } catch (_) {}
  }

  /// 队列总条数（内存判断，未加载时 0——飞传页轮询每 1.5s 调 flushFor，
  /// 依赖这个 getter 做零 IO 快速短路）。
  int get count => _loaded ? _items.length : 0;

  /// 某会话的待发送项（最新在前）。
  Future<List<PendingSend>> listFor(String peerKey) async {
    await _ensureLoaded();
    return _items.where((e) => e.peerKey == peerKey).toList();
  }

  /// 入队一条。返回 false 表示参数无效。
  Future<bool> enqueue(PendingSend item) async {
    if ((item.kind == 'file' && item.paths.isEmpty) ||
        (item.kind == 'text' && (item.text == null || item.text!.isEmpty))) {
      return false;
    }
    await _ensureLoaded();
    _items.insert(0, item);
    await _persist();
    return true;
  }

  /// 移除一条（用户取消）。
  Future<void> remove(String id) async {
    await _ensureLoaded();
    _items.removeWhere((e) => e.id == id);
    await _persist();
  }

  /// 清空某会话的队列。
  Future<void> clearFor(String peerKey) async {
    await _ensureLoaded();
    _items.removeWhere((e) => e.peerKey == peerKey);
    await _persist();
  }

  /// 尝试把某在线设备的队列全部发出。返回成功发出的条数。
  ///
  /// - 设备离线/队列为空直接返回 0（无 IO，可高频调用）
  /// - 同一设备并发 flush 由 _flushing 防重入
  /// - 单条失败保留在队列，下轮上线再试
  Future<int> flushFor(LanPeer peer) async {
    if (!_loaded || _items.isEmpty) return 0;
    final key = peer.id;
    if (_flushing.contains(key)) return 0;
    final mine = _items.where((e) => e.peerKey == key).toList();
    if (mine.isEmpty) return 0;
    _flushing.add(key);
    var okCount = 0;
    try {
      // 最新在前入队，发送按时间正序（最旧的先发）
      for (final item in mine.reversed) {
        var ok = false;
        try {
          if (item.kind == 'text') {
            ok = await _sendTextTo(peer, item.text!);
          } else {
            ok = await _sendFilesTo(peer, item.paths);
          }
        } catch (_) {
          ok = false;
        }
        if (ok) {
          _items.removeWhere((e) => e.id == item.id);
          okCount++;
          await _persist();
        }
      }
    } finally {
      _flushing.remove(key);
    }
    return okCount;
  }

  Future<bool> _sendTextTo(LanPeer peer, String text) async {
    if (peer.isLandrop) {
      final r = await LandropService.instance.sendTextToDevice(
        LandropDevice(
          publicKey: peer.ldPkB64 ?? peer.id,
          name: peer.name,
          type: '',
          address: peer.ip,
          port: peer.ldPort ?? peer.httpPort,
          lastSeen: peer.lastSeen,
        ),
        text,
      );
      return r.ok;
    }
    return LanTransferService.instance.sendText(peer: peer, text: text);
  }

  Future<bool> _sendFilesTo(LanPeer peer, List<String> paths) async {
    if (peer.isLandrop) {
      final r = await LandropService.instance.sendFilesToDevice(
        LandropDevice(
          publicKey: peer.ldPkB64 ?? peer.id,
          name: peer.name,
          type: '',
          address: peer.ip,
          port: peer.ldPort ?? peer.httpPort,
          lastSeen: peer.lastSeen,
        ),
        paths
            .map((fp) =>
                LandropSendFile(path: fp, filename: p.basename(fp)))
            .toList(),
      );
      return r.ok;
    }
    for (final path in paths) {
      final ok = await LanTransferService.instance.sendFile(
        peer: peer,
        filePath: path,
      );
      if (!ok) return false;
    }
    return true;
  }
}

/// 一条待发送项。kind: file | text。
class PendingSend {
  final String id;
  final String peerKey; // = TransferRecord.peerKey（会话 key）
  final String peerName; // 入队时设备名（展示用）
  final String kind;
  final List<String> paths; // kind=file
  final String? text; // kind=text
  final DateTime createdAt;

  PendingSend({
    required this.id,
    required this.peerKey,
    required this.peerName,
    required this.kind,
    this.paths = const [],
    this.text,
    required this.createdAt,
  });

  factory PendingSend.fromJson(Map<String, dynamic> j) => PendingSend(
        id: j['id'] as String,
        peerKey: (j['peerKey'] as String?) ?? '',
        peerName: (j['peerName'] as String?) ?? '',
        kind: (j['kind'] as String?) ?? 'file',
        paths:
            (j['paths'] as List<dynamic>?)?.map((e) => e as String).toList() ??
                const [],
        text: j['text'] as String?,
        createdAt: DateTime.tryParse((j['createdAt'] as String?) ?? '') ??
            DateTime.now(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'peerKey': peerKey,
        'peerName': peerName,
        'kind': kind,
        'paths': paths,
        if (text != null) 'text': text,
        'createdAt': createdAt.toIso8601String(),
      };
}

/// 生成记录 id（与 TransferRecord 同风格：时间戳+随机后缀，够唯一即可）。
String newPendingId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
    '${DateTime.now().millisecondsSinceEpoch.remainder(9973)}';
