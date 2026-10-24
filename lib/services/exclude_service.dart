import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// 全盘搜索排除列表（对齐 Everything「排除文件夹」）
///
/// - 模式为通配符（`*` 任意字符、`?` 单字符），不区分大小写，匹配**完整路径**
/// - 例：`*\temp\*`（Windows）、`*/android/data/*`（安卓）、`*.tmp`（按扩展名）
/// - 构建索引时生效（目录不入队、文件不入索引）；修改后需重建索引才完整生效
/// - 搜索结果侧也做一次兜底过滤（覆盖从旧落盘索引加载的场景）
class ExcludeService {
  static const String prefsKey = 'index_exclude_patterns';
  static List<String>? _cache;

  /// 平台默认排除列表（保守：只排缓存/临时/系统私有目录，避免误排用户文件）
  static List<String> defaults() {
    if (Platform.isAndroid) {
      return const [
        '*/android/data/*',
        '*/android/obb/*',
        '*/.thumbnails/*',
        '*/.cache/*',
        '*/cache/*',
        '*/temp/*',
        '*/tmp/*',
        '*.tmp',
      ];
    }
    return const [
      r'*\temp\*',
      r'*\tmp\*',
      r'*\$recycle.bin\*',
      r'*\system volume information\*',
      r'*\windowsapps\*',
      r'*\node_modules\*',
      r'*\__pycache__\*',
      r'*\.cache\*',
      '*.tmp',
    ];
  }

  /// 读取当前排除列表。
  /// - 首次运行（从未保存过）：把平台默认列表**落盘为可编辑条目**，让默认项也能被
  ///   用户逐条删除或整体清空——默认可以，但不能固化住不让删（v1.2.22 修复）
  /// - 已保存过（含显式空列表）：原样返回；空列表 = 不排除任何文件夹
  static Future<List<String>> load() async {
    if (_cache != null) return List<String>.of(_cache!);
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(prefsKey);
      if (list == null) {
        // 首次：把默认落盘，之后就和用户手加的条目一样可删
        _cache = List<String>.of(defaults());
        await prefs.setStringList(prefsKey, _cache!);
      } else {
        _cache = List<String>.of(list);
      }
    } catch (_) {
      _cache = defaults();
    }
    return List<String>.of(_cache!);
  }

  /// 保存排除列表（空列表 = 清除，恢复用默认）
  static Future<void> save(List<String> patterns) async {
    _cache = List<String>.of(patterns);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(prefsKey, _cache!);
    } catch (_) {}
  }

  /// 通配符匹配（与 Rust 侧 wildcard_match 同算法，兜底过滤用）
  static bool match(String pattern, String path) {
    final pat = pattern.trim().toLowerCase().codeUnits;
    final text = path.toLowerCase().codeUnits;
    var pi = 0, ti = 0, star = -1, mark = 0;
    while (ti < text.length) {
      if (pi < pat.length && (pat[pi] == 0x3F /*?*/ || pat[pi] == text[ti])) {
        pi++;
        ti++;
      } else if (pi < pat.length && pat[pi] == 0x2A /***/) {
        star = pi;
        mark = ti;
        pi++;
      } else if (star != -1) {
        pi = star + 1;
        mark++;
        ti = mark;
      } else {
        return false;
      }
    }
    while (pi < pat.length && pat[pi] == 0x2A) {
      pi++;
    }
    return pi == pat.length;
  }

  /// 路径是否被任一模式排除
  static bool isExcluded(String path, List<String> patterns) =>
      patterns.any((pat) => match(pat, path));
}
