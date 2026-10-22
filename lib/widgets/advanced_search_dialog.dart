import 'package:flutter/material.dart';

import '../framework/setting_store.dart';
import 'search_syntax.dart';

/// 高级搜索对话框（M4 / plan §四.4）：表单式拼条件，生成搜索语法串回填搜索框。
///
/// 引擎侧语法（v1.2.6）已全部支持，这里只做「表单 → 语法串」翻译。
/// 大小/日期条件依赖设置项 `search_stat_filters`（默认关）：点击搜索时若未开启
/// 会自动打开并提示（避免用户疑惑「填了没反应」）。
class AdvancedSearchDialog extends StatefulWidget {
  /// 生成语法后的回调（调用方负责灌入输入框并触发搜索）。
  final void Function(String syntax)? onSearch;

  const AdvancedSearchDialog({super.key, this.onSearch});

  static Future<String?> show(
    BuildContext context, {
    void Function(String syntax)? onSearch,
  }) =>
      showDialog<String>(
        context: context,
        builder: (_) => AdvancedSearchDialog(onSearch: onSearch),
      );

  @override
  State<AdvancedSearchDialog> createState() => _AdvancedSearchDialogState();
}

class _AdvancedSearchDialogState extends State<AdvancedSearchDialog> {
  final _nameCtl = TextEditingController();
  final _extCtl = TextEditingController();
  final _sizeMinCtl = TextEditingController();
  final _sizeMaxCtl = TextEditingController();

  String _sizeUnit = 'mb';
  String _dm = ''; // 空=不限
  final Set<String> _macros = {};

  static const _dmOptions = <(String, String)>[
    ('', '不限'),
    ('today', '今天'),
    ('yesterday', '昨天'),
    ('thisweek', '本周'),
    ('lastweek', '上周'),
    ('thismonth', '本月'),
    ('lastmonth', '上月'),
    ('thisyear', '今年'),
    ('lastyear', '去年'),
  ];

  static const _sizeUnits = <(String, String)>[
    ('kb', 'KB'),
    ('mb', 'MB'),
    ('gb', 'GB'),
  ];

  @override
  void dispose() {
    _nameCtl.dispose();
    _extCtl.dispose();
    _sizeMinCtl.dispose();
    _sizeMaxCtl.dispose();
    super.dispose();
  }

  String get _syntax {
    final parts = <String>[];
    final name = _nameCtl.text.trim();
    if (name.isNotEmpty) parts.add(name);
    for (final m in _macros) {
      parts.add('$m:');
    }
    final ext = _extCtl.text.trim();
    if (ext.isNotEmpty) {
      final exts = ext
          .split(RegExp(r'[,;\s]+'))
          .map((e) => e.replaceFirst(RegExp(r'^\.'), ''))
          .where((e) => e.isNotEmpty)
          .join(';');
      if (exts.isNotEmpty) parts.add('ext:$exts');
    }
    final min = _sizeMinCtl.text.trim();
    final max = _sizeMaxCtl.text.trim();
    if (min.isNotEmpty) parts.add('size:>$min$_sizeUnit');
    if (max.isNotEmpty) parts.add('size:<$max$_sizeUnit');
    if (_dm.isNotEmpty) parts.add('dm:$_dm');
    return parts.join(' ');
  }

  bool get _needsStat =>
      _sizeMinCtl.text.trim().isNotEmpty ||
      _sizeMaxCtl.text.trim().isNotEmpty ||
      _dm.isNotEmpty;

  void _rebuild() => setState(() {});

  Future<void> _submit() async {
    final syntax = _syntax.trim();
    if (syntax.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('请至少填写一个条件'),
        duration: Duration(seconds: 2),
      ));
      return;
    }
    if (_needsStat && !SettingStore.get<bool>('search_stat_filters', false)) {
      // 自动开启大小/日期筛选（默认关），避免「填了没反应」
      await SettingStore.set('search_stat_filters', true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('已自动开启「大小/日期筛选语法」设置'),
        duration: Duration(seconds: 2),
      ));
    }
    if (!mounted) return;
    widget.onSearch?.call(syntax);
    Navigator.pop(context, syntax);
  }

  @override
  Widget build(BuildContext context) {
    final syntax = _syntax;
    return AlertDialog(
      title: const Text('高级搜索'),
      content: SizedBox(
        width: 420,
        child: ListView(
          shrinkWrap: true,
          children: [
            TextField(
              controller: _nameCtl,
              decoration: const InputDecoration(
                labelText: '名称包含',
                hintText: '如：报告 2026（多词为“都要包含”）',
                isDense: true,
              ),
              onChanged: (_) => _rebuild(),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 6,
                children: [
                  for (final m in SearchMacro.all)
                    FilterChip(
                      avatar: Icon(m.icon, size: 15),
                      label: Text(m.label),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      selected: _macros.contains(m.id),
                      showCheckmark: false,
                      onSelected: (v) {
                        setState(() {
                          if (v) {
                            _macros.add(m.id);
                          } else {
                            _macros.remove(m.id);
                          }
                        });
                      },
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _extCtl,
              decoration: const InputDecoration(
                labelText: '扩展名',
                hintText: '如：pdf;docx;txt（分号或逗号分隔）',
                isDense: true,
              ),
              onChanged: (_) => _rebuild(),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _sizeMinCtl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '大小 ≥',
                      isDense: true,
                    ),
                    onChanged: (_) => _rebuild(),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _sizeMaxCtl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '大小 ≤',
                      isDense: true,
                    ),
                    onChanged: (_) => _rebuild(),
                  ),
                ),
                const SizedBox(width: 10),
                DropdownButton<String>(
                  value: _sizeUnit,
                  isDense: true,
                  items: [
                    for (final (v, label) in _sizeUnits)
                      DropdownMenuItem(value: v, child: Text(label)),
                  ],
                  onChanged: (v) => setState(() => _sizeUnit = v ?? 'mb'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _dm,
              isDense: true,
              decoration: const InputDecoration(
                labelText: '修改时间',
                isDense: true,
              ),
              items: [
                for (final (v, label) in _dmOptions)
                  DropdownMenuItem(value: v, child: Text(label)),
              ],
              onChanged: (v) => setState(() => _dm = v ?? ''),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('生成的搜索条件',
                      style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).hintColor)),
                  const SizedBox(height: 2),
                  Text(
                    syntax.isEmpty ? '（空）' : syntax,
                    style: const TextStyle(
                        fontSize: 12, fontFamily: 'monospace'),
                  ),
                ],
              ),
            ),
            if (_needsStat) ...[
              const SizedBox(height: 6),
              Text(
                '含大小/日期条件，将自动开启设置「大小/日期筛选语法」',
                style: TextStyle(
                    fontSize: 11, color: Theme.of(context).hintColor),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消')),
        TextButton(onPressed: _submit, child: const Text('搜索')),
      ],
    );
  }
}
