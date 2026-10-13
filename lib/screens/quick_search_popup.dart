import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../framework/module_registry.dart';
import '../framework/setting_store.dart';
import '../services/disk_index_service.dart';
import '../services/quick_search_window.dart';
import '../services/search_history_service.dart';
import '../widgets/file_thumbnail.dart';

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
  bool _focused = true;
  bool _showHistory = false; // 主动点搜索框/按方向键后才展示历史（呼出时保持窄条）
  List<String> _history = [];
  Timer? _debounce;

  int get _guideIndex => _hits.length; // 引导位紧跟最后一条结果
  int get _totalItems => _hits.isEmpty ? 0 : _hits.length + 1;
  int get _maxPage => _totalItems <= 0 ? 0 : (_totalItems - 1) ~/ _rowsPerPage;
  bool get _expanded =>
      _controller.text.trim().isNotEmpty || (_focused && _showHistory);

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
                      autofocus: true,
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
            // 主体：窄条时不渲染（窗口本身只有 64 高）
            if (_expanded)
              Expanded(
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
                  child: _buildBody(theme),
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
            ListTile(
              dense: true,
              leading: Icon(Icons.history, size: 18, color: theme.hintColor),
              title: Text(h, style: const TextStyle(fontSize: 13)),
              onTap: () => _useHistory(h),
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
