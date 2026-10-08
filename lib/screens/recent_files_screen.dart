import 'dart:io';
import 'package:flutter/material.dart';

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

  @override
  void initState() {
    super.initState();
    refresh();
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

  (IconData, Color) _iconFor(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    const video = {'mp4', 'avi', 'mkv', 'mov', 'wmv', 'flv', 'ts'};
    const image = {'jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic'};
    const audio = {'mp3', 'wav', 'flac', 'aac', 'm4a', 'ogg'};
    const text = {'txt', 'md', 'json', 'xml', 'csv', 'log'};
    const archive = {'zip', 'rar', '7z', 'tar', 'gz'};
    if (name.endsWith('.wemi')) return (Icons.lock, Colors.orange);
    if (video.contains(ext)) return (Icons.movie_outlined, Colors.purple);
    if (image.contains(ext)) return (Icons.image_outlined, Colors.teal);
    if (audio.contains(ext)) return (Icons.music_note_outlined, Colors.pink);
    if (ext == 'pdf') return (Icons.picture_as_pdf_outlined, Colors.red);
    if (text.contains(ext)) return (Icons.description_outlined, Colors.blue);
    if (archive.contains(ext)) {
      return (Icons.folder_zip_outlined, Colors.amber.shade700);
    }
    return (Icons.insert_drive_file_outlined, Colors.grey);
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

    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _files.length,
        separatorBuilder: (_, __) =>
            Divider(height: 1, color: Colors.grey.shade200),
        itemBuilder: (context, index) {
          final f = _files[index];
          final (icon, color) = _iconFor(f.name);
          final dirPath =
              f.path.substring(0, f.path.length - f.name.length - 1);
          return InkWell(
            onTap: () => widget.onOpenFile(f.path),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: color.withAlpha(20),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(icon, size: 22, color: color),
                  ),
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
        },
      ),
    );
  }
}
