import 'package:flutter/material.dart';

import '../services/search_filters_service.dart';
import 'search_syntax.dart';

/// 自定义筛选器管理对话框（M3 plan §四.3）。
///
/// 列表（应用/编辑/删除）+ 新建 + 导入/导出。
/// [onApply] 在「应用」某条筛选器时回调：调用方负责灌入查询词、持久化开关并重搜。
class SavedFiltersDialog extends StatefulWidget {
  final String initialQuery;
  final SearchOpts initialOpts;
  final void Function(SavedFilter filter)? onApply;

  const SavedFiltersDialog({
    super.key,
    this.initialQuery = '',
    this.initialOpts = const SearchOpts(),
    this.onApply,
  });

  /// 便捷打开方式。返回应用的那条筛选器（直接关闭=null）。
  static Future<SavedFilter?> show(
    BuildContext context, {
    String initialQuery = '',
    SearchOpts initialOpts = const SearchOpts(),
    void Function(SavedFilter filter)? onApply,
  }) =>
      showDialog<SavedFilter>(
        context: context,
        builder: (_) => SavedFiltersDialog(
          initialQuery: initialQuery,
          initialOpts: initialOpts,
          onApply: onApply,
        ),
      );

  @override
  State<SavedFiltersDialog> createState() => _SavedFiltersDialogState();
}

class _SavedFiltersDialogState extends State<SavedFiltersDialog> {
  List<SavedFilter> _filters = [];
  bool _loading = true;

  // 编辑态：null=列表；非 null=编辑/新建表单
  SavedFilter? _editing; // 已有条目
  bool _creating = false;
  final _nameCtl = TextEditingController();
  final _queryCtl = TextEditingController();
  late SearchOpts _formOpts;

