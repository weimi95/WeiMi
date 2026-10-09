import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/file_item.dart';
import '../services/encryption_service.dart';
import '../services/file_batch_ops.dart';
import '../services/file_operations_service.dart';
import '../services/file_viewer_service.dart';
import '../services/view_prefs_service.dart';
import '../widgets/file_selection_bar.dart';
import '../widgets/file_thumbnail.dart';
import 'lan_transfer_screen.dart';

/// WeiMi Vault 屏幕
///
/// 根视图（「文件」标签首页）：
/// - 常用目录：内置（微密 Vault / 下载 / 文档 / 图片 / 相册 / 音乐 / 视频，桌面端为用户主目录下的常用目录）
/// - 我的目录：用户自行添加（file_picker 选目录，持久化到 SharedPreferences，长按移除）
/// - 每个目录默认折叠，点击展开就地列出其下的文件夹与文件
/// - 整页可滚动并显示滚动条（Scrollbar）
///
/// 点击子文件夹进入浏览视图（原有的前进/后退导航），点击文件走 查看/加密/解密/删除 流程。
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

/// 目录条目（根视图折叠列表里的一项）
class _DirEntry {
  final String title;
  final String dirPath;
  final IconData icon;
  final bool isVault; // 加密文件存放目录
  final bool isCustom; // 用户手动添加的目录

  const _DirEntry(
    this.title,
    this.dirPath,
    this.icon, {
    this.isVault = false,
    this.isCustom = false,
  });
}

class _WeiMiVaultScreenState extends State<WeiMiVaultScreen> {
  static const String _kCustomDirsKey = 'weimi_custom_dirs';
  static const String _kVaultDirKey = 'weimi_vault_dir';

  // ============ 浏览视图（进入某目录后）状态 ============
  List<FileItem> _items = [];
  bool _loading = true;
  String _currentPath = '';
  List<String> _pathHistory = [];
  int _historyIndex = -1;

