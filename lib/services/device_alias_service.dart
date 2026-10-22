import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 设备别名（重命名）：按设备 ID 持久化，覆盖设备广播出的名字。
/// 设备列表/聊天窗标题/发送选择框统一读这里（v1.2.13：设备列表
/// 长按（手机）/右击（电脑）菜单的「重命名」落点）。
class DeviceAliasService {
  DeviceAliasService._();
  static final DeviceAliasService instance = DeviceAliasService._();

  static const String _key = 'device_aliases';
  Map<String, String>? _cache;

  /// 读取全部别名（id -> alias）
  Future<Map<String, String>> load() async {
    if (_cache != null) return Map<String, String>.of(_cache!);
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) {
        _cache = <String, String>{};
      } else {
        final m = json.decode(raw) as Map<String, dynamic>;
        _cache = m.map((k, v) => MapEntry(k, v.toString()));
      }
    } catch (_) {
      _cache = <String, String>{};
    }
    return Map<String, String>.of(_cache!);
  }

  /// 某设备别名（无则返回 null）
  Future<String?> aliasOf(String deviceId) async {
    if (deviceId.isEmpty) return null;
    final m = await load();
    final a = m[deviceId];
    return (a == null || a.trim().isEmpty) ? null : a.trim();
  }

  /// 设置/覆盖别名（空串 = 清除别名，恢复广播名）
  Future<void> setAlias(String deviceId, String alias) async {
    if (deviceId.isEmpty) return;
    final m = await load();
    final a = alias.trim();
    if (a.isEmpty) {
      m.remove(deviceId);
    } else {
      m[deviceId] = a;
    }
    _cache = m;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, json.encode(m));
    } catch (_) {}
  }

  /// 清除别名（删除设备时连带清）
  Future<void> remove(String deviceId) async {
    await setAlias(deviceId, '');
  }
}