  @override
  void initState() {
    super.initState();
    _formOpts = widget.initialOpts;
    _reload();
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _queryCtl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final list = await SearchFiltersService.instance.load();
    if (!mounted) return;
    setState(() {
      _filters = list.toList();
      _loading = false;
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  void _startCreate() {
    _nameCtl.clear();
    _queryCtl.text = widget.initialQuery.trim();
    _formOpts = widget.initialOpts;
    setState(() {
      _creating = true;
      _editing = null;
    });
  }

  void _startEdit(SavedFilter f) {
    _nameCtl.text = f.name;
    _queryCtl.text = f.query;
    _formOpts = f.toOpts();
    setState(() {
      _creating = false;
      _editing = f;
    });
  }

  void _cancelForm() => setState(() {
        _creating = false;
        _editing = null;
      });

  Future<void> _saveForm() async {
    final name = _nameCtl.text.trim();
    final query = _queryCtl.text.trim();
    if (name.isEmpty) {
      _toast('请填写筛选器名称');
      return;
    }
    if (query.isEmpty) {
      _toast('请填写搜索词');
      return;
    }
    final svc = SearchFiltersService.instance;
    if (_creating) {
      final f = await svc.add(name, query, _formOpts);
      if (f == null) {
        _toast('新建失败（筛选器数量已达上限 ${SearchFiltersService.maxCount} 条）');
        return;
      }
    } else if (_editing != null) {
      await svc.update(_editing!.copyWith(
        name: name,
        query: query,
        caseSensitive: _formOpts.caseSensitive,
        wholeWord: _formOpts.wholeWord,
        matchPath: _formOpts.matchPath,
        regex: _formOpts.regex,
      ));
    }
    await _reload();
    if (!mounted) return;
    setState(() {
      _creating = false;
      _editing = null;
    });
    _toast('已保存');
  }

  Future<void> _delete(SavedFilter f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除筛选器'),
        content: Text('确定删除「${f.name}」吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await SearchFiltersService.instance.remove(f.id);
    await _reload();
    _toast('已删除「${f.name}」');
  }

  Future<void> _export() async {
    final ok = await SearchFiltersService.exportToFile(_filters);
    _toast(ok ? '已导出 ${_filters.length} 条筛选器' : '导出取消或失败');
  }

  Future<void> _import() async {
    final (added, updated, err) =
        await SearchFiltersService.importFromFile();
    if (err != null) {
      _toast(err);
      return;
    }
    if (added == 0 && updated == 0) {
      _toast('没有可导入的筛选器');
      return;
    }
    await _reload();
    _toast('导入完成：新增 $added 条，更新 $updated 条');
  }

  void _apply(SavedFilter f) {
    widget.onApply?.call(f);
    Navigator.pop(context, f);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final formMode = _creating || _editing != null;
    return AlertDialog(
      title: Row(
        children: [
          Expanded(
            child: Text(formMode ? (_creating ? '新建筛选器' : '编辑筛选器') : '自定义筛选器'),
          ),
          if (formMode)
            IconButton(
              tooltip: '返回列表',
              icon: const Icon(Icons.arrow_back, size: 20),
              onPressed: _cancelForm,
            ),
        ],
      ),
      content: SizedBox(
        width: 460,
        height: 420,
        child: formMode ? _buildForm(theme) : _buildList(theme),
      ),
      actions: formMode
          ? [
              TextButton(onPressed: _cancelForm, child: const Text('取消')),
              TextButton(onPressed: _saveForm, child: const Text('保存')),
            ]
          : [
              TextButton(
                onPressed: _import,
                child: const Text('导入'),
              ),
              TextButton(
                onPressed: _filters.isEmpty ? null : _export,
                child: const Text('导出'),
              ),
              TextButton(
                onPressed: _startCreate,
                child: const Text('新建'),
              ),
            ],
    );
  }

  Widget _buildList(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_filters.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.filter_alt_off, size: 40, color: theme.hintColor),
            const SizedBox(height: 10),
            Text('还没有自定义筛选器', style: TextStyle(color: theme.hintColor)),
            const SizedBox(height: 4),
            Text('把常用「搜索词 + 开关组合」存下来，一键复用',
                style: TextStyle(fontSize: 12, color: theme.hintColor)),
          ],
        ),
      );
    }
    return ListView.separated(
      itemCount: _filters.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (ctx, i) {
        final f = _filters[i];
        final badges = <String>[
          if (f.caseSensitive) '大小写',
          if (f.wholeWord) '全字',
          if (f.matchPath) '路径',
          if (f.regex) '正则',
        ];
        return ListTile(
          dense: true,
          leading: const Icon(Icons.filter_alt_outlined, size: 20),
          title: Text(f.name,
              style: const TextStyle(fontSize: 13),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [
              f.query,
              if (badges.isNotEmpty) badges.join(' · '),
            ].join('   '),
            style: const TextStyle(fontSize: 11),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: '编辑',
                icon: const Icon(Icons.edit_outlined, size: 17),
                onPressed: () => _startEdit(f),
              ),
              IconButton(
                tooltip: '删除',
                icon: const Icon(Icons.delete_outline, size: 17),
                onPressed: () => _delete(f),
              ),
            ],
          ),
          onTap: () => _apply(f),
        );
      },
    );
  }

  Widget _buildForm(ThemeData theme) {
    return ListView(
      children: [
        TextField(
          controller: _nameCtl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '筛选器名称',
            hintText: '如：大视频文件',
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _queryCtl,
          decoration: const InputDecoration(
            labelText: '搜索词',
            hintText: '如：video: size:>100mb',
            helperText: '支持全部搜索语法（通配符/宏/ext:/size: 等）',
            helperMaxLines: 2,
          ),
          maxLines: 2,
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 4,
            children: [
              FilterChip(
                label: const Text('区分大小写'),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                selected: _formOpts.caseSensitive,
                showCheckmark: false,
                onSelected: (v) => setState(
                    () => _formOpts = SearchOpts(
                          caseSensitive: v,
                          wholeWord: _formOpts.wholeWord,
                          matchPath: _formOpts.matchPath,
                          regex: _formOpts.regex,
                        )),
              ),
              FilterChip(
                label: const Text('全字匹配'),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                selected: _formOpts.wholeWord,
                showCheckmark: false,
                onSelected: (v) => setState(
                    () => _formOpts = SearchOpts(
                          caseSensitive: _formOpts.caseSensitive,
                          wholeWord: v,
                          matchPath: _formOpts.matchPath,
                          regex: _formOpts.regex,
                        )),
              ),
              FilterChip(
                label: const Text('匹配路径'),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                selected: _formOpts.matchPath,
                showCheckmark: false,
                onSelected: (v) => setState(
                    () => _formOpts = SearchOpts(
                          caseSensitive: _formOpts.caseSensitive,
                          wholeWord: _formOpts.wholeWord,
                          matchPath: v,
                          regex: _formOpts.regex,
                        )),
              ),
              FilterChip(
                label: const Text('正则表达式'),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                selected: _formOpts.regex,
                showCheckmark: false,
                onSelected: (v) => setState(
                    () => _formOpts = SearchOpts(
                          caseSensitive: _formOpts.caseSensitive,
                          wholeWord: _formOpts.wholeWord,
                          matchPath: _formOpts.matchPath,
                          regex: v,
                        )),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
