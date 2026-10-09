import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../services/file_batch_ops.dart';
import '../services/view_prefs_service.dart';
import '../widgets/file_selection_bar.dart';
import '../widgets/file_thumbnail.dart';

/// 最近文件信息
class RecentFileInfo {
  final String path;
  final String name;
  final DateTime modified;
  final int size;

  RecentFileInfo({
    required this.path,
    required this.name,
    required this.modified,
    required this.size,
  });

  Map<String, dynamic> toJson() => {
        'path': path,
        'name': name,
        'mtime': modified.millisecondsSinceEpoch,
        'size': size,
      };

  factory RecentFileInfo.fromJson(Map<String, dynamic> j) => RecentFileInfo(
        path: j['path'] as String,
        name: j['name'] as String,
        modified: DateTime.fromMillisecondsSinceEpoch(j['mtime'] as int),
        size: j['size'] as int,
      );
}

/// 最近页扫描结果缓存：本地 JSON，启动秒开，后台增量重扫后覆盖
class RecentScanCache {
  static const int kVersion = 1;

  static Future<File?> _file() async {
    try {
      final dir = await getApplicationSupportDirectory();
      return File(p.join(dir.path, 'recent_scan_cache.json'));
    } catch (_) {
      return null;
    }
  }

  static Future<List<RecentFileInfo>?> load() async {
    try {
      final f = await _file();
      if (f == null || !await f.exists()) return null;
      final d = jsonDecode(await f.readAsString());
      if (d is! Map || d['v'] != kVersion) return null;
      final list = d['files'] as List;
      return list
          .whereType<Map>()
          .map((e) => RecentFileInfo.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(List<RecentFileInfo> files) async {
    try {
      final f = await _file();
      if (f == null) return;
      await f.writeAsString(jsonEncode({
        'v': kVersion,
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'files': files.map((e) => e.toJson()).toList(),
      }));
    } catch (_) {}
  }

  static Future<void> clear() async {
    try {
      final f = await _file();
      if (f != null && await f.exists()) await f.delete();
    } catch (_) {}
  }
}

/// 「最近」页：像手机文件管理器一样展示全部文件，最近修改的排在前面。
/// - 固定顶部搜索框（文件名过滤）
/// - 列表 / 宫格 / 瀑布流三种视图
/// - 日期分区（不区分 / 按天 / 按月 / 按年）
/// - 本地缓存秒开 + 后台重扫增量更新
class RecentFilesScreen extends StatefulWidget {
  final String Function(String) translate;
  final Future<void> Function(String) onOpenFile;

  const RecentFilesScreen({
    super.key,
    required this.translate,
    required this.onOpenFile,
  });

  @override
  State<RecentFilesScreen> createState() => RecentFilesScreenState();
}

class RecentFilesScreenState extends State<RecentFilesScreen> {
  bool _loading = true;
  bool _rescanning = false; // 缓存已展示，后台重扫中
  String? _error;
  List<RecentFileInfo> _files = [];

  // ============ 搜索与筛选 ============
  String _query = '';
  FileCategory _filter = FileCategory.all;
  final TextEditingController _searchCtrl = TextEditingController();

  // ============ 多选模式 ============
  final Set<String> _selectedPaths = {};
  bool get _selecting => _selectedPaths.isNotEmpty;
  bool _aspectRefreshing = false;

  void _toggleSelect(String path) {
    setState(() {
      if (!_selectedPaths.remove(path)) _selectedPaths.add(path);
    });
  }

  Future<void> _afterChange(Iterable<String> touched) async {
    _selectedPaths.removeAll(touched);
    await refresh();
  }

  void setFilter(FileCategory c) => setState(() => _filter = c);

  FileCategory get filter => _filter;

  List<RecentFileInfo> get _filtered {
    Iterable<RecentFileInfo> it = _files;
    if (_filter != FileCategory.all) {
      it = it.where((f) => FileThumbs.categoryOf(f.name) == _filter);
    }
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      it = it.where((f) => f.name.toLowerCase().contains(q));
    }
    return it.toList();
  }

  @override
  void initState() {
    super.initState();
    refresh();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 刷新策略：先展示本地缓存（秒开），后台全量重扫后覆盖并回写缓存。
  /// 下拉刷新走同一路径，感知上只是列表原地更新。
  Future<void> refresh() async {
    if (!_loading) {
      // 已有内容：后台静默重扫
      setState(() => _rescanning = true);
    }
    try {
      final cached = await RecentScanCache.load();
      if (mounted && cached != null && cached.isNotEmpty && _loading) {
        setState(() {
          _files = cached;
          _loading = false;
        });
      }
      final files = await _scan();
      if (mounted) {
        setState(() {
          _files = files;
          _loading = false;
          _rescanning = false;
          _error = null;
        });
      }
      await RecentScanCache.save(files);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
          _rescanning = false;
        });
      }
    }
  }

