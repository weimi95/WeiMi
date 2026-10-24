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
    // 离开页面：有过修改则**强制全量重建**索引（用最新排除列表）。
    // 不能走 prepareIndex——它会优先 loadIndex 加载带旧排除规则的旧落盘索引并
    // 直接返回，导致「改了排除却搜不到」的假象（误以为默认项删不掉）。
    // v1.2.25：不再 freeIndex——Rust index_build 本就不清旧表（扫描在本地
    // Vec 完成后原子写回），重建期间旧索引照常可搜（Everything 同款体验）。
    // 旧版先 freeIndex 清表，全量重扫几分钟内索引真空，搜索恒 0 结果干等。
    if (_dirty) {
      DiskIndexService.buildIndex(
        DiskIndexService.defaultRoots(),
        persist: true,
      ).catchError((_) {});
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
    // v1.2.25：删到空 = 清空排除——系统目录将全部纳入索引，返回时全量重建
    // 耗时数分钟（v1.2.24 老板实测被误认为假死）。删除前先确认。
    if (_patterns.length == 1) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('清空排除列表？'),
          content: const Text(
            '清空后所有文件夹（含系统目录）都将纳入全盘索引，返回上一页时'
            '需要全量重建（约 1~3 分钟）。重建期间搜索不受影响，仍用旧索引结果。',
            style: TextStyle(fontSize: 13.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清空'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
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
                    '例：*\\temp\\*　*.tmp　*/android/data/*\n'
                    '默认列表只是初始值，每条都可点 ✕ 删除，也可全部清空（清空=不排除任何文件夹）。',
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
