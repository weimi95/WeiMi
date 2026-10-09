import 'dart:io';

import 'package:flutter/material.dart';

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
}

/// 「最近」页：像手机文件管理器一样展示全部文件，最近修改的排在前面。
/// 支持列表 / 宫格 / 瀑布流三种视图、关键字搜索、类型筛选与多选批量操作。
/// 安卓扫内置存储根目录，桌面端扫用户主目录；限制扫描深度与数量防卡顿。
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
  String? _error;
  List<RecentFileInfo> _files = [];

  // ============ 搜索与筛选 ============
  bool _showSearch = false;
  String _query = '';
  FileCategory _filter = FileCategory.all;
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

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

  /// 主界面 AppBar 按钮调用
  void toggleSearch() {
    setState(() => _showSearch = !_showSearch);
    if (_showSearch) {
      _searchFocus.requestFocus();
    } else {
      _searchCtrl.clear();
      _query = '';
    }
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
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final files = await _scan();
      if (mounted) {
        setState(() {
          _files = files;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
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

  /// 瀑布流：按图片宽高比估算高度，贪心分配到两列
  Widget _buildWaterfall(List<RecentFileInfo> files) {
    // 图片宽高比未缓存时先触发异步解码，完成后整体刷新一次
    final missing = files
        .where((f) =>
            FileThumbs.isImage(f.name) &&
            !FileThumbs.aspectCache.containsKey(f.path))
        .toList();
    if (missing.isNotEmpty && !_aspectRefreshing) {
      _aspectRefreshing = true;
      Future.wait(missing.take(60).map((f) => FileThumbs.aspectRatio(f.path)))
          .then((_) {
        _aspectRefreshing = false;
        if (mounted) setState(() {});
      });
    }

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

    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [col(colA, hA), const SizedBox(width: 10), col(colB, hB)],
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
          switch (ViewPrefsService.instance.mode) {
            case ViewMode.grid:
              return RefreshIndicator(
                onRefresh: refresh,
                child: GridView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(10),
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 130,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 0.78,
                  ),
                  itemCount: files.length,
                  itemBuilder: (context, i) => _buildGridCard(files[i]),
                ),
              );
            case ViewMode.waterfall:
              return RefreshIndicator(
                onRefresh: refresh,
                child: _buildWaterfall(files),
              );
            case ViewMode.list:
            default:
              return RefreshIndicator(
                onRefresh: refresh,
                child: ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemCount: files.length,
                  separatorBuilder: (_, __) =>
                      Divider(height: 1, color: Colors.grey.shade200),
                  itemBuilder: (context, index) =>
                      _buildListTile(files[index]),
                ),
              );
          }
        },
      );
    }

    // 搜索栏（顶部）
    if (_showSearch) {
      content = Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _searchCtrl,
              focusNode: _searchFocus,
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
          Expanded(child: content),
        ],
      );
    }

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
