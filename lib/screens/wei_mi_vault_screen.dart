import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart' hide FileType;
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import '../framework/setting_store.dart';
import '../services/android_compat.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/file_item.dart';
import '../services/disk_index_service.dart';
import '../services/encryption_service.dart';
import '../services/file_batch_ops.dart';
import '../services/file_operations_service.dart';
import '../services/file_viewer_service.dart';
import '../services/quick_search_window.dart';
import '../services/search_history_service.dart';
import '../services/system_open_service.dart';
import '../services/view_prefs_service.dart';
import '../services/vault_service.dart';
import '../widgets/file_selection_bar.dart';
import '../widgets/file_thumbnail.dart';
import '../widgets/search_syntax.dart';
import 'file_filter_sheet.dart';
import 'lan_transfer_screen.dart';
import 'vault_browser_screen.dart';

/// 缩略图档位 → 宫格单元格最大宽度（手机默认「中」，与 PC 一致降认知负担）
double _gridExtentFor(ThumbSize s) {
  final desktop = !Platform.isAndroid && !Platform.isIOS;
  // 手机 432dp 宽：小 90→4 列 / 中 110→3 列 / 大 210→2 列；
  // SliverGridDelegateWithMaxCrossAxisExtent 本身按可用宽度算列数，
  // 平板/宽屏自动加列（小≈每 100dp 一列、大≈每 220dp 一列），无需平台特判
  return switch (s) {
    ThumbSize.small => desktop ? 100 : 90,
    ThumbSize.medium => desktop ? 130 : 110,
    ThumbSize.large => desktop ? 170 : 210,
  };
}

/// 缩略图档位 → 列表视图缩略图尺寸
double _listThumbFor(ThumbSize s) => switch (s) {
      ThumbSize.small => 36.0,
      ThumbSize.medium => 42.0,
      ThumbSize.large => 56.0,
    };

/// 缩略图档位 → 瀑布流列宽
double _waterfallWidthFor(ThumbSize s) {
  final desktop = !Platform.isAndroid && !Platform.isIOS;
  return switch (s) {
    ThumbSize.small => desktop ? 180 : 160,
    ThumbSize.medium => desktop ? 260 : 230,
    ThumbSize.large => desktop ? 360 : 320,
  };
}

/// WeiMi Vault 屏幕
///
/// 根视图（「文件」标签首页）：
/// - 常用目录：内置（微密 Vault / 下载 / 文档 / 图片 / 相册 / 音乐 / 视频，桌面端为用户主目录下的常用目录）
/// - 我的目录：用户自行添加（file_picker 选目录，持久化到 SharedPreferences，长按移除）
/// - 每个目录默认折叠，点击展开就地列出其下的文件夹与文件
/// - 整页可滚动并显示滚动条（Scrollbar）
///
/// 点击子文件夹进入浏览视图（原有的前进/后退导航），点击文件走 查看/加密/解密/删除 流程。
class WeiMiVaultScreen extends StatefulWidget {
  final bool showSystemDirs; // true = 桌面端，显示常用系统目录
  final String? initialPath; // 桌面端可指定初始路径
  final Future<void> Function()? onEncryptFiles; // 加密文件（主界面流程）
  final Future<void> Function()? onDecryptFiles; // 解密文件（主界面流程）

  const WeiMiVaultScreen({
    super.key,
    this.showSystemDirs = false,
    this.initialPath,
    this.onEncryptFiles,
    this.onDecryptFiles,
  });

  @override
  State<WeiMiVaultScreen> createState() => WeiMiVaultScreenState();
}

/// 目录条目（根视图折叠列表里的一项）
class _DirEntry {
  final String title;
  final String dirPath;
  final IconData icon;
  final bool isCustom; // 用户手动添加的目录

  const _DirEntry(
    this.title,
    this.dirPath,
    this.icon, {
    this.isCustom = false,
  });
}

class WeiMiVaultScreenState extends State<WeiMiVaultScreen> {
  static const String _kCustomDirsKey = 'weimi_custom_dirs';
  static const String _kVaultDirKey = 'weimi_vault_dir';
  static const String _kCommonOpenKey = 'weimi_sec_common_open';
  static const String _kMineOpenKey = 'weimi_sec_mine_open';

  // ============ 浏览视图（进入某目录后）状态 ============
  List<FileItem> _items = [];
  bool _loading = true;
  String _currentPath = '';
  List<String> _pathHistory = [];
  int _historyIndex = -1;

  // ============ 根视图（目录折叠列表）状态 ============
  String? _vaultDir; // 加密文件存放目录（用户设置，null = 未设置）
  bool _storageGranted = true; // Android 存储权限（桌面端恒 true）
  final Set<String> _expandedDirs = {}; // 展开中的目录
  bool _commonOpen = true; // 「常用目录」分组展开
  bool _mineOpen = true; // 「我的目录」分组展开
  bool _showVaultEntry = true; // 「我的目录」里的保险箱入口（设置页可开关）
  final Map<String, List<FileItem>> _dirChildren = {}; // 展开后的子项缓存
  final Map<String, bool> _dirLoading = {};
  List<String> _customDirs = []; // 用户添加的目录
  List<_DirEntry> _desktopDirs = []; // 桌面端常用目录
  final ScrollController _rootScroll = ScrollController();

  // ============ 固定搜索框（根视图与浏览视图共用） ============
  String _fileQuery = '';
  final TextEditingController _fileSearchCtrl = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  bool _showSearchHistory = false; // 聚焦且无输入时展示历史（点击外部收起）
  List<String> _searchHistory = [];

  // ============ 全盘搜索（主搜索框直搜全盘，手机/PC 通用，无独立窗口） ============
  List<FileItem>? _globalResults; // 非 null = 浏览视图展示全盘结果
  bool _globalSearching = false;
  bool _indexBuilding = false;
  Timer? _fileDebounce;
  int _lastSearchMs = 0; // 最近一次全盘搜索耗时（状态栏展示）

  // ============ 类型筛选（目录内容 / 展开子项 / 全盘搜索结果共用） ============
  FileCategory? _filterCat; // null = 全部
  Set<String> _filterExts = {}; // 空 = 该分类全部格式

  /// 类型筛选匹配：只作用于文件，目录始终显示（保证可导航）
  bool _matchFilter(FileItem it) {
    if (_filterCat == null) return true;
    if (it.isDirectory) return true;
    final c = FileThumbs.categoryOf(it.name);
    if (_filterCat == FileCategory.other) return c == FileCategory.other;
    if (c != _filterCat) return false;
    if (_filterExts.isEmpty) return true;
    return _filterExts.contains(FileThumbs.ext(it.name));
  }

  Future<void> _showFilterSheet() async {
    final r = await FileFilterSheet.show(
        context, _filterCat, _filterExts);
    if (r == null || !mounted) return;
    setState(() {
      _filterCat = r.$1;
      _filterExts = r.$2;
    });
  }

  void _onFileSearchChanged(String v) {
    setState(() => _fileQuery = v.trim());
    _fileDebounce?.cancel();
    if (_fileQuery.isEmpty) {
      setState(() {
        _globalResults = null;
        _globalSearching = false;
        _indexBuilding = false;
      });
      return;
    }
    // 有输入即收起历史面板
    if (_showSearchHistory) setState(() => _showSearchHistory = false);
    final delayMs =
        int.tryParse(SettingStore.get<String>('qs_search_delay', '300')) ?? 300;
    _fileDebounce = Timer(Duration(milliseconds: delayMs), _runFileGlobalSearch);
  }

  /// 聚焦搜索框且无输入时展示历史记录（点击外部/有输入即收起）
  void _onSearchTap() {
    if (_fileSearchCtrl.text.trim().isNotEmpty) return;
    if (_showSearchHistory || _searchHistory.isEmpty) return;
    setState(() => _showSearchHistory = true);
  }

  Future<void> _loadSearchHistory() async {
    final items = await SearchHistoryService.load();
    if (mounted) setState(() => _searchHistory = items);
  }

  /// 点历史项：填入并直接搜索
  void _applyHistoryQuery(String q) {
    _fileDebounce?.cancel();
    _fileSearchCtrl.text = q;
    _searchFocusNode.unfocus();
    setState(() => _showSearchHistory = false);
    _onFileSearchChanged(q);
  }

  Future<void> _clearSearchHistory() async {
    await SearchHistoryService.clear();
    if (mounted) setState(() => _searchHistory = []);
  }

