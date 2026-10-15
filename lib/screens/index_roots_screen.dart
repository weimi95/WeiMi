import 'package:file_picker/file_picker.dart' as fp;
import 'package:flutter/material.dart';

import '../services/disk_index_service.dart';

/// 索引文件夹设置（仅桌面端）：索引根白名单。
/// 留空 = 索引所有固定磁盘（默认）；非空 = 只索引列表里的盘 / 文件夹 /
/// 局域网共享（\\server\share）。支持手动输入（UNC 无法用目录选择器选），
/// 也可用浏览按钮选本地文件夹。修改立即保存；返回上一页时后台重建索引。
class IndexRootsScreen extends StatefulWidget {
  const IndexRootsScreen({super.key});

  @override
  State<IndexRootsScreen> createState() => _IndexRootsScreenState();
}

class _IndexRootsScreenState extends State<IndexRootsScreen> {
  List<String> _roots = [];
  bool _loaded = false;
  bool _dirty = false;
  final _inputCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    DiskIndexService.loadRemovablePref().then((_) {
      if (mounted) {
        setState(() {
          _roots = DiskIndexService.hasCustomRoots
              ? List<String>.of(
                  // defaultRoots() 在有白名单时返回白名单本身
                  DiskIndexService.defaultRoots())
              : <String>[];
          _loaded = true;
        });
      }
    });
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    // 离开页面：有过修改则重建索引 + 按新根重拉监视器（后台执行，不阻塞）
    if (_dirty) {
      DiskIndexService.freeIndex()
          .then((_) => DiskIndexService.prepareIndex())
          .then((_) => DiskIndexService.ensureWatcher())
          .catchError((_) {});
    }
    super.dispose();
  }

  Future<void> _persist() async {
    _dirty = true;
    await DiskIndexService.saveRootsSetting(_roots);
    if (mounted) setState(() {});
  }

  Future<void> _add(String raw) async {
    final n = DiskIndexService.normalizeRoot(raw);
    if (n.isEmpty) return;
    if (_roots.contains(n)) {
      _inputCtrl.clear();
      return;
    }
    _inputCtrl.clear();
    setState(() => _roots.add(n));
    await _persist();
  }

  /// 浏览只填充输入框，不直接添加——统一由「添加」按钮提交，
  /// 与浮窗「浏览=填充、按钮=提交」模式一致（否则按钮形同虚设）。
  Future<void> _browse() async {
    try {
      final res = await fp.FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择要索引的文件夹',
      );
      if (res == null || res.isEmpty || !mounted) return;
      _inputCtrl.text = res;
      _inputCtrl.selection = TextSelection.collapsed(offset: res.length);
    } catch (_) {}
  }

  Future<void> _removeAt(int i) async {
    setState(() => _roots.removeAt(i));
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    final empty = _roots.isEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('索引文件夹')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.blue.shade200),
                  ),
                  child: Text(
                    empty
                        ? '未配置：索引所有固定磁盘（默认）。'
                            '添加后只索引列表里的磁盘 / 文件夹 / 局域网共享，其余不扫描。'
                            '「排除文件夹」规则在已索引范围内仍然生效。'
                        : '只索引列表里的磁盘 / 文件夹 / 局域网共享，其余不扫描。'
                            '清空列表即恢复默认（索引所有固定磁盘）。'
                            '「排除文件夹」规则在已索引范围内仍然生效。',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _inputCtrl,
                        decoration: const InputDecoration(
                          isDense: true,
                          hintText: r'盘符 / 文件夹 / 局域网共享，如 \\Cs07\f',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: 10, vertical: 10),
                        ),
                        onSubmitted: _add,
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: '浏览本地文件夹',
                      onPressed: _browse,
                      icon: const Icon(Icons.folder_open),
                    ),
                    const SizedBox(width: 4),
                    FilledButton.icon(
                      onPressed: () => _add(_inputCtrl.text),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('添加'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (empty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text('未配置索引文件夹（默认全盘）',
                          style: TextStyle(color: Colors.grey, fontSize: 13)),
                    ),
                  )
                else
                  ...List.generate(_roots.length, (i) {
                    final isUnc = _roots[i].startsWith('\\\\');
                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 3),
                      child: ListTile(
                        dense: true,
                        leading: Icon(
                          isUnc ? Icons.lan_outlined : Icons.folder_outlined,
                          size: 20,
                        ),
                        title: Text(_roots[i],
                            style: const TextStyle(fontSize: 14)),
                        trailing: IconButton(
                          icon: const Icon(Icons.close,
                              size: 18, color: Colors.grey),
                          tooltip: '移除',
                          onPressed: () => _removeAt(i),
                        ),
                      ),
                    );
                  }),
                const SizedBox(height: 8),
                Text(
                  '修改后立即保存；返回上一页时自动在后台重建索引。'
                  '局域网共享离线时该根下的条目不可搜，恢复在线后自动补回。',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
    );
  }
}