  static Future<List<RecentFileInfo>> _scan({
    int maxResults = 300,
    int maxDepth = 3,
  }) async {
    final roots = <String>[];
    if (Platform.isAndroid) {
      roots.add('/storage/emulated/0');
    } else if (Platform.isWindows) {
      roots.add(Platform.environment['USERPROFILE'] ?? '');
    } else {
      roots.add(Platform.environment['HOME'] ?? '');
    }
    roots.removeWhere((e) => e.isEmpty);

    // 跳过系统/应用私有目录与巨量无关目录
    const skipNames = {
      'Android',
      'Windows',
      'Program Files',
      'Program Files (x86)',
      'ProgramData',
      'AppData',
      'Library',
      'Applications',
      'System Volume Information',
      r'$RECYCLE.BIN',
      'node_modules',
    };

    final results = <RecentFileInfo>[];
    int budget = 5000; // 统计条目上限，防止扫太久

    Future<void> walk(Directory dir, int depth) async {
      if (depth > maxDepth || budget <= 0) return;
      List<FileSystemEntity> entries;
      try {
        entries = await dir.list(followLinks: false).toList();
      } catch (_) {
        return; // 无权限等，跳过
      }
      for (final e in entries) {
        if (budget <= 0) return;
        final name = e.path.split(Platform.pathSeparator).last;
        if (name.startsWith('.')) continue;
        if (e is Directory) {
          if (skipNames.contains(name)) continue;
          budget--;
          await walk(e, depth + 1);
        } else if (e is File) {
          budget--;
          try {
            final stat = await e.stat();
            results.add(RecentFileInfo(
              path: e.path,
              name: name,
              modified: stat.modified,
              size: stat.size,
            ));
          } catch (_) {}
        }
      }
    }

    for (final r in roots) {
      final d = Directory(r);
      if (await d.exists()) {
        await walk(d, 1);
      }
    }

    results.sort((a, b) => b.modified.compareTo(a.modified));
    return results.take(maxResults).toList();
  }

  String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  String _fmtDate(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }

  // ============ 日期分区 ============

  /// 把文件列表按 GroupMode 分组，返回 (分组标题, 文件列表) 顺序序列
  List<MapEntry<String, List<RecentFileInfo>>> _grouped(
      List<RecentFileInfo> files) {
    final mode = ViewPrefsService.instance.group;
    if (mode == GroupMode.none) return [MapEntry('', files)];

    String two(int n) => n.toString().padLeft(2, '0');
    String keyFor(DateTime dt) {
      switch (mode) {
        case GroupMode.day:
          return '${dt.year}-${two(dt.month)}-${two(dt.day)}';
        case GroupMode.month:
          return '${dt.year}-${two(dt.month)}';
        case GroupMode.year:
          return '${dt.year}';
        case GroupMode.none:
          return '';
      }
    }

    String labelFor(String key) {
      if (mode == GroupMode.day) {
        final now = DateTime.now();
        final today = '${now.year}-${two(now.month)}-${two(now.day)}';
        final yst = '${now.year}-${two(now.month)}-${two(now.day - 1)}';
        if (key == today) return '今天';
        if (key == yst) return '昨天';
        final parts = key.split('-');
        final thisYear = parts[0] == '${DateTime.now().year}';
        return thisYear ? '${int.parse(parts[1])}月${int.parse(parts[2])}日' : key;
      }
      if (mode == GroupMode.month) {
        final parts = key.split('-');
        final thisYear = parts[0] == '${DateTime.now().year}';
        return thisYear ? '${int.parse(parts[1])}月' : '${parts[0]}年${int.parse(parts[1])}月';
      }
      return '$key年';
    }

    final result = <MapEntry<String, List<RecentFileInfo>>>[];
    for (final f in files) {
      final key = keyFor(f.modified);
      if (result.isNotEmpty && result.last.key == key) {
        result.last.value.add(f);
      } else {
        result.add(MapEntry(key, [f]));
      }
    }
    return result.map((e) => MapEntry(labelFor(e.key), e.value)).toList();
  }

