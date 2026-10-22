import 'dart:async';

import 'package:flutter/material.dart';

import '../framework/setting_store.dart';
import '../services/search_filters_service.dart';
import 'saved_filters_dialog.dart';

/// M3 搜索菜单开关（全局修饰符，持久化；与 Rust `case:`/`wholeword:`/`path:`/`regex:` 裸词对应）。
///
/// 修饰符是**全局生效**的：拼在查询串任意位置皆可，[apply] 统一拼在最前面。
/// 开关状态不写进用户输入框（历史记录存的也是原始词），搜索时现场拼。
class SearchOpts {
  final bool caseSensitive;
  final bool wholeWord;
  final bool matchPath;
  final bool regex;

  const SearchOpts({
    this.caseSensitive = false,
    this.wholeWord = false,
    this.matchPath = false,
    this.regex = false,
  });

  static const kCase = 'search_opt_case';
  static const kWord = 'search_opt_wholeword';
  static const kPath = 'search_opt_path';
  static const kRegex = 'search_opt_regex';

  static SearchOpts load() => SearchOpts(
        caseSensitive: SettingStore.get<bool>(kCase, false),
        wholeWord: SettingStore.get<bool>(kWord, false),
        matchPath: SettingStore.get<bool>(kPath, false),
        regex: SettingStore.get<bool>(kRegex, false),
      );

  static Future<void> save(SearchOpts o) async {
    await SettingStore.set(kCase, o.caseSensitive);
    await SettingStore.set(kWord, o.wholeWord);
    await SettingStore.set(kPath, o.matchPath);
    await SettingStore.set(kRegex, o.regex);
  }

  int get activeCount =>
      [caseSensitive, wholeWord, matchPath, regex].where((b) => b).length;

  bool get anyActive => activeCount > 0;

  /// 把生效的全局修饰符拼成前缀（原查询为空时返回空前缀，由调用方判空）。
  String apply(String query) {
    final q = query.trim();
    if (!anyActive) return q;
    final pre = <String>[
      if (caseSensitive) 'case:',
      if (wholeWord) 'wholeword:',
      if (matchPath) 'path:',
      if (regex) 'regex:',
    ].join(' ');
    if (q.isEmpty) return pre;
    return '$pre $q';
  }
}

/// 预设宏分类（与 Rust `macro_exts` 同源；`folder:` 引擎侧未实现，不放）。
class SearchMacro {
  final String id;
  final String label;
  final IconData icon;
  const SearchMacro(this.id, this.label, this.icon);

  static const all = <SearchMacro>[
    SearchMacro('image', '图片', Icons.image_outlined),
    SearchMacro('video', '视频', Icons.videocam_outlined),
    SearchMacro('audio', '音频', Icons.music_note_outlined),
    SearchMacro('doc', '文档', Icons.description_outlined),
    SearchMacro('zip', '压缩', Icons.folder_zip_outlined),
    SearchMacro('exe', '程序', Icons.terminal),
  ];

  static final Set<String> _ids = all.map((m) => m.id).toSet();

  /// 查询串中已激活的宏 id（`!image:` 否定形式也算激活）。
  static Set<String> activeIn(String query) {
    final out = <String>{};
    for (final tok in query.split(RegExp(r'\s+'))) {
      var t = tok;
      if (t.startsWith('!')) t = t.substring(1);
      final head = t.split(':').first.toLowerCase();
      if (_ids.contains(head)) out.add(head);
    }
    return out;
  }

  /// 切换某个宏：激活则移除其所有 token（含否定），未激活则追加 `id:`。
  static String toggle(String query, String id) {
    final active = activeIn(query);
    if (active.contains(id)) {
      final kept = query
          .split(RegExp(r'\s+'))
          .where((tok) {
            var t = tok;
            if (t.startsWith('!')) t = t.substring(1);
            return t.split(':').first.toLowerCase() != id;
          })
          .where((t) => t.isNotEmpty)
          .join(' ');
      return kept;
    }
    final q = query.trim();
    return q.isEmpty ? '$id:' : '$q $id:';
  }

  /// 清除所有宏 token。
  static String clearAll(String query) => query
      .split(RegExp(r'\s+'))
      .where((tok) {
        var t = tok;
        if (t.startsWith('!')) t = t.substring(1);
        return !_ids.contains(t.split(':').first.toLowerCase());
      })
      .where((t) => t.isNotEmpty)
      .join(' ');
}

/// 搜索菜单按钮：四个全局开关 + 语法帮助 + 自定义筛选器入口。
/// 开关变更即写盘并回调触发重搜。
class SearchOptsButton extends StatefulWidget {
  final ValueChanged<SearchOpts>? onChanged;

  /// 当前输入框内容（用于「保存当前为筛选器」预填；为空时隐藏该入口）。
  final String currentQuery;

  /// 应用某条已存筛选器：调用方负责灌查询词、持久化开关、重搜。
  final void Function(SavedFilter filter)? onApplyFilter;

  const SearchOptsButton({
    super.key,
    this.onChanged,
    this.currentQuery = '',
    this.onApplyFilter,
  });

  @override
  State<SearchOptsButton> createState() => _SearchOptsButtonState();
}

class _SearchOptsButtonState extends State<SearchOptsButton> {
  late SearchOpts _opts;

  @override
  void initState() {
    super.initState();
    _opts = SearchOpts.load();
  }

