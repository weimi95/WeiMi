import 'package:flutter/material.dart';

/// 文件类型分类（筛选用）
enum FileCategory { image, video, audio, doc, archive, installer, encrypted, other }

/// 分类 → 扩展名映射与判定。扩展名一律小写、不含点。
class FileCategories {
  FileCategories._();

  static const Map<FileCategory, List<String>> exts = {
    FileCategory.image: [
      'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif',
      'tiff', 'tif', 'svg', 'ico',
    ],
    FileCategory.video: [
      'mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm', 'm4v',
      'ts', 'rmvb', 'rm', '3gp', 'mpg', 'mpeg', 'vob',
    ],
    FileCategory.audio: [
      'mp3', 'flac', 'wav', 'aac', 'ogg', 'm4a', 'wma', 'ape', 'opus',
    ],
    FileCategory.doc: [
      'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'md',
      'csv', 'epub', 'mobi', 'rtf', 'wps', 'et', 'dps',
    ],
    FileCategory.archive: [
      'zip', 'rar', '7z', 'tar', 'gz', 'tgz', 'bz2', 'xz', 'cab', 'iso',
    ],
    FileCategory.installer: [
      'exe', 'msi', 'apk', 'dmg', 'pkg', 'deb', 'rpm', 'appimage', 'msix',
    ],
    FileCategory.encrypted: ['wemi', 'kyl'],
  };

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

  /// 取文件扩展名（小写、无点）；无扩展名返回 ''
  static String extOf(String name) {
    final i = name.lastIndexOf('.');
    if (i <= 0 || i == name.length - 1) return '';
    return name.substring(i + 1).toLowerCase();
  }

  /// 按扩展名判定分类；不在任何分类里返回 null（即「其他」）
  static FileCategory? of(String name) {
    final e = extOf(name);
    if (e.isEmpty) return null;
    for (final entry in exts.entries) {
      if (entry.value.contains(e)) return entry.key;
    }
    return null;
  }
}

/// 筛选面板：单选分类 + 可细化到具体格式（多选）。
/// 用法：final r = await FileFilterSheet.show(context, cat, exts);
/// 返回 null = 取消；否则 (cat, exts) 为新筛选（cat 为 null 表示全部）。
class FileFilterSheet extends StatefulWidget {
  const FileFilterSheet({
    super.key,
    required this.initialCat,
    required this.initialExts,
  });

  final FileCategory? initialCat;
  final Set<String> initialExts;

  static Future<(FileCategory?, Set<String>)?> show(
    BuildContext context,
    FileCategory? cat,
    Set<String> exts,
  ) {
    return showModalBottomSheet<(FileCategory?, Set<String>)>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => FileFilterSheet(
        initialCat: cat,
        initialExts: Set.of(exts),
      ),
    );
  }

  @override
  State<FileFilterSheet> createState() => _FileFilterSheetState();
}

class _FileFilterSheetState extends State<FileFilterSheet> {
  FileCategory? _cat;
  late Set<String> _exts;

  @override
  void initState() {
    super.initState();
    _cat = widget.initialCat;
    _exts = Set.of(widget.initialExts);
  }

  bool get _refinable =>
      _cat != null &&
      _cat != FileCategory.other &&
      _cat != FileCategory.encrypted;

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
    final cats = FileCategory.values;
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
                const Text('按类型筛选',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(context, (null, <String>{})),
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
                    for (final c in cats)
                      ListTile(
                        dense: true,
                        leading: Icon(FileCategories.icons[c]),
                        title: Text(FileCategories.labels[c]!),
                        trailing: _cat == c
                            ? const Icon(Icons.check, color: Colors.blue)
                            : null,
                        onTap: () => _pick(c),
                      ),
                    if (_refinable) ...[
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
                            for (final e in FileCategories.exts[_cat!]!)
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
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: FilledButton(
                onPressed: () => Navigator.pop(context, (_cat, Set.of(_exts))),
                child: const Text('完成'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
