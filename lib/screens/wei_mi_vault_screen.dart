import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/file_item.dart';
import '../services/disk_index_service.dart';
import '../services/encryption_service.dart';
import '../services/file_batch_ops.dart';
import '../services/file_operations_service.dart';
import '../services/file_viewer_service.dart';
import '../services/view_prefs_service.dart';
import '../widgets/file_selection_bar.dart';
import '../widgets/file_thumbnail.dart';
import '../widgets/global_search_dialog.dart';
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
  final Future<void> Function()? onEncryptFiles; // 加密文件（主界面流程）
  final Future<void> Function()? onDecryptFiles; // 解密文件（主界面流程）

  const WeiMiVaultScreen({
    super.key,
    this.showSystemDirs = false,
    this.initialPath,
    this.onEncryptFiles,
    this.onDecryptFiles,
  });

  @override
  State<WeiMiVaultScreen> createState() => WeiMiVaultScreenState();
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

class WeiMiVaultScreenState extends State<WeiMiVaultScreen> {
  static const String _kCustomDirsKey = 'weimi_custom_dirs';
  static const String _kVaultDirKey = 'weimi_vault_dir';
  static const String _kExpandedDirsKey = 'weimi_expanded_dirs';
  static const String _kCommonOpenKey = 'weimi_sec_common_open';
  static const String _kMineOpenKey = 'weimi_sec_mine_open';

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
  bool _commonOpen = true; // 「常用目录」分组展开
  bool _mineOpen = true; // 「我的目录」分组展开
  final Map<String, List<FileItem>> _dirChildren = {}; // 展开后的子项缓存
  final Map<String, bool> _dirLoading = {};
  List<String> _customDirs = []; // 用户添加的目录
  List<_DirEntry> _desktopDirs = []; // 桌面端常用目录
  final ScrollController _rootScroll = ScrollController();

  // ============ 固定搜索框（根视图与浏览视图共用） ============
  String _fileQuery = '';
  final TextEditingController _fileSearchCtrl = TextEditingController();

  bool get _isDesktop => !Platform.isAndroid && !Platform.isIOS;
  int _lastSelectIndex = -1; // 浏览视图 Shift 范围选择的锚点

  @override
  void initState() {
    super.initState();
    _initRoot();
    _navigateTo(widget.initialPath ?? '');
  }

  @override
  void dispose() {
    _rootScroll.dispose();
    _fileSearchCtrl.dispose();
    super.dispose();
  }

