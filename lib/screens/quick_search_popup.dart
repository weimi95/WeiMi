import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart' as fp;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../framework/module_registry.dart';
import '../framework/setting_store.dart';
import '../services/disk_index_service.dart';
import '../services/quick_launch_service.dart';
import '../services/quick_search_window.dart';
import '../services/search_history_service.dart';
import '../services/system_open_service.dart';
import '../widgets/file_thumbnail.dart';
import 'package:url_launcher/url_launcher.dart';

/// 快捷搜索浮窗（双击 Ctrl 呼出）。
///
/// 交互仿 Lertaro：
/// - 刚呼出只有一条搜索框（窄条窗口），输入内容后展开成完整结果窗；
/// - 结果一屏 9 条，滚轮按页翻（9 条一起换），Ctrl+1..9 直接打开对应条目，
///   Ctrl+G 打开选中项所在文件夹；
/// - 结果末尾固定一个「去主界面展示全部结果」引导位（带词跳主界面）；
/// - 搜索框聚焦且无输入时显示搜索历史（条数见设置 qs_history_limit）。
///
/// 搜索直接复用全盘索引（DiskIndexService.search）；
/// 文件动作从模块注册表取（ModuleRegistry.actionsFor）——
/// 与设置中心同源，新增动作零改动本页。
class QuickSearchPopup extends StatefulWidget {
  const QuickSearchPopup({super.key});

  @override
  State<QuickSearchPopup> createState() => _QuickSearchPopupState();
}

class _Hit {
  _Hit(this.path);
  final String path;
  late final String name = p.basename(path);
  late final String dir = p.dirname(path);
  bool get isEncrypted => path.toLowerCase().endsWith('.wemi');
}

class _QuickSearchPopupState extends State<QuickSearchPopup> {
  static const int _rowsPerPage = 9;
  static const double _rowHeight = 39.0;

  final TextEditingController _controller = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  final FocusNode _keyboardFocus = FocusNode();

  List<_Hit> _hits = [];
  int _selected = -1; // 连续索引：0..totalItems-1（最后一个 = 引导位）
  int _page = 0;
  bool _searching = false;
  bool _indexReady = false;
  bool _focused = false; // 点击搜索框后进搜索视图；呼出默认显示常用网格
  bool _showHistory = false; // 搜索视图里聚焦且无输入时展示搜索历史
  List<String> _history = [];
  List<QuickLaunchItem> _quickLaunch = [];
  Timer? _debounce;
  Directory? _iconDir; // 快捷项图标缓存目录
  final Map<String, Future<String?>> _iconFuts = {}; // target → 图标解析

  int get _guideIndex => _hits.length; // 引导位紧跟最后一条结果
  int get _totalItems => _hits.isEmpty ? 0 : _hits.length + 1;
  int get _maxPage => _totalItems <= 0 ? 0 : (_totalItems - 1) ~/ _rowsPerPage;

  /// 搜索视图：点了搜索框或有输入词；否则显示常用软件/网址网格
  bool get _searchMode =>
      _focused || _controller.text.trim().isNotEmpty;

  /// 浮窗固定展开（空态显示常用网格，需要完整高度；不再有窄条态）
  bool get _expanded => true;

  @override
  void initState() {
    super.initState();
    _indexReady = DiskIndexService.isBuilt;
    if (!_indexReady) {
      unawaited(DiskIndexService.prepareIndex().then((_) {
        if (mounted) setState(() => _indexReady = true);
      }));
    }
    _controller.addListener(_onQueryChanged);
    _inputFocus.addListener(_onFocusChanged);
    unawaited(_reloadHistory());
    unawaited(_reloadQuickLaunch());
    unawaited(() async {
      try {
        final base = await getApplicationSupportDirectory();
        final dir =
            Directory('${base.path}${Platform.pathSeparator}quick_launch_icons');
        if (!dir.existsSync()) dir.createSync(recursive: true);
        if (mounted) setState(() => _iconDir = dir);
      } catch (_) {}
    }());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.removeListener(_onQueryChanged);
    _controller.dispose();
    _inputFocus.removeListener(_onFocusChanged);
    _inputFocus.dispose();
    _keyboardFocus.dispose();
    super.dispose();
  }

