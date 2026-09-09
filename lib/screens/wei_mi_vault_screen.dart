import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import '../models/file_item.dart';
import '../services/encryption_service.dart';
import '../services/file_operations_service.dart';
import '../services/file_viewer_service.dart';

/// WeiMi Vault 屏幕：浏览应用私有目录下的加密/解密文件
/// 手机和桌面通用，但桌面端会额外显示系统目录
class WeiMiVaultScreen extends StatefulWidget {
  final bool showSystemDirs; // true = 桌面端，显示常用系统目录
  final String? initialPath; // 桌面端可指定初始路径

  const WeiMiVaultScreen({
    super.key,
    this.showSystemDirs = false,
    this.initialPath,
  });

  @override
  State<WeiMiVaultScreen> createState() => _WeiMiVaultScreenState();
}

class _WeiMiVaultScreenState extends State<WeiMiVaultScreen> {
  List<FileItem> _items = [];
  bool _loading = true;
  String _currentPath = '';
  List<String> _pathHistory = [];
  int _historyIndex = -1;

  @override
  void initState() {
    super.initState();
    _navigateTo(widget.initialPath ?? '');
  }

  Future<void> _navigateTo(String targetPath) async {
    setState(() {
      _loading = true;
      _items = [];
      if (targetPath.isEmpty) {
        _currentPath = '';
        _pathHistory = [''];
        _historyIndex = 0;
      } else {
        _currentPath = targetPath;
        if (_historyIndex < _pathHistory.length - 1) {
          _pathHistory = _pathHistory.sublist(0, _historyIndex + 1);
        }
        if (!_pathHistory.contains(targetPath)) {
          _pathHistory.add(targetPath);
          _historyIndex = _pathHistory.length - 1;
        } else {
          _historyIndex = _pathHistory.indexOf(targetPath);
        }
      }
    });

    try {
      final items = await listDirectory(targetPath);
      if (mounted) {
        setState(() {
          _items = items;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法访问目录: $e')),
        );
      }
    }
  }

  void _goBack() {
    if (_historyIndex > 0) {
      _navigateTo(_pathHistory[_historyIndex - 1]);
    }
  }

  void _goForward() {
    if (_historyIndex < _pathHistory.length - 1) {
      _navigateTo(_pathHistory[_historyIndex + 1]);
    }
  }

  Future<void> _openFile(FileItem item) async {
    if (!mounted) return;

    if (item.isDirectory) {
      _navigateTo(item.fullPath);
      return;
    }

    // 文件操作菜单
    final result = await showModalBottomSheet<FileAction>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _FileActionSheet(item: item),
    );

    if (result == null || !mounted) return;

    switch (result) {
      case FileAction.view:
        final isEnc = await EncryptionService.isEncryptedFile(item.fullPath);
        if (isEnc) {
          final hint = await EncryptionService.getPasswordHint(item.fullPath);
          final password = await _showPasswordDialog(hint: hint);
          if (password != null) {
            await FileViewerService.openFile(
              context, item.fullPath, password: password, isEncrypted: true,
            );
          }
        } else {
          await FileViewerService.openFile(context, item.fullPath);
        }
        break;

      case FileAction.encrypt:
        if (item.isEncryptedFile) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('该文件已加密')),
          );
          break;
        }
        _encryptFile(item.fullPath);
        break;

      case FileAction.decrypt:
        if (!item.isEncryptedFile) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('该文件未加密')),
          );
          break;
        }
        final hint = await EncryptionService.getPasswordHint(item.fullPath);
        final password = await _showPasswordDialog(hint: hint);
        if (password == null || !mounted) return;
        _decryptFile(item.fullPath, password);
        break;

      case FileAction.delete:
        await _deleteFile(item);
        break;
    }
  }

  Future<void> _encryptFile(String filePath) async {
    if (!mounted) return;

    final outputDir = await FileOperationsService.pickOutputDirectory();
    if (outputDir == null || !mounted) return;

    final result = await _showEncryptPasswordDialog();
    if (result == null || !mounted) return;

    try {
      await FileOperationsService.encryptFile(
        filePath, outputDir, result['password']!,
        hint: result['hint'],
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('加密成功')),
        );
        _navigateTo(_currentPath);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加密失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _decryptFile(String filePath, String password) async {
    if (!mounted) return;

    final outputDir = await FileOperationsService.pickOutputDirectory();
    if (outputDir == null || !mounted) return;

    try {
      await FileOperationsService.decryptFile(filePath, outputDir, password);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('解密成功')),
        );
        _navigateTo(_currentPath);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('解密失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _deleteFile(FileItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除文件'),
        content: Text('确定要删除 "${item.name}" 吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await File(item.fullPath).delete();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已删除')),
        );
        _navigateTo(_currentPath);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<Map<String, String?>?> _showEncryptPasswordDialog() async {
    final passwordController = TextEditingController();
    final confirmController = TextEditingController();
    final hintController = TextEditingController();

    return showDialog<Map<String, String?>>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('设置密码'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: passwordController, obscureText: true, maxLength: 32, decoration: const InputDecoration(labelText: '密码')),
              const SizedBox(height: 16),
              TextField(controller: confirmController, obscureText: true, maxLength: 32, decoration: const InputDecoration(labelText: '确认密码')),
              const SizedBox(height: 16),
              TextField(controller: hintController, decoration: const InputDecoration(labelText: '密码提示词（可选）')),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
            TextButton(
              onPressed: () {
                if (passwordController.text.isEmpty || passwordController.text != confirmController.text) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('密码不一致')));
                  return;
                }
                Navigator.pop(context, {
                  'password': passwordController.text,
                  'hint': hintController.text.isNotEmpty ? hintController.text : null,
                });
              },
              child: const Text('确认'),
            ),
          ],
        );
      },
    );
  }

  Future<String?> _showPasswordDialog({String? hint}) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('输入密码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hint != null && hint.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text('提示: $hint', style: const TextStyle(color: Colors.blue)),
              ),
            TextField(controller: controller, obscureText: true, maxLength: 32, decoration: const InputDecoration(labelText: '密码')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('确认')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = !Platform.isAndroid && !Platform.isIOS;

    return Scaffold(
      appBar: AppBar(
        title: Text(_currentPath.isEmpty ? '微密 Vault' : path.basename(_currentPath)),
        leading: _historyIndex > 0
            ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: _goBack)
            : null,
        actions: [
          if (_historyIndex < _pathHistory.length - 1)
            IconButton(icon: const Icon(Icons.arrow_forward), onPressed: _goForward),
          if (isDesktop && widget.showSystemDirs)
            PopupMenuButton<String>(
              icon: const Icon(Icons.folder_open),
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'desktop', child: Text('桌面')),
                const PopupMenuItem(value: 'documents', child: Text('文档')),
                const PopupMenuItem(value: 'downloads', child: Text('下载')),
                const PopupMenuItem(value: 'pictures', child: Text('图片')),
              ],
              onSelected: (v) async {
                final dir = await _getSystemDir(v);
                if (dir != null) _navigateTo(dir);
              },
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? _emptyState
              : _buildFileList(),
      floatingActionButton: isDesktop
          ? FloatingActionButton.extended(
              onPressed: () => _showAddDialog(),
              icon: const Icon(Icons.add),
              label: const Text('新建'),
            )
          : null,
    );
  }

  Widget get _emptyState => Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.folder_open, size: 64, color: Colors.grey),
        const SizedBox(height: 16),
        Text(
          _currentPath.isEmpty ? '微密 Vault 目录为空' : '该目录为空',
          style: const TextStyle(color: Colors.grey),
        ),
      ],
    ),
  );

  Widget _buildFileList() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _items.length,
      itemBuilder: (context, index) {
        final item = _items[index];
        return _FileListItem(
          item: item,
          onTap: () => _openFile(item),
        );
      },
    );
  }

  Future<String?> _getSystemDir(String type) async {
    final dir = await getApplicationDocumentsDirectory();
    switch (type) {
      case 'desktop':
        return path.join(dir.path, 'Desktop');
      case 'documents':
        return path.join(dir.path, 'Documents');
      case 'downloads':
        return path.join(dir.path, 'Downloads');
      case 'pictures':
        return path.join(dir.path, 'Pictures');
    }
    return null;
  }

  void _showAddDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder),
              title: const Text('新建文件夹'),
              onTap: () {
                Navigator.pop(ctx);
                _createFolder();
              },
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file),
              title: const Text('新建文件'),
              onTap: () {
                Navigator.pop(ctx);
                _createFile();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createFolder() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建文件夹'),
        content: TextField(controller: controller, decoration: const InputDecoration(hintText: '文件夹名称')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('创建')),
        ],
      ),
    );
    if (result == null || result.isEmpty || !mounted) return;

    try {
      await Directory(path.join(_currentPath, result)).create();
      _navigateTo(_currentPath);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('创建失败: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _createFile() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建文件'),
        content: TextField(controller: controller, decoration: const InputDecoration(hintText: '文件名（含扩展名）')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('创建')),
        ],
      ),
    );
    if (result == null || result.isEmpty || !mounted) return;

    try {
      await File(path.join(_currentPath, result)).create();
      _navigateTo(_currentPath);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('创建失败: $e'), backgroundColor: Colors.red),
      );
    }
  }
}

