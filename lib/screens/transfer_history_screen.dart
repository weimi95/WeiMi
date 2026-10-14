import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../services/file_viewer_service.dart';
import '../services/transfer_history_service.dart';

/// 传输记录页：飞传收发的文件/文本列表。
/// - 复选框多选 + 全选
/// - 桌面端：复制（真把文件复制进系统剪贴板）、移动、删除
/// - 手机端：移动、删除（无复制）
/// - 删除时询问「仅删除记录」还是「连文件一起删除」
/// - 文本记录只显示前 50 字，点击看全文、可复制
class TransferHistoryScreen extends StatefulWidget {
  const TransferHistoryScreen({super.key});

  @override
  State<TransferHistoryScreen> createState() => _TransferHistoryScreenState();
}

class _TransferHistoryScreenState extends State<TransferHistoryScreen> {
  final TransferHistoryService _svc = TransferHistoryService.instance;
  List<TransferRecord> _records = [];
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final list = await _svc.load();
    if (!mounted) return;
    setState(() {
      _records = list.toList();
      _selected.clear();
    });
  }

  bool get _allSelected =>
      _records.isNotEmpty && _selected.length == _records.length;

  List<TransferRecord> get _selectedRecords => _records
      .where((r) => _selected.contains(r.id))
      .toList();

  bool get _hasFileSelection =>
      _selectedRecords.any((r) => r.kind == 'file');

  void _toggle(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  void _toggleAll() {
    setState(() {
      if (_allSelected) {
        _selected.clear();
      } else {
        _selected.addAll(_records.map((r) => r.id));
      }
    });
  }

  Future<void> _copyFiles() async {
    final paths = _selectedRecords
        .where((r) => r.kind == 'file' && r.path != null)
        .map((r) => r.path!)
        .where((p0) => File(p0).existsSync())
        .toList();
    if (paths.isEmpty) {
      _snack('选中项里没有可复制的文件', Colors.orange);
      return;
    }
    final ok = await _svc.copyFilesToClipboard(paths);
    _snack(ok ? '已复制 ${paths.length} 个文件到剪贴板' : '复制失败（此平台不支持）',
        ok ? Colors.green : Colors.red);
  }

  Future<void> _moveFiles() async {
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '移动到哪个目录？',
    );
    if (dir == null) return;
    final n = await _svc.moveFiles(_selected.toList(), dir);
    if (mounted) {
      _snack(n > 0 ? '已移动 $n 个文件到 $dir' : '没有文件被移动（文件可能已不存在）',
          n > 0 ? Colors.green : Colors.orange);
    }
    await _reload();
  }

  Future<void> _deleteSelected() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除 ${_selected.length} 条记录'),
        content: const Text('只删除传输记录，还是连文件一起删除？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'record'),
              child: const Text('仅删除记录')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'file'),
              child: const Text('连文件一起删除',
                  style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (choice == null) return;
    final fileCount = await _svc.deleteRecords(
      _selected.toList(),
      deleteFiles: choice == 'file',
    );
    if (mounted) {
      _snack(
        choice == 'file'
            ? '已删除 ${_selected.length} 条记录和 $fileCount 个文件'
            : '已删除 ${_selected.length} 条记录（文件保留）',
        Colors.green,
      );
    }
    await _reload();
  }

  Future<void> _clearAll() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空传输记录'),
        content: const Text('只清空记录，不删除任何文件。确定？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清空')),
        ],
      ),
    );
    if (yes != true) return;
    await _svc.clearAll();
    await _reload();
  }

  void _showTextDetail(TransferRecord r) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('来自「${r.peerName}」的${r.direction == 'in' ? '' : '已发'}文本'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 400, maxWidth: 480),
          child: SingleChildScrollView(child: SelectableText(r.text ?? '')),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: r.text ?? ''));
              Navigator.pop(ctx);
              _snack('已复制到剪贴板', Colors.green);
            },
            child: const Text('复制'),
          ),
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }

  /// 单击打开：支持的格式（图片/视频/音频/文本/PDF）进内置查看器，
  /// 不支持的（安装包等）调系统「打开方式」；拒收/无文件给提示。
  Future<void> _openRecord(TransferRecord r) async {
    final path = r.path;
    if (path == null || path.isEmpty) {
      _snack(r.ok ? '该记录没有可打开的文件' : '该内容已被拒收，未传输',
          r.ok ? Colors.orange : Colors.red);
      return;
    }
    if (!File(path).existsSync()) {
      _snack('文件已不存在（可能被移动或删除）', Colors.orange);
      return;
    }
    try {
      await FileViewerService.openFile(context, path);
    } catch (e) {
      _snack('打开失败：$e', Colors.red);
    }
  }

  void _snack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: color));
  }

  String _fmtTime(DateTime t) {
    final now = DateTime.now();
    final sameDay = t.year == now.year && t.month == now.month && t.day == now.day;
    final hh = '${t.hour}'.padLeft(2, '0');
    final mm = '${t.minute}'.padLeft(2, '0');
    return sameDay ? '$hh:$mm' : '${t.month}-${t.day} $hh:$mm';
  }

  String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final canCopy = _svc.isDesktop && _hasFileSelection;
    return Scaffold(
      appBar: AppBar(
        title: const Text('传输记录'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: '清空记录',
            onPressed: _records.isEmpty ? null : _clearAll,
          ),
        ],
      ),
      body: _records.isEmpty
          ? const Center(
              child: Text('暂无传输记录',
                  style: TextStyle(color: Colors.grey)),
            )
          : Column(
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  child: Row(
                    children: [
                      Checkbox(value: _allSelected, onChanged: (_) => _toggleAll()),
                      const Text('全选', style: TextStyle(fontSize: 13)),
                      const Spacer(),
                      Text('已选 ${_selected.length} / ${_records.length}',
                          style:
                              const TextStyle(fontSize: 12, color: Colors.grey)),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    itemCount: _records.length,
                    itemBuilder: (ctx, i) {
                      final r = _records[i];
                      final checked = _selected.contains(r.id);
                      final isText = r.kind == 'text';
                      final preview = isText
                          ? (r.text!.length > 50
                              ? '${r.text!.substring(0, 50)}…'
                              : r.text!)
                          : r.name;
                      // 右击（桌面）与长按（手机）同义：进入多选
                      return GestureDetector(
                        onSecondaryTapUp: (_) => _toggle(r.id),
                        child: ListTile(
                        leading: Checkbox(
                          value: checked,
                          onChanged: (_) => _toggle(r.id),
                        ),
                        title: Text(
                          preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            color: r.ok ? null : Colors.red,
                            decoration: r.ok ? null : TextDecoration.lineThrough,
                          ),
                        ),
                        subtitle: Text(
                          '${r.direction == 'in' ? '收' : '发'} · ${r.peerName} · '
                          '${isText ? '${r.size} 字' : _fmtSize(r.size)} · '
                          '${_fmtTime(r.time)}${r.ok ? '' : ' · ${r.note ?? '失败'}'}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: isText
                            ? const Icon(Icons.chat_bubble_outline,
                                size: 18, color: Colors.grey)
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.folder_open,
                                        size: 18, color: Colors.grey),
                                    tooltip: '打开目录',
                                    onPressed: r.path == null
                                        ? null
                                        : () => _svc.openParentDirectory(r.path!),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.drive_folder_upload_outlined,
                                        size: 18, color: Colors.grey),
                                    tooltip: '在管理器中选中',
                                    onPressed: r.path == null
                                        ? null
                                        : () => _svc.revealInFileManager([r.path!]),
                                  ),
                                  Icon(
                                    r.direction == 'in'
                                        ? Icons.download_outlined
                                        : Icons.upload_outlined,
                                    size: 18,
                                    color: Colors.grey,
                                  ),
                                ],
                              ),
                        onTap: isText
                            ? () => _showTextDetail(r)
                            : () => _openRecord(r),
                        onLongPress: () => _toggle(r.id),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
      bottomNavigationBar: _selected.isEmpty
          ? null
          : SafeArea(
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  border: Border(
                      top: BorderSide(color: Colors.grey.shade300)),
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    if (canCopy)
                      TextButton.icon(
                        onPressed: _copyFiles,
                        icon: const Icon(Icons.copy_all_outlined, size: 18),
                        label: const Text('复制'),
                      ),
                    if (_hasFileSelection) ...[
                      TextButton.icon(
                        onPressed: () async {
                          final paths = _selectedRecords
                              .where((r) => r.kind == 'file' && r.path != null)
                              .map((r) => r.path!)
                              .where((p0) => File(p0).existsSync())
                              .toList();
                          if (paths.isEmpty) {
                            _snack('选中项里没有可定位的文件', Colors.orange);
                            return;
                          }
                          await _svc.revealInFileManager(paths);
                          _snack(paths.length == 1
                              ? '已在文件管理器中选中文件'
                              : '已在文件管理器中打开目录（Windows 不支持一次多选，已定位到第一个文件所在目录）',
                              Colors.green);
                        },
                        icon: const Icon(Icons.drive_folder_upload_outlined, size: 18),
                        label: const Text('选中'),
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          final paths = _selectedRecords
                              .where((r) => r.kind == 'file' && r.path != null)
                              .map((r) => r.path!)
                              .where((p0) => File(p0).existsSync())
                              .toList();
                          if (paths.isEmpty) {
                            _snack('选中项里没有可定位的文件', Colors.orange);
                            return;
                          }
                          await _svc.openParentDirectory(paths.first);
                          _snack('已打开目录', Colors.green);
                        },
                        icon: const Icon(Icons.folder_open, size: 18),
                        label: const Text('目录'),
                      ),
                    ],
                    if (_hasFileSelection)
                      TextButton.icon(
                        onPressed: _moveFiles,
                        icon: const Icon(Icons.drive_file_move_outlined,
                            size: 18),
                        label: const Text('移动'),
                      ),
                    TextButton.icon(
                      onPressed: _deleteSelected,
                      icon: const Icon(Icons.delete_outline,
                          size: 18, color: Colors.red),
                      label: const Text('删除',
                          style: TextStyle(color: Colors.red)),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
