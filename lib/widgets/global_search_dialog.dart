import 'dart:io';

import 'package:flutter/material.dart';

import '../services/disk_index_service.dart';

/// 全盘搜索对话框（桌面端）：文件名子串匹配，返回选中的路径。
/// 文件页与最近页的搜索框共用。
class GlobalSearchDialog extends StatefulWidget {
  final String initialQuery;
  const GlobalSearchDialog({super.key, required this.initialQuery});

  /// 打开对话框，返回选中的文件路径（取消返回 null）
  static Future<String?> show(BuildContext context, {String initialQuery = ''}) {
    return showDialog<String>(
      context: context,
      builder: (_) => GlobalSearchDialog(initialQuery: initialQuery),
    );
  }

  @override
  State<GlobalSearchDialog> createState() => _GlobalSearchDialogState();
}

class _GlobalSearchDialogState extends State<GlobalSearchDialog> {
  late final TextEditingController _ctrl;
  List<String> _results = [];
  bool _busy = false; // 建索引或搜索中
  String _busyText = '';

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialQuery);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _doSearch() async {
    final q = _ctrl.text.trim();
    if (q.isEmpty || _busy) return;
    final hasSaved = await DiskIndexService.hasSavedIndex();
    setState(() {
      _busy = true;
      _results = [];
      _busyText = DiskIndexService.isBuilt
          ? '搜索中...'
          : (hasSaved
              ? '正在加载索引…'
              : '首次使用，正在建立全盘索引（约 1~2 分钟）...');
    });
    try {
      if (!DiskIndexService.isBuilt) {
        final n = await DiskIndexService.prepareIndex();
        if (!mounted) return;
        if (n >= 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('索引就绪：$n 个文件')),
          );
        }
      }
      final r = await DiskIndexService.search(q);
      if (!mounted) return;
      setState(() {
        _results = r;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('搜索失败: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _rebuildIndex() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _results = [];
      _busyText = '正在重建全盘索引（约 1~2 分钟）...';
    });
    try {
      final n =
          await DiskIndexService.buildIndex(DiskIndexService.defaultRoots());
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('索引完成：$n 个文件')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('建索引失败: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _freeIndex() async {
    await DiskIndexService.freeIndex();
    if (!mounted) return;
    setState(() => _results = []);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已释放全盘索引内存')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final count = DiskIndexService.indexedCount;
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      title: Row(children: [
        const Expanded(child: Text('全盘搜索')),
        if (count != null) ...[
          IconButton(
            tooltip: '释放索引内存（下次搜索自动重建）',
            icon: const Icon(Icons.memory_outlined, size: 20),
            onPressed: _busy ? null : _freeIndex,
          ),
          IconButton(
            tooltip: '重建索引',
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: _busy ? null : _rebuildIndex,
          ),
        ],
      ]),
      content: SizedBox(
        width: 560,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _ctrl,
              autofocus: true,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: '输入文件名关键词，匹配电脑上的所有文件',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onSubmitted: (_) => _doSearch(),
            ),
            const SizedBox(height: 10),
            Row(children: [
              FilledButton.icon(
                onPressed: _busy ? null : _doSearch,
                icon: const Icon(Icons.search, size: 18),
                label: const Text('搜索'),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _busy
                      ? _busyText
                      : count != null
                          ? '索引已就绪（$count 个文件）'
                          : '首次搜索会先建立全盘索引',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: _results.isEmpty && !_busy
                  ? Center(
                      child: Text(
                        _ctrl.text.trim().isEmpty ? '输入关键词开始搜索' : '没有匹配的文件',
                        style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                      ),
                    )
                  : Scrollbar(
                      thumbVisibility: true,
                      child: ListView.builder(
                        itemCount: _results.length,
                        itemBuilder: (ctx, i) {
                          final path = _results[i];
                          final isDir = FileSystemEntity.isDirectorySync(path);
                          final name = path
                              .split(Platform.isWindows ? '\\' : '/')
                              .last;
                          return ListTile(
                            dense: true,
                            leading: Icon(
                              isDir ? Icons.folder : Icons.insert_drive_file,
                              size: 20,
                              color: isDir ? Colors.amber.shade700 : Colors.grey,
                            ),
                            title: Text(name,
                                style: const TextStyle(fontSize: 14)),
                            subtitle: Text(path,
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.grey),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            onTap: () => Navigator.pop(context, path),
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