  // ============ 根视图（目录折叠列表）状态 ============
  String? _vaultDir; // 加密文件存放目录（用户设置，null = 未设置）
  bool _storageGranted = true; // Android 存储权限（桌面端恒 true）
  final Set<String> _expandedDirs = {}; // 展开中的目录
  final Map<String, List<FileItem>> _dirChildren = {}; // 展开后的子项缓存
  final Map<String, bool> _dirLoading = {};
  List<String> _customDirs = []; // 用户添加的目录
  List<_DirEntry> _desktopDirs = []; // 桌面端常用目录
  final ScrollController _rootScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _initRoot();
    _navigateTo(widget.initialPath ?? '');
  }

  @override
  void dispose() {
    _rootScroll.dispose();
    super.dispose();
  }

  Future<void> _initRoot() async {
    // 加密文件存放目录（用户设置的；未设置时由用户首次进入时选择）
    try {
      final prefs = await SharedPreferences.getInstance();
      _vaultDir = prefs.getString(_kVaultDirKey);
    } catch (_) {}

    // 桌面端常用目录
    if (!Platform.isAndroid && !Platform.isIOS) {
      final home =
          Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) {
        _desktopDirs = [
          _DirEntry('桌面', p.join(home, 'Desktop'), Icons.desktop_windows_outlined),
          _DirEntry('文档', p.join(home, 'Documents'), Icons.description_outlined),
          _DirEntry('下载', p.join(home, 'Downloads'), Icons.download_outlined),
          _DirEntry('图片', p.join(home, 'Pictures'), Icons.image_outlined),
        ];
      }
    }

    // Android 存储权限状态
    if (Platform.isAndroid) {
      try {
        final status = await Permission.manageExternalStorage.status;
        _storageGranted = status.isGranted;
      } catch (_) {}
    }

    // 用户自定义目录
    try {
      final prefs = await SharedPreferences.getInstance();
      _customDirs = prefs.getStringList(_kCustomDirsKey) ?? [];
    } catch (_) {}

    if (mounted) setState(() {});
  }

  // ============ 权限 ============

  Future<void> _requestStoragePermission() async {
    final status = await Permission.manageExternalStorage.request();
    if (status.isGranted) {
      if (mounted) setState(() => _storageGranted = true);
    } else if (status.isPermanentlyDenied || status.isRestricted) {
      await openAppSettings();
    }
    // 复查一次（用户可能去设置里开了再回来）
    final now = await Permission.manageExternalStorage.status;
    if (mounted) setState(() => _storageGranted = now.isGranted);
  }

  Widget get _permissionBanner => Container(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.orange.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.orange.shade200),
        ),
        child: Row(
          children: [
            Icon(Icons.warning_amber_outlined,
                size: 20, color: Colors.orange.shade700),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '需要「所有文件访问」权限才能浏览手机目录',
                style: TextStyle(fontSize: 13, color: Colors.orange.shade900),
              ),
            ),
            TextButton(
              onPressed: _requestStoragePermission,
              child: const Text('去授权'),
            ),
          ],
        ),
      );

  // ============ 我的目录：添加 / 移除 ============

  Future<void> _addCustomDir() async {
    String? picked = await FilePicker.platform
        .getDirectoryPath(dialogTitle: '选择要添加的目录');
    if (picked == null || !mounted) return;
    picked = _normalizeAndroidDir(picked);

    final exists = await Directory(picked).exists();
    if (!exists) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('目录不存在或无法访问: $picked')),
      );
      return;
    }
    if (_customDirs.contains(picked) ||
        (_vaultDir != null && picked == _vaultDir)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该目录已在列表中')),
      );
      return;
    }

    setState(() => _customDirs.add(picked!));
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kCustomDirsKey, _customDirs);
    } catch (_) {}
  }

  /// Android 上 file_picker 可能返回 SAF tree 路径（/tree/primary:Download），
  /// 转换为真实文件系统路径（/storage/emulated/0/Download）
  String _normalizeAndroidDir(String path) {
    if (!Platform.isAndroid) return path;
    final m = RegExp(r'^/tree/([^:]+):(.*)$').firstMatch(path);
    if (m == null) return path;
    final vol = m.group(1)!;
    final rest = m.group(2)!;
    final base = vol == 'primary' ? '/storage/emulated/0' : '/storage/$vol';
    return rest.isEmpty ? base : '$base/$rest';
  }

  Future<void> _removeCustomDir(String dirPath) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除目录'),
        content: Text('从列表移除 "${p.basename(dirPath)}"？\n（不会删除磁盘上的文件）'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('移除')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _customDirs.remove(dirPath);
      _expandedDirs.remove(dirPath);
      _dirChildren.remove(dirPath);
      _dirLoading.remove(dirPath);
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kCustomDirsKey, _customDirs);
    } catch (_) {}
  }

  // ============ 加密文件存放目录：设置 / 更改 ============

  /// 首次设置或更改「加密文件存放目录」。加密完成的文件默认存这里，
  /// 局域网收到的文件也落在这里。
  Future<void> _setupVaultDir() async {
    final picked = await FilePicker.platform
        .getDirectoryPath(dialogTitle: '选择加密文件的存放目录');
    if (picked == null || !mounted) return;
    final dir = _normalizeAndroidDir(picked);

    final exists = await Directory(dir).exists();
    if (!exists) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('目录不存在或无法访问: $dir')),
      );
      return;
    }

    setState(() => _vaultDir = dir);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kVaultDirKey, dir);
    } catch (_) {}
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已设置，之后加密/接收的文件默认存入: $dir')),
      );
    }
  }

  // ============ 目录展开 / 折叠 ============

  Future<void> _toggleDir(String dirPath) async {
    if (_expandedDirs.contains(dirPath)) {
      setState(() => _expandedDirs.remove(dirPath));
      return;
    }

    // 每次展开都重新读取，保证内容新鲜
    setState(() {
      _expandedDirs.add(dirPath);
      _dirLoading[dirPath] = true;
    });
    try {
      final items = await listDirectory(dirPath);
      if (!mounted) return;
      setState(() {
        _dirChildren[dirPath] = items;
        _dirLoading[dirPath] = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _dirChildren[dirPath] = [];
        _dirLoading[dirPath] = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法读取目录: $e')),
      );
    }
  }

  // ============ 导航（浏览视图） ============

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

  // ============ 文件操作 ============

  Future<void> _openFile(FileItem item) async {
    if (!mounted) return;

    if (item.isDirectory) {
      _navigateTo(item.fullPath);
      return;
    }

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

    // 已设置「加密文件存放目录」时直接用它，不再每次询问
    String? outputDir;
    if (_vaultDir != null) {
      outputDir = _vaultDir;
    } else {
      outputDir = await FileOperationsService.pickOutputDirectory();
    }
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
        _refreshAfterOp(filePath);
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
        _refreshAfterOp(filePath);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('解密失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// 操作后刷新：在浏览视图则刷新当前目录，展开的目录列表也刷新缓存
  void _refreshAfterOp(String opFilePath) {
    final dir = p.dirname(opFilePath);
    if (_currentPath.isNotEmpty) {
      _navigateTo(_currentPath);
    }
    if (_dirChildren.containsKey(dir)) {
      _dirChildren.remove(dir);
      if (_expandedDirs.contains(dir)) _toggleDir(dir);
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
        if (_currentPath.isNotEmpty) {
          _navigateTo(_currentPath);
        } else {
          // 根视图里删除：刷新对应展开目录
          final dir = p.dirname(item.fullPath);
          _dirChildren.remove(dir);
          if (_expandedDirs.contains(dir)) _toggleDir(dir);
          setState(() {});
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // ============ 多选模式 ============

  final Set<String> _selectedPaths = {}; // 当前选中的文件路径
  bool _aspectRefreshing = false; // 瀑布流图片比例异步加载标记
  bool get _selecting => _selectedPaths.isNotEmpty;

  void _toggleSelect(String path) {
    setState(() {
      if (!_selectedPaths.remove(path)) _selectedPaths.add(path);
    });
  }

  void _clearSelection() => setState(_selectedPaths.clear);

  void _selectAllVisible(Iterable<String> paths) {
    setState(() => _selectedPaths.addAll(paths));
  }

  /// 操作后统一刷新：浏览视图刷新当前目录，根视图失效展开缓存
  Future<void> _afterBatchChange(Iterable<String> touchedPaths) async {
    for (final dir in {for (final p0 in touchedPaths) p.dirname(p0)}) {
      _invalidateDir(dir);
    }
    if (_currentPath.isNotEmpty) {
      _navigateTo(_currentPath);
    } else {
      setState(() {});
    }
  }

  Future<void> _shareSelected() async {
    await FileBatchOps.share(context, _selectedPaths.toList());
  }

  Future<void> _copySelected() async {
    await FileBatchOps.copyTo(context, _selectedPaths.toList(),
        afterChange: () async {});
  }

  Future<void> _moveSelected() async {
    final paths = _selectedPaths.toList();
    await FileBatchOps.moveTo(context, paths,
        afterChange: () => _afterBatchChange(paths));
    if (mounted) _clearSelection();
  }

  Future<void> _deleteSelected() async {
    final paths = _selectedPaths.toList();
    await FileBatchOps.delete(context, paths,
        afterChange: () => _afterBatchChange(paths));
    if (mounted) _clearSelection();
  }

  Future<void> _moreSelected() async {
    final single = _selectedPaths.length == 1 ? _selectedPaths.first : null;
    final action = await FileBatchOps.moreSheet(context, single: single != null);
    if (action == null || !mounted) return;
    switch (action) {
      case 'info':
        await FileBatchOps.info(context, single!);
        break;
      case 'rename':
        await FileBatchOps.rename(context, single!,
            afterChange: () => _afterBatchChange([single]));
        if (mounted) _clearSelection();
        break;
      case 'encrypt':
        if (single != null) {
          _encryptFile(single);
        } else {
          // 多选加密：逐个走单文件加密流程（每个文件都要确认密码）
          for (final f in _selectedPaths.toList()) {
            if (!mounted) return;
            await _encryptFile(f);
          }
        }
        if (mounted) _clearSelection();
        break;
    }
  }

  /// 使目录展开缓存失效（存在则移除，保持折叠状态时下次展开重新读取）
  void _invalidateDir(String dir) {
    _dirChildren.remove(dir);
  }

  /// 当前界面可见、可参与多选的文件路径（不含文件夹）
  Iterable<String> _visibleSelectableFiles() sync* {
    if (_currentPath.isNotEmpty) {
      for (final item in _items) {
        if (!item.isDirectory) yield item.fullPath;
      }
    } else {
      for (final children in _dirChildren.values) {
        if (children == null) continue;
        for (final item in children) {
          if (!item.isDirectory) yield item.fullPath;
        }
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

  // ============ UI 构建 ============

  @override
  Widget build(BuildContext context) {
    final isDesktop = !Platform.isAndroid && !Platform.isIOS;
    final isRoot = _currentPath.isEmpty;

    return Scaffold(
      appBar: _selecting
          ? AppBar(
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: _clearSelection,
              ),
              title: Text('已选择 ${_selectedPaths.length} 项'),
              actions: [
                TextButton(
                  onPressed: () =>
                      _selectAllVisible(_visibleSelectableFiles()),
                  child: const Text('全选'),
                ),
              ],
            )
          : AppBar(
              title: Text(isRoot ? '文件' : p.basename(_currentPath)),
              leading: _historyIndex > 0
                  ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: _goBack)
                  : null,
              actions: [
                if (_historyIndex < _pathHistory.length - 1)
                  IconButton(icon: const Icon(Icons.arrow_forward), onPressed: _goForward),
              ],
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (isRoot ? _buildRootView() : (_items.isEmpty ? _emptyState : _buildFileList())),
      bottomSheet: _selecting && !_loading
          ? FileSelectionBar(
              count: _selectedPaths.length,
              onShare: _shareSelected,
              onMove: _moveSelected,
              onCopy: _copySelected,
              onDelete: _deleteSelected,
              onMore: _moreSelected,
            )
          : null,
      floatingActionButton: isRoot
          ? FloatingActionButton.extended(
              onPressed: _addCustomDir,
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('添加目录'),
            )
          : (isDesktop
              ? FloatingActionButton.extended(
                  onPressed: () => _showAddDialog(),
                  icon: const Icon(Icons.add),
                  label: const Text('新建'),
                )
              : null),
    );
  }

  /// 根视图：全部文件入口 + 常用目录（含加密文件存放目录）+ 我的目录 + 局域网传输
  Widget _buildRootView() {
    final entries = _buildRootEntries();

    return Scrollbar(
      controller: _rootScroll,
      thumbVisibility: true, // 滚动条常显（含移动端）
      interactive: true,
      child: ListView(
        controller: _rootScroll,
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          if (Platform.isAndroid && !_storageGranted) _permissionBanner,
          // 全部文件入口（像手机文件管理器，浏览设备全部文件）
          ListTile(
            leading: const Icon(Icons.apps, color: Colors.deepPurple),
            title: const Text('全部文件',
                style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
              Platform.isAndroid ? '/storage/emulated/0' : _homeDir(),
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
            ),
            trailing:
                const Icon(Icons.chevron_right, color: Colors.grey),
            onTap: () => _navigateTo(Platform.isAndroid
                ? '/storage/emulated/0'
                : _homeDir()),
          ),
          const Divider(height: 1, indent: 16),
          // 加密文件存放目录（未设置时引导设置）
          if (_vaultDir == null)
            ListTile(
              leading: Icon(Icons.shield_outlined, color: Colors.blue.shade700),
              title: const Text('加密文件存放目录',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text('尚未设置，点击选择一个文件夹\n之后加密/接收的文件默认存入',
                  style: TextStyle(fontSize: 11)),
              trailing: TextButton(
                onPressed: _setupVaultDir,
                child: const Text('设置'),
              ),
              onTap: _setupVaultDir,
            ),
          _sectionHeader('常用目录'),
          for (final d in entries.where((e) => !e.isCustom))
            _buildDirTile(d),
          _sectionHeader('我的目录'),
          for (final d in entries.where((e) => e.isCustom)) _buildDirTile(d),
          ListTile(
            leading: Icon(Icons.add_circle_outline, color: Colors.blue.shade700),
            title: const Text('添加目录'),
            subtitle: const Text('选择手机/电脑上的任意文件夹加入列表',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            onTap: _addCustomDir,
          ),
          const Divider(height: 1, indent: 16),
          // 局域网传输入口
          ListTile(
            leading: const Icon(Icons.lan_outlined, color: Colors.teal),
            title: const Text('局域网传输',
                style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: const Text('同一 WiFi 下发现设备、互传文件（支持加密发送）',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            trailing: const Icon(Icons.chevron_right, color: Colors.grey),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (context) => const LanTransferScreen()),
              );
            },
          ),
        ],
      ),
    );
  }

  String _homeDir() {
    return Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '/';
  }

  List<_DirEntry> _buildRootEntries() {
    final entries = <_DirEntry>[];

    // 1. 加密文件存放目录（用户设置过的才出现在折叠列表里）
    if (_vaultDir != null) {
      entries.add(_DirEntry(
          '加密文件存放目录', _vaultDir!, Icons.shield_outlined,
          isVault: true));
    }

    // 2. 平台常用目录
    if (Platform.isAndroid) {
      const root = '/storage/emulated/0';
      entries.addAll([
        const _DirEntry('下载', '$root/Download', Icons.download_outlined),
        const _DirEntry('文档', '$root/Documents', Icons.description_outlined),
        const _DirEntry('图片', '$root/Pictures', Icons.image_outlined),
        const _DirEntry('相册', '$root/DCIM', Icons.photo_camera_outlined),
        const _DirEntry('音乐', '$root/Music', Icons.music_note_outlined),
        const _DirEntry('视频', '$root/Movies', Icons.movie_outlined),
      ]);
    } else {
      entries.addAll(_desktopDirs);
    }

    // 3. 用户自定义目录
    for (final dirPath in _customDirs) {
      entries.add(_DirEntry(p.basename(dirPath), dirPath, Icons.folder_outlined,
          isCustom: true));
    }
    return entries;
  }

  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: Colors.grey.shade600,
          ),
        ),
      );

  /// 单个目录条目：默认折叠，点击展开列出其下的文件夹与文件
  Widget _buildDirTile(_DirEntry d) {
    final expanded = _expandedDirs.contains(d.dirPath);
    final loading = _dirLoading[d.dirPath] == true;
    final children = _dirChildren[d.dirPath];

    return Column(
      children: [
        ListTile(
          leading: Icon(
            d.icon,
            color: d.isVault
                ? Colors.blue
                : (d.isCustom ? Colors.teal : Colors.amber.shade700),
          ),
          title: Text(d.title, style: const TextStyle(fontWeight: FontWeight.w500)),
          subtitle: Text(
            d.dirPath,
            style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (d.isCustom)
                IconButton(
                  icon: const Icon(Icons.close, size: 18, color: Colors.grey),
                  tooltip: '移除',
                  onPressed: () => _removeCustomDir(d.dirPath),
                ),
              if (loading)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  color: Colors.grey,
                ),
            ],
          ),
          onTap: () => _toggleDir(d.dirPath),
          onLongPress: d.isVault ? _setupVaultDir : null, // 长按更改加密目录
        ),
        if (expanded) ..._buildExpandedContent(children),
      ],
    );
  }

  List<Widget> _buildExpandedContent(List<FileItem>? children) {
    if (children == null) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (children.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Center(
            child: Text('空目录', style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
          ),
        ),
        const Divider(height: 1, indent: 16),
      ];
    }
    return [
      for (final item in children) _buildChildRow(item),
      const Divider(height: 1, indent: 16),
    ];
  }

  /// 展开后的子项行（缩进显示）：文件夹点击进入浏览，文件点击走操作菜单
  Widget _buildChildRow(FileItem item) {
    final selectable = !item.isDirectory;
    final selected = selectable && _selectedPaths.contains(item.fullPath);
    return Padding(
      padding: const EdgeInsets.only(left: 24),
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        leading: _selecting && selectable
            ? Icon(
                selected
                    ? Icons.check_box
                    : Icons.check_box_outline_blank,
                size: 20,
                color: selected ? Colors.blue : Colors.grey,
              )
            : Icon(
                item.isDirectory ? Icons.folder : _fileIcon(item),
                size: 20,
                color: item.isDirectory
                    ? Colors.amber.shade700
                    : (item.isEncryptedFile ? Colors.blue : Colors.grey),
              ),
        title: Text(item.name, style: const TextStyle(fontSize: 14)),
        subtitle: !item.isDirectory
            ? Text(item.humanSize,
                style: const TextStyle(fontSize: 11, color: Colors.grey))
            : null,
        trailing: item.isEncryptedFile && !_selecting
            ? const Icon(Icons.lock, size: 14, color: Colors.blue)
            : null,
        onTap: () {
          if (_selecting) {
            if (selectable) _toggleSelect(item.fullPath);
          } else {
            _openFile(item);
          }
        },
        onLongPress: selectable ? () => _toggleSelect(item.fullPath) : null,
      ),
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
    return Scrollbar(
      thumbVisibility: true, // 文件多时滚动条常显
      interactive: true,
      child: AnimatedBuilder(
        animation: ViewPrefsService.instance,
        builder: (context, _) {
          switch (ViewPrefsService.instance.mode) {
            case ViewMode.grid:
              return _buildGridBody();
            case ViewMode.waterfall:
              return _buildWaterfallBody();
            case ViewMode.list:
            default:
              return ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: _items.length,
                itemBuilder: (context, index) {
                  final item = _items[index];
                  final selectable = !item.isDirectory;
                  final selected =
                      selectable && _selectedPaths.contains(item.fullPath);
                  return _FileListItem(
                    item: item,
                    selected: selected,
                    selecting: _selecting,
                    onTap: () {
                      if (_selecting) {
                        if (selectable) _toggleSelect(item.fullPath);
                      } else {
                        _openFile(item);
                      }
                    },
                    onLongPress:
                        selectable ? () => _toggleSelect(item.fullPath) : null,
                  );
                },
              );
          }
        },
      ),
    );
  }

  /// 宫格视图（文件夹 + 文件卡片）
  Widget _buildGridBody() {
    return GridView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(10),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 130,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 0.78,
      ),
      itemCount: _items.length,
      itemBuilder: (context, i) => _buildCard(_items[i], null),
    );
  }

  /// 瀑布流视图（两列，图片按宽高比）
  Widget _buildWaterfallBody() {
    // 图片比例未缓存的先异步解码，完成后刷新
    final missing = _items
        .where((it) =>
            !it.isDirectory &&
            FileThumbs.isImage(it.name) &&
            !FileThumbs.aspectCache.containsKey(it.fullPath))
        .toList();
    if (missing.isNotEmpty && !_aspectRefreshing) {
      _aspectRefreshing = true;
      Future.wait(missing.take(60).map((it) =>
              FileThumbs.aspectRatio(it.fullPath)))
          .then((_) {
        _aspectRefreshing = false;
        if (mounted) setState(() {});
      });
    }

    final colA = <FileItem>[];
    final colB = <FileItem>[];
    final hA = <FileItem, double>{};
    final hB = <FileItem, double>{};
    double sumA = 0, sumB = 0;
    for (final it in _items) {
      final ratio =
          it.isDirectory ? null : FileThumbs.aspectCache[it.fullPath];
      final thumbH = it.isDirectory
          ? 120.0
          : ratio == null || ratio <= 0
              ? 160.0
              : (260.0 / ratio).clamp(120.0, 320.0);
      final itemH = thumbH + 52;
      if (sumA <= sumB) {
        colA.add(it);
        hA[it] = thumbH;
        sumA += itemH;
      } else {
        colB.add(it);
        hB[it] = thumbH;
        sumB += itemH;
      }
    }

    Widget col(List<FileItem> items, Map<FileItem, double> hs) {
      return Expanded(
        child: Column(
          children: [
            for (final it in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _buildCard(it, hs[it] ?? 160),
              ),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [col(colA, hA), const SizedBox(width: 10), col(colB, hB)],
      ),
    );
  }

  /// 文件/文件夹卡片（宫格与瀑布流共用）
  Widget _buildCard(FileItem item, double? thumbHeight) {
    final selectable = !item.isDirectory;
    final selected = selectable && _selectedPaths.contains(item.fullPath);

    Widget thumbArea;
    if (item.isDirectory) {
      thumbArea = Icon(
        Icons.folder,
        size: 56,
        color: Colors.amber.shade600,
      );
    } else if (thumbHeight != null) {
      // 瀑布流：固定高度容器内放缩略图
      thumbArea = SizedBox(
        width: double.infinity,
        height: thumbHeight,
        child: FileThumbnail(path: item.fullPath, name: item.name, size: 64),
      );
    } else {
      thumbArea = FileThumbnail(path: item.fullPath, name: item.name, size: 72);
    }

    final Widget imageSection = thumbHeight != null
        ? ClipRRect(
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(9)),
            child: thumbArea,
          )
        : Expanded(
            child: Center(child: thumbArea),
          );

    return InkWell(
      onTap: () {
        if (_selecting) {
          if (selectable) _toggleSelect(item.fullPath);
        } else {
          _openFile(item);
        }
      },
      onLongPress: selectable ? () => _toggleSelect(item.fullPath) : null,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? Colors.blue : Colors.grey.shade200,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            imageSection,
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight:
                          item.isDirectory ? FontWeight.w500 : null,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    item.isDirectory ? '文件夹' : item.humanSize,
                    style:
                        TextStyle(fontSize: 10, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
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
      await Directory(p.join(_currentPath, result)).create();
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
      await File(p.join(_currentPath, result)).create();
      _navigateTo(_currentPath);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('创建失败: $e'), backgroundColor: Colors.red),
      );
    }
  }
}

