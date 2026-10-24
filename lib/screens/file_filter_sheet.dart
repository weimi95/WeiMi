import 'package:flutter/material.dart';
import '../widgets/file_thumbnail.dart';

/// 筛选面板 UI 元数据。分类定义复用 FileThumbs.FileCategory（单一权威源，
/// 扩展名集合见 file_thumbnail.dart，不在此重复维护）。
class FilterMeta {
  FilterMeta._();

  /// 筛选面板展示的分类顺序（不含 all）
  static const List<FileCategory> cats = [
    FileCategory.image,
    FileCategory.video,
    FileCategory.audio,
    FileCategory.doc,
    FileCategory.archive,
    FileCategory.installer,
    FileCategory.encrypted,
    FileCategory.other,
  ];

  static const Map<FileCategory, String> labels = {
    FileCategory.image: '图片',
    FileCategory.video: '视频',
    FileCategory.audio: '音乐',
    FileCategory.doc: '文档',
    FileCategory.archive: '压缩包',
    FileCategory.installer: '安装包',
    FileCategory.encrypted: '加密文件',
    FileCategory.other: '其他',
  };

  static const Map<FileCategory, IconData> icons = {
    FileCategory.image: Icons.image_outlined,
    FileCategory.video: Icons.movie_outlined,
    FileCategory.audio: Icons.music_note_outlined,
    FileCategory.doc: Icons.description_outlined,
    FileCategory.archive: Icons.folder_zip_outlined,
    FileCategory.installer: Icons.system_update_alt,
    FileCategory.encrypted: Icons.lock_outline,
    FileCategory.other: Icons.insert_drive_file_outlined,
  };

  /// 可细化到具体格式的分类 → 该分类的扩展名集合（引用 FileThumbs 权威定义）
  static const Map<FileCategory, Set<String>> refinableExts = {
    FileCategory.image: FileThumbs.image,
    FileCategory.video: FileThumbs.video,
    FileCategory.audio: FileThumbs.audio,
    FileCategory.doc: FileThumbs.doc,
    FileCategory.archive: FileThumbs.archive,
    FileCategory.installer: FileThumbs.installer,
  };

  static bool refinable(FileCategory c) => refinableExts.containsKey(c);
}

/// 筛选面板：单选分类 + 可细化到具体格式（多选）+ 排序方式（v1.2.25 并入，
/// 老板拍板方案 A：筛选+排序同族语义，一个入口，AppBar 不再放独立排序按钮）。
/// 用法：final r = await FileFilterSheet.show(context, cat, exts, sortMode, sortAsc);
/// 返回 null = 取消；否则 (cat, exts, sortMode, sortAsc)。
/// cat 为 null 表示全部；sortMode: smart/name/size/type/time。
class FileFilterSheet extends StatefulWidget {
  const FileFilterSheet({
    super.key,
    required this.initialCat,
    required this.initialExts,
    this.initialSortMode = 'smart',
    this.initialSortAsc = true,
  });

  final FileCategory? initialCat;
  final Set<String> initialExts;
  final String initialSortMode;
  final bool initialSortAsc;

  static Future<(FileCategory?, Set<String>, String, bool)?> show(
    BuildContext context,
    FileCategory? cat,
    Set<String> exts, [
    String sortMode = 'smart',
    bool sortAsc = true,
  ]) {
    return showModalBottomSheet<(FileCategory?, Set<String>, String, bool)>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => FileFilterSheet(
        initialCat: cat,
        initialExts: Set.of(exts),
        initialSortMode: sortMode,
        initialSortAsc: sortAsc,
      ),
    );
  }

  @override
  State<FileFilterSheet> createState() => _FileFilterSheetState();
}

class _FileFilterSheetState extends State<FileFilterSheet> {
  FileCategory? _cat;
  late Set<String> _exts;
  late String _sortMode;
  late bool _sortAsc;

  /// 排序选项（与排序语义一致：智能=常用格式优先，升降只影响同权重内名称）
  static const List<(String, String)> _sortOptions = [
    ('smart', '智能排序（常用格式优先）'),
    ('name', '按名称'),
    ('size', '按大小'),
    ('type', '按类型'),
    ('time', '按修改时间'),
  ];

  @override
  void initState() {
    super.initState();
    _cat = widget.initialCat;
    _exts = Set.of(widget.initialExts);
    _sortMode = widget.initialSortMode;
    _sortAsc = widget.initialSortAsc;
  }

  void _pick(FileCategory? c) {
    setState(() {
      _cat = c;
      _exts.clear();
    });
  }

  void _toggleExt(String e) {
    setState(() {
      if (_exts.contains(e)) {
        _exts.remove(e);
      } else {
        _exts.add(e);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 12, 0, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const SizedBox(width: 16),
                const Icon(Icons.filter_list, size: 20),
                const SizedBox(width: 8),
                const Text('筛选与排序',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                TextButton(
                  onPressed: () =>
                      Navigator.pop(context, (null, <String>{}, _sortMode, _sortAsc)),
                  child: const Text('清除'),
                ),
                const SizedBox(width: 4),
              ],
            ),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.filter_alt_outlined),
                      title: const Text('全部'),
                      trailing: _cat == null
                          ? const Icon(Icons.check, color: Colors.blue)
                          : null,
                      onTap: () => _pick(null),
                    ),
                    for (final c in FilterMeta.cats)
                      ListTile(
                        dense: true,
                        leading: Icon(FilterMeta.icons[c]),
                        title: Text(FilterMeta.labels[c]!),
                        trailing: _cat == c
                            ? const Icon(Icons.check, color: Colors.blue)
                            : null,
                        onTap: () => _pick(c),
                      ),
                    if (_cat != null && FilterMeta.refinable(_cat!)) ...[
                      const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                        child: Text(
                          '细化格式（不选 = 该类全部）',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade600),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final e
                                in FilterMeta.refinableExts[_cat!]!)
                              FilterChip(
                                label: Text('.${e.toUpperCase()}',
                                    style: const TextStyle(fontSize: 12)),
                                selected: _exts.contains(e),
                                onSelected: (_) => _toggleExt(e),
                                visualDensity: VisualDensity.compact,
                              ),
                          ],
                        ),
                      ),
                    ],
                    // 排序方式（v1.2.25 并入）：智能=常用格式优先，
                    // 升降开关对智能排序只影响同权重内的名称
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                      child: Row(
                        children: [
                          const Icon(Icons.sort, size: 18),
                          const SizedBox(width: 8),
                          const Text('排序方式',
                              style: TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 13)),
                          const Spacer(),
                          SizedBox(
                            height: 32,
                            child: SegmentedButton<bool>(
                              showSelectedIcon: false,
                              segments: const [
                                ButtonSegment(
                                    value: true, label: Text('升序',
                                        style: TextStyle(fontSize: 12))),
                                ButtonSegment(
                                    value: false, label: Text('降序',
                                        style: TextStyle(fontSize: 12))),
                              ],
                              selected: {_sortAsc},
                              onSelectionChanged: (s) =>
                                  setState(() => _sortAsc = s.first),
                            ),
                          ),
                        ],
                      ),
                    ),
                    for (final opt in _sortOptions)
                      ListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        title: Text(opt.$2, style: const TextStyle(fontSize: 14)),
                        trailing: _sortMode == opt.$1
                            ? const Icon(Icons.check, color: Colors.blue)
                            : null,
                        onTap: () => setState(() => _sortMode = opt.$1),
                      ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: FilledButton(
                onPressed: () => Navigator.pop(
                    context, (_cat, Set.of(_exts), _sortMode, _sortAsc)),
                child: const Text('完成'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