  /// 搜索历史面板（搜索框下方，聚焦且无输入时展示）
  Widget _buildSearchHistoryPanel() {
    if (!_showSearchHistory || _searchHistory.isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade300),
      ),
      constraints: const BoxConstraints(maxHeight: 260),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
            child: Row(
              children: [
                Icon(Icons.history, size: 16, color: Colors.grey.shade600),
                const SizedBox(width: 6),
                Text('搜索历史',
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey.shade600)),
                const Spacer(),
                TextButton(
                  onPressed: _clearSearchHistory,
                  style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: const Size(0, 32)),
                  child: const Text('清空', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 6),
              itemCount: _searchHistory.length,
              itemBuilder: (context, i) {
                final q = _searchHistory[i];
                // pointer-down 即填词：tap-up 前失焦监听会摘掉面板，onTap 被吞
                return Listener(
                  onPointerDown: (_) => _applyHistoryQuery(q),
                  child: ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    leading: const Icon(Icons.north_west, size: 16),
                    title: Text(q, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 全盘搜索（手机/PC 通用）：索引未就绪先建（首次约 1~2 分钟，之后毫秒级）
  Future<void> _runFileGlobalSearch() async {
    final q = _fileQuery;
    if (q.isEmpty || _globalSearching) return;
    setState(() => _globalSearching = true);
    try {
      if (!DiskIndexService.isBuilt) {
        setState(() => _indexBuilding = true);
        await DiskIndexService.prepareIndex();
        if (!mounted) return;
        setState(() => _indexBuilding = false);
      }
      final sw = Stopwatch()..start();
      final paths = await DiskIndexService.search(SearchOpts.load().apply(q));
      sw.stop();
      if (!mounted) return;
      _lastSearchMs = sw.elapsedMilliseconds;
      // 落一条搜索历史（去重 + 按 qs_history_limit 裁剪），供下次聚焦搜索框展示
      unawaited(() async {
        await SearchHistoryService.record(q);
        if (mounted) {
          final items = await SearchHistoryService.load();
          if (mounted) setState(() => _searchHistory = items);
        }
      }());
      // 空结果兜底：索引明显过期（如加载的是旧落盘索引、新建文件还没进索引）
      // 时后台重建一次并自动重搜，避免「文件明明存在却搜不到」。
      if (paths.isEmpty && DiskIndexService.isStale()) {
        setState(() => _indexBuilding = true);
        unawaited(() async {
          try {
            await DiskIndexService.rebuildIfStale(
                maxAge: const Duration(minutes: 2));
          } catch (_) {}
          if (!mounted) return;
          setState(() => _indexBuilding = false);
          // 查询词没变才自动重搜（重建后 isStale=false，不会再次触发兜底，无死循环）
          if (_fileQuery == q) {
            await _runFileGlobalSearch();
          }
        }());
      }
      setState(() {
        _globalResults = paths.map((path) {
          final name = p.basename(path);
          var modified = DateTime.fromMillisecondsSinceEpoch(0);
          var size = 0;
          var isDir = false;
          try {
            final st = File(path).statSync();
            modified = st.modified;
            size = st.size;
            isDir = FileSystemEntity.isDirectorySync(path);
          } catch (_) {}
          return FileItem(
            name: name,
            fullPath: path,
            isDirectory: isDir,
            size: size,
            modified: modified,
          );
        }).toList();
        _globalSearching = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _globalResults = [];
        _globalSearching = false;
      });
    }
  }

  bool get _isDesktop => !Platform.isAndroid && !Platform.isIOS;
  int _lastSelectIndex = -1; // 浏览视图 Shift 范围选择的锚点

  @override
  void initState() {
    super.initState();
    _sortMode = SettingStore.get<String>('weimi_file_sort_mode', 'name');
    _sortAsc = SettingStore.get<bool>('weimi_file_sort_asc', true);
    // 浮窗「打开主界面 / 去主界面展示全部结果」带过来的搜索词：
    // 写入搜索框并立即触发全盘搜索（不要像新开窗口一样丢掉关键词）。
    final pending = WindowModeService.instance.takePendingQuery();
    if (pending != null && pending.isNotEmpty) {
      _fileSearchCtrl.text = pending;
      _onFileSearchChanged(pending);
    }
    _initRoot();
    _navigateTo(widget.initialPath ?? '');
    _loadSearchHistory();
    // 失焦即收起历史面板（点历史项时 _applyHistoryQuery 已先 unfocus 并关面板）
    _searchFocusNode.addListener(() {
      if (!_searchFocusNode.hasFocus && _showSearchHistory) {
        setState(() => _showSearchHistory = false);
      }
    });
    // 预热索引（加载旧索引毫秒级；无索引则后台全量构建），完成后计数自动刷新搜索框
    unawaited(() async {
      try {
        await DiskIndexService.prepareIndex();
      } catch (_) {}
    }());
  }

  @override
  void dispose() {
    _rootScroll.dispose();
    _fileDebounce?.cancel();
    _fileSearchCtrl.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Future<void> _initRoot() async {
    // 加密文件存放目录（用户设置的；未设置时由用户首次进入时选择）
    // + 折叠状态记忆
    try {
      final prefs = await SharedPreferences.getInstance();
      _vaultDir = prefs.getString(_kVaultDirKey);
      _commonOpen = prefs.getBool(_kCommonOpenKey) ?? true;
      _mineOpen = prefs.getBool(_kMineOpenKey) ?? true;
      // 「我的目录」里的保险箱入口（设置页可显示/隐藏）
      _showVaultEntry =
          prefs.getBool(VaultService.showInDirsPrefKey) ?? true;
      // 目录展开状态不再持久化/恢复：启动一律折叠，
      // 避免恢复的展开目录没有触发子项加载而无限转圈
    } catch (_) {}

    // 桌面端常用目录
    if (!Platform.isAndroid && !Platform.isIOS) {
      final home =
          Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) {
        _desktopDirs = [
          _DirEntry('桌面', p.join(home, 'Desktop'), Icons.desktop_windows_outlined),
          _DirEntry('文档', p.join(home, 'Documents'), Icons.description_outlined),
          _DirEntry('下载', p.join(home, 'Downloads'), Icons.download_outlined),
          _DirEntry('图片', p.join(home, 'Pictures'), Icons.image_outlined),
        ];
      }
    }

    // Android 存储权限状态（API 30+ 查「所有文件访问」，低版本查传统存储权限）
    if (Platform.isAndroid) {
      try {
        if (await AndroidCompat.useManageStorage()) {
          final status = await Permission.manageExternalStorage.status;
          _storageGranted = status.isGranted;
        } else {
          final status = await Permission.storage.status;
          _storageGranted = status.isGranted;
        }
      } catch (_) {}
    }

    // 用户自定义目录
    try {
      final prefs = await SharedPreferences.getInstance();
      _customDirs = prefs.getStringList(_kCustomDirsKey) ?? [];
    } catch (_) {}

    if (mounted) setState(() {});
  }

  // ============ 权限 ============

  Future<void> _requestStoragePermission() async {
    final useManage = await AndroidCompat.useManageStorage();
    final perm =
        useManage ? Permission.manageExternalStorage : Permission.storage;
    var status = await perm.request();
    if (status.isPermanentlyDenied || status.isRestricted) {
      if (useManage && mounted) await _showManageStorageGuide();
      await openAppSettings();
    }
    // 复查一次（用户可能去设置里开了再回来）
    final now = await perm.status;
    if (mounted) setState(() => _storageGranted = now.isGranted);
  }

  /// 「所有文件访问」授权指引（跳设置前先讲清步骤，避免用户找不到开关）。
  Future<void> _showManageStorageGuide() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('授权步骤'),
        content: const Text(
          '1. 在接下来的设置页找到「微密文件」\n'
          '2. 点「权限」→「文件和媒体」\n'
          '3. 选择「允许管理所有文件」\n\n'
          '该权限仅用于浏览和加密本地文件，微密不会上传任何数据。',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
        ],
      ),
    );
  }

  Widget get _permissionBanner {
    return FutureBuilder<bool>(
      future: AndroidCompat.useManageStorage(),
      builder: (ctx, snap) {
        final useManage = snap.data ?? true;
        return Container(
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.orange.shade50,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.orange.shade200),
          ),
          child: Row(
            children: [
              Icon(Icons.warning_amber_outlined,
                  size: 20, color: Colors.orange.shade700),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  useManage
                      ? '需要「所有文件访问」权限才能浏览手机目录'
                      : '需要存储权限才能浏览手机目录',
                  style: TextStyle(
                      fontSize: 13, color: Colors.orange.shade900),
                ),
              ),
              TextButton(
                onPressed: _requestStoragePermission,
                child: const Text('去授权'),
              ),
            ],
          ),
        );
      },
    );
  }

  // ============ 我的目录：添加 / 移除 ============

  Future<void> _addCustomDir() async {
    String? picked = await FilePicker.platform
        .getDirectoryPath(dialogTitle: '选择要添加的目录');
    if (picked == null || !mounted) return;
    picked = _normalizeAndroidDir(picked);

    final exists = await Directory(picked).exists();
    if (!exists) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('目录不存在或无法访问: $picked')),
      );
      return;
    }
    if (_customDirs.contains(picked) ||
        (_vaultDir != null && picked == _vaultDir)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该目录已在列表中')),
      );
      return;
    }

    setState(() => _customDirs.add(picked!));
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kCustomDirsKey, _customDirs);
    } catch (_) {}
  }

  /// Android 上 file_picker 可能返回 SAF tree 路径（/tree/primary:Download），
  /// 转换为真实文件系统路径（/storage/emulated/0/Download）
  String _normalizeAndroidDir(String path) {
    if (!Platform.isAndroid) return path;
    final m = RegExp(r'^/tree/([^:]+):(.*)$').firstMatch(path);
    if (m == null) return path;
    final vol = m.group(1)!;
    final rest = m.group(2)!;
    final base = vol == 'primary' ? '/storage/emulated/0' : '/storage/$vol';
    return rest.isEmpty ? base : '$base/$rest';
  }

  Future<void> _removeCustomDir(String dirPath) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除目录'),
        content: Text('从列表移除 "${p.basename(dirPath)}"？\n（不会删除磁盘上的文件）'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('移除')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _customDirs.remove(dirPath);
      _expandedDirs.remove(dirPath);
      _dirChildren.remove(dirPath);
      _dirLoading.remove(dirPath);
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kCustomDirsKey, _customDirs);
    } catch (_) {}
  }

  // ============ 目录展开 / 折叠 ============

  Future<void> _toggleDir(String dirPath) async {
    if (_expandedDirs.contains(dirPath)) {
      setState(() => _expandedDirs.remove(dirPath));
      return;
    }

    // 每次展开都重新读取，保证内容新鲜
    setState(() {
      _expandedDirs.add(dirPath);
      _dirLoading[dirPath] = true;
    });
    try {
      final items = await listDirectory(dirPath);
      if (!mounted) return;
      setState(() {
        _dirChildren[dirPath] = items;
        _dirLoading[dirPath] = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _dirChildren[dirPath] = [];
        _dirLoading[dirPath] = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法读取目录: $e')),
      );
    }
  }

  /// 原位重载某个已展开目录的子项（保持展开状态，不清空缓存外的状态）
  Future<void> _reloadDir(String dirPath) async {
    setState(() => _dirLoading[dirPath] = true);
    try {
      final items = await listDirectory(dirPath);
      if (!mounted) return;
      setState(() {
        _dirChildren[dirPath] = items;
        _dirLoading[dirPath] = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _dirLoading[dirPath] = false);
    }
  }

  Future<void> _setSectionOpen({required bool mine, required bool open}) async {
    setState(() {
      if (mine) {
        _mineOpen = open;
      } else {
        _commonOpen = open;
      }
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(mine ? _kMineOpenKey : _kCommonOpenKey, open);
    } catch (_) {}
  }

  // ============ 导航（浏览视图） ============

  Future<void> _navigateTo(String targetPath) async {
    setState(() {
      _loading = true;
      _items = [];
      if (targetPath.isEmpty) {
        _currentPath = '';
        _pathHistory = [''];
        _historyIndex = 0;
      } else {
        _currentPath = targetPath;
        if (_historyIndex < _pathHistory.length - 1) {
          _pathHistory = _pathHistory.sublist(0, _historyIndex + 1);
        }
        if (!_pathHistory.contains(targetPath)) {
          _pathHistory.add(targetPath);
          _historyIndex = _pathHistory.length - 1;
        } else {
          _historyIndex = _pathHistory.indexOf(targetPath);
        }
      }
    });

    try {
      final items = await listDirectory(targetPath);
      if (mounted) {
        setState(() {
          _items = items;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法访问目录: $e')),
        );
      }
    }
  }

  void _goBack() {
    if (_historyIndex > 0) {
      _navigateTo(_pathHistory[_historyIndex - 1]);
    }
  }

  void _goForward() {
    if (_historyIndex < _pathHistory.length - 1) {
      _navigateTo(_pathHistory[_historyIndex + 1]);
    }
  }

  /// AppBar 标题：根视图/我的电脑虚拟路径/普通目录
  String _titleFor(String path, bool isRoot) {
    if (isRoot) return '文件';
    if (path == kMyComputerPath) return '我的电脑';
    return p.basename(path);
  }

  // ============ 面包屑路径栏（手机/桌面通用，点任意上级跳转） ============

  /// 路径 → [(显示名, 真实路径)]。Android 内部存储首级显示「手机存储」；
  /// Windows 首级为盘符；Linux/macOS 首级为根目录。
  List<(String, String)> _breadcrumbParts(String path) {
    if (path.isEmpty || path == kMyComputerPath) return const [];
    final norm = path.replaceAll('\\', '/');
    final segs = norm.split('/').where((s) => s.isNotEmpty).toList();
    if (segs.isEmpty) return const [];
    final parts = <(String, String)>[];
    if (Platform.isAndroid && norm.startsWith('/storage/emulated/0')) {
      parts.add(('手机存储', '/storage/emulated/0'));
      var acc = '/storage/emulated/0';
      for (final s in segs.skip(3)) {
        acc = '$acc/$s';
        parts.add((s, acc));
      }
      return parts;
    }
    var acc = '';
    for (var i = 0; i < segs.length; i++) {
      acc = i == 0
          ? (Platform.isWindows ? segs[0] : '/${segs[0]}')
          : '$acc/${segs[i]}';
      parts.add((segs[i], acc));
    }
    return parts;
  }

  /// 面包屑行：横向滚动、每级可点（对齐手机文件管理器/资源管理器地址栏习惯）
  Widget _buildBreadcrumb(String path) {
    final parts = _breadcrumbParts(path);
    if (parts.isEmpty) return const SizedBox.shrink();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < parts.length; i++) ...[
            if (i > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Icon(Icons.chevron_right,
                    size: 13, color: Colors.grey.shade500),
              ),
            InkWell(
              onTap: () => _navigateTo(parts[i].$2),
              child: Text(
                parts[i].$1,
                style: TextStyle(
                  fontSize: 11,
                  color: i == parts.length - 1
                      ? Theme.of(context).colorScheme.onSurface
                      : Colors.blue.shade600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ============ 排序（浏览视图，文件夹优先，状态持久化） ============
  String _sortMode = 'name'; // name / size / type / time
  bool _sortAsc = true;

  Future<void> _showSortSheet() async {
    final r = await showModalBottomSheet<(String, bool)>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _sortRadio(ctx, 'name', '名称'),
            _sortRadio(ctx, 'size', '大小'),
            _sortRadio(ctx, 'type', '类型'),
            _sortRadio(ctx, 'time', '修改时间'),
            const Divider(height: 1),
            SwitchListTile(
              dense: true,
              title: Text(_sortAsc ? '升序' : '降序'),
              secondary: Icon(
                  _sortAsc ? Icons.arrow_upward : Icons.arrow_downward),
              value: _sortAsc,
              onChanged: (v) => Navigator.pop(ctx, (_sortMode, v)),
            ),
          ],
        ),
      ),
    );
    if (r == null || !mounted) return;
    if (r.$1 == _sortMode && r.$2 == _sortAsc) return;
    setState(() {
      _sortMode = r.$1;
      _sortAsc = r.$2;
    });
    await SettingStore.set('weimi_file_sort_mode', _sortMode);
    await SettingStore.set('weimi_file_sort_asc', _sortAsc);
  }

  Widget _sortRadio(BuildContext ctx, String mode, String label) {
    return RadioListTile<String>(
      dense: true,
      value: mode,
      groupValue: _sortMode,
      onChanged: (v) => Navigator.pop(ctx, (v ?? mode, _sortAsc)),
      title: Text(label),
    );
  }

  // ============ 桌面快捷键（F2 重命名 / F5 刷新；Ctrl+A、Delete 已有） ============

  /// F2：重命名当前单选（资源管理器习惯）
  void _renameFromKeyboard() {
    if (!_isDesktop) return;
    if (_selectedPaths.length != 1) return;
    final path = _selectedPaths.first;
    FileBatchOps.rename(context, path,
        afterChange: () => _afterBatchChange([path]));
  }

  /// F5：刷新当前目录（根视图则 setState 重展开）
  void _refreshFromKeyboard() {
    if (!_isDesktop) return;
    if (_currentPath.isEmpty) {
      setState(() {});
      return;
    }
    _navigateTo(_currentPath);
  }

  // ============ 状态栏（资源管理器底栏习惯） ============

  /// 底部状态条：项目数 / 文件夹数 / 选中数 / 合计大小
  Widget _buildStatusBar() {
    final items = _browseItems;
    final dirs = items.where((e) => e.isDirectory).length;
    final files = items.length - dirs;
    String text;
    if (_selecting) {
      int total = 0;
      for (final s in _selectedPaths) {
        try {
          total += File(s).lengthSync();
        } catch (_) {}
      }
      text = '共 ${items.length} 项 · 已选 ${_selectedPaths.length} 个 · '
          '合计 ${_fmtBytes(total)}';
    } else if (_globalResults != null) {
      text = '共 ${items.length} 项 · $dirs 个文件夹 · $files 个文件'
          '${_lastSearchMs > 0 ? ' · 耗时 ${_lastSearchMs}ms' : ''}';
    } else {
      text = '共 ${items.length} 项 · $dirs 个文件夹 · $files 个文件';
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border(top: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Text(text,
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
    );
  }

  String _fmtBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  /// 系统返回键处理：true = 已内部消化（回到上一级/清除选择），false = 在根视图，允许退出应用
  bool handleSystemBack() {    if (_selectedPaths.isNotEmpty) {
      _clearSelection();
      return true;
    }
    if (_historyIndex > 0) {
      _goBack();
      return true;
    }
    return false;
  }

  // ============ 文件操作 ============

  /// 智能打开（单击/双击/点击统一入口）：
  /// - 文件夹 → 进入
  /// - 加密文件 → 直接问密码，输完直接查看
  /// - 非加密 + 内置支持格式 → 直接查看
  /// - 非加密 + 不支持格式 → 直接调系统打开菜单
  Future<void> _smartOpen(FileItem item) async {
    if (!mounted) return;

    if (item.isDirectory) {
      _navigateTo(item.fullPath);
      return;
    }

    if (item.isEncryptedFile) {
      // 归档容器（WEMI_FARC）不是单文件格式：单击直接进解包流程
      if (await EncryptionService.isArchiveFile(item.fullPath)) {
        await _unpackArchiveWithDialog(item.fullPath);
        return;
      }
      final hint = await EncryptionService.getPasswordHint(item.fullPath);
      final password = await _showPasswordDialog(hint: hint);
      if (password == null || !mounted) return;
      await _viewFile(item, presetPassword: password);
      return;
    }

    final type = FileOperationsService.getFileType(item.fullPath);
    if (type == FileType.unknown) {
      // 内置查看器不支持的格式 → 系统打开；失败按原因兜底
      // （apk 未授权「安装未知应用」→ 引导；无应用 → 打开方式）
      final r = await SystemOpenService.open(item.fullPath);
      if (!r.ok && mounted) {
        await SystemOpenService.handleFailure(context, item.fullPath, r);
      }
      return;
    }
    await _viewFile(item);
  }

  /// 内置查看器打开（加密文件先问密码；可由 _smartOpen 预置密码避免二次询问）
  Future<void> _viewFile(FileItem item, {String? presetPassword}) async {
    String? password = presetPassword;
    if (password == null) {
      final isEnc = await EncryptionService.isEncryptedFile(item.fullPath);
      if (isEnc) {
        final hint = await EncryptionService.getPasswordHint(item.fullPath);
        password = await _showPasswordDialog(hint: hint);
        if (password == null) return;
      }
    }
    try {
      await FileViewerService.openFile(
        context, item.fullPath,
        password: password, isEncrypted: password != null,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    }
  }

  /// 问密码后解密单个文件（右键菜单/操作面板共用）；归档容器走独立流程
  Future<void> _decryptWithDialog(FileItem item) async {
    if (await EncryptionService.isArchiveFile(item.fullPath)) {
      await _unpackArchiveWithDialog(item.fullPath);
      return;
    }
    final hint = await EncryptionService.getPasswordHint(item.fullPath);
    final password = await _showPasswordDialog(hint: hint);
    if (password == null || !mounted) return;
    _decryptFile(item.fullPath, password);
  }

  Future<void> _encryptFile(String filePath) async {
    if (!mounted) return;

    // 已设置「加密文件存放目录」时直接用它，不再每次询问
    String? outputDir;
    if (_vaultDir != null) {
      outputDir = _vaultDir;
    } else {
      outputDir = await FileOperationsService.pickOutputDirectory();
    }
    if (outputDir == null || !mounted) return;

    final result = await _showEncryptPasswordDialog();
    if (result == null || !mounted) return;

    try {
      await FileOperationsService.encryptFile(
        filePath, outputDir, result['password']!,
        hint: result['hint'],
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('加密成功')),
        );
        _refreshAfterOp(filePath);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加密失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _decryptFile(String filePath, String password) async {
    if (!mounted) return;

    final outputDir = await FileOperationsService.pickOutputDirectory();
    if (outputDir == null || !mounted) return;

    try {
      await FileOperationsService.decryptFile(filePath, outputDir, password);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('解密成功')),
        );
        _refreshAfterOp(filePath);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('解密失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // ============ 文件夹加密（归档容器 WEMI_FARC）============

  /// 主界面（拖拽/解密卡片）入口：加密文件夹
  Future<void> packFolderFlow(String dirPath) => _packFolderWithDialog(dirPath);

  /// 主界面（拖拽/解密卡片）入口：解密归档
  Future<void> openArchiveFlow(String archivePath) =>
      _unpackArchiveWithDialog(archivePath);

  /// 右键「加密文件夹」：选输出目录 → 设密码 → isolate 后台打包（不卡 UI）
  Future<void> _packFolderWithDialog(String dirPath) async {
    if (!mounted) return;

    String? outputDir;
    if (_vaultDir != null) {
      outputDir = _vaultDir;
    } else {
      outputDir = await FileOperationsService.pickOutputDirectory();
    }
    if (outputDir == null || !mounted) return;

    final result = await _showEncryptPasswordDialog();
    if (result == null || !mounted) return;

    final folderName = p.basename(dirPath);
    final outputPath = p.join(outputDir, '$folderName.wemi');
    if (await File(outputPath).exists()) {
      final overwrite = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('文件已存在'),
          content: Text('$folderName.wemi 已存在于输出目录，覆盖它吗？'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('覆盖')),
          ],
        ),
      );
      if (overwrite != true || !mounted) return;
    }

    final password = result['password']!;
    final hint = result['hint'];
    await _runArchiveJob(
      title: '正在加密文件夹',
      job: () => EncryptionService.packFolder(dirPath, outputPath, password, hint: hint),
    );
    if (mounted) _refreshAfterOp(dirPath);
  }

  /// 归档解密入口（右键/单击加密文件时按 magic 路由进来）：
  /// 输密码 → 列清单 → 勾选 → 选输出目录 → isolate 后台解包
  Future<void> _unpackArchiveWithDialog(String archivePath) async {
    if (!mounted) return;

    final password = await _showPasswordDialog();
    if (password == null || password.isEmpty || !mounted) return;

    final ArchiveListing listing;
    try {
      listing = await EncryptionService.listArchive(archivePath, password);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red),
        );
      }
      return;
    }

    final selected = await _showArchiveListingDialog(listing);
    if (selected == null || !mounted) return; // null = 取消

    final outputDir = await FileOperationsService.pickOutputDirectory();
    if (outputDir == null || !mounted) return;

    final paths = selected.isEmpty ? const <String>[] : selected;
    await _runArchiveJob(
      title: '正在解密归档',
      job: () => EncryptionService.extractSelected(archivePath, outputDir, password, paths),
    );
    if (mounted) _refreshAfterOp(archivePath);
  }

  /// 归档清单对话框：全量字节 + 勾选。返回 null=取消；空列表=全部；否则勾选项。
  Future<List<String>?> _showArchiveListingDialog(ArchiveListing listing) async {
    final checked = <String>{for (final e in listing.entries) e.path};
    return showDialog<List<String>>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: Text('归档内容（${listing.entries.length} 个文件）'),
              content: SizedBox(
                width: 420,
                height: 380,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '总大小 ${_formatBytes(listing.totalSize)}'
                      '${listing.hint != null && listing.hint!.isNotEmpty ? ' · 提示: ${listing.hint}' : ''}',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.builder(
                        itemCount: listing.entries.length,
                        itemBuilder: (c, i) {
                          final e = listing.entries[i];
                          final on = checked.contains(e.path);
                          return CheckboxListTile(
                            dense: true,
                            value: on,
                            title: Text(e.path,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 13)),
                            subtitle: Text(_formatBytes(e.size),
                                style: const TextStyle(fontSize: 11)),
                            onChanged: (v) {
                              setDialogState(() {
                                if (v == true) {
                                  checked.add(e.path);
                                } else {
                                  checked.remove(e.path);
                                }
                              });
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
                TextButton(
                  onPressed: checked.isEmpty
                      ? null
                      : () => Navigator.pop(ctx, checked.toList()),
                  child: Text('解密所选 (${checked.length})'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, const <String>[]),
                  child: const Text('全部解密'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 归档任务执行器：isolate 跑重活 + 轮询进度对话框，完成后统一报错/成功
  Future<void> _runArchiveJob({
    required String title,
    required Future<void> Function() job,
  }) async {
    if (!mounted) return;
    Object? error;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ArchiveProgressDialog(title: title),
    );
    try {
      await Isolate.run(job);
    } catch (e) {
      error = e;
    }
    if (!mounted) return;
    Navigator.of(context).pop(); // 关进度对话框
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$error'), backgroundColor: Colors.red),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('操作成功')),
      );
    }
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// 操作后刷新：在浏览视图则刷新当前目录，展开的目录列表也刷新缓存
  void _refreshAfterOp(String opFilePath) {
    final dir = p.dirname(opFilePath);
    if (_currentPath.isNotEmpty) {
      _navigateTo(_currentPath);
    }
    if (_dirChildren.containsKey(dir)) {
      _dirChildren.remove(dir);
      if (_expandedDirs.contains(dir)) _reloadDir(dir);
    }
  }

  Future<void> _deleteFile(FileItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除文件'),
        content: Text('确定要删除 "${item.name}" 吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await File(item.fullPath).delete();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已删除')),
        );
        if (_currentPath.isNotEmpty) {
          _navigateTo(_currentPath);
        } else {
          // 根视图里删除：刷新对应展开目录
          final dir = p.dirname(item.fullPath);
          _dirChildren.remove(dir);
          if (_expandedDirs.contains(dir)) _reloadDir(dir);
          setState(() {});
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // ============ 多选模式 ============

  final Set<String> _selectedPaths = {}; // 当前选中的文件路径
  bool _aspectRefreshing = false; // 瀑布流图片比例异步加载标记
  bool get _selecting => _selectedPaths.isNotEmpty;

  void _toggleSelect(String path) {
    setState(() {
      if (!_selectedPaths.remove(path)) _selectedPaths.add(path);
    });
  }

  void _clearSelection() => setState(_selectedPaths.clear);

  void _selectAllVisible(Iterable<String> paths) {
    setState(() => _selectedPaths.addAll(paths));
  }

  // ============ 桌面端交互（单击选中/双击打开/右键菜单/Ctrl+Shift/Delete） ============

  /// 桌面端单击：Ctrl=加减选，Shift=范围选，普通=单选。文件夹直接进入。
  void _desktopTap(FileItem item, int index, List<FileItem> scope) {
    if (item.isDirectory) {
      _navigateTo(item.fullPath);
      return;
    }
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (shift && _lastSelectIndex >= 0 && _lastSelectIndex < scope.length) {
      final a = _lastSelectIndex < index ? _lastSelectIndex : index;
      final b = _lastSelectIndex < index ? index : _lastSelectIndex;
      setState(() {
        for (var i = a; i <= b; i++) {
          if (!scope[i].isDirectory) _selectedPaths.add(scope[i].fullPath);
        }
      });
      return;
    }
    if (ctrl) {
      _toggleSelect(item.fullPath);
    } else {
      setState(() {
        _selectedPaths.clear();
        _selectedPaths.add(item.fullPath);
      });
    }
    _lastSelectIndex = index;
  }

  /// 桌面端双击：文件夹进入，文件走操作面板（查看/加密/解密/删除）
  void _desktopOpen(FileItem item) {
    if (item.isDirectory) {
      _navigateTo(item.fullPath);
    } else {
      _smartOpen(item);
    }
  }

  PopupMenuItem<String> _ctxMenuItem(String value, IconData icon, String label,
      {Color? color}) {
    return PopupMenuItem<String>(
      value: value,
      height: 40,
      child: Row(children: [
        Icon(icon, size: 18, color: color ?? Colors.black87),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(color: color)),
      ]),
    );
  }

  /// 桌面端右键菜单：右键未选中项时先重置为该项；多选时给批量动作
  Future<void> _showContextMenu(
      FileItem item, Offset pos, int index, List<FileItem> scope) async {
    if (!item.isDirectory && !_selectedPaths.contains(item.fullPath)) {
      setState(() {
        _selectedPaths.clear();
        _selectedPaths.add(item.fullPath);
      });
      _lastSelectIndex = index;
    }
    final multi = !item.isDirectory && _selectedPaths.length > 1;
    final List<PopupMenuEntry<String>> entries;
    if (item.isDirectory) {
      entries = [
        _ctxMenuItem('open', Icons.folder_open, '打开'),
        _ctxMenuItem('packfolder', Icons.folder_zip_outlined, '加密文件夹'),
        _ctxMenuItem('rename', Icons.drive_file_rename_outline, '重命名'),
      ];
    } else if (multi) {
      final hasEnc = _selectedPaths.any((p0) =>
          p0.toLowerCase().endsWith('.wemi') ||
          p0.toLowerCase().endsWith('.kyl'));
      entries = [
        _ctxMenuItem('encryptsel', Icons.lock_outline,
            '加密所选 (${_selectedPaths.length})'),
        if (hasEnc)
          _ctxMenuItem('decryptsel', Icons.lock_open_outlined, '解密所选'),
        _ctxMenuItem('share', Icons.share_outlined, '分享所选 (${_selectedPaths.length})'),
        _ctxMenuItem('move', Icons.drive_file_move_outlined, '移动所选'),
        _ctxMenuItem('copy', Icons.copy_all_outlined, '复制所选'),
        _ctxMenuItem('delete', Icons.delete_outline, '删除所选', color: Colors.red),
      ];
    } else {
      entries = [
        // 加密/解密置顶（对齐 Everything：搜到即可直接操作）
        if (!item.isEncryptedFile)
          _ctxMenuItem('encrypt', Icons.lock_outline, '加密'),
        if (item.isEncryptedFile)
          _ctxMenuItem('decrypt', Icons.lock_open_outlined, '解密'),
        _ctxMenuItem('rename', Icons.drive_file_rename_outline, '重命名'),
        _ctxMenuItem('view', Icons.visibility_outlined, '查看'),
        _ctxMenuItem('systemopen', Icons.open_in_new, '用系统打开'),
        _ctxMenuItem('openfolder', Icons.folder_open, '打开所在路径'),
        const PopupMenuDivider(),
        _ctxMenuItem('copypath', Icons.content_copy, '复制完整路径'),
        const PopupMenuDivider(),
        _ctxMenuItem('delete', Icons.delete_outline, '删除', color: Colors.red),
      ];
    }
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 1, pos.dy + 1),
      items: entries,
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'open':
        _navigateTo(item.fullPath);
        break;
      case 'packfolder':
        await _packFolderWithDialog(item.fullPath);
        break;
      case 'view':
        await _viewFile(item);
        break;
      case 'systemopen':
        final r = await SystemOpenService.open(item.fullPath);
        if (!r.ok && mounted) {
          await SystemOpenService.handleFailure(context, item.fullPath, r);
        }
        break;
      case 'rename':
        await FileBatchOps.rename(context, item.fullPath,
            afterChange: () => _afterBatchChange([item.fullPath]));
        break;
      case 'encrypt':
        _encryptFile(item.fullPath);
        break;
      case 'decrypt':
        await _decryptWithDialog(item);
        break;
      case 'encryptsel':
        // 逐个走单文件加密流程（每个文件确认密码，与手机端「更多」一致）
        for (final f in _selectedPaths.toList()) {
          if (!mounted) return;
          await _encryptFile(f);
        }
        if (mounted) _clearSelection();
        break;
      case 'decryptsel':
        await _decryptSelected();
        break;
      case 'copypath':
        await Clipboard.setData(ClipboardData(text: item.fullPath));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('路径已复制'), duration: Duration(seconds: 1)),
          );
        }
        break;
      case 'openfolder':
        await _revealInFileManager(item.fullPath);
        break;
      case 'share':
        _shareSelected();
        break;
      case 'move':
        _moveSelected();
        break;
      case 'copy':
        _copySelected();
        break;
      case 'delete':
        _deleteSelected();
        break;
    }
  }

  /// 在系统文件管理器中定位文件（对齐 Everything「打开路径」）
  /// Windows: explorer /select；macOS: open -R；Linux: xdg-open 目录；Android: 提示路径
  Future<void> _revealInFileManager(String path) async {
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', ['/select,$path']);
      } else if (Platform.isMacOS) {
        await Process.run('open', ['-R', path]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [p.dirname(path)]);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('所在目录：${p.dirname(path)}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// Ctrl+A：全选当前可见文件
  void _selectAllVisibleFiles() {
    setState(() {
      _selectedPaths
          .addAll([for (final it in _browseItems) if (!it.isDirectory) it.fullPath]);
    });
  }

  Future<void> _deleteSelectedFromKeyboard() async {
    if (_selectedPaths.isEmpty) return;
    await _deleteSelected();
  }

  /// 操作后统一刷新：浏览视图刷新当前目录，根视图失效展开缓存
  Future<void> _afterBatchChange(Iterable<String> touchedPaths) async {
    for (final dir in {for (final p0 in touchedPaths) p.dirname(p0)}) {
      _invalidateDir(dir);
    }
    if (_currentPath.isNotEmpty) {
      _navigateTo(_currentPath);
    } else {
      setState(() {});
    }
  }

  Future<void> _shareSelected() async {
    await FileBatchOps.share(context, _selectedPaths.toList());
  }

  Future<void> _copySelected() async {
    await FileBatchOps.copyTo(context, _selectedPaths.toList(),
        afterChange: () async {});
  }

  Future<void> _moveSelected() async {
    final paths = _selectedPaths.toList();
    await FileBatchOps.moveTo(context, paths,
        afterChange: () => _afterBatchChange(paths));
    if (mounted) _clearSelection();
  }

  Future<void> _deleteSelected() async {
    final paths = _selectedPaths.toList();
    await FileBatchOps.delete(context, paths,
        afterChange: () => _afterBatchChange(paths));
    if (mounted) _clearSelection();
  }

  /// 从路径构造 FileItem（批量解密补问时复用单文件流程）
  Future<FileItem> _fileItemOf(String path) async {
    int size = 0;
    DateTime? modified;
    try {
      final st = await File(path).stat();
      size = st.size;
      modified = st.modified;
    } catch (_) {}
    return FileItem(
      name: p.basename(path),
      fullPath: path,
      isDirectory: false,
      size: size,
      modified: modified,
    );
  }

  /// 批量解密选中的加密文件（.wemi/.kyl）：问一次密码 + 选一次输出目录，
  /// 逐个解；密码不一致的文件逐个补问（对齐保险箱「批量补密码」体验）
  Future<void> _decryptSelected() async {
    final targets = _selectedPaths
        .where((p0) =>
            p0.toLowerCase().endsWith('.wemi') ||
            p0.toLowerCase().endsWith('.kyl'))
        .toList();
    if (targets.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('选中的文件里没有加密文件（.wemi）')));
      }
      return;
    }
    if (targets.length == 1) {
      await _decryptWithDialog(await _fileItemOf(targets.first));
      if (mounted) _clearSelection();
      return;
    }
    final hint = await EncryptionService.getPasswordHint(targets.first);
    final password = await _showPasswordDialog(hint: hint);
    if (password == null || !mounted) return;
    final outputDir = await FileOperationsService.pickOutputDirectory();
    if (outputDir == null || !mounted) return;

    final failed = <String>[];
    for (final f in targets) {
      if (!mounted) return;
      try {
        await FileOperationsService.decryptFile(f, outputDir, password);
      } catch (_) {
        failed.add(f);
      }
    }
    if (!mounted) return;
    var msg = '解密完成：成功 ${targets.length - failed.length} 个';
    if (failed.isNotEmpty) {
      var recovered = 0;
      for (final f in failed) {
        if (!mounted) break;
        try {
          await _decryptWithDialog(await _fileItemOf(f));
          recovered++;
        } catch (_) {}
      }
      msg += '，密码不一致已逐个补问（成功 $recovered/${failed.length}）';
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    _clearSelection();
  }

  Future<void> _moreSelected() async {
    final single = _selectedPaths.length == 1 ? _selectedPaths.first : null;
    final hasEncrypted = _selectedPaths.any((p0) =>
        p0.toLowerCase().endsWith('.wemi') ||
        p0.toLowerCase().endsWith('.kyl'));
    final action = await FileBatchOps.moreSheet(context,
        single: single != null, hasEncrypted: hasEncrypted);
    if (action == null || !mounted) return;
    switch (action) {
      case 'info':
        await FileBatchOps.info(context, single!);
        break;
      case 'rename':
        await FileBatchOps.rename(context, single!,
            afterChange: () => _afterBatchChange([single]));
        if (mounted) _clearSelection();
        break;
      case 'encrypt':
        if (single != null) {
          _encryptFile(single);
        } else {
          // 多选加密：逐个走单文件加密流程（每个文件都要确认密码）
          for (final f in _selectedPaths.toList()) {
            if (!mounted) return;
            await _encryptFile(f);
          }
        }
        if (mounted) _clearSelection();
        break;
      case 'decrypt':
        await _decryptSelected();
        break;
      case 'systemopen':
        // 逐个调系统打开（多选时可能弹多个窗口，用户预期内）；
        // 失败只兜底第一个，避免弹窗叠弹窗
        for (final f in _selectedPaths.toList()) {
          final r = await SystemOpenService.open(f);
          if (!r.ok && mounted) {
            await SystemOpenService.handleFailure(context, f, r);
            break;
          }
        }
        if (mounted) _clearSelection();
        break;
    }
  }

  /// 使目录展开缓存失效（存在则移除，保持折叠状态时下次展开重新读取）
  void _invalidateDir(String dir) {
    _dirChildren.remove(dir);
  }

  /// 当前界面可见、可参与多选的文件路径（不含文件夹）
  Iterable<String> _visibleSelectableFiles() sync* {
    if (_currentPath.isNotEmpty) {
      for (final item in _items) {
        if (!item.isDirectory) yield item.fullPath;
      }
    } else {
      for (final children in _dirChildren.values) {
        if (children == null) continue;
        for (final item in children) {
          if (!item.isDirectory) yield item.fullPath;
        }
      }
    }
  }

  Future<Map<String, String?>?> _showEncryptPasswordDialog() async {
    final passwordController = TextEditingController();
    final confirmController = TextEditingController();
    final hintController = TextEditingController();

    return showDialog<Map<String, String?>>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('设置密码'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: passwordController, obscureText: true, maxLength: 32, decoration: const InputDecoration(labelText: '密码')),
              const SizedBox(height: 16),
              TextField(controller: confirmController, obscureText: true, maxLength: 32, decoration: const InputDecoration(labelText: '确认密码')),
              const SizedBox(height: 16),
              TextField(controller: hintController, decoration: const InputDecoration(labelText: '密码提示词（可选）')),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
            TextButton(
              onPressed: () {
                if (passwordController.text.isEmpty || passwordController.text != confirmController.text) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('密码不一致')));
                  return;
                }
                Navigator.pop(context, {
                  'password': passwordController.text,
                  'hint': hintController.text.isNotEmpty ? hintController.text : null,
                });
              },
              child: const Text('确认'),
            ),
          ],
        );
      },
    );
  }

  Future<String?> _showPasswordDialog({String? hint}) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('输入密码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hint != null && hint.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text('提示: $hint', style: const TextStyle(color: Colors.blue)),
              ),
            TextField(controller: controller, obscureText: true, maxLength: 32, decoration: const InputDecoration(labelText: '密码')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('确认')),
        ],
      ),
    );
  }

  // ============ UI 构建 ============

  @override
  Widget build(BuildContext context) {
    final isDesktop = !Platform.isAndroid && !Platform.isIOS;
    final isRoot = _currentPath.isEmpty;

    return Scaffold(
      // 根视图不显示内层标题栏（外层 AppBar 直接接搜索框）；浏览子目录时保留前进/后退
      appBar: _selecting
          ? AppBar(
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: _clearSelection,
              ),
              title: Text('已选择 ${_selectedPaths.length} 项'),
              actions: [
                TextButton(
                  onPressed: () =>
                      _selectAllVisible(_visibleSelectableFiles()),
                  child: const Text('全选'),
                ),
              ],
            )
          : (isRoot
              ? null
              : AppBar(
                  title: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_titleFor(_currentPath, isRoot),
                          style: const TextStyle(fontSize: 16)),
                      if (_currentPath != kMyComputerPath)
                        _buildBreadcrumb(_currentPath),
                    ],
                  ),
                  leading: _historyIndex > 0
                      ? IconButton(
                          icon: const Icon(Icons.arrow_back),
                          onPressed: _goBack)
                      : null,
                  actions: [
                    if (_historyIndex < _pathHistory.length - 1)
                      IconButton(
                          icon: const Icon(Icons.arrow_forward),
                          onPressed: _goForward),
                    IconButton(
                      icon: const Icon(Icons.sort),
                      tooltip: '排序',
                      onPressed: _showSortSheet,
                    ),
                  ],
                )),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Focus(
              autofocus: true,
              child: CallbackShortcuts(
                bindings: _isDesktop
                    ? {
                        const SingleActivator(LogicalKeyboardKey.keyA, control: true):
                            _selectAllVisibleFiles,
                        const SingleActivator(LogicalKeyboardKey.delete):
                            _deleteSelectedFromKeyboard,
                        const SingleActivator(LogicalKeyboardKey.f2):
                            _renameFromKeyboard,
                        const SingleActivator(LogicalKeyboardKey.f5):
                            _refreshFromKeyboard,
                      }
                    : const {},
                child: Column(
                  children: [
                    // 固定顶部搜索框（根视图与浏览视图都显示）
                    if (!_selecting) _buildFileSearchField(),
                    // 预设类型宏筛选条（有查询词时才显示，点击即改查询串）
                    if (!_selecting && _fileQuery.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: SearchMacroBar(
                          query: _fileQuery,
                          onQuery: (q) {
                            _fileSearchCtrl.text = q;
                            _fileSearchCtrl.selection =
                                TextSelection.collapsed(offset: q.length);
                          },
                        ),
                      ),
                    // 搜索历史面板（聚焦搜索框且无输入时展示）
                    if (!_selecting) _buildSearchHistoryPanel(),
                    // 当前类型筛选提示（点击 × 清除）
                    if (!_selecting && _filterCat != null)
                      _buildActiveFilterChip(),
                    Expanded(
                      child: _globalResults != null
                          ? _buildFileList()
                          : (isRoot
                              ? _buildRootView()
                              : (_items.isEmpty
                                  ? _emptyState
                                  : _buildFileList())),
                    ),
                    // 状态栏（资源管理器底栏习惯；根视图无路径概念不显示）
                    if (_globalResults != null || !isRoot) _buildStatusBar(),
                  ],
                ),
              ),
            ),
      bottomSheet: _selecting && !_loading
          ? FileSelectionBar(
              count: _selectedPaths.length,
              onShare: _shareSelected,
              onMove: _moveSelected,
              onCopy: _copySelected,
              onDelete: _deleteSelected,
              onMore: _moreSelected,
            )
          : null,
      floatingActionButton: !isRoot && isDesktop
          ? FloatingActionButton.extended(
              onPressed: () => _showAddDialog(),
              icon: const Icon(Icons.add),
              label: const Text('新建'),
            )
          : null,
    );
  }

  /// 文件页固定搜索框：有查询词时手机/PC 均直接全盘搜索（结果替换列表），无独立窗口
  Widget _buildFileSearchField() {
    return ValueListenableBuilder<int?>(
      valueListenable: DiskIndexService.countNotifier,
      builder: (context, count, _) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        controller: _fileSearchCtrl,
        focusNode: _searchFocusNode,
        onTap: _onSearchTap,
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SearchOptsButton(
                currentQuery: _fileQuery,
                onChanged: (_) {
                  // 菜单开关变更即重搜（空词不搜）
                  if (_fileQuery.isNotEmpty) {
                    _fileDebounce?.cancel();
                    _fileDebounce = Timer(
                        const Duration(milliseconds: 50), _runFileGlobalSearch);
                  }
                },
                onApplyFilter: (f) async {
                  // 应用筛选器：灌查询词 + 持久化其开关 + 重搜
                  _fileSearchCtrl.text = f.query;
                  _fileSearchCtrl.selection = TextSelection.collapsed(
                      offset: f.query.length);
                  await SearchOpts.save(f.toOpts());
                  if (!mounted) return;
                  setState(() => _fileQuery = f.query);
                  _fileDebounce?.cancel();
                  _fileDebounce = Timer(
                      const Duration(milliseconds: 50), _runFileGlobalSearch);
                },
              ),
              IconButton(
                icon: Icon(
                  _filterCat == null
                      ? Icons.filter_list_outlined
                      : Icons.filter_alt,
                  size: 20,
                  color: _filterCat == null ? null : Colors.blue,
                ),
                tooltip: '按类型筛选',
                onPressed: _showFilterSheet,
              ),
              if (_fileQuery.isNotEmpty)
                (_globalSearching
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _fileDebounce?.cancel();
                          _fileSearchCtrl.clear();
                          setState(() {
                            _fileQuery = '';
                            _globalResults = null;
                          });
                        },
                      )),
            ],
          ),
          hintText: count == null
              ? '搜索全盘文件（毫秒级匹配）'
              : '搜索全盘文件（$count个文件）',
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
        ),
        onChanged: _onFileSearchChanged,
      ),
      ),
    );
  }

  /// 搜索框下方的筛选状态条
  Widget _buildActiveFilterChip() {
    final cat = _filterCat!;
    final label = _filterExts.isEmpty
        ? FilterMeta.labels[cat]!
        : '${FilterMeta.labels[cat]} · ${_filterExts.length} 种格式';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Row(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: _showFilterSheet,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.blue.withValues(alpha: 0.4)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(FilterMeta.icons[cat],
                      size: 14, color: Colors.blue),
                  const SizedBox(width: 4),
                  Text(label,
                      style: const TextStyle(
                          fontSize: 12, color: Colors.blue)),
                  const SizedBox(width: 4),
                  GestureDetector(
                    onTap: () => setState(() {
                      _filterCat = null;
                      _filterExts = {};
                    }),
                    child: const Icon(Icons.close,
                        size: 14, color: Colors.blue),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 根视图：搜索框 + 快捷操作卡 + 常用目录（含全部文件）+ 我的目录（加密目录 + 添加目录）
  Widget _buildRootView() {
    final entries = _buildRootEntries();
    final builtin = entries.where((e) => !e.isCustom).toList();
    final customs = entries.where((e) => e.isCustom).toList();

    // 搜索过滤：有查询词时，只显示匹配的展开子项
    final q = _fileQuery.toLowerCase();
    bool matchChild(FileItem it) =>
        q.isEmpty || it.name.toLowerCase().contains(q);

    Widget section({
      required String title,
      required bool open,
      required ValueChanged<bool> onToggle,
      required List<Widget> children,
    }) {
      return Column(
        children: [
          InkWell(
            onTap: () => onToggle(!open),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Row(
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey.shade600,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    open ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: Colors.grey,
                  ),
                ],
              ),
            ),
          ),
          if (open) ...children,
        ],
      );
    }

    return Scrollbar(
      controller: _rootScroll,
      thumbVisibility: true, // 滚动条常显（含移动端）
      interactive: true,
      child: ListView(
        controller: _rootScroll,
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (Platform.isAndroid && !_storageGranted) _permissionBanner,
          // 快捷操作：加密 / 解密 / 微密飞传
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: _actionCard(
                    icon: Icons.lock,
                    label: '加密文件',
                    color: Colors.orange,
                    onTap: () =>
                        widget.onEncryptFiles?.call() ?? _pickAndEncrypt(),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _actionCard(
                    icon: Icons.lock_open,
                    label: '解密文件',
                    color: Colors.green,
                    onTap: () =>
                        widget.onDecryptFiles?.call() ?? _pickAndDecrypt(),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _actionCard(
                    icon: Icons.lan_outlined,
                    label: '微密飞传',
                    color: Colors.teal,
                    onTap: _openLanTransfer,
                  ),
                ),
              ],
            ),
          ),
          section(
            title: '常用目录',
            open: _commonOpen,
            onToggle: (v) => _setSectionOpen(mine: false, open: v),
            children: [
              // 全部文件/我的电脑入口（像手机文件管理器，浏览设备全部文件）
              ListTile(
                leading: Icon(
                  Platform.isAndroid ? Icons.apps : Icons.computer,
                  color: Colors.deepPurple,
                ),
                title: Text(Platform.isAndroid ? '我的手机' : '我的电脑',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(
                  Platform.isAndroid
                      ? '/storage/emulated/0'
                      : '所有磁盘与分区',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                ),
                trailing:
                    const Icon(Icons.chevron_right, color: Colors.grey),
                onTap: () => _navigateTo(Platform.isAndroid
                    ? '/storage/emulated/0'
                    : kMyComputerPath),
              ),
              for (final d in builtin) _buildDirTile(d, filterQuery: q),
            ],
          ),
          section(
            title: '我的目录',
            open: _mineOpen,
            onToggle: (v) => _setSectionOpen(mine: true, open: v),
            children: [
              // 微密保险箱入口（设置页「在我的目录显示保险箱入口」可隐藏）
              if (_showVaultEntry)
                ListTile(
                  leading: const Icon(Icons.lock_outline,
                      color: Colors.deepOrange),
                  title: const Text('微密保险箱',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: const Text('主密码门禁 + 文件密码库 + 缩略图',
                      style: TextStyle(fontSize: 11)),
                  trailing:
                      const Icon(Icons.chevron_right, color: Colors.grey),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (context) => const VaultBrowserScreen()),
                    );
                  },
                ),
              for (final d in customs) _buildDirTile(d, filterQuery: q),
              ListTile(
                leading: Icon(Icons.add_circle_outline,
                    color: Colors.blue.shade700),
                title: const Text('添加目录'),
                subtitle: const Text('选择手机/电脑上的任意文件夹加入列表',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                onTap: _addCustomDir,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 快捷操作卡（与主界面加密/解密同款样式）
  Widget _actionCard({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: color.withAlpha(15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withAlpha(50)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 24, color: color),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openLanTransfer() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const LanTransferScreen()),
    );
  }

  /// 未接主界面回调时的兜底：直接走文件选择 + 本页加密流程
  Future<void> _pickAndEncrypt() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    final files = result?.files.where((f) => f.path != null).toList() ?? [];
    for (final f in files) {
      if (!mounted) return;
      await _encryptFile(f.path!);
    }
  }

  Future<void> _pickAndDecrypt() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    final files = result?.files.where((f) => f.path != null).toList() ?? [];
    for (final f in files) {
      if (!mounted) return;
      final path = f.path!;
      if (!await EncryptionService.isEncryptedFile(path)) continue;
      final hint = await EncryptionService.getPasswordHint(path);
      final password = await _showPasswordDialog(hint: hint);
      if (password == null || !mounted) return;
      _decryptFile(path, password);
    }
  }

  List<_DirEntry> _buildRootEntries() {
    final entries = <_DirEntry>[];

    // 1. 平台常用目录
    if (Platform.isAndroid) {
      const root = '/storage/emulated/0';
      entries.addAll([
        const _DirEntry('下载', '$root/Download', Icons.download_outlined),
        const _DirEntry('文档', '$root/Documents', Icons.description_outlined),
        const _DirEntry('图片', '$root/Pictures', Icons.image_outlined),
        const _DirEntry('相册', '$root/DCIM', Icons.photo_camera_outlined),
        const _DirEntry('音乐', '$root/Music', Icons.music_note_outlined),
        const _DirEntry('视频', '$root/Movies', Icons.movie_outlined),
      ]);
    } else {
      entries.addAll(_desktopDirs);
    }

    // 2. 用户自定义目录
    for (final dirPath in _customDirs) {
      entries.add(_DirEntry(p.basename(dirPath), dirPath, Icons.folder_outlined,
          isCustom: true));
    }
    return entries;
  }

  /// 单个目录条目：默认折叠，点击展开列出其下的文件夹与文件（搜索时过滤子项）
  Widget _buildDirTile(_DirEntry d, {String filterQuery = ''}) {
    final expanded = _expandedDirs.contains(d.dirPath);
    final loading = _dirLoading[d.dirPath] == true;
    final children = _dirChildren[d.dirPath];

    return Column(
      children: [
        ListTile(
          leading: Icon(
            d.icon,
            color: d.isCustom ? Colors.teal : Colors.amber.shade700,
          ),
          title: Text(d.title, style: const TextStyle(fontWeight: FontWeight.w500)),
          subtitle: Text(
            d.dirPath,
            style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (d.isCustom)
                IconButton(
                  icon: const Icon(Icons.close, size: 18, color: Colors.grey),
                  tooltip: '移除',
                  onPressed: () => _removeCustomDir(d.dirPath),
                ),
              if (loading)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  color: Colors.grey,
                ),
            ],
          ),
          onTap: () => _toggleDir(d.dirPath),
        ),
        if (expanded) ..._buildExpandedContent(children, filterQuery),
      ],
    );
  }

  List<Widget> _buildExpandedContent(
      List<FileItem>? children, String filterQuery) {
    if (children == null) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    // 搜索过滤（不区分大小写）+ 类型筛选
    var visible = children;
    if (filterQuery.isNotEmpty) {
      final q = filterQuery.toLowerCase();
      visible =
          visible.where((it) => it.name.toLowerCase().contains(q)).toList();
    }
    if (_filterCat != null) {
      visible = visible.where(_matchFilter).toList();
    }
    if (visible.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Center(
            child: Text('空目录', style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
          ),
        ),
        const Divider(height: 1, indent: 16),
      ];
    }
    // 子项跟随全局视图设置：列表 / 宫格 / 瀑布流
    return [
      AnimatedBuilder(
        animation: ViewPrefsService.instance,
        builder: (context, _) {
          switch (ViewPrefsService.instance.mode) {
            case ViewMode.grid:
              return Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 10, 4),
                child: _buildGridContent(visible, shrinkWrap: true),
              );
            case ViewMode.waterfall:
              _ensureAspect(visible);
              return Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 10, 4),
                child: _buildWaterfallContent(visible, scope: visible),
              );
            case ViewMode.list:
            default:
              return Column(
                children: [
                  for (final item in visible) _buildChildRow(item),
                ],
              );
          }
        },
      ),
      const Divider(height: 1, indent: 16),
    ];
  }

  /// 展开后的子项行（缩进显示）：文件夹点击进入浏览，文件点击走操作菜单
  Widget _buildChildRow(FileItem item) {
    final selectable = !item.isDirectory;
    final selected = selectable && _selectedPaths.contains(item.fullPath);
    return Padding(
      padding: const EdgeInsets.only(left: 24),
      child: GestureDetector(
        onDoubleTap: _isDesktop ? () => _desktopOpen(item) : null,
        onSecondaryTapUp: _isDesktop
            ? (d) => _showContextMenu(item, d.globalPosition, -1, const [])
            : null,
        child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        leading: _selecting && selectable
            ? Icon(
                selected
                    ? Icons.check_box
                    : Icons.check_box_outline_blank,
                size: 20,
                color: selected ? Colors.blue : Colors.grey,
              )
            : Icon(
                item.isDirectory ? Icons.folder : _fileIcon(item),
                size: 20,
                color: item.isDirectory
                    ? Colors.amber.shade700
                    : (item.isEncryptedFile ? Colors.blue : Colors.grey),
              ),
        title: Text(item.name, style: const TextStyle(fontSize: 14)),
        subtitle: !item.isDirectory
            ? Text(item.humanSize,
                style: const TextStyle(fontSize: 11, color: Colors.grey))
            : null,
        trailing: item.isEncryptedFile && !_selecting
            ? const Icon(Icons.lock, size: 14, color: Colors.blue)
            : null,
        onTap: _isDesktop
            ? () => _desktopTap(item, -1, const [])
            : () {
                if (_selecting) {
                  if (selectable) _toggleSelect(item.fullPath);
                } else {
                  _smartOpen(item);
                }
              },
        onLongPress: selectable && !_isDesktop
            ? () => _toggleSelect(item.fullPath)
            : null,
      ),
      ),
    );
  }

  Widget get _emptyState => Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.folder_open, size: 64, color: Colors.grey),
        const SizedBox(height: 16),
        Text(
          _currentPath.isEmpty ? '微密 Vault 目录为空' : '该目录为空',
          style: const TextStyle(color: Colors.grey),
        ),
      ],
    ),
  );

  /// 浏览视图条目：桌面端全盘模式下展示全盘结果，否则本地过滤当前目录。
  /// 统一走 _sortItems 排序（文件夹优先 + 用户排序偏好）。
  List<FileItem> get _browseItems {
    List<FileItem> raw;
    if (_globalResults != null) {
      raw = _filterCat == null
          ? _globalResults!
          : _globalResults!.where(_matchFilter).toList();
    } else if (_fileQuery.isEmpty) {
      raw = _filterCat == null ? _items : _items.where(_matchFilter).toList();
    } else {
      final q = _fileQuery.toLowerCase();
      raw = _items
          .where((it) => it.name.toLowerCase().contains(q))
          .where(_matchFilter)
          .toList();
    }
    return _sortItems(raw);
  }

  /// 文件夹优先，再按 _sortMode/_sortAsc（与常见文件管理器一致）
  List<FileItem> _sortItems(List<FileItem> src) {
    final sorted = [...src];
    sorted.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      int c;
      switch (_sortMode) {
        case 'size':
          c = a.size.compareTo(b.size);
          break;
        case 'time':
          c = (a.modified ?? DateTime(0))
              .compareTo(b.modified ?? DateTime(0));
          break;
        case 'type':
          c = a.ext.compareTo(b.ext);
          break;
        default:
          c = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      }
      return _sortAsc ? c : -c;
    });
    return sorted;
  }

  Widget _buildFileList() {
    final items = _browseItems;
    if (items.isEmpty && _fileQuery.isNotEmpty) {
      return Center(
        child: Text(
            _indexBuilding
                ? '索引可能过期，正在后台刷新，稍后自动重搜…'
                : _globalResults != null
                    ? '全盘没有找到匹配的文件'
                    : '没有匹配的文件',
            style: TextStyle(fontSize: 14, color: Colors.grey.shade500)),
      );
    }
    return Scrollbar(
      thumbVisibility: true, // 文件多时滚动条常显
      interactive: true,
      child: AnimatedBuilder(
        animation: ViewPrefsService.instance,
        builder: (context, _) {
          switch (ViewPrefsService.instance.mode) {
            case ViewMode.grid:
              return _buildGridBody();
            case ViewMode.waterfall:
              return _buildWaterfallBody();
            case ViewMode.list:
            default:
              return ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  final selectable = !item.isDirectory;
                  final selected =
                      selectable && _selectedPaths.contains(item.fullPath);
                  return _FileListItem(
                    item: item,
                    selected: selected,
                    selecting: _selecting,
                    onTap: _isDesktop
                        ? () => _desktopTap(item, index, items)
                        : () {
                            if (_selecting) {
                              if (selectable) _toggleSelect(item.fullPath);
                            } else {
                              _smartOpen(item);
                            }
                          },
                    onDoubleTap:
                        _isDesktop ? () => _desktopOpen(item) : null,
                    onSecondaryTapUp: _isDesktop
                        ? (d) => _showContextMenu(
                            item, d.globalPosition, index, items)
                        : null,
                    onLongPress: selectable && !_isDesktop
                        ? () => _toggleSelect(item.fullPath)
                        : null,
                  );
                },
              );
          }
        },
      ),
    );
  }

  /// 宫格视图（文件夹 + 文件卡片）
  Widget _buildGridBody() {
    return _buildGridContent(_browseItems);
  }

  /// 宫格内容块：浏览页可滚动；目录展开区 shrinkWrap 嵌入
  Widget _buildGridContent(List<FileItem> items, {bool shrinkWrap = false}) {
    return GridView.builder(
      physics: shrinkWrap
          ? const NeverScrollableScrollPhysics()
          : const AlwaysScrollableScrollPhysics(),
      shrinkWrap: shrinkWrap,
      padding: const EdgeInsets.all(10),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: _gridExtentFor(ViewPrefsService.instance.thumbSize),
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 0.78,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) => _buildCard(items[i], null, index: i, scope: items),
    );
  }

  /// 瀑布流视图（两列，图片按宽高比）
  Widget _buildWaterfallBody() {
    final items = _browseItems;
    _ensureAspect(items);
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(10),
      child: _buildWaterfallContent(items, scope: items),
    );
  }

  /// 图片比例未缓存的先异步解码，完成后刷新
  void _ensureAspect(List<FileItem> items) {
    final missing = items
        .where((it) =>
            !it.isDirectory &&
            FileThumbs.isImage(it.name) &&
            !FileThumbs.aspectCache.containsKey(it.fullPath))
        .toList();
    if (missing.isNotEmpty && !_aspectRefreshing) {
      _aspectRefreshing = true;
      Future.wait(missing.take(60).map((it) =>
              FileThumbs.aspectRatio(it.fullPath)))
          .then((_) {
        _aspectRefreshing = false;
        if (mounted) setState(() {});
      });
    }
  }

  /// 瀑布流内容块（两列 Row），浏览页与目录展开区共用
  Widget _buildWaterfallContent(List<FileItem> items,
      {List<FileItem> scope = const []}) {
    final colWidth = _waterfallWidthFor(ViewPrefsService.instance.thumbSize);
    final colA = <FileItem>[];
    final colB = <FileItem>[];
    final hA = <FileItem, double>{};
    final hB = <FileItem, double>{};
    double sumA = 0, sumB = 0;
    for (final it in items) {
      final ratio =
          it.isDirectory ? null : FileThumbs.aspectCache[it.fullPath];
      final thumbH = it.isDirectory
          ? 120.0
          : ratio == null || ratio <= 0
              ? 160.0
              : (colWidth / ratio).clamp(120.0, 320.0);
      final itemH = thumbH + 52;
      if (sumA <= sumB) {
        colA.add(it);
        hA[it] = thumbH;
        sumA += itemH;
      } else {
        colB.add(it);
        hB[it] = thumbH;
        sumB += itemH;
      }
    }

    Widget col(List<FileItem> items, Map<FileItem, double> hs) {
      return Expanded(
        child: Column(
          children: [
            for (final it in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _buildCard(it, hs[it] ?? 160,
                    index: scope.indexOf(it), scope: scope),
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

  /// 文件/文件夹卡片（宫格与瀑布流共用）
  Widget _buildCard(FileItem item, double? thumbHeight,
      {int index = -1, List<FileItem> scope = const []}) {
    final selectable = !item.isDirectory;
    final selected = selectable && _selectedPaths.contains(item.fullPath);

    Widget thumbArea;
    // 缩略图区底色：contain 模式下横竖图留白的背板（随主题明暗自适应）
    final thumbBg = Theme.of(context).colorScheme.surfaceContainerHighest;
    if (item.isDirectory) {
      thumbArea = Icon(
        Icons.folder,
        size: 56,
        color: Colors.amber.shade600,
      );
    } else if (thumbHeight != null) {
      // 瀑布流：固定高度容器内等比缩放完整显示（不裁切）
      thumbArea = Container(
        color: thumbBg,
        child: SizedBox(
          width: double.infinity,
          height: thumbHeight,
          child: FileThumbnail(
            path: item.fullPath,
            name: item.name,
            size: 64,
            fit: BoxFit.contain,
          ),
        ),
      );
    } else {
      // 宫格：图片区撑满卡片宽，contain 不裁切
      thumbArea = ColoredBox(
        color: thumbBg,
        child: FileThumbnail(
          path: item.fullPath,
          name: item.name,
          size: 72,
          fit: BoxFit.contain,
        ),
      );
    }

    final Widget imageSection = thumbHeight != null
        ? ClipRRect(
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(9)),
            child: thumbArea,
          )
        : Expanded(
            child: Center(child: thumbArea),
          );

    return InkWell(
      onTap: _isDesktop
          ? () => _desktopTap(item, index, scope)
          : () {
              if (_selecting) {
                if (selectable) _toggleSelect(item.fullPath);
              } else {
                _smartOpen(item);
              }
            },
      onDoubleTap: _isDesktop ? () => _desktopOpen(item) : null,
      onSecondaryTapUp: _isDesktop
          ? (d) => _showContextMenu(item, d.globalPosition, index, scope)
          : null,
      onLongPress: selectable && !_isDesktop
          ? () => _toggleSelect(item.fullPath)
          : null,
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
            imageSection,
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight:
                          item.isDirectory ? FontWeight.w500 : null,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    item.isDirectory ? '文件夹' : item.humanSize,
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

  void _showAddDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder),
              title: const Text('新建文件夹'),
              onTap: () {
                Navigator.pop(ctx);
                _createFolder();
              },
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file),
              title: const Text('新建文件'),
              onTap: () {
                Navigator.pop(ctx);
                _createFile();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createFolder() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建文件夹'),
        content: TextField(controller: controller, decoration: const InputDecoration(hintText: '文件夹名称')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('创建')),
        ],
      ),
    );
    if (result == null || result.isEmpty || !mounted) return;

    try {
      await Directory(p.join(_currentPath, result)).create();
      _navigateTo(_currentPath);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('创建失败: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _createFile() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建文件'),
        content: TextField(controller: controller, decoration: const InputDecoration(hintText: '文件名（含扩展名）')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('创建')),
        ],
      ),
    );
    if (result == null || result.isEmpty || !mounted) return;

    try {
      await File(p.join(_currentPath, result)).create();
      _navigateTo(_currentPath);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('创建失败: $e'), backgroundColor: Colors.red),
      );
    }
  }
}

