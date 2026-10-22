import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 传输记录服务：飞传（App↔App / 网页快传）收发的文件与文本都记账。
///
/// - JSON 文件持久化（应用文档目录 transfer_history.json），内存缓存
/// - 上限 500 条，超出自动挤掉最旧的
/// - 记录埋点在 LanTransferService（sendFile/sendText 成败处 + 收到数据处），
///   后台收到也记账，不依赖页面开着
class TransferHistoryService {
  static const int maxRecords = 500;
  static const MethodChannel _clipChannel =
      MethodChannel('com.weimi95.weimi/clipboard_files');

  TransferHistoryService._();
  static final TransferHistoryService instance = TransferHistoryService._();

  final List<TransferRecord> _records = [];
  bool _loaded = false;
  String? _filePath;

  List<TransferRecord> get records =>
      List.unmodifiable(_records); // 最新在前由 add 时维护

  /// 确保已从磁盘载入并返回记录（最新在前）
  Future<List<TransferRecord>> load() async {
    await _ensureLoaded();
    return List.unmodifiable(_records);
  }

  Future<String> _resolveFilePath() async {
    if (_filePath != null) return _filePath!;
    final docs = await getApplicationDocumentsDirectory();
    _filePath = p.join(docs.path, 'transfer_history.json');
    return _filePath!;
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = File(await _resolveFilePath());
      if (await f.exists()) {
        final list = json.decode(await f.readAsString()) as List<dynamic>;
        _records
          ..clear()
          ..addAll(list.map((e) => TransferRecord.fromJson(e)));
      }
    } catch (_) {
      _records.clear();
    }
  }

  Future<void> _persist() async {
    try {
      final f = File(await _resolveFilePath());
      await f.writeAsString(json.encode(
          _records.take(maxRecords).map((r) => r.toJson()).toList()));
    } catch (_) {}
  }

  // ---- 未读标记（会话级，独立小文件） ----
  final Map<String, int> _readMarkers = {};
  bool _readLoaded = false;
  String? _readPath;

  Future<String> _resolveReadPath() async {
    if (_readPath != null) return _readPath!;
    final docs = await getApplicationDocumentsDirectory();
    _readPath = p.join(docs.path, 'transfer_read_markers.json');
    return _readPath!;
  }

  Future<void> _ensureReadLoaded() async {
    if (_readLoaded) return;
    _readLoaded = true;
    try {
      final f = File(await _resolveReadPath());
      if (await f.exists()) {
        final m = json.decode(await f.readAsString()) as Map<String, dynamic>;
        for (final e in m.entries) {
          _readMarkers[e.key] = (e.value as num).toInt();
        }
      }
    } catch (_) {}
  }

  /// 打开某会话时调用：记下已读时间（微秒）。
  Future<void> markRead(String peerKey) async {
    await _ensureReadLoaded();
    _readMarkers[peerKey] = DateTime.now().microsecondsSinceEpoch;
    try {
      final f = File(await _resolveReadPath());
      await f.writeAsString(json.encode(_readMarkers));
    } catch (_) {}
  }

  DateTime? lastRead(String peerKey) {
    final m = _readMarkers[peerKey];
    return m == null ? null : DateTime.fromMicrosecondsSinceEpoch(m);
  }

  /// 该会话有无未读（最后一条记录晚于已读时间即为未读）。
  bool isUnread(String peerKey, DateTime lastTime) {
    final lr = lastRead(peerKey);
    return lr == null || lastTime.isAfter(lr);
  }

  /// 新增一条记录（最新在前）。文本超长截断存储。
  Future<void> add(TransferRecord record) async {
    await _ensureLoaded();
    if (record.kind == 'text' && record.text != null &&
        record.text!.length > 2000) {
      _records.insert(0, record.copyWith(text: record.text!.substring(0, 2000)));
    } else {
      _records.insert(0, record);
    }
    if (_records.length > maxRecords) {
      _records.removeRange(maxRecords, _records.length);
    }
    await _persist();
  }

  /// 删除记录；deleteFiles=true 时连文件一起删（文本记录无文件，跳过）。
  /// 返回实际删除的文件数。
  Future<int> deleteRecords(List<String> ids, {bool deleteFiles = false}) async {
    await _ensureLoaded();
    int fileCount = 0;
    if (deleteFiles) {
      for (final r in _records.where((r) => ids.contains(r.id))) {
        if (r.kind == 'file' && r.path != null) {
          try {
            final f = File(r.path!);
            if (await f.exists()) {
              await f.delete();
              fileCount++;
            }
          } catch (_) {}
        }
      }
    }
    _records.removeWhere((r) => ids.contains(r.id));
    await _persist();
    return fileCount;
  }

  /// 把选中文件记录批量移动到目标目录，成功后更新记录里的 path。
  /// 返回成功移动数。
  Future<int> moveFiles(List<String> ids, String targetDir) async {
    await _ensureLoaded();
    int moved = 0;
    for (int i = 0; i < _records.length; i++) {
      final r = _records[i];
      if (!ids.contains(r.id) || r.kind != 'file' || r.path == null) continue;
      try {
        final src = File(r.path!);
        if (!await src.exists()) continue;
        final fileName = p.basename(r.path!);
        var target = p.join(targetDir, fileName);
        var n = 1;
        while (await File(target).exists()) {
          final ext = p.extension(fileName);
          target = p.join(targetDir,
              '${p.basenameWithoutExtension(fileName)} ($n)$ext');
          n++;
        }
        await src.rename(target);
        _records[i] = r.copyWith(path: target);
        moved++;
      } catch (_) {}
    }
    if (moved > 0) await _persist();
    return moved;
  }

  /// 真把文件复制进系统剪贴板（桌面端平台通道；Android 上返回 false）。
  Future<bool> copyFilesToClipboard(List<String> paths) async {
    if (paths.isEmpty) return false;
    try {
      if (Platform.isAndroid || Platform.isIOS) return false;
      final ok = await _clipChannel.invokeMethod('copyFiles', {'paths': paths});
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> clearAll() async {
    await _ensureLoaded();
    _records.clear();
    await _persist();
  }

  bool get isDesktop => !Platform.isAndroid && !Platform.isIOS;

  /// 在系统文件管理器中打开指定文件的父目录。
  /// - Windows: `explorer <dir>`
  /// - macOS: `open <dir>`
  /// - Linux: `xdg-open <dir>`
  Future<void> openParentDirectory(String filePath) async {
    if (filePath.isEmpty) return;
    final dir = p.dirname(filePath);
    if (!Directory(dir).existsSync()) return;
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', [dir]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [dir]);
      } else {
        await Process.run('xdg-open', [dir]);
      }
    } catch (_) {}
  }

  /// 在系统文件管理器中「选中」指定文件（列表可多选，只选中第一个存在的）。
  /// 返回实际选中的文件路径，null 表示无可用文件或调用失败。
  /// - Windows: `explorer /select,<path>`
  /// - macOS: `open -R <path>`
  /// - Linux: 无标准 select 命令，退回打开父目录
  Future<String?> revealInFileManager(List<String> filePaths) async {
    final existing =
        filePaths.where((p0) => p0.isNotEmpty && File(p0).existsSync()).toList();
    if (existing.isEmpty) return null;
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', ['/select,' + existing.first]);
      } else if (Platform.isMacOS) {
        await Process.run('open', ['-R', existing.first]);
      } else {
        await Process.run('xdg-open', [p.dirname(existing.first)]);
      }
      return existing.first;
    } catch (_) {
      return null;
    }
  }
}

