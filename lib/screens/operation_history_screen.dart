import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/history_service.dart';

/// 加解密历史页：列出本机所有加密/解密操作记录（与「传输记录」同级，入口在首页右上角）。
/// - 顶部「清空」按钮：仅删记录，不动文件。
/// - 每条记录可点击 / 点文件夹图标，在文件管理器中打开结果文件所在目录。
class OperationHistoryScreen extends StatefulWidget {
  const OperationHistoryScreen({super.key});

  @override
  State<OperationHistoryScreen> createState() => _OperationHistoryScreenState();
}

class _OperationHistoryScreenState extends State<OperationHistoryScreen> {
  List<HistoryRecord> _records = [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final list = await HistoryService.getAllRecords();
    if (!mounted) return;
    setState(() => _records = list);
  }

  Future<void> _clearAll() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空加解密历史'),
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
    await HistoryService.clearAll();
    await _reload();
  }

  void _snack(String msg, Color color) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  String _fmtTime(DateTime t) {
    final now = DateTime.now();
    final sameDay =
        t.year == now.year && t.month == now.month && t.day == now.day;
    final hh = '${t.hour}'.padLeft(2, '0');
    final mm = '${t.minute}'.padLeft(2, '0');
    return sameDay ? '$hh:$mm' : '${t.year}-${t.month}-${t.day} $hh:$mm';
  }

  /// 在系统文件管理器中打开结果文件所在目录（桌面端）。Android 无文件管理器跳转，提示路径。
  Future<void> _openFolder(String path) async {
    final file = File(path);
    final dir = file.existsSync()
        ? file.parent.path
        : (Directory(path).existsSync() ? path : null);
    if (dir == null) {
      _snack('文件或目录不存在，可能已移动/删除', Colors.orange);
      return;
    }
    if (Platform.isAndroid) {
      _snack('请在文件管理器中手动定位：\n$dir', Colors.orange);
      return;
    }
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', [dir]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [dir]);
      } else {
        await Process.run('xdg-open', [dir]);
      }
    } catch (e) {
      _snack('打开失败：$e', Colors.red);
    }
  }

  @override
  Widget build(BuildContext context) {
    const tr = _Tr();
    return Scaffold(
      appBar: AppBar(
        title: Text(tr.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: tr.clear,
            onPressed: _records.isEmpty ? null : _clearAll,
          ),
        ],
      ),
      body: _records.isEmpty
          ? Center(
              child: Text(tr.empty, style: const TextStyle(color: Colors.grey)),
            )
          : ListView.separated(
              itemCount: _records.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (ctx, i) {
                final r = _records[i];
                final isEncrypt = r.operation == 'encrypt';
                final name = p.basename(r.encryptedPath.isNotEmpty
                    ? r.encryptedPath
                    : r.filePath);
                final openPath = r.encryptedPath.isNotEmpty
                    ? r.encryptedPath
                    : r.filePath;
                return ListTile(
                  leading: Icon(
                    isEncrypt ? Icons.lock : Icons.lock_open,
                    color: isEncrypt ? Colors.blue : Colors.green,
                    size: 22,
                  ),
                  title: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14),
                  ),
                  subtitle: Text(
                    '${isEncrypt ? tr.encrypt : tr.decrypt} · '
                    '${_fmtTime(DateTime.parse(r.timestamp))}'
                    '${r.hint.isNotEmpty ? ' · 提示: ${r.hint}' : ''}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.folder_open_outlined,
                        size: 20, color: Colors.grey),
                    tooltip: tr.openFolder,
                    onPressed: () => _openFolder(openPath),
                  ),
                  onTap: () => _openFolder(openPath),
                );
              },
            ),
    );
  }
}

/// 内置中文文案（首页历史按钮与记录列表均为中文 UI，避免再引 LocalizationService 依赖）。
class _Tr {
  const _Tr();
  String get title => '加解密历史';
  String get empty => '暂无加解密记录';
  String get clear => '清空记录';
  String get encrypt => '加密';
  String get decrypt => '解密';
  String get openFolder => '打开所在目录';
}