/// 按扩展名取文件图标
IconData _fileIcon(FileItem item) {
  final ext = item.ext;
  if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic'].contains(ext)) {
    return Icons.image;
  }
  if (['mp4', 'avi', 'mkv', 'mov', 'wmv', 'flv'].contains(ext)) {
    return Icons.videocam;
  }
  if (['mp3', 'wav', 'flac', 'aac', 'm4a', 'ogg'].contains(ext)) {
    return Icons.audiotrack;
  }
  if (ext == 'pdf') return Icons.picture_as_pdf;
  if (['txt', 'md', 'json', 'xml', 'csv', 'yaml', 'log'].contains(ext)) {
    return Icons.text_snippet;
  }
  return Icons.insert_drive_file;
}

/// 文件列表行
class _FileListItem extends StatelessWidget {
  final FileItem item;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onDoubleTap;
  final GestureTapUpCallback? onSecondaryTapUp;
  final bool selected;
  final bool selecting;

  const _FileListItem({
    required this.item,
    required this.onTap,
    this.onLongPress,
    this.onDoubleTap,
    this.onSecondaryTapUp,
    this.selected = false,
    this.selecting = false,
  });

  @override
  Widget build(BuildContext context) {
    final showCheck = selecting && !item.isDirectory;
    final Widget leading;
    if (showCheck) {
      leading = Icon(
        selected ? Icons.check_box : Icons.check_box_outline_blank,
        color: selected ? Colors.blue : Colors.grey,
      );
    } else if (item.isDirectory) {
      leading = const Icon(Icons.folder, color: Colors.amber);
    } else {
      // SizedBox 必须给：FileThumbnail 的 contain 分支本身无边界
      // （宫格/瀑布流由父容器约束），放进 ListTile leading 会把行撑爆，
      // 文件名被挤成单字符竖排——只在纯图片文件夹的列表视图出现
      final ts = _listThumbFor(ViewPrefsService.instance.thumbSize);
      leading = SizedBox(
        width: ts,
        height: ts,
        child: FileThumbnail(
          path: item.fullPath,
          name: item.name,
          size: ts,
          fit: BoxFit.contain,
        ),
      );
    }
    return GestureDetector(
      onDoubleTap: onDoubleTap,
      onSecondaryTapUp: onSecondaryTapUp,
      child: ListTile(
      leading: leading,
      title: Text(
        item.name,
        style: TextStyle(fontWeight: item.isDirectory ? FontWeight.w500 : null),
      ),
      subtitle: !item.isDirectory ? Text(item.humanSize, style: const TextStyle(fontSize: 12, color: Colors.grey)) : null,
      trailing: item.isEncryptedFile && !selecting
          ? const Icon(Icons.lock, size: 16, color: Colors.blue)
          : null,
      onTap: onTap,
      onLongPress: onLongPress,
      ),
    );
  }
}

/// 归档打包/解包进度对话框：轮询 Rust 侧原子计数器（明文字节）。
/// 后台任务跑在 isolate，UI 线程空闲，轮询可正常刷新。
class _ArchiveProgressDialog extends StatefulWidget {
  final String title;
  const _ArchiveProgressDialog({required this.title});

  @override
  State<_ArchiveProgressDialog> createState() => _ArchiveProgressDialogState();
}

class _ArchiveProgressDialogState extends State<_ArchiveProgressDialog> {
  Timer? _timer;
  int _done = 0;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 400), (_) => _poll());
    _poll();
  }

  void _poll() {
    final p = EncryptionService.archiveProgress();
    if (!mounted) return;
    setState(() {
      _done = p.done;
      _total = p.total;
    });
  }

  String _fmt(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = _total > 0 ? _done / _total : null;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(widget.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(value: value),
            const SizedBox(height: 14),
            Text(
              value != null ? '已处理 ${_fmt(_done)} / ${_fmt(_total)}' : '准备中…',
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 6),
            Text(
              '大文件夹耗时较长，请勿关闭窗口',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
            ),
          ],
        ),
      ),
    );
  }
}
