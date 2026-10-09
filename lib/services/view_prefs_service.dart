import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 文件浏览视图模式
enum ViewMode { list, grid, waterfall }

/// 全局视图偏好：最近页 / 文件页共用，切换后立即生效并持久化
class ViewPrefsService extends ChangeNotifier {
  ViewPrefsService._();
  static final ViewPrefsService instance = ViewPrefsService._();

  static const _key = 'weimi_view_mode';

  ViewMode _mode = ViewMode.list;
  bool _loaded = false;

  ViewMode get mode => _mode;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getString(_key);
      if (v == 'grid') _mode = ViewMode.grid;
      if (v == 'waterfall') _mode = ViewMode.waterfall;
      _loaded = true;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setMode(ViewMode m) async {
    if (m == _mode) return;
    _mode = m;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, m.name);
    } catch (_) {}
  }

  /// 循环切换：列表 → 宫格 → 瀑布流 → 列表
  void cycle() {
    const order = ViewMode.values;
    final next = order[(order.indexOf(_mode) + 1) % order.length];
    setMode(next);
  }
}