/// 一条传输记录。kind: file | text；direction: in | out。
class TransferRecord {
  final String id;
  final String kind;
  final String direction;
  final String name; // 文件名 / 对端摘要标题
  final String? path; // 文件落盘路径（kind=file）
  final String? text; // 文本内容（kind=text，超长截断）
  final int size; // 字节；文本为字符数
  final String peerName;
  /// 稳定会话 key：微密自研=对方 identityId / 纯 LocalSend=`ls_指纹` /
  /// LANDrop=身份公钥 base64 / 网页快传固定 'web'。用于把历史记录归并到
  /// 具体设备会话（聊天窗口）。旧记录（无此字段）按 peerName 兜底归并。
  final String? peerKey;
  final DateTime time;
  final bool ok;
  final String? note; // 失败/拒收原因（如「未信任，已拒收」），ok=false 时显示

  TransferRecord({
    required this.id,
    required this.kind,
    required this.direction,
    required this.name,
    this.path,
    this.text,
    required this.size,
    required this.peerName,
    this.peerKey,
    required this.time,
    required this.ok,
    this.note,
  });

  factory TransferRecord.fromJson(Map<String, dynamic> j) => TransferRecord(
        id: j['id'] as String,
        kind: (j['kind'] as String?) ?? 'file',
        direction: (j['direction'] as String?) ?? 'in',
        name: (j['name'] as String?) ?? '',
        path: j['path'] as String?,
        text: j['text'] as String?,
        size: (j['size'] as num?)?.toInt() ?? 0,
        peerName: (j['peerName'] as String?) ?? '',
        peerKey: j['peerKey'] as String?,
        time:
            DateTime.tryParse((j['time'] as String?) ?? '') ?? DateTime.now(),
        ok: (j['ok'] as bool?) ?? true,
        note: j['note'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'direction': direction,
        'name': name,
        if (path != null) 'path': path,
        if (text != null) 'text': text,
        'size': size,
        'peerName': peerName,
        if (peerKey != null) 'peerKey': peerKey,
        'time': time.toIso8601String(),
        'ok': ok,
        if (note != null) 'note': note,
      };

  TransferRecord copyWith({String? path, String? text}) => TransferRecord(
        id: id,
        kind: kind,
        direction: direction,
        name: name,
        path: path ?? this.path,
        text: text ?? this.text,
        size: size,
        peerName: peerName,
        peerKey: peerKey,
        time: time,
        ok: ok,
        note: note,
      );
}

/// 按设备聚合的会话摘要（飞传页聊天式列表用）。
class Conversation {
  final String key; // 稳定会话 key（= TransferRecord.peerKey）
  final String name; // 最近一条记录的对端名
  final DateTime lastTime; // 最近一条记录时间
  final TransferRecord lastRecord; // 最近一条记录（用于预览摘要）
  final int count; // 该会话总条数