  Future<void> _initRoot() async {
    // 加密文件存放目录（用户设置的；未设置时由用户首次进入时选择）
    // + 折叠状态记忆
    try {
      final prefs = await SharedPreferences.getInstance();
      _vaultDir = prefs.getString(_kVaultDirKey);
      _commonOpen = prefs.getBool(_kCommonOpenKey) ?? true;
      _mineOpen = prefs.getBool(_kMineOpenKey) ?? true;
      final expanded = prefs.getStringList(_kExpandedDirsKey) ?? [];
      _expandedDirs.addAll(expanded);
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
    _persistExpandedDirs();
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
      _persistExpandedDirs();
      return;
    }

    // 每次展开都重新读取，保证内容新鲜
    setState(() {
      _expandedDirs.add(dirPath);
      _dirLoading[dirPath] = true;
    });
    _persistExpandedDirs();
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

  Future<void> _persistExpandedDirs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kExpandedDirsKey, _expandedDirs.toList());
    } catch (_) {}
  }

  Future<void> _setSectionOpen({required bool mine, required bool open}) async {
    setState(() {
      if (mine) {
        _mineOpen = open;
      } else {
        _commonOpen = open;
      }
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(mine ? _kMineOpenKey : _kCommonOpenKey, open);
    } catch (_) {}
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

  /// AppBar 标题：根视图/我的电脑虚拟路径/普通目录
  String _titleFor(String path, bool isRoot) {
    if (isRoot) return '文件';
    if (path == kMyComputerPath) return '我的电脑';
    return p.basename(path);
  }

  /// 系统返回键处理：true = 已内部消化（回到上一级/清除选择），false = 在根视图，允许退出应用
  bool handleSystemBack() {    if (_selectedPaths.isNotEmpty) {
      _clearSelection();
      return true;
    }
    if (_historyIndex > 0) {
      _goBack();
      return true;
    }
    return false;
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
        await _viewFile(item);
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
        await _decryptWithDialog(item);
        break;

      case FileAction.delete:
        await _deleteFile(item);
        break;
    }
  }

  /// 内置查看器打开（加密文件先问密码）
  Future<void> _viewFile(FileItem item) async {
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
  }

  /// 问密码后解密单个文件（右键菜单/操作面板共用）
  Future<void> _decryptWithDialog(FileItem item) async {
    final hint = await EncryptionService.getPasswordHint(item.fullPath);
    final password = await _showPasswordDialog(hint: hint);
    if (password == null || !mounted) return;
    _decryptFile(item.fullPath, password);
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

  // ============ 桌面端交互（单击选中/双击打开/右键菜单/Ctrl+Shift/Delete） ============

  /// 桌面端单击：Ctrl=加减选，Shift=范围选，普通=单选。文件夹直接进入。
  void _desktopTap(FileItem item, int index, List<FileItem> scope) {
    if (item.isDirectory) {
      _navigateTo(item.fullPath);
      return;
    }
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (shift && _lastSelectIndex >= 0 && _lastSelectIndex < scope.length) {
      final a = _lastSelectIndex < index ? _lastSelectIndex : index;
      final b = _lastSelectIndex < index ? index : _lastSelectIndex;
      setState(() {
        for (var i = a; i <= b; i++) {
          if (!scope[i].isDirectory) _selectedPaths.add(scope[i].fullPath);
        }
      });
      return;
    }
    if (ctrl) {
      _toggleSelect(item.fullPath);
    } else {
      setState(() {
        _selectedPaths.clear();
        _selectedPaths.add(item.fullPath);
      });
    }
    _lastSelectIndex = index;
  }

  /// 桌面端双击：文件夹进入，文件走操作面板（查看/加密/解密/删除）
  void _desktopOpen(FileItem item) {
    if (item.isDirectory) {
      _navigateTo(item.fullPath);
    } else {
      _openFile(item);
    }
  }

  PopupMenuItem<String> _ctxMenuItem(String value, IconData icon, String label,
      {Color? color}) {
    return PopupMenuItem<String>(
      value: value,
      height: 40,
      child: Row(children: [
        Icon(icon, size: 18, color: color ?? Colors.black87),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(color: color)),
      ]),
    );
  }

  /// 桌面端右键菜单：右键未选中项时先重置为该项；多选时给批量动作
  Future<void> _showContextMenu(
      FileItem item, Offset pos, int index, List<FileItem> scope) async {
    if (!item.isDirectory && !_selectedPaths.contains(item.fullPath)) {
      setState(() {
        _selectedPaths.clear();
        _selectedPaths.add(item.fullPath);
      });
      _lastSelectIndex = index;
    }
    final multi = !item.isDirectory && _selectedPaths.length > 1;
    final List<PopupMenuEntry<String>> entries;
    if (item.isDirectory) {
      entries = [_ctxMenuItem('open', Icons.folder_open, '打开')];
    } else if (multi) {
      entries = [
        _ctxMenuItem('share', Icons.share_outlined, '分享所选 (${_selectedPaths.length})'),
        _ctxMenuItem('move', Icons.drive_file_move_outlined, '移动所选'),
        _ctxMenuItem('copy', Icons.copy_all_outlined, '复制所选'),
        _ctxMenuItem('delete', Icons.delete_outline, '删除所选', color: Colors.red),
      ];
    } else {
      entries = [
        _ctxMenuItem('view', Icons.visibility_outlined, '查看'),
        if (!item.isEncryptedFile)
          _ctxMenuItem('encrypt', Icons.lock_outline, '加密'),
        if (item.isEncryptedFile)
          _ctxMenuItem('decrypt', Icons.lock_open_outlined, '解密'),
        const PopupMenuDivider(),
        _ctxMenuItem('copypath', Icons.content_copy, '复制路径'),
        _ctxMenuItem('delete', Icons.delete_outline, '删除', color: Colors.red),
      ];
    }
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 1, pos.dy + 1),
      items: entries,
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'open':
        _navigateTo(item.fullPath);
        break;
      case 'view':
        await _viewFile(item);
        break;
      case 'encrypt':
        _encryptFile(item.fullPath);
        break;
      case 'decrypt':
        await _decryptWithDialog(item);
        break;
      case 'copypath':
        await Clipboard.setData(ClipboardData(text: item.fullPath));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('路径已复制'), duration: Duration(seconds: 1)),
          );
        }
        break;
      case 'share':
        _shareSelected();
        break;
      case 'move':
        _moveSelected();
        break;
      case 'copy':
        _copySelected();
        break;
      case 'delete':
        _deleteSelected();
        break;
    }
  }

  /// Ctrl+A：全选当前可见文件
  void _selectAllVisibleFiles() {
    setState(() {
      _selectedPaths
          .addAll([for (final it in _browseItems) if (!it.isDirectory) it.fullPath]);
    });
  }

  Future<void> _deleteSelectedFromKeyboard() async {
    if (_selectedPaths.isEmpty) return;
    await _deleteSelected();
  }

  // ============ 全盘搜索（桌面端） ============

  void _openGlobalSearch() {
    showDialog<String>(
      context: context,
      builder: (ctx) => GlobalSearchDialog(initialQuery: _fileQuery),
    ).then((path) {
      if (path == null || !mounted) return;
      try {
        if (FileSystemEntity.isDirectorySync(path)) {
          _navigateTo(path);
        } else {
          final f = File(path);
          _openFile(FileItem(
            name: p.basename(path),
            fullPath: path,
            isDirectory: false,
            size: f.lengthSync(),
            modified: f.lastModifiedSync(),
          ));
        }
      } catch (_) {}
    });
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
              title: Text(_titleFor(_currentPath, isRoot)),
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
          : Focus(
              autofocus: true,
              child: CallbackShortcuts(
                bindings: _isDesktop
                    ? {
                        const SingleActivator(LogicalKeyboardKey.keyA, control: true):
                            _selectAllVisibleFiles,
                        const SingleActivator(LogicalKeyboardKey.delete):
                            _deleteSelectedFromKeyboard,
                      }
                    : const {},
                child: Column(
                  children: [
                    // 固定顶部搜索框（根视图与浏览视图都显示）
                    if (!_selecting) _buildFileSearchField(),
                    Expanded(
                      child: isRoot
                          ? _buildRootView()
                          : (_items.isEmpty ? _emptyState : _buildFileList()),
                    ),
                  ],
                ),
              ),
            ),
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
      floatingActionButton: !isRoot && isDesktop
          ? FloatingActionButton.extended(
              onPressed: () => _showAddDialog(),
              icon: const Icon(Icons.add),
              label: const Text('新建'),
            )
          : null,
    );
  }

  /// 文件页固定搜索框：根视图过滤展开目录的子项，浏览视图过滤当前目录
  Widget _buildFileSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        controller: _fileSearchCtrl,
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
            if (_isDesktop)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: ActionChip(
                  label: const Text('全盘', style: TextStyle(fontSize: 12)),
                  visualDensity: VisualDensity.compact,
                  onPressed: _openGlobalSearch,
                ),
              ),
            if (_fileQuery.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.clear, size: 18),
                onPressed: () {
                  _fileSearchCtrl.clear();
                  setState(() => _fileQuery = '');
                },
              ),
          ]),
          hintText: '搜索文件',
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
        ),
        onChanged: (v) => setState(() => _fileQuery = v.trim()),
      ),
    );
  }

  /// 根视图：搜索框 + 快捷操作卡 + 常用目录（含全部文件）+ 我的目录（加密目录 + 添加目录）
  Widget _buildRootView() {
    final entries = _buildRootEntries();
    final builtin = entries.where((e) => !e.isCustom && !e.isVault).toList();
    final customs = entries.where((e) => e.isCustom).toList();

    // 搜索过滤：有查询词时，只显示匹配的展开子项
    final q = _fileQuery.toLowerCase();
    bool matchChild(FileItem it) =>
        q.isEmpty || it.name.toLowerCase().contains(q);

    Widget section({
      required String title,
      required bool open,
      required ValueChanged<bool> onToggle,
      required List<Widget> children,
    }) {
      return Column(
        children: [
          InkWell(
            onTap: () => onToggle(!open),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Row(
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey.shade600,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    open ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: Colors.grey,
                  ),
                ],
              ),
            ),
          ),
          if (open) ...children,
        ],
      );
    }

    return Scrollbar(
      controller: _rootScroll,
      thumbVisibility: true, // 滚动条常显（含移动端）
      interactive: true,
      child: ListView(
        controller: _rootScroll,
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (Platform.isAndroid && !_storageGranted) _permissionBanner,
          // 快捷操作：加密 / 解密 / 微密飞传
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: _actionCard(
                    icon: Icons.lock,
                    label: '加密文件',
                    color: Colors.orange,
                    onTap: () =>
                        widget.onEncryptFiles?.call() ?? _pickAndEncrypt(),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _actionCard(
                    icon: Icons.lock_open,
                    label: '解密文件',
                    color: Colors.green,
                    onTap: () =>
                        widget.onDecryptFiles?.call() ?? _pickAndDecrypt(),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _actionCard(
                    icon: Icons.lan_outlined,
                    label: '微密飞传',
                    color: Colors.teal,
                    onTap: _openLanTransfer,
                  ),
                ),
              ],
            ),
          ),
          section(
            title: '常用目录',
            open: _commonOpen,
            onToggle: (v) => _setSectionOpen(mine: false, open: v),
            children: [
              // 全部文件/我的电脑入口（像手机文件管理器，浏览设备全部文件）
              ListTile(
                leading: Icon(
                  Platform.isAndroid ? Icons.apps : Icons.computer,
                  color: Colors.deepPurple,
                ),
                title: Text(Platform.isAndroid ? '我的手机' : '我的电脑',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(
                  Platform.isAndroid
                      ? '/storage/emulated/0'
                      : '所有磁盘与分区',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                ),
                trailing:
                    const Icon(Icons.chevron_right, color: Colors.grey),
                onTap: () => _navigateTo(Platform.isAndroid
                    ? '/storage/emulated/0'
                    : kMyComputerPath),
              ),
              for (final d in builtin) _buildDirTile(d, filterQuery: q),
            ],
          ),
          section(
            title: '我的目录',
            open: _mineOpen,
            onToggle: (v) => _setSectionOpen(mine: true, open: v),
            children: [
              // 加密文件存放目录（未设置时引导设置，置顶）
              if (_vaultDir == null)
                ListTile(
                  leading:
                      Icon(Icons.shield_outlined, color: Colors.blue.shade700),
                  title: const Text('加密文件存放目录',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: const Text('尚未设置，点击选择一个文件夹\n之后加密/接收的文件默认存入',
                      style: TextStyle(fontSize: 11)),
                  trailing: TextButton(
                    onPressed: _setupVaultDir,
                    child: const Text('设置'),
                  ),
                  onTap: _setupVaultDir,
                )
              else
                _buildDirTile(
                  _DirEntry(
                      '加密文件存放目录', _vaultDir!, Icons.shield_outlined,
                      isVault: true),
                  filterQuery: q,
                ),
              for (final d in customs) _buildDirTile(d, filterQuery: q),
              ListTile(
                leading: Icon(Icons.add_circle_outline,
                    color: Colors.blue.shade700),
                title: const Text('添加目录'),
                subtitle: const Text('选择手机/电脑上的任意文件夹加入列表',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                onTap: _addCustomDir,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 快捷操作卡（与主界面加密/解密同款样式）
  Widget _actionCard({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: color.withAlpha(15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withAlpha(50)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 24, color: color),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openLanTransfer() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const LanTransferScreen()),
    );
  }

  /// 未接主界面回调时的兜底：直接走文件选择 + 本页加密流程
  Future<void> _pickAndEncrypt() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    final files = result?.files.where((f) => f.path != null).toList() ?? [];
    for (final f in files) {
      if (!mounted) return;
      await _encryptFile(f.path!);
    }
  }

  Future<void> _pickAndDecrypt() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    final files = result?.files.where((f) => f.path != null).toList() ?? [];
    for (final f in files) {
      if (!mounted) return;
      final path = f.path!;
      if (!await EncryptionService.isEncryptedFile(path)) continue;
      final hint = await EncryptionService.getPasswordHint(path);
      final password = await _showPasswordDialog(hint: hint);
      if (password == null || !mounted) return;
      _decryptFile(path, password);
    }
  }

  List<_DirEntry> _buildRootEntries() {
    final entries = <_DirEntry>[];

    // 1. 平台常用目录
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

    // 2. 用户自定义目录
    for (final dirPath in _customDirs) {
      entries.add(_DirEntry(p.basename(dirPath), dirPath, Icons.folder_outlined,
          isCustom: true));
    }
    return entries;
  }

  /// 单个目录条目：默认折叠，点击展开列出其下的文件夹与文件（搜索时过滤子项）
  Widget _buildDirTile(_DirEntry d, {String filterQuery = ''}) {
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
        if (expanded) ..._buildExpandedContent(children, filterQuery),
      ],
    );
  }

  List<Widget> _buildExpandedContent(
      List<FileItem>? children, String filterQuery) {
    // 搜索过滤（不区分大小写）
    List<FileItem>? visible = children;
    if (filterQuery.isNotEmpty && children != null) {
      final q = filterQuery.toLowerCase();
      visible =
          children.where((it) => it.name.toLowerCase().contains(q)).toList();
    }
    if (visible == null) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (visible.isEmpty) {
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
      for (final item in visible) _buildChildRow(item),
      const Divider(height: 1, indent: 16),
    ];
  }

  /// 展开后的子项行（缩进显示）：文件夹点击进入浏览，文件点击走操作菜单
  Widget _buildChildRow(FileItem item) {
    final selectable = !item.isDirectory;
    final selected = selectable && _selectedPaths.contains(item.fullPath);
    return Padding(
      padding: const EdgeInsets.only(left: 24),
      child: GestureDetector(
        onDoubleTap: _isDesktop ? () => _desktopOpen(item) : null,
        onSecondaryTapUp: _isDesktop
            ? (d) => _showContextMenu(item, d.globalPosition, -1, const [])
            : null,
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
        onTap: _isDesktop
            ? () => _desktopTap(item, -1, const [])
            : () {
                if (_selecting) {
                  if (selectable) _toggleSelect(item.fullPath);
                } else {
                  _openFile(item);
                }
              },
        onLongPress: selectable && !_isDesktop
            ? () => _toggleSelect(item.fullPath)
            : null,
      ),
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

  /// 浏览视图条目（搜索框过滤，不区分大小写）
  List<FileItem> get _browseItems {
    if (_fileQuery.isEmpty) return _items;
    final q = _fileQuery.toLowerCase();
    return _items.where((it) => it.name.toLowerCase().contains(q)).toList();
  }

  Widget _buildFileList() {
    final items = _browseItems;
    if (items.isEmpty && _fileQuery.isNotEmpty) {
      return Center(
        child: Text('没有匹配的文件',
            style: TextStyle(fontSize: 14, color: Colors.grey.shade500)),
      );
    }
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
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  final selectable = !item.isDirectory;
                  final selected =
                      selectable && _selectedPaths.contains(item.fullPath);
                  return _FileListItem(
                    item: item,
                    selected: selected,
                    selecting: _selecting,
                    onTap: _isDesktop
                        ? () => _desktopTap(item, index, items)
                        : () {
                            if (_selecting) {
                              if (selectable) _toggleSelect(item.fullPath);
                            } else {
                              _openFile(item);
                            }
                          },
                    onDoubleTap:
                        _isDesktop ? () => _desktopOpen(item) : null,
                    onSecondaryTapUp: _isDesktop
                        ? (d) => _showContextMenu(
                            item, d.globalPosition, index, items)
                        : null,
                    onLongPress: selectable && !_isDesktop
                        ? () => _toggleSelect(item.fullPath)
                        : null,
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
    final items = _browseItems;
    return GridView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(10),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 130,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 0.78,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) => _buildCard(items[i], null, index: i, scope: items),
    );
  }

  /// 瀑布流视图（两列，图片按宽高比）
  Widget _buildWaterfallBody() {
    final items = _browseItems;
    // 图片比例未缓存的先异步解码，完成后刷新
    final missing = items
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
    for (final it in items) {
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
                child: _buildCard(it, hs[it] ?? 160,
                    index: _browseItems.indexOf(it), scope: _browseItems),
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
  Widget _buildCard(FileItem item, double? thumbHeight,
      {int index = -1, List<FileItem> scope = const []}) {
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
      onTap: _isDesktop
          ? () => _desktopTap(item, index, scope)
          : () {
              if (_selecting) {
                if (selectable) _toggleSelect(item.fullPath);
              } else {
                _openFile(item);
              }
            },
      onDoubleTap: _isDesktop ? () => _desktopOpen(item) : null,
      onSecondaryTapUp: _isDesktop
          ? (d) => _showContextMenu(item, d.globalPosition, index, scope)
          : null,
      onLongPress: selectable && !_isDesktop
          ? () => _toggleSelect(item.fullPath)
          : null,
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
  final VoidCallback? onDoubleTap;
  final GestureTapUpCallback? onSecondaryTapUp;
  final bool selected;
  final bool selecting;

  const _FileListItem({
    required this.item,
    required this.onTap,
    this.onLongPress,
    this.onDoubleTap,
    this.onSecondaryTapUp,
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
    return GestureDetector(
      onDoubleTap: onDoubleTap,
      onSecondaryTapUp: onSecondaryTapUp,
      child: ListTile(
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
      ),
    );
  }
}
