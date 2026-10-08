import 'package:flutter/material.dart';

/// 多选模式顶部横幅：已选择 N 项 | 全选 | 取消
class SelectionHeaderBar extends StatelessWidget {
  final int count;
  final VoidCallback onSelectAll;
  final VoidCallback onCancel;

  const SelectionHeaderBar({
    super.key,
    required this.count,
    required this.onSelectAll,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withAlpha(120),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '已选择 $count 项',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(onPressed: onSelectAll, child: const Text('全选')),
          TextButton(onPressed: onCancel, child: const Text('取消')),
        ],
      ),
    );
  }
}

/// 多选模式底部操作栏：分享 | 移动 | 复制 | 删除 | 更多
class FileSelectionBar extends StatelessWidget {
  final int count;
  final VoidCallback? onShare;
  final VoidCallback onMove;
  final VoidCallback onCopy;
  final VoidCallback onDelete;
  final VoidCallback onMore;

  const FileSelectionBar({
    super.key,
    required this.count,
    this.onShare,
    required this.onMove,
    required this.onCopy,
    required this.onDelete,
    required this.onMore,
  });

  Widget _btn(BuildContext context, IconData icon, String label, VoidCallback? onTap,
      {Color? color}) {
    final c = color ?? Theme.of(context).colorScheme.onSurface;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: onTap == null ? c.withAlpha(90) : c),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: onTap == null ? c.withAlpha(90) : c,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(
            top: BorderSide(color: Theme.of(context).dividerColor.withAlpha(60)),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            _btn(context, Icons.share_outlined, '分享', onShare),
            _btn(context, Icons.drive_file_move_outlined, '移动', onMove),
            _btn(context, Icons.copy_all_outlined, '复制', onCopy),
            _btn(context, Icons.delete_outline, '删除', onDelete,
                color: Colors.red),
            _btn(context, Icons.more_horiz, '更多', onMore),
          ],
        ),
      ),
    );
  }
}
