import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 微密飞传：信任设备列表（按设备 ID）。
/// 信任过的设备来文件/文本时免确认直接接收。
///
/// 文件存储（trusted_devices.json，应用文档目录）：跨进程共享——
/// 托盘进程读写，主程序经 IPC 读取 peer.trusted 标记，不直连本类。
class TrustedDevices {
  TrustedDevices._();
  static final TrustedDevices instance = TrustedDevices._();

  /// id -> 名称（内存缓存，启动时 load）
  final Map<String, String> _trusted = {};
  bool _loaded = false;

  Future<String> _path() async {
    final docs = await getApplicationDocumentsDirectory();
    return p.join(docs.path, 'trusted_devices.json');
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    await _read();
  }

  /// 强制重读磁盘文件（托盘进程改了信任后，主程序内存副本需刷新）
  Future<void> reload() async {
    _loaded = false;
    _trusted.clear();
    await _read();
  }

  Future<void> _read() async {
    try {
      final f = File(await _path());
      if (await f.exists()) {
        final raw = await f.readAsString();
        if (raw.isNotEmpty) {
          final map = json.decode(raw) as Map<String, dynamic>;
          _trusted
            ..clear()
            ..addAll(map.map((k, v) => MapEntry(k, v.toString())));
        }
      }
    } catch (e) {
      debugPrint('TrustedDevices load failed: $e');
    }
  }

  bool isTrustedSync(String deviceId) =>
      deviceId.isNotEmpty && _trusted.containsKey(deviceId);

  List<MapEntry<String, String>> get all => _trusted.entries.toList();

  Future<void> add(String deviceId, String name) async {
    if (deviceId.isEmpty) return;
    _trusted[deviceId] = name.isEmpty ? '未知设备' : name;
    await _persist();
  }

  Future<void> remove(String deviceId) async {
    _trusted.remove(deviceId);
    await _persist();
  }

  Future<void> _persist() async {
    try {
      final f = File(await _path());
      await f.writeAsString(json.encode(_trusted));
    } catch (e) {
      debugPrint('TrustedDevices persist failed: $e');
    }
  }
}