  Future<void> _reloadHistory() async {
    final list = await SearchHistoryService.load();
    if (mounted) setState(() => _history = list);
  }

  Future<void> _reloadQuickLaunch() async {
    final list = await QuickLaunchService.load();
    if (mounted) setState(() => _quickLaunch = list);
  }

  Future<void> _openQuickLaunch(QuickLaunchItem item) async {
    if (item.url) {
      final uri = Uri.tryParse(item.target);
      if (uri != null) {
        try {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } catch (_) {}
      }
      return;
    }
    unawaited(SystemOpenService.open(item.target));
  }

  Future<void> _showQuickLaunchMenu(
      QuickLaunchItem? item, int? index, TapUpDetails d) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final pos = RelativeRect.fromLTRB(
      d.globalPosition.dx,
      d.globalPosition.dy,
      overlay.size.width - d.globalPosition.dx,
      overlay.size.height - d.globalPosition.dy,
    );
    final action = await showMenu<String>(
      context: context,
      position: pos,
      items: [
        if (item != null)
          const PopupMenuItem(value: 'open', child: Text('打开')),
        if (item != null)
          const PopupMenuItem(value: 'edit', child: Text('编辑')),
        if (item != null)
          const PopupMenuItem(value: 'remove', child: Text('删除')),
        const PopupMenuItem(value: 'add', child: Text('添加快捷项')),
      ],
    );
    if (!mounted || action == null) return;
    if (action == 'open' && item != null) return _openQuickLaunch(item);
    if (action == 'remove' && index != null) {
      await QuickLaunchService.remove(index);
      await _reloadQuickLaunch();
      return;
    }
    if (action == 'edit' && item != null && index != null) {
      final edited = await _editQuickLaunchDialog(item);
      if (edited != null) {
        await QuickLaunchService.update(index, edited);
        await _reloadQuickLaunch();
      }
      return;
    }
    if (action == 'add') {
      final created = await _editQuickLaunchDialog(null);
      if (created != null) {
        await QuickLaunchService.add(created);
        await _reloadQuickLaunch();
      }
    }
  }

  /// 添加 / 编辑快捷项弹窗（item=null 为添加）。
  Future<QuickLaunchItem?> _editQuickLaunchDialog(
      QuickLaunchItem? item) async {
    final nameCtrl = TextEditingController(text: item?.name ?? '');
    final targetCtrl = TextEditingController(text: item?.target ?? '');
    final formKey = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(item == null ? '添加快捷项' : '编辑快捷项'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                    labelText: '名称', hintText: '如：记事本、百度'),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? '请输入名称' : null,
              ),
              TextFormField(
                controller: targetCtrl,
                decoration: InputDecoration(
                  labelText: '路径或网址',
                  hintText: r'如 C:\Windows\notepad.exe 或 https://…',
                  suffixIcon: IconButton(
                    tooltip: '浏览文件',
                    icon: const Icon(Icons.folder_open, size: 20),
                    onPressed: () async {
                      try {
                        // 系统文件选择器会抢走焦点：抑制浮窗「失焦即收」，
                        // 否则浮窗连同上层的添加对话框一起被收掉、选择结果丢失
                        WindowModeService.suppressBlurHide = true;
                        final res = await fp.FilePicker.platform
                            .pickFiles(type: fp.FileType.any);
                        final path = res?.files.single.path;
                        if (path == null || path.isEmpty) return;
                        targetCtrl.text = path;
                        if (nameCtrl.text.trim().isEmpty) {
                          nameCtrl.text = p.basenameWithoutExtension(path);
                        }
                      } catch (_) {} finally {
                        // 留一点余量，等失焦事件走完再恢复
                        Future.delayed(const Duration(milliseconds: 400), () {
                          WindowModeService.suppressBlurHide = false;
                        });
                      }
                    },
                  ),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? '请输入路径或网址' : null,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() ?? false) {
                  Navigator.pop(ctx, true);
                }
              },
              child: const Text('确定')),
        ],
      ),
    );
    if (ok != true) return null;
    return QuickLaunchItem(
        name: nameCtrl.text.trim(),
        target: QuickLaunchService.normalizeTarget(targetCtrl.text));
  }

  /// 空态主体：常用软件 / 常用网址网格（点击搜索框或输入后切搜索视图）。
  /// 支持把 .lnk/.exe 等文件直接拖进来添加；右键条目编辑/删除，右键空白/末尾「添加」格新增。
  Widget _buildLaunchGrid(ThemeData theme) {
    final items = _quickLaunch;
    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.launch_rounded, size: 40, color: theme.hintColor),
            const SizedBox(height: 12),
            Text('把常用软件的快捷方式拖到这里\n或点击下方按钮添加',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: theme.hintColor)),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _addQuickLaunchByDialog(),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加常用'),
            ),
          ],
        ),
      );
    }
    return SingleChildScrollView(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapUp: (d) => _showQuickLaunchMenu(null, null, d),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 0; i < items.length; i++)
                _buildLaunchTile(theme, items[i], i),
              _buildLaunchAddTile(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLaunchTile(ThemeData theme, QuickLaunchItem it, int index) {
    return GestureDetector(
      onSecondaryTapUp: (d) => _showQuickLaunchMenu(it, index, d),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _openQuickLaunch(it),
        child: Container(
          width: 88,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: theme.dividerColor, width: 0.5),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 32,
                height: 32,
                child: _launchIcon(theme, it),
              ),
              const SizedBox(height: 4),
              Text(
                it.name,
                style: const TextStyle(fontSize: 11),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLaunchAddTile(ThemeData theme) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _addQuickLaunchByDialog(),
      child: Container(
        width: 88,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: theme.dividerColor, width: 0.5),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add,
                size: 30, color: theme.colorScheme.primary),
            const SizedBox(height: 6),
            Text('添加',
                style: TextStyle(
                    fontSize: 11, color: theme.hintColor)),
          ],
        ),
      ),
    );
  }

  /// 条目图标：网址 favicon / 本地程序系统图标（均落盘缓存），失败用兜底。
  Widget _launchIcon(ThemeData theme, QuickLaunchItem it) {
    final dir = _iconDir;
    Widget fallback() => Icon(
          it.url ? Icons.public : Icons.apps,
          size: 26,
          color: it.url
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        );
    if (dir == null) return fallback();
    final fut = _iconFuts.putIfAbsent(
      it.target,
      () => QuickLaunchService.resolveIcon(it, dir.path),
    );
    return FutureBuilder<String?>(
      future: fut,
      builder: (ctx, snap) {
        final path = snap.data;
        if (path == null || !File(path).existsSync()) return fallback();
        return Image.file(File(path),
            width: 30, height: 30, fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => fallback());
      },
    );
  }

  /// 对话框添加（带浏览按钮选文件/快捷方式）
  Future<void> _addQuickLaunchByDialog() async {
    final created = await _editQuickLaunchDialog(null);
    if (created != null) {
      await QuickLaunchService.add(created);
      await _reloadQuickLaunch();
    }
  }

  /// 拖文件进来 → 逐个加入常用（文件名去后缀作名称）
  Future<void> _addDroppedForLaunch(List<dynamic> files) async {
    var added = 0;
    for (final f in files) {
      try {
        final path = (f.path as String?) ?? '';
        if (path.isEmpty) continue;
        final item = QuickLaunchItem(
          name: p.basenameWithoutExtension(path),
          target: path,
        );
        await QuickLaunchService.add(item);
        added++;
      } catch (_) {}
    }
    if (added > 0) await _reloadQuickLaunch();
  }
  void _onFocusChanged() {
    if (!mounted) return;
    setState(() => _focused = _inputFocus.hasFocus);
    _syncWindowSize();
  }

  void _onQueryChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), _runSearch);
    setState(() {});
    _syncWindowSize();
  }

  /// 窄条（只有搜索框）↔ 完整结果窗
  void _syncWindowSize() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !WindowModeService.instance.isPopup) return;
      unawaited(WindowModeService.instance.setPopupExpanded(_expanded));
    });
  }

  Future<void> _runSearch() async {
    final q = _controller.text.trim();
    if (q.isEmpty) {
      if (!mounted) return;
      setState(() {
        _hits = [];
        _selected = -1;
        _page = 0;
        _searching = false;
      });
      return;
    }
    if (!mounted) return;
    setState(() => _searching = true);
    final limit = SettingStore.get<int>('qs_result_limit', 50);
    final paths = await DiskIndexService.search(q, limit: limit);
    if (!mounted) return;
    setState(() {
      _hits = paths.map(_Hit.new).toList();
      _selected = _hits.isEmpty ? -1 : 0;
      _page = 0;
      _searching = false;
      _indexReady = DiskIndexService.isBuilt;
    });
    _syncWindowSize();
    // 搜索执行后写入历史（纯浏览结果也记，便于下次复用），并刷新本浮窗历史列表
    if (q.isNotEmpty) {
      unawaited(SearchHistoryService.record(q).then((_) {
        if (mounted) unawaited(_reloadHistory());
      }));
    }
  }

  FileActionDef? _findAction(String path, String id) {
    final list = ModuleRegistry.actionsFor(path, contextId: 'quick_popup');
    for (final a in list) {
      if (a.id == id) return a;
    }
    return null;
  }

  void _openMainWithQuery() {
    final q = _controller.text.trim();
    if (q.isNotEmpty) unawaited(SearchHistoryService.record(q));
    unawaited(WindowModeService.instance.openMainWithQuery(q));
  }

  /// 打开指定索引位的条目（>= _guideIndex 即引导位）。
  void _openItem(int index) {
    if (index < 0) return;
    if (index >= _guideIndex) {
      _openMainWithQuery();
      return;
    }
    final path = _hits[index].path;
    unawaited(SearchHistoryService.record(_controller.text));
    final action = _findAction(path, 'qs_open');
    if (action?.onExecute != null) action!.onExecute!(context, path);
  }

  /// Ctrl+G：打开选中项所在文件夹
  void _openFolderOfSelected() {
    if (_selected < 0 || _selected >= _guideIndex) return;
    final path = _hits[_selected].path;
    final action = _findAction(path, 'qs_open_folder');
    if (action?.onExecute != null) action!.onExecute!(context, path);
  }

  void _moveSelection(int delta) {
    if (_totalItems == 0) return;
    var next = (_selected + delta).clamp(0, _totalItems - 1);
    setState(() {
      _selected = next;
      _page = next ~/ _rowsPerPage;
    });
  }

  void _flipPage(int dir) {
    final next = (_page + dir).clamp(0, _maxPage);
    if (next == _page) return;
    setState(() {
      _page = next;
      _selected = next * _rowsPerPage;
      if (_selected >= _totalItems) _selected = _totalItems - 1;
    });
  }

  void _onWheel(double dy) {
    if (_totalItems == 0) return;
    _flipPage(dy > 0 ? 1 : -1);
  }

  /// 当前页要显示的条目（索引连续，含引导位）。
  List<int> get _pageItems {
    if (_totalItems == 0) return const [];
    final start = _page * _rowsPerPage;
    final end = (start + _rowsPerPage).clamp(0, _totalItems);
    return [for (var i = start; i < end; i++) i];
  }

  void _handleKey(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.escape) {
      unawaited(WindowModeService.instance.hidePopup());
    } else if (key == LogicalKeyboardKey.arrowDown) {
      if (_controller.text.trim().isEmpty && !_showHistory) {
        setState(() => _showHistory = true);
        _syncWindowSize();
      } else {
        _moveSelection(1);
      }
    } else if (key == LogicalKeyboardKey.arrowUp) {
      if (_controller.text.trim().isEmpty && !_showHistory) {
        setState(() => _showHistory = true);
        _syncWindowSize();
      } else {
        _moveSelection(-1);
      }
    } else if (key == LogicalKeyboardKey.pageDown) {
      _flipPage(1);
    } else if (key == LogicalKeyboardKey.pageUp) {
      _flipPage(-1);
    } else if (key == LogicalKeyboardKey.enter) {
      _openItem(_selected);
    } else if (key == LogicalKeyboardKey.keyG) {
      if (HardwareKeyboard.instance.isControlPressed) _openFolderOfSelected();
    } else {
      // Ctrl+1..9 快捷打开当前页对应条目
      const digits = [
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.digit2,
        LogicalKeyboardKey.digit3,
        LogicalKeyboardKey.digit4,
        LogicalKeyboardKey.digit5,
        LogicalKeyboardKey.digit6,
        LogicalKeyboardKey.digit7,
        LogicalKeyboardKey.digit8,
        LogicalKeyboardKey.digit9,
      ];
      final idx = digits.indexOf(key);
      if (idx >= 0 && HardwareKeyboard.instance.isControlPressed) {
        _openItem(_page * _rowsPerPage + idx);
      }
    }
  }

  void _useHistory(String q) {
    _controller.text = q;
    _controller.selection =
        TextSelection.collapsed(offset: q.length);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showActions = SettingStore.get<bool>('qs_show_actions', true);
    final selectedHit = (_selected >= 0 && _selected < _hits.length)
        ? _hits[_selected]
        : null;
    final List<FileActionDef> actions = selectedHit == null
        ? const []
        : ModuleRegistry.actionsFor(selectedHit.path, contextId: 'quick_popup');

    return KeyboardListener(
      focusNode: _keyboardFocus,
      autofocus: true,
      onKeyEvent: (event) {
        if (event is KeyDownEvent) _handleKey(event.logicalKey);
      },
      child: Scaffold(
        backgroundColor: theme.colorScheme.surface,
        body: Column(
          children: [
            // 顶部搜索区
            Container(
              padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: theme.dividerColor, width: 0.5),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.search, size: 20, color: theme.hintColor),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _inputFocus,
                      onTap: () {
                        if (!_showHistory) {
                          setState(() => _showHistory = true);
                          _syncWindowSize();
                        }
                      },
                      onSubmitted: (_) => _openItem(_selected),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: _indexReady ? '搜索全盘文件' : '索引准备中…',
                        hintStyle: const TextStyle(fontSize: 14),
                      ),
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                  if (_searching)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  IconButton(
                    tooltip: '打开主界面',
                    icon: const Icon(Icons.open_in_full, size: 18),
                    onPressed: _openMainWithQuery,
                  ),
                ],
              ),
            ),
            // 主体：搜索视图（历史/结果）或常用软件/网址网格（空态）
            Expanded(
              child: DropTarget(
                onDragDone: (details) {
                  if (!_searchMode) _addDroppedForLaunch(details.files);
                },
                child: Listener(
                  onPointerSignal: (event) {
                    // 兼容各 Flutter 版本：滚轮事件基类为 PointerSignalEvent，
                    // 具体滚轮子类（PointerScrollEvent）携带 scrollDelta，但不保证被导出。
                    double dy = 0;
                    try {
                      final d = (event as dynamic).scrollDelta;
                      if (d is Offset) dy = d.dy;
                    } catch (_) {
                      dy = 0;
                    }
                    if (dy != 0) _onWheel(dy);
                  },
                  child: _searchMode
                      ? _buildBody(theme)
                      : _buildLaunchGrid(theme),
                ),
              ),
            ),
            // 底部动作条 + 状态（仅展开态）
            if (_expanded) ...[
              if (showActions && selectedHit != null && actions.isNotEmpty)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(color: theme.dividerColor, width: 0.5),
                    ),
                  ),
                  child: Row(
                    children: [
                      for (final a in actions)
                        Expanded(
                          child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: () =>
                                a.onExecute?.call(context, selectedHit.path),
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 6),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(a.icon, size: 18),
                                  const SizedBox(height: 2),
                                  Text(a.title,
                                      style: const TextStyle(fontSize: 10),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                color: theme.colorScheme.surfaceContainerHighest,
                child: Text(
                  _statusText(),
                  style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _statusText() {
    if (!_indexReady) return '全盘索引准备中，稍后可搜索…';
    final q = _controller.text.trim();
    if (q.isEmpty) {
      final count = DiskIndexService.countNotifier.value;
      return count == null ? '输入关键字开始搜索' : '共 $count 个文件 · 输入关键字搜索';
    }
    if (_searching) return '搜索中…';
    return '找到 ${_hits.length} 个结果 · Ctrl+1..9 快捷打开 · Ctrl+G 打开文件夹 · Esc 收起';
  }

  Widget _buildBody(ThemeData theme) {
    if (!_indexReady) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 12),
              Text('正在准备全盘索引…', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
      );
    }
    final q = _controller.text.trim();
    if (q.isEmpty) {
      // 聚焦无输入：搜索历史
      if (_history.isEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.keyboard_command_key,
                    size: 40, color: theme.hintColor),
                const SizedBox(height: 12),
                Text('输入文件名关键字，搜索全盘文件',
                    style: TextStyle(fontSize: 13, color: theme.hintColor)),
                const SizedBox(height: 4),
                Text('搜到的文件可直接加密、解密或发送到手机',
                    style: TextStyle(fontSize: 12, color: theme.hintColor)),
              ],
            ),
          ),
        );
      }
      return ListView(
        padding: const EdgeInsets.symmetric(vertical: 4),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 2),
            child: Row(
              children: [
                Text('搜索历史',
                    style: TextStyle(
                        fontSize: 12,
                        color: theme.hintColor,
                        fontWeight: FontWeight.w600)),
                const Spacer(),
                TextButton(
                  onPressed: () async {
                    await SearchHistoryService.clear();
                    await _reloadHistory();
                  },
                  child: const Text('清空', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
          for (final h in _history)
            // pointer-down 即填词：tap-up 前失焦会摘掉列表导致 onTap 被吞
            Listener(
              onPointerDown: (_) => _useHistory(h),
              child: ListTile(
                dense: true,
                leading: Icon(Icons.history, size: 18, color: theme.hintColor),
                title: Text(h, style: const TextStyle(fontSize: 13)),
              ),
            ),
        ],
      );
    }
    if (_hits.isEmpty && !_searching) {
      return Center(
        child: Text('没有找到「$q」相关文件',
            style: TextStyle(fontSize: 13, color: theme.hintColor)),
      );
    }
    // 一屏 9 条按页展示（滚轮翻页见外层 Listener）
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        for (final i in _pageItems)
          if (i >= _guideIndex)
            _buildGuideRow(theme)
          else
            _buildResultRow(theme, i),
      ],
    );
  }

  Widget _buildResultRow(ThemeData theme, int i) {
    final hit = _hits[i];
    final selected = i == _selected;
    final shortcut = 'Ctrl+${i - _page * _rowsPerPage + 1}';
    return SizedBox(
      height: _rowHeight,
      child: Container(
        color: selected
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.45)
            : null,
        child: InkWell(
          onTap: () => setState(() {
            _selected = i;
            _page = i ~/ _rowsPerPage;
          }),
          onDoubleTap: () => _openItem(i),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                FileThumbnail(path: hit.path, name: hit.name, size: 24),
                const SizedBox(width: 10),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          hit.name,
                          style: TextStyle(
                            fontSize: 13,
                            color:
                                selected ? theme.colorScheme.primary : null,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (hit.isEncrypted) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.lock,
                            size: 12, color: theme.colorScheme.primary),
                      ],
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          hit.dir,
                          style: TextStyle(
                              fontSize: 11, color: theme.hintColor),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(shortcut,
                    style: TextStyle(
                        fontSize: 10, color: theme.hintColor)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGuideRow(ThemeData theme) {
    final selected = _selected == _guideIndex;
    final idxInPage = _guideIndex - _page * _rowsPerPage;
    return SizedBox(
      height: _rowHeight,
      child: Container(
        color: selected
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.45)
            : null,
        child: InkWell(
          onTap: _openMainWithQuery,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Icon(Icons.open_in_new,
                    size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('去主界面展示全部结果',
                      style: TextStyle(
                          fontSize: 13, color: theme.colorScheme.primary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                if (idxInPage >= 1 && idxInPage <= 9)
                  Text('Ctrl+$idxInPage',
                      style:
                          TextStyle(fontSize: 10, color: theme.hintColor)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