  // ============ 列表行（列表视图） ============

  Widget _buildListTile(RecentFileInfo f) {
    final dirPath = f.path.substring(0, f.path.length - f.name.length - 1);
    final selected = _selectedPaths.contains(f.path);
    return InkWell(
      onTap: () {
        if (_selecting) {
          _toggleSelect(f.path);
        } else {
          widget.onOpenFile(f.path);
        }
      },
      onLongPress: () => _toggleSelect(f.path),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            if (_selecting)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Icon(
                  selected ? Icons.check_box : Icons.check_box_outline_blank,
                  size: 22,
                  color: selected ? Colors.blue : Colors.grey,
                ),
              ),
            FileThumbnail(path: f.path, name: f.name, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    f.name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    dirPath,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  _fmtSize(f.size),
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _fmtDate(f.modified),
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade500,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ============ 宫格卡片 ============

  Widget _buildGridCard(RecentFileInfo f) {
    final selected = _selectedPaths.contains(f.path);
    return InkWell(
      onTap: () {
        if (_selecting) {
          _toggleSelect(f.path);
        } else {
          widget.onOpenFile(f.path);
        }
      },
      onLongPress: () => _toggleSelect(f.path),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? Colors.blue : Colors.grey.shade200,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: FileThumbnail(path: f.path, name: f.name, size: 72),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    f.name,
                    style: const TextStyle(fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _fmtSize(f.size),
                    style:
                        TextStyle(fontSize: 10, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============ 瀑布流卡片 ============

  Widget _buildWaterfallCard(RecentFileInfo f, double thumbHeight) {
    final selected = _selectedPaths.contains(f.path);
    return InkWell(
      onTap: () {
        if (_selecting) {
          _toggleSelect(f.path);
        } else {
          widget.onOpenFile(f.path);
        }
      },
      onLongPress: () => _toggleSelect(f.path),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? Colors.blue : Colors.grey.shade200,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(9)),
              child: SizedBox(
                width: double.infinity,
                height: thumbHeight,
                child: FileThumbnail(path: f.path, name: f.name, size: 64),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    f.name,
                    style: const TextStyle(fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${_fmtSize(f.size)} · ${_fmtDate(f.modified)}',
                    style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 瀑布流（单个分组内部）：按图片宽高比估算高度，贪心分配到两列
  Widget _buildWaterfallSection(List<RecentFileInfo> files) {
    final colA = <RecentFileInfo>[];
    final colB = <RecentFileInfo>[];
    final hA = <RecentFileInfo, double>{};
    final hB = <RecentFileInfo, double>{};
    double sumA = 0, sumB = 0;

    for (final f in files) {
      final ratio = FileThumbs.aspectCache[f.path];
      final thumbH = ratio == null || ratio <= 0
          ? 160.0
          : (260.0 / ratio).clamp(120.0, 320.0);
      final itemH = thumbH + 52; // 卡片文字区估算
      if (sumA <= sumB) {
        colA.add(f);
        hA[f] = thumbH;
        sumA += itemH;
      } else {
        colB.add(f);
        hB[f] = thumbH;
        sumB += itemH;
      }
    }

    Widget col(List<RecentFileInfo> items, Map<RecentFileInfo, double> hs) {
      return Expanded(
        child: Column(
          children: [
            for (final f in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _buildWaterfallCard(f, hs[f] ?? 160),
              ),
          ],
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [col(colA, hA), const SizedBox(width: 10), col(colB, hB)],
    );
  }

  /// 分区标题
  Widget _groupHeader(String label) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 8),
          Expanded(child: Divider(height: 1, color: Colors.grey.shade300)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    String t(String key) => widget.translate(key);

    if (_loading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(t('scanning'),
                style: TextStyle(fontSize: 14, color: Colors.grey.shade600)),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 56, color: Colors.red.shade300),
            const SizedBox(height: 12),
            Text('${t('scanFailed')}: $_error',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
          ],
        ),
      );
    }

    if (_files.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.folder_open, size: 64, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            Text(t('noFilesFound'),
                style: TextStyle(fontSize: 15, color: Colors.grey.shade500)),
          ],
        ),
      );
    }

    final files = _filtered;

    Widget content;
    if (files.isEmpty) {
      content = Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 56, color: Colors.grey.shade300),
            const SizedBox(height: 12),
            Text('没有匹配的文件',
                style: TextStyle(fontSize: 14, color: Colors.grey.shade500)),
          ],
        ),
      );
    } else {
      content = AnimatedBuilder(
        animation: ViewPrefsService.instance,
        builder: (context, _) {
          final grouped = _grouped(files);
          final hasGroups =
              grouped.length > 1 || grouped.first.key.isNotEmpty;

          switch (ViewPrefsService.instance.mode) {
            case ViewMode.grid:
              if (!hasGroups) {
                return RefreshIndicator(
                  onRefresh: refresh,
                  child: _gridView(files),
                );
              }
              // 分区宫格：每组一个小标题 + shrinkWrap 宫格
              return RefreshIndicator(
                onRefresh: refresh,
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(bottom: 20),
                  child: Column(
                    children: [
                      for (final g in grouped) ...[
                        _groupHeader(g.key),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: _gridView(g.value, shrink: true),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            case ViewMode.waterfall:
              // 瀑布流比例异步解码（只对未缓存的图片）
              final missing = files
                  .where((f) =>
                      FileThumbs.isImage(f.name) &&
                      !FileThumbs.aspectCache.containsKey(f.path))
                  .toList();
              if (missing.isNotEmpty && !_aspectRefreshing) {
                _aspectRefreshing = true;
                Future.wait(missing
                        .take(60)
                        .map((f) => FileThumbs.aspectRatio(f.path)))
                    .then((_) {
                  _aspectRefreshing = false;
                  if (mounted) setState(() {});
                });
              }
              return RefreshIndicator(
                onRefresh: refresh,
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    children: [
                      for (final g in grouped) ...[
                        _groupHeader(g.key),
                        _buildWaterfallSection(g.value),
                      ],
                    ],
                  ),
                ),
              );
            case ViewMode.list:
            default:
              // 分区列表：扁平化 (标题行 / 文件行)
              return RefreshIndicator(
                onRefresh: refresh,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    for (final g in grouped) ...[
                      _groupHeader(g.key),
                      for (final f in g.value) _buildListTile(f),
                    ],
                  ],
                ),
              );
          }
        },
      );
    }

    // 固定顶部搜索框
    content = Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _query = '');
                      },
                    ),
              hintText: '搜索文件名',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
            ),
            onChanged: (v) => setState(() => _query = v.trim()),
          ),
        ),
        if (_rescanning)
          const LinearProgressIndicator(minHeight: 2),
        Expanded(child: content),
      ],
    );

    // 多选模式：顶部「已选择 N 项」横幅 + 底部操作栏
    if (_selecting) {
      content = Column(
        children: [
          SelectionHeaderBar(
            count: _selectedPaths.length,
            onSelectAll: () =>
                setState(() => _selectedPaths.addAll(files.map((f) => f.path))),
            onCancel: () => setState(_selectedPaths.clear),
          ),
          Expanded(child: content),
          FileSelectionBar(
            count: _selectedPaths.length,
            onShare: () =>
                FileBatchOps.share(context, _selectedPaths.toList()),
            onMove: () => FileBatchOps.moveTo(context, _selectedPaths.toList(),
                afterChange: () => _afterChange(_selectedPaths)),
            onCopy: () => FileBatchOps.copyTo(context, _selectedPaths.toList()),
            onDelete: () => FileBatchOps.delete(context, _selectedPaths.toList(),
                afterChange: () => _afterChange(_selectedPaths)),
            onMore: _moreSelected,
          ),
        ],
      );
    }
    return content;
  }

  Widget _gridView(List<RecentFileInfo> files, {bool shrink = false}) {
    final grid = GridView.builder(
      physics: shrink ? const NeverScrollableScrollPhysics() : const AlwaysScrollableScrollPhysics(),
      shrinkWrap: shrink,
      padding: EdgeInsets.zero,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 130,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 0.78,
      ),
      itemCount: files.length,
      itemBuilder: (context, i) => _buildGridCard(files[i]),
    );
    if (shrink) return grid;
    return Padding(
      padding: const EdgeInsets.all(10),
      child: grid,
    );
  }

  Future<void> _moreSelected() async {
    final single = _selectedPaths.length == 1 ? _selectedPaths.first : null;
    final action = await FileBatchOps.moreSheet(context, single: single != null);
    if (action == null || !mounted) return;
    switch (action) {
      case 'info':
        await FileBatchOps.info(context, single!);
        break;
      case 'rename':
        await FileBatchOps.rename(context, single!,
            afterChange: () => _afterChange([single]));
        break;
      case 'encrypt':
        break; // 最近页不提供加密入口（在「加密」页操作）
    }
  }
}
