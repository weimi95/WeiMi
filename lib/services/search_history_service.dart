import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../framework/setting_store.dart';

/// 浮窗搜索历史（本地 prefs，最最近在前、去重）。
///
/// 保留条数由设置项 `qs_history_limit` 控制（默认 10，0 = 不记录）。
class SearchHistoryService {
  SearchHistoryService._();
  static const String _key = 'qs_search_history';

  static Future<List<String>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return [];
      final list = (jsonDecode(raw) as List).cast<String>();
      return list;
    } catch (_) {
      return [];
    }
  }

  /// 记录一次搜索词（去重置顶，超限裁剪）。limit<=0 不记录。
  static Future<void> record(String query) async {
    final q = query.trim();
    final limit = SettingStore.get<int>('qs_history_limit', 10);
    if (q.isEmpty || limit <= 0) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = await load();
      list.removeWhere((e) => e == q);
      list.insert(0, q);
      while (list.length > limit) {
        list.removeLast();
      }
      await prefs.setString(_key, jsonEncode(list));
    } catch (_) {}
  }

  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {}
  }
}
