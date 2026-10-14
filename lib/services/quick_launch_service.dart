import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'windows_system_icon.dart';

/// 浮窗快捷方式区（仿 Lertaro）：常用软件 / 常用网址。
///
/// 数据存 prefs JSON：[{name, target, icon}]，target 为本地路径或 http(s) 网址；
/// icon 为图标缓存文件的绝对路径，可为空（UI 用兜底图标）。
/// 图标来源：
/// - 本地路径：WindowsSystemIcon（SHGetFileInfo → PNG，服务内自带磁盘缓存）；
/// - 网址：拉取站点 /favicon.ico 落盘缓存（<图标缓存目录>/<host>.img）。
class QuickLaunchService {
  QuickLaunchService._();
  static const _key = 'qs_quick_launch';

  /// 单条上限，防误存超长文本。
  static const int maxItems = 24;

  static bool isUrl(String target) {
    final t = target.trim().toLowerCase();
    return t.startsWith('http://') || t.startsWith('https://');
  }

  /// 目标规整：无协议但像网址（含点、无反斜杠、非盘符）补 https://，
  /// 否则按本地路径原样返回。
  static String normalizeTarget(String target) {
    final s = target.trim();
    if (s.isEmpty) return s;
    if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(s)) return s;
    final looksUrl = !s.contains('\\') &&
        !RegExp(r'^[a-zA-Z]:').hasMatch(s) &&
        s.contains('.') &&
        !s.contains(' ');
    return looksUrl ? 'https://$s' : s;
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
              icon: ((e['icon'] ?? '') as String).isEmpty
                  ? null
                  : e['icon'] as String,
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
        {
          'name': it.name,
          'target': it.target,
          if (it.icon != null) 'icon': it.icon,
        },
    ]);
    await prefs.setString(_key, raw);
  }

  static Future<void> add(QuickLaunchItem item) async {
    // load() 空列表返回 const []（不可变），必须拷贝成可变列表再改
    final items = [...await load()];
    if (items.any((e) => e.target == item.target)) return; // 去重
    items.add(item);
    await save(items);
  }

  static Future<void> update(int index, QuickLaunchItem item) async {
    final items = [...await load()];
    if (index < 0 || index >= items.length) return;
    items[index] = item;
    await save(items);
  }

  static Future<void> remove(int index) async {
    final items = [...await load()];
    if (index < 0 || index >= items.length) return;
    items.removeAt(index);
    await save(items);
  }

  /// 解析条目图标：返回缓存文件绝对路径；拿不到返回 null（UI 用兜底图标）。
  /// [cacheDir] 由调用方注入（<app support>/quick_launch_icons）。
  static Future<String?> resolveIcon(
      QuickLaunchItem item, String cacheDir) async {
    try {
      final dir = Directory(cacheDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      if (item.url) {
        final host = Uri.tryParse(item.target)?.host ?? '';
        if (host.isEmpty) return null;
        final safe = host.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
        final f = File('${dir.path}${Platform.pathSeparator}$safe.img');
        if (f.existsSync() && f.lengthSync() > 16) return f.path;
        return await _fetchFavicon(item.target, f);
      }
      if (!Platform.isWindows) return null;
      if (!File(item.target).existsSync()) return null;
      return WindowsSystemIcon.getIconFile(item.target);
    } catch (_) {
      return null;
    }
  }

  /// 拉站点 favicon.ico 落盘（超时 5s、上限 256KB、非图片拒收）。
  static Future<String?> _fetchFavicon(String url, File dest) async {
    HttpClient? client;
    try {
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
      final fav = Uri.parse('${uri.scheme}://${uri.host}/favicon.ico');
      client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      final req = await client.getUrl(fav);
      final resp = await req.close().timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return null;
      final builder = BytesBuilder(copy: false);
      var total = 0;
      await for (final chunk in resp) {
        total += chunk.length;
        if (total > 256 * 1024) return null;
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      if (bytes.length < 16) return null;
      // 图片魔数：ico(00 00)/png(89 50)/gif(GIF8)/jpeg(FF D8)；'<'>=html 错误页拒收
      final isImg = (bytes[0] == 0x00 && bytes[1] == 0x00) ||
          (bytes[0] == 0x89 && bytes[1] == 0x50) ||
          (bytes[0] == 0x47 && bytes[1] == 0x49) ||
          (bytes[0] == 0xFF && bytes[1] == 0xD8);
      if (!isImg) return null;
      await dest.writeAsBytes(bytes, flush: true);
      return dest.path;
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }
}

class QuickLaunchItem {
  QuickLaunchItem({required this.name, required this.target, this.icon});
  final String name;
  final String target;

  /// 图标缓存文件绝对路径，null = 未解析 / 用兜底图标。
  final String? icon;

  bool get url => QuickLaunchService.isUrl(target);

  QuickLaunchItem copyWith({String? name, String? target, String? icon}) =>
      QuickLaunchItem(
        name: name ?? this.name,
        target: target ?? this.target,
        icon: icon ?? this.icon,
      );
}
