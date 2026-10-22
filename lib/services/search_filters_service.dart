import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/search_syntax.dart';

/// 自定义筛选器（M3 plan §四.3）：把「查询词 + 四个全局开关」存为命名筛选器，
/// JSON 落盘（SharedPreferences），支持导入/导出（对齐 Everything Filters.csv 思路）。
///
/// 筛选器与 [SearchOpts] 解耦：服务只认四布尔字段，应用时现构 SearchOpts，
/// 避免 widgets → services 反向依赖固化。
class SavedFilter {
  final String id;
  final String name;
  final String query;

  /// 四个全局开关（与 SearchOpts 字段一一对应）。
  final bool caseSensitive;
  final bool wholeWord;
  final bool matchPath;
  final bool regex;

  const SavedFilter({
    required this.id,
    required this.name,
    required this.query,
    this.caseSensitive = false,
    this.wholeWord = false,
    this.matchPath = false,
    this.regex = false,
  });

  SavedFilter copyWith({
    String? name,
    String? query,
    bool? caseSensitive,
    bool? wholeWord,
    bool? matchPath,
    bool? regex,
  }) =>
      SavedFilter(
        id: id,
        name: name ?? this.name,
        query: query ?? this.query,
        caseSensitive: caseSensitive ?? this.caseSensitive,
        wholeWord: wholeWord ?? this.wholeWord,
        matchPath: matchPath ?? this.matchPath,
        regex: regex ?? this.regex,
      );

  int get optCount =>
      [caseSensitive, wholeWord, matchPath, regex].where((b) => b).length;

  /// 应用时构造的全局开关（调用方负责 SearchOpts.save + 重搜）。
  SearchOpts toOpts() => SearchOpts(
        caseSensitive: caseSensitive,
        wholeWord: wholeWord,
        matchPath: matchPath,
        regex: regex,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'query': query,
        'case': caseSensitive,
        'word': wholeWord,
        'path': matchPath,
        'regex': regex,
      };

  static SavedFilter? fromJson(Map<String, dynamic> j) {
    final name = (j['name'] as String?)?.trim() ?? '';
    final query = (j['query'] as String?)?.trim() ?? '';
    if (name.isEmpty || query.isEmpty) return null;
    return SavedFilter(
      id: (j['id'] as String?)?.trim() ??
          DateTime.now().microsecondsSinceEpoch.toRadixString(36),
      name: name,
      query: query,
      caseSensitive: j['case'] == true,
      wholeWord: j['word'] == true,
      matchPath: j['path'] == true,
      regex: j['regex'] == true,
    );
  }
}

/// 自定义筛选器存储（单例）。上限 50 条，防无限堆积。
class SearchFiltersService {
  SearchFiltersService._();
  static final SearchFiltersService instance = SearchFiltersService._();

  static const String _key = 'qs_saved_filters';
  static const int maxCount = 50;

  List<SavedFilter> _cache = [];

  Future<List<SavedFilter>> load() async {
    if (_cache.isNotEmpty) return List.unmodifiable(_cache);
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return List.unmodifiable(_cache);
      final list = (jsonDecode(raw) as List)
          .whereType<Map<String, dynamic>>()
          .map(SavedFilter.fromJson)
          .whereType<SavedFilter>()
          .toList();
      _cache = list;
    } catch (_) {}
    return List.unmodifiable(_cache);
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode(_cache.map((f) => f.toJson()).toList()));
  }

  /// 新建。同名会自动追加序号；超上限返回 false。
  Future<SavedFilter?> add(String name, String query, SearchOpts opts) async {
    final n = name.trim();
    final q = query.trim();
    if (n.isEmpty || q.isEmpty) return null;
    await load();
    if (_cache.length >= maxCount) return null;
    final f = SavedFilter(
      id: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
      name: await _uniqueName(n),
      query: q,
      caseSensitive: opts.caseSensitive,
      wholeWord: opts.wholeWord,
      matchPath: opts.matchPath,
      regex: opts.regex,
    );
    _cache.insert(0, f);
    await _persist();
    return f;
  }

  Future<void> update(SavedFilter f) async {
    await load();
    final i = _cache.indexWhere((e) => e.id == f.id);
    if (i < 0) return;
    _cache[i] = f;
    await _persist();
  }

  Future<void> remove(String id) async {
    await load();
    _cache.removeWhere((e) => e.id == id);
    await _persist();
  }

  Future<void> clear() async {
    _cache = [];
    await _persist();
  }

  Future<String> _uniqueName(String base) async {
    var name = base;
    var i = 2;
    while (_cache.any((f) => f.name == name)) {
      name = '$base ($i)';
      i++;
    }
    return name;
  }

  /// 导出为 JSON 文本（含格式版本号）。
  static String exportJson(List<SavedFilter> filters) => jsonEncode({
        'app': 'weimi-file',
        'kind': 'search-filters',
        'version': 1,
        'filters': filters.map((f) => f.toJson()).toList(),
      });

  /// 从 JSON 文本导入。返回 (新增条数, 更新条数, 失败原因或 null)。
  /// 同 id 覆盖更新；超上限部分忽略。
  static Future<(int, int, String?)> importJson(String text) async {
    List<dynamic> raw;
    try {
      final d = jsonDecode(text);
      raw = d is Map ? (d['filters'] as List? ?? const []) : (d as List);
    } catch (e) {
      return (0, 0, '不是有效的 JSON：$e');
    }
    final svc = instance;
    await svc.load();
    int added = 0, updated = 0;
    for (final e in raw) {
      if (e is! Map) continue;
      final j = Map<String, dynamic>.from(e);
      final f = SavedFilter.fromJson(j);
      if (f == null) continue;
      final i = svc._cache.indexWhere((x) => x.id == f.id);
      if (i >= 0) {
        svc._cache[i] = f;
        updated++;
      } else {
        if (svc._cache.length >= maxCount) break;
        svc._cache.add(f);
        added++;
      }
    }
    await svc._persist();
    return (added, updated, null);
  }

  /// 弹出保存对话框导出（桌面端）。返回是否成功。
  static Future<bool> exportToFile(List<SavedFilter> filters) async {
    if (filters.isEmpty) return false;
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '导出筛选器',
        fileName: 'weimi-search-filters.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (path == null) return false;
      await File(path).writeAsString(exportJson(filters));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 弹出选择对话框导入。返回 (新增, 更新, 失败原因或 null)。
  static Future<(int, int, String?)> importFromFile() async {
    try {
      final r = await FilePicker.platform.pickFiles(
        dialogTitle: '导入筛选器',
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: false,
      );
      if (r == null || r.files.isEmpty) return (0, 0, null);
      final p = r.files.single.path;
      if (p == null) return (0, 0, '无法读取所选文件');
      return await importJson(await File(p).readAsString());
    } catch (e) {
      return (0, 0, '导入失败：$e');
    }
  }
}
