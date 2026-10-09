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
  final DateTime time;
  final bool ok;

  TransferRecord({
    required this.id,
    required this.kind,
    required this.direction,
    required this.name,
    this.path,
    this.text,
    required this.size,
    required this.peerName,
    required this.time,
    required this.ok,
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
        time:
            DateTime.tryParse((j['time'] as String?) ?? '') ?? DateTime.now(),
        ok: (j['ok'] as bool?) ?? true,
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
        'time': time.toIso8601String(),
        'ok': ok,
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
        time: time,
        ok: ok,
      );
}
