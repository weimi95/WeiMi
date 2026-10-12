import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/exclude_service.dart';
import '../services/disk_index_service.dart';

/// 排除文件夹设置（Everything 式）：通配符模式列表，匹配完整路径，不区分大小写。
/// 修改立即保存；离开页面时若有过修改则后台重建索引（期间搜索结果已由兜底过滤保证正确）。
class ExcludeSettingsScreen extends StatefulWidget {
  const ExcludeSettingsScreen({super.key});

  @override
  State<ExcludeSettingsScreen> createState() => _ExcludeSettingsScreenState();
}

class _ExcludeSettingsScreenState extends State<ExcludeSettingsScreen> {
  List<String> _patterns = [];
  bool _loaded = false;
  bool _dirty = false;
  final _inputCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    ExcludeService.load().then((list) {
      if (mounted) {
        setState(() {
          _patterns = list;
          _loaded = true;
        });
      }
    });
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    // 离开页面：有过修改则重建索引（后台执行，不阻塞）
    if (_dirty) {
      DiskIndexService.freeIndex()
          .then((_) => DiskIndexService.prepareIndex())
          .catchError((_) {});
    }
    super.dispose();
  }

  Future<void> _persist() async {
    _dirty = true;
    await ExcludeService.save(_patterns);
    if (mounted) setState(() {});
  }

  Future<void> _addPattern() async {
    final raw = _inputCtrl.text.trim();
    if (raw.isEmpty) return;
    // 反斜杠/正斜杠统一按平台写法提示即可，这里原样保存（匹配时大小写不敏感）
    if (_patterns.contains(raw)) {
      _inputCtrl.clear();
      return;
    }
    _inputCtrl.clear();
    setState(() => _patterns.add(raw));
    await _persist();
  }

  Future<void> _removeAt(int i) async {
    setState(() => _patterns.removeAt(i));
    await _persist();
  }

  Future<void> _restoreDefaults() async {
    setState(() => _patterns = ExcludeService.defaults());
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('排除文件夹')),
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
                  child: const Text(
                    '命中的文件夹和文件将被跳过、不扫描不索引（全盘搜索搜不到）。'
                    '支持通配符：* 匹配任意字符，? 匹配单个字符；不区分大小写，匹配完整路径。\n'
                    '例：*\\temp\\*　*.tmp　*/android/data/*',
                    style: TextStyle(fontSize: 13),
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
                          hintText: r'输入排除模式，如 *\temp\*',
                          border: OutlineInputBorder(),
                          contentPadding:
                              EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                        ),
                        onSubmitted: (_) => _addPattern(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: _addPattern,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('添加'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_patterns.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text('暂无排除模式',
                          style: TextStyle(color: Colors.grey, fontSize: 13)),
                    ),
                  )
                else
                  ...List.generate(_patterns.length, (i) {
                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 3),
                      child: ListTile(
                        dense: true,
                        leading:
                            const Icon(Icons.folder_off_outlined, size: 20),
                        title: Text(_patterns[i],
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
                OutlinedButton.icon(
                  onPressed: _restoreDefaults,
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: const Text('恢复默认列表'),
                ),
                const SizedBox(height: 8),
                Text(
                  '修改后立即保存并过滤搜索结果；返回上一页时自动在后台重建索引（首次全量约 1~2 分钟）。',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
    );
  }
}