/// 文件底部操作菜单
enum FileAction { view, encrypt, decrypt, delete }

class _FileActionSheet extends StatelessWidget {
  final FileItem item;
  const _FileActionSheet({required this.item});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(item.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            Text(item.humanSize, style: TextStyle(fontSize: 12, color: Colors.grey)),
            const Divider(height: 24),
            _actionRow(context, icon: Icons.visibility, label: '查看', action: FileAction.view),
            if (!item.isEncryptedFile)
              _actionRow(context, icon: Icons.lock, label: '加密', action: FileAction.encrypt),
            if (item.isEncryptedFile)
              _actionRow(context, icon: Icons.lock_open, label: '解密', action: FileAction.decrypt),
            _actionRow(context, icon: Icons.delete, label: '删除', action: FileAction.delete, color: Colors.red),
          ],
        ),
      ),
    );
  }

  Widget _actionRow(BuildContext ctx, {required IconData icon, required String label, required FileAction action, Color? color}) {
    return ListTile(
      leading: Icon(icon, color: color ?? Colors.black87),
      title: Text(label, style: TextStyle(color: color)),
      onTap: () => Navigator.pop(ctx, action),
    );
  }
}

/// 文件列表行
class _FileListItem extends StatelessWidget {
  final FileItem item;
  final VoidCallback onTap;
  const _FileListItem({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        item.isDirectory ? Icons.folder : _fileIcon,
        color: item.isDirectory ? Colors.amber : (item.isEncryptedFile ? Colors.blue : Colors.grey),
      ),
      title: Text(
        item.name,
        style: TextStyle(fontWeight: item.isDirectory ? FontWeight.w500 : null),
      ),
      subtitle: !item.isDirectory ? Text(item.humanSize, style: const TextStyle(fontSize: 12, color: Colors.grey)) : null,
      trailing: item.isEncryptedFile ? const Icon(Icons.lock, size: 16, color: Colors.blue) : null,
      onTap: onTap,
    );
  }

  IconData get _fileIcon {
    final ext = item.ext;
    if (['jpg', 'jpeg', 'png', 'gif', 'webp'].contains(ext)) return Icons.image;
    if (['mp4', 'avi', 'mkv', 'mov'].contains(ext)) return Icons.videocam;
    if (['mp3', 'wav', 'flac'].contains(ext)) return Icons.audiotrack;
    if (ext == 'pdf') return Icons.picture_as_pdf;
    if (['txt', 'md', 'json'].contains(ext)) return Icons.text_snippet;
    return Icons.insert_drive_file;
  }
}
