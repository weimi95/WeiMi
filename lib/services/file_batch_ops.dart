import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../services/file_operations_service.dart';

/// 文件批量操作（分享 / 复制 / 移动 / 删除 / 详情 / 重命名 / 更多菜单）。
/// 供「最近」页与「文件」页共用；操作完成后通过 afterChange 回调通知页面刷新。
class FileBatchOps {
  static void _toast(BuildContext context, String msg,
      {Color? background, int seconds = 3}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: background,
      duration: Duration(seconds: seconds),
    ));
  }

  static Future<void> share(BuildContext context, List<String> paths) async {
    final ok = await FileOperationsService.shareFiles(paths);
    if (context.mounted && !ok) {
      _toast(context, '当前平台不支持系统分享（仅 Android）');
    }
  }

  static Future<void> copyTo(
    BuildContext context,
    List<String> paths, {
    Future<void> Function()? afterChange,
  }) async {
    if (paths.isEmpty) return;
    final dest = await FileOperationsService.pickDirectory('复制到…');
    if (dest == null || !context.mounted) return;
    final r = await FileOperationsService.copyFilesTo(paths, dest);
    if (!context.mounted) return;
    _toast(context, '复制完成：成功 ${r[0]}，失败 ${r[1]}',
        background: r[1] == 0 ? Colors.green : Colors.orange);
    if (r[0] > 0) await afterChange?.call();
  }

  static Future<void> moveTo(
    BuildContext context,
    List<String> paths, {
    Future<void> Function()? afterChange,
  }) async {
    if (paths.isEmpty) return;
    final dest = await FileOperationsService.pickDirectory('移动到…');
    if (dest == null || !context.mounted) return;
    // 过滤目标目录等于源目录的项，防自我复制
    final safe = paths.where((p0) => p.dirname(p0) != dest).toList();
    if (safe.isEmpty || !context.mounted) return;
    final r = await FileOperationsService.moveFilesTo(safe, dest);
    if (!context.mounted) return;
    _toast(context, '移动完成：成功 ${r[0]}，失败 ${r[1]}',
        background: r[1] == 0 ? Colors.green : Colors.orange);
    if (r[0] > 0) await afterChange?.call();
  }

  static Future<void> delete(
    BuildContext context,
    List<String> paths, {
    Future<void> Function()? afterChange,
  }) async {
    if (paths.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除文件'),
        content:
            Text('确定要删除选中的 ${paths.length} 个文件吗？此操作不可恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    int ok = 0, fail = 0;
    for (final path in paths) {
      try {
        await File(path).delete();
        ok++;
      } catch (_) {
        fail++;
      }
    }
    if (!context.mounted) return;
    _toast(context, '删除完成：成功 $ok，失败 $fail',
        background: fail == 0 ? Colors.green : Colors.red);
    if (ok > 0) await afterChange?.call();
  }

  /// 「更多」菜单，返回所选项：info / rename / encrypt（单选时才有 info/rename）
  static Future<String?> moreSheet(BuildContext context,
      {required bool single}) async {
    return showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (single)
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('详细信息'),
                onTap: () => Navigator.pop(ctx, 'info'),
              ),
            if (single)
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline),
                title: const Text('重命名'),
                onTap: () => Navigator.pop(ctx, 'rename'),
              ),
            ListTile(
              leading: const Icon(Icons.lock),
              title: const Text('加密'),
              onTap: () => Navigator.pop(ctx, 'encrypt'),
            ),
          ],
        ),
      ),
    );
  }

  static Future<void> info(BuildContext context, String path) async {
    final f = File(path);
    final stat = await f.stat();
    final name = p.basename(path);
    if (!context.mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('详细信息'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('文件名：$name'),
            const SizedBox(height: 6),
            Text(
                '大小：${(stat.size / 1024).toStringAsFixed(1)} KB'),
            const SizedBox(height: 6),
            Text(
                '修改时间：${stat.modified.year}-${stat.modified.month.toString().padLeft(2, '0')}-${stat.modified.day.toString().padLeft(2, '0')} '
                '${stat.modified.hour.toString().padLeft(2, '0')}:${stat.modified.minute.toString().padLeft(2, '0')}'),
            const SizedBox(height: 6),
            Text('路径：$path', style: const TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }

  static Future<void> rename(
    BuildContext context,
    String path, {
    Future<void> Function()? afterChange,
  }) async {
    final controller = TextEditingController(text: p.basename(path));
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '新文件名'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('确认')),
        ],
      ),
    );
    if (newName == null ||
        newName.isEmpty ||
        newName == p.basename(path) ||
        !context.mounted) {
      return;
    }
    final ok = await FileOperationsService.renameFile(path, newName);
    if (!context.mounted) return;
    _toast(context, ok ? '重命名成功' : '重命名失败（重名或无权限）',
        background: ok ? Colors.green : Colors.red);
    if (ok) await afterChange?.call();
  }
}
