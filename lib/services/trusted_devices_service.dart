import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 微密飞传：信任设备列表（按设备 ID）。
/// 信任过的设备来文件/文本时免确认直接接收。
class TrustedDevices {
  TrustedDevices._();
  static final TrustedDevices instance = TrustedDevices._();

  static const String _kKey = 'lan_trusted_devices';

  /// id -> 名称（内存缓存，启动时 load）
  final Map<String, String> _trusted = {};
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final map = json.decode(raw) as Map<String, dynamic>;
        _trusted
          ..clear()
          ..addAll(map.map((k, v) => MapEntry(k, v.toString())));
      } catch (e) {
        debugPrint('TrustedDevices load failed: $e');
      }
    }
    _loaded = true;
  }

  bool isTrustedSync(String deviceId) =>
      deviceId.isNotEmpty && _trusted.containsKey(deviceId);

  List<MapEntry<String, String>> get all =>
      _trusted.entries.toList();

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
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kKey, json.encode(_trusted));
  }
}