  Conversation({
    required this.key,
    required this.name,
    required this.lastTime,
    required this.lastRecord,
    required this.count,
  });

  /// 预览文字：图标前缀 + 文件名/文本内容（截断）。
  String get preview {
    final r = lastRecord;
    final prefix = r.direction == 'out' ? '我: ' : '';
    final body = r.kind == 'text'
        ? (r.text ?? r.name)
        : r.name;
    final stat = r.ok ? '' : '（失败）';
    final s = body.length > 28 ? '${body.substring(0, 28)}…' : body;
    return '$prefix$s$stat';
  }
}

extension TransferHistoryConversations on TransferHistoryService {
  /// 所有会话（按最后活动时间降序）。旧记录无 peerKey 时按 peerName 兜底聚合，
  /// 与在线设备 key 可能不完全一致——在线会话在 UI 层由 _peers 驱动，这里只覆盖离线。
  List<Conversation> conversations() {
    final Map<String, List<TransferRecord>> groups = {};
    for (final r in _records) {
      final key = r.peerKey ?? r.peerName;
      groups.putIfAbsent(key, () => []).add(r);
    }
    final out = <Conversation>[];
    for (final e in groups.entries) {
      final list = e.value;
      list.sort((a, b) => b.time.compareTo(a.time));
      out.add(Conversation(
        key: e.key,
        name: list.first.peerName,
        lastTime: list.first.time,
        lastRecord: list.first,
        count: list.length,
      ));
    }
    out.sort((a, b) => b.lastTime.compareTo(a.lastTime));
    return out;
  }

  /// 某会话的全部记录（最新在前）。
  List<TransferRecord> recordsFor(String peerKey) =>
      _records.where((r) => (r.peerKey ?? r.peerName) == peerKey).toList();
}
