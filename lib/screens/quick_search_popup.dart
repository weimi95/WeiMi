import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../framework/module_registry.dart';
import '../framework/setting_store.dart';
import '../services/disk_index_service.dart';
import '../services/quick_search_window.dart';
import '../widgets/file_thumbnail.dart';

/// 快捷搜索浮窗（双击 Ctrl 呼出）。
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
  final TextEditingController _controller = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  final FocusNode _keyboardFocus = FocusNode();
  final ScrollController _listController = ScrollController();

  List<_Hit> _hits = [];
  int _selected = -1;
  bool _searching = false;
  bool _indexReady = false;
  Timer? _debounce;

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
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.removeListener(_onQueryChanged);
    _controller.dispose();
    _inputFocus.dispose();
    _keyboardFocus.dispose();
    _listController.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), _runSearch);
  }

  Future<void> _runSearch() async {
    final q = _controller.text.trim();
    if (q.isEmpty) {
      if (!mounted) return;
      setState(() {
        _hits = [];
        _selected = -1;
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
      _searching = false;
      _indexReady = DiskIndexService.isBuilt;
    });
  }

  void _moveSelection(int delta) {
    if (_hits.isEmpty) return;
    setState(() {
      _selected = (_selected + delta).clamp(0, _hits.length - 1);
    });
    // 选中项滚入可视区
    if (_listController.hasClients) {
      _listController.animateTo(
        (_selected * 52.0).clamp(
          0.0,
          _listController.position.maxScrollExtent,
        ),
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    }
  }

  FileActionDef? _findOpenAction(String path) {
    final list = ModuleRegistry
        .actionsFor(path, contextId: 'quick_popup')
        .where((a) => a.id == 'qs_open');
    return list.isEmpty ? null : list.first;
  }

  Future<void> _openSelected() async {
    if (_selected < 0 || _selected >= _hits.length) return;
    final path = _hits[_selected].path;
    _findOpenAction(path)?.onExecute?.call(context, path);
  }

  void _executeAction(FileActionDef action, String path) {
    action.onExecute?.call(context, path);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showActions = SettingStore.get<bool>('qs_show_actions', true);
    final selectedHit =
        (_selected >= 0 && _selected < _hits.length) ? _hits[_selected] : null;
    final actions = selectedHit == null
        ? const []
        : ModuleRegistry.actionsFor(selectedHit.path, contextId: 'quick_popup');

    return KeyboardListener(
      focusNode: _keyboardFocus,
      autofocus: true,
      onKeyEvent: (event) {
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.escape) {
            unawaited(WindowModeService.instance.hidePopup());
          } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
            _moveSelection(1);
          } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
            _moveSelection(-1);
          } else if (event.logicalKey == LogicalKeyboardKey.enter) {
            unawaited(_openSelected());
          }
        }
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
                      onSubmitted: (_) => unawaited(_openSelected()),
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
                    onPressed: () =>
                        unawaited(WindowModeService.instance.hidePopup(openMain: true)),
                  ),
                ],
              ),
            ),
            // 结果列表
            Expanded(
              child: _buildBody(theme),
            ),
            // 底部动作条 + 状态
            if (showActions && selectedHit != null && actions.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
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
                          onTap: () => _executeAction(a, selectedHit.path),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              color: theme.colorScheme.surfaceContainerHighest,
              child: Text(
                _statusText(),
                style: TextStyle(
                    fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _statusText() {
    if (!_indexReady) return '全盘索引准备中，稍后可搜索…';
    if (_controller.text.trim().isEmpty) {
      final count = DiskIndexService.countNotifier.value;
      return count == null ? '输入关键字开始搜索' : '共 $count 个文件 · 输入关键字搜索';
    }
    if (_searching) return '搜索中…';
    return '找到 ${_hits.length} 个结果 · Enter 打开 · Esc 收起';
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
    if (_controller.text.trim().isEmpty) {
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
    if (_hits.isEmpty && !_searching) {
      return Center(
        child: Text('没有找到「${_controller.text.trim()}」相关文件',
            style: TextStyle(fontSize: 13, color: theme.hintColor)),
      );
    }
    return ListView.builder(
      controller: _listController,
      itemCount: _hits.length,
      itemExtent: 52,
      itemBuilder: (ctx, i) {
        final hit = _hits[i];
        return InkWell(
          selected: i == _selected,
          onTap: () => setState(() => _selected = i),
          onDoubleTap: () {
            _findOpenAction(hit.path)?.onExecute?.call(context, hit.path);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                FileThumbnail(path: hit.path, name: hit.name, size: 32),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              hit.name,
                              style: TextStyle(
                                fontSize: 13,
                                color: i == _selected
                                    ? theme.colorScheme.primary
                                    : null,
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
                        ],
                      ),
                      Text(
                        hit.dir,
                        style: TextStyle(
                            fontSize: 11, color: theme.hintColor),
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
      },
    );
  }
}