/// 按扩展名取文件图标
IconData _fileIcon(FileItem item) {
  final ext = item.ext;
  if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic'].contains(ext)) {
    return Icons.image;
  }
  if (['mp4', 'avi', 'mkv', 'mov', 'wmv', 'flv'].contains(ext)) {
    return Icons.videocam;
  }
  if (['mp3', 'wav', 'flac', 'aac', 'm4a', 'ogg'].contains(ext)) {
    return Icons.audiotrack;
  }
  if (ext == 'pdf') return Icons.picture_as_pdf;
  if (['txt', 'md', 'json', 'xml', 'csv', 'yaml', 'log'].contains(ext)) {
    return Icons.text_snippet;
  }
  return Icons.insert_drive_file;
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
  final VoidCallback? onLongPress;
  final bool selected;
  final bool selecting;

  const _FileListItem({
    required this.item,
    required this.onTap,
    this.onLongPress,
    this.selected = false,
    this.selecting = false,
  });

  @override
  Widget build(BuildContext context) {
    final showCheck = selecting && !item.isDirectory;
    final Widget leading;
    if (showCheck) {
      leading = Icon(
        selected ? Icons.check_box : Icons.check_box_outline_blank,
        color: selected ? Colors.blue : Colors.grey,
      );
    } else if (item.isDirectory) {
      leading = const Icon(Icons.folder, color: Colors.amber);
    } else {
      leading = FileThumbnail(path: item.fullPath, name: item.name, size: 42);
    }
    return ListTile(
      leading: leading,
      title: Text(
        item.name,
        style: TextStyle(fontWeight: item.isDirectory ? FontWeight.w500 : null),
      ),
      subtitle: !item.isDirectory ? Text(item.humanSize, style: const TextStyle(fontSize: 12, color: Colors.grey)) : null,
      trailing: item.isEncryptedFile && !selecting
          ? const Icon(Icons.lock, size: 16, color: Colors.blue)
          : null,
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}