  Future<void> _toggle(int which) async {
    final next = SearchOpts(
      caseSensitive: which == 0 ? !_opts.caseSensitive : _opts.caseSensitive,
      wholeWord: which == 1 ? !_opts.wholeWord : _opts.wholeWord,
      matchPath: which == 2 ? !_opts.matchPath : _opts.matchPath,
      regex: which == 3 ? !_opts.regex : _opts.regex,
    );
    setState(() => _opts = next);
    await SearchOpts.save(next);
    widget.onChanged?.call(next);
  }

  void _showHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('搜索语法速查'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('通配符', style: TextStyle(fontWeight: FontWeight.w600)),
              Text('* 任意字符   ? 单个字符（对整个文件名匹配）'),
              SizedBox(height: 8),
              Text('逻辑', style: TextStyle(fontWeight: FontWeight.w600)),
              Text('空格 = AND（都要含）   | = OR（任含其一）   !词 = 排除'),
              Text('"两词之间" = 精确字面量（含空格）'),
              SizedBox(height: 8),
              Text('修饰符（全局生效，菜单可常驻）', style: TextStyle(fontWeight: FontWeight.w600)),
              Text('case: 区分大小写    wholeword: 全字匹配'),
              Text('path: 连目录一起匹配    regex: 正则表达式'),
              SizedBox(height: 8),
              Text('函数', style: TextStyle(fontWeight: FontWeight.w600)),
              Text('ext:pdf;doc 指定扩展名    size:>100mb 大小'),
              Text('dm: 修改日期    dc: 创建日期'),
              Text('支持 today/yesterday/thisweek/lastweek/thismonth/'
                  'lastmonth/thisyear/lastyear、2026-01-01、a..b'),
              Text('（size/日期需在设置里开启「高级筛选函数」）'),
              SizedBox(height: 8),
              Text('类型宏', style: TextStyle(fontWeight: FontWeight.w600)),
              Text('image:  video:  audio:  doc:  zip:  exe:'),
              SizedBox(height: 8),
              Text('拼音', style: TextStyle(fontWeight: FontWeight.w600)),
              Text('输 douyin 或 dy 可命中「抖音」（设置可关）'),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: '搜索选项',
      padding: EdgeInsets.zero,
      iconSize: 20,
      icon: Badge(
        isLabelVisible: _opts.anyActive,
        label: Text('${_opts.activeCount}', style: const TextStyle(fontSize: 9)),
        child: const Icon(Icons.tune, size: 20),
      ),
      itemBuilder: (ctx) => [
        CheckedPopupMenuItem<int>(
          value: 0,
          checked: _opts.caseSensitive,
          child: const Text('区分大小写'),
        ),
        CheckedPopupMenuItem<int>(
          value: 1,
          checked: _opts.wholeWord,
          child: const Text('全字匹配'),
        ),
        CheckedPopupMenuItem<int>(
          value: 2,
          checked: _opts.matchPath,
          child: const Text('匹配路径'),
        ),
        CheckedPopupMenuItem<int>(
          value: 3,
          checked: _opts.regex,
          child: const Text('正则表达式'),
        ),
        const PopupMenuDivider(),
        if (widget.currentQuery.trim().isNotEmpty)
          const PopupMenuItem<int>(
            value: 98,
            child: ListTile(
              leading: Icon(Icons.bookmark_add_outlined, size: 20),
              title: Text('保存当前为筛选器', style: TextStyle(fontSize: 13)),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        const PopupMenuItem<int>(
          value: 97,
          child: ListTile(
            leading: Icon(Icons.filter_alt_outlined, size: 20),
            title: Text('管理自定义筛选器', style: TextStyle(fontSize: 13)),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<int>(
          value: 99,
          child: ListTile(
            leading: Icon(Icons.help_outline, size: 20),
            title: Text('搜索语法速查', style: TextStyle(fontSize: 13)),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
      onSelected: (v) {
        if (v == 99) {
          _showHelp();
        } else if (v == 97) {
          _openFilters();
        } else if (v == 98) {
          unawaited(_saveCurrent());
        } else {
          unawaited(_toggle(v));
        }
      },
    );
  }

  Future<void> _saveCurrent() async {
    final q = widget.currentQuery.trim();
    if (q.isEmpty) return;
    final name = q.length > 12 ? '${q.substring(0, 12)}…' : q;
    final f = await SearchFiltersService.instance.add(name, q, _opts);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(f == null
          ? '保存失败（筛选器数量已达上限 ${SearchFiltersService.maxCount} 条）'
          : '已保存为筛选器「${f.name}」'),
      duration: const Duration(seconds: 2),
    ));
  }

  void _openFilters() {
    unawaited(SavedFiltersDialog.show(
      context,
      initialQuery: widget.currentQuery,
      initialOpts: _opts,
      onApply: widget.onApplyFilter,
    ));
  }
}

/// 预设宏筛选条（纯函数式：按 query 里的宏 token 决定高亮，点击回调新 query）。
class SearchMacroBar extends StatelessWidget {
  final String query;
  final ValueChanged<String> onQuery;
  final bool dense;
  const SearchMacroBar({
    super.key,
    required this.query,
    required this.onQuery,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final active = SearchMacro.activeIn(query);
    final noneActive = active.isEmpty;
    return SizedBox(
      height: dense ? 34 : 38,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        children: [
          FilterChip(
            label: const Text('全部'),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            selected: noneActive,
            showCheckmark: false,
            onSelected: (_) => onQuery(SearchMacro.clearAll(query)),
          ),
          const SizedBox(width: 6),
          for (final m in SearchMacro.all) ...[
            FilterChip(
              avatar: Icon(m.icon, size: 15),
              label: Text(m.label),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              selected: active.contains(m.id),
              showCheckmark: false,
              onSelected: (_) => onQuery(SearchMacro.toggle(query, m.id)),
            ),
            const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }
}
