import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 浮窗快捷方式区（仿 Lertaro）：常用软件 / 常用网址。
///
/// 数据结构存 prefs JSON：[{name, target}]，target 为本地路径或 http(s) 网址，
/// 以 `http://` / `https://` 开头判定为网址。
/// 纯静态方法类（无单例），与 SearchHistoryService 同款风格。
class QuickLaunchService {
  QuickLaunchService._();
  static const _key = 'qs_quick_launch';

  /// 单条上限，防误存超长文本。
  static const int maxItems = 24;

  static bool isUrl(String target) {
    final t = target.trim().toLowerCase();
    return t.startsWith('http://') || t.startsWith('https://');
  }

  static Future<List<QuickLaunchItem>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return [
        for (final e in list)
          if (e is Map)
            QuickLaunchItem(
              name: (e['name'] ?? '').toString(),
              target: (e['target'] ?? '').toString(),
            ),
      ];
    } catch (_) {
      return const [];
    }
  }

  static Future<void> save(List<QuickLaunchItem> items) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode([
      for (final it in items.take(maxItems))
        {'name': it.name, 'target': it.target},
    ]);
    await prefs.setString(_key, raw);
  }

  static Future<void> add(QuickLaunchItem item) async {
    final items = await load();
    if (items.any((e) => e.target == item.target)) return; // 去重
    items.add(item);
    await save(items);
  }

  static Future<void> update(int index, QuickLaunchItem item) async {
    final items = await load();
    if (index < 0 || index >= items.length) return;
    items[index] = item;
    await save(items);
  }

  static Future<void> remove(int index) async {
    final items = await load();
    if (index < 0 || index >= items.length) return;
    items.removeAt(index);
    await save(items);
  }
}

class QuickLaunchItem {
  QuickLaunchItem({required this.name, required this.target});
  final String name;
  final String target;

  bool get url => QuickLaunchService.isUrl(target);
}
