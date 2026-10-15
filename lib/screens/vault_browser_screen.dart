import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/file_viewer_service.dart';
import '../services/vault_biometric.dart';
import '../services/vault_service.dart';

/// 微密保险箱：设置引导 → 锁定屏 → 解锁后宫格
class VaultBrowserScreen extends StatefulWidget {
  const VaultBrowserScreen({super.key});

  @override
  State<VaultBrowserScreen> createState() => _VaultBrowserScreenState();
}

class _VaultBrowserScreenState extends State<VaultBrowserScreen>
    with WidgetsBindingObserver {
  static const _imgExt = {
    'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'heic', 'heif',
  };
  static const _videoExt = {
    'mp4', 'mov', 'avi', 'mkv', 'webm', 'm4v', '3gp', 'ts', 'flv', 'wmv',
  };

  bool _loading = true;
  bool _setupMode = false; // 未设置保险箱 → 引导创建
  String? _vaultDir;
  VaultLockInfo _lockInfo =
      const VaultLockInfo(lockedOut: false, remainingSec: 0, failCount: 0);

  // 解锁后的宫格状态
  List<FileSystemEntity> _files = [];
  final Map<String, Uint8List?> _thumbCache = {};
  bool _busy = false;

  // 设置引导输入
  final _pw1Ctrl = TextEditingController();
  final _pw2Ctrl = TextEditingController();
  String _chosenDir = '';

  // 锁定屏输入
  final _unlockCtrl = TextEditingController();
  bool _canBiometric = false;
  int _countdownSec = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshAll();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pw1Ctrl.dispose();
    _pw2Ctrl.dispose();
    _unlockCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    // 严格模式：切后台/最小化即锁（可选开关）
    if (state == AppLifecycleState.hidden &&
        VaultService.instance.isUnlocked) {
      final lockOnExit = await VaultService.instance.getLockOnExit();
      if (lockOnExit) {
        await VaultService.instance.lock();
        if (mounted) _refreshAll();
      }
    }
  }

  Future<void> _refreshAll() async {
    final dir = await VaultService.instance.getVaultDir();
    final setup = !(await VaultService.instance.isSetup());
    setState(() {
      _vaultDir = dir;
      _setupMode = setup;
      _loading = false;
    });
    if (setup) {
      final canBio = await VaultBiometricService.canAuth();
      if (mounted && canBio != _canBiometric) {
        setState(() => _canBiometric = canBio);
      }
      return;
    }
    if (VaultService.instance.isUnlocked) {
      await _loadFiles();
    } else {
      final info = await VaultService.instance.lockInfo(dir ?? '.');
      if (mounted) {
        setState(() => _lockInfo = info);
        _startCountdown(info.remainingSec);
      }
      final canBio = await VaultBiometricService.canAuth();
      final enabled = await VaultBiometricService.isEnabled();
      final has = await VaultBiometricService.hasSavedMaster();
      if (mounted) {
        setState(() => _canBiometric = canBio && enabled && has);
      }
    }
  }

  void _startCountdown(int sec) {
    if (sec <= 0) return;
    setState(() => _countdownSec = sec);
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return false;
      if (_countdownSec <= 1) {
        setState(() => _countdownSec = 0);
        return false;
      }
      setState(() => _countdownSec -= 1);
      return true;
    });
  }

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_setupMode) return _buildSetup();
    if (!VaultService.instance.isUnlocked) return _buildLocked();
    return _buildBrowser();
  }

  // ---------- 设置引导 ----------

  Widget _buildSetup() {
    final strong = _pw1Ctrl.text.length >= 12;
    final valid = _pw1Ctrl.text.length >= 8 &&
        _pw1Ctrl.text == _pw2Ctrl.text &&
        _chosenDir.isNotEmpty;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.lock_outline, size: 56),
              const SizedBox(height: 12),
              Text('微密保险箱',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              const Text(
                '箱内文件加密保存并隐藏内容，进入需要主密码。'
                '\n主密码一旦忘记将无法找回，请务必牢记。',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              OutlinedButton.icon(
                icon: const Icon(Icons.folder_open),
                label: Text(_chosenDir.isEmpty
                    ? '选择保险箱目录'
                    : _chosenDir),
                onPressed: _pickSetupDir,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _pw1Ctrl,
                obscureText: true,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: '设置主密码（至少 8 位）',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_pw1Ctrl.text.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: LinearProgressIndicator(
                          value: (_pw1Ctrl.text.length / 16).clamp(0.0, 1.0),
                          color: strong ? Colors.green : Colors.orange,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(strong ? '强' : '建议 12 位以上',
                          style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: _pw2Ctrl,
                obscureText: true,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: '确认主密码',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('创建保险箱'),
                onPressed: valid ? _createVault : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickSetupDir() async {
    VaultService.instance.notifyActivity();
    try {
      final res = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择保险箱目录',
      );
      if (res == null || res.isEmpty) return;
      setState(() => _chosenDir = res);
    } catch (_) {}
  }

  Future<void> _createVault() async {
    setState(() => _busy = true);
    try {
      await VaultService.instance.createVault(_chosenDir, _pw1Ctrl.text);
      await VaultService.instance.unlock(_pw1Ctrl.text);
      if (!mounted) return;
      _pw1Ctrl.clear();
      _pw2Ctrl.clear();
      await _refreshAll();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------- 锁定屏 ----------

  Widget _buildLocked() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.lock, size: 56),
              const SizedBox(height: 12),
              Text('保险箱已锁定',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge),
              if (_vaultDir != null) ...[
                const SizedBox(height: 4),
                Text(_vaultDir!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
              const SizedBox(height: 24),
              TextField(
                controller: _unlockCtrl,
                obscureText: true,
                enabled: _countdownSec == 0 && !_busy,
                onSubmitted: (_) => _tryUnlock(),
                decoration: InputDecoration(
                  labelText: '主密码',
                  border: const OutlineInputBorder(),
                  errorText: _lockInfo.failCount > 0 && _countdownSec == 0
                      ? '密码错误（${_lockInfo.failCount}/${VaultService.maxAttempts}）'
                      : null,
                ),
              ),
              if (_countdownSec > 0) ...[
                const SizedBox(height: 12),
                Text(
                  '错误次数过多，$_countdownSec 秒后可重试',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.red),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.lock_open),
                label: const Text('解锁'),
                onPressed:
                    (_countdownSec > 0 || _busy) ? null : _tryUnlock,
              ),
              if (_canBiometric) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('生物识别解锁'),
                  onPressed: (_countdownSec > 0 || _busy)
                      ? null
                      : _tryBiometricUnlock,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _tryUnlock() async {
    final pw = _unlockCtrl.text;
    if (pw.isEmpty) return;
    setState(() => _busy = true);
    try {
      await VaultService.instance.unlock(pw);
      // 开启了生物识别但还没保存主密码 → 触发一次生物验证保存，
      // 之后锁定屏出现「生物识别解锁」按钮
      final bioEnabled = await VaultBiometricService.isEnabled();
      final bioHas = await VaultBiometricService.hasSavedMaster();
      if (bioEnabled && !bioHas && await VaultBiometricService.canAuth()) {
        await VaultBiometricService.saveMaster(pw);
      }
      _unlockCtrl.clear();
      if (!mounted) return;
      await _refreshAll();
    } catch (e) {
      _unlockCtrl.clear();
      if (!mounted) return;
      await _refreshAll();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _tryBiometricUnlock() async {
    setState(() => _busy = true);
    try {
      final master = await VaultBiometricService.loadMaster();
      if (master == null) return;
      await VaultService.instance.unlock(master);
      if (!mounted) return;
      await _refreshAll();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------- 解锁后宫格 ----------

  Widget _buildBrowser() {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                const Icon(Icons.lock_open, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '保险箱 · ${_files.length} 个文件',
                    style: Theme.of(context).textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: '导入文件',
                  icon: const Icon(Icons.add),
                  onPressed: _busy ? null : _showImportSheet,
                ),
                IconButton(
                  tooltip: '立即上锁',
                  icon: const Icon(Icons.lock),
                  onPressed: _busy ? null : _manualLock,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _files.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.inventory_2_outlined, size: 48,
                            color: Colors.grey),
                        const SizedBox(height: 8),
                        const Text('保险箱是空的'),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          icon: const Icon(Icons.add),
                          label: const Text('导入文件'),
                          onPressed: _busy ? null : _showImportSheet,
                        ),
                      ],
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.all(8),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 140,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 0.85,
                    ),
                    itemCount: _files.length,
                    itemBuilder: (context, i) {
                      final f = _files[i];
                      return _buildGridCell(f);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildGridCell(FileSystemEntity f) {
    final name = p.basename(f.path);
    final hasThumb = _thumbCache.containsKey(f.path);
    final thumb = _thumbCache[f.path];
    final ext = p.extension(name).replaceFirst('.', '').toLowerCase();
    return GestureDetector(
      onTap: () => _openVaultFile(f),
      onSecondaryTap: () => _showFileMenu(f),
      onLongPress: () => _showFileMenu(f),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: hasThumb && thumb != null
                  ? Image.memory(thumb, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _typeIcon(ext))
                  : _typeIcon(ext),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
              child: Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _typeIcon(String ext) {
    IconData icon;
    if (_imgExt.contains(ext)) {
      icon = Icons.image_outlined;
    } else if (_videoExt.contains(ext)) {
      icon = Icons.movie_outlined;
    } else if (const {
      'mp3', 'wav', 'flac', 'aac', 'ogg', 'm4a'
    }.contains(ext)) {
      icon = Icons.audiotrack_outlined;
    } else if (const {'pdf', 'doc', 'docx', 'txt', 'md'}.contains(ext)) {
      icon = Icons.description_outlined;
    } else {
      icon = Icons.insert_drive_file_outlined;
    }
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(icon, size: 40, color: Colors.grey),
    );
  }

  Future<void> _loadFiles() async {
    final dir = await VaultService.instance.getVaultDir();
    if (dir == null) return;
    final list = <FileSystemEntity>[];
    try {
      await for (final e
          in Directory(dir).list(followLinks: false)) {
        if (e is! File) continue;
        final n = p.basename(e.path);
        if (n.startsWith('.')) continue;
        if (!n.toLowerCase().endsWith('.wemi')) continue;
        list.add(e);
      }
    } catch (_) {}
    list.sort((a, b) => p
        .basename(a.path)
        .toLowerCase()
        .compareTo(p.basename(b.path).toLowerCase()));
    if (!mounted) return;
    setState(() {
      _files = list;
      _thumbCache.removeWhere((k, _) => !list.any((f) => f.path == k));
    });
    _loadThumbs();
  }

  Future<void> _loadThumbs() async {
    for (final f in _files) {
      if (!mounted || !VaultService.instance.isUnlocked) return;
      if (_thumbCache.containsKey(f.path)) continue;
      final t = await VaultService.instance.thumbForFile(f.path);
      if (!mounted) return;
      setState(() => _thumbCache[f.path] = t);
    }
  }

  Future<void> _manualLock() async {
    await VaultService.instance.lock();
    if (mounted) _refreshAll();
  }

  // ---------- 打开 / 菜单 ----------

  Future<void> _openVaultFile(FileSystemEntity f) async {
    VaultService.instance.notifyActivity();
    var pw = VaultService.instance.passwordFor(f.path);
    if (pw == null) {
      pw = await _askFilePassword(f);
      if (pw == null) return;
    }
    setState(() => _busy = true);
    try {
      final plainPath = await VaultService.instance.decryptToTemp(f.path);
      if (!mounted) return;
      await FileViewerService.openFile(context, plainPath,
          isEncrypted: false);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askFilePassword(FileSystemEntity f) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('输入文件密码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(p.basename(f.path),
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 8),
            TextField(
              controller: ctrl,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                  labelText: '密码', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            const Text('保存后可点击即开并显示缩略图',
                style: TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确定')),
        ],
      ),
    );
    if (ok != true || ctrl.text.isEmpty) return null;
    try {
      await VaultService.instance.saveEntry(f.path, ctrl.text);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
    return ctrl.text;
  }

  Future<void> _showFileMenu(FileSystemEntity f) async {
    VaultService.instance.notifyActivity();
    final name = p.basename(f.path);
    final hasPw = VaultService.instance.passwordFor(f.path) != null;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('打开'),
              onTap: () => Navigator.pop(ctx, 'open'),
            ),
            ListTile(
              leading: const Icon(Icons.key),
              title: Text(hasPw ? '修改保存的密码' : '保存文件密码'),
              onTap: () => Navigator.pop(ctx, 'pw'),
            ),
            ListTile(
              leading: const Icon(Icons.file_upload_outlined),
              title: const Text('解密并移出保险箱'),
              onTap: () => Navigator.pop(ctx, 'export'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'open':
        await _openVaultFile(f);
        break;
      case 'pw':
        final pw = await _askFilePassword(f);
        if (pw != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('密码已保存到保险箱密码库')));
        }
        break;
      case 'export':
        await _exportFile(f);
        break;
      case 'delete':
        await _deleteFile(f);
        break;
    }
  }

  Future<void> _exportFile(FileSystemEntity f) async {
    setState(() => _busy = true);
    try {
      var pw = VaultService.instance.passwordFor(f.path);
      if (pw == null) {
        pw = await _askFilePassword(f);
        if (pw == null) return;
      }
      final plainPath = await VaultService.instance.decryptToTemp(f.path);
      final outDir = await FilePicker.platform.getDirectoryPath(
          dialogTitle: '选择导出位置');
      if (outDir == null) return;
      final outPath =
          p.join(outDir, p.basename(plainPath));
      await File(plainPath).copy(outPath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已导出：${p.basename(outPath)}')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteFile(FileSystemEntity f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除文件'),
        content: Text('确定删除 ${p.basename(f.path)} 吗？此操作不可恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await f.delete();
      await VaultService.instance.removeEntry(f.path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
    if (mounted) _loadFiles();
  }

  // ---------- 导入 ----------

  Future<void> _showImportSheet() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.add_photo_alternate_outlined),
              title: const Text('加密新文件进保险箱'),
              subtitle: const Text('选择任意文件，加密为 .wemi 存入'),
              onTap: () => Navigator.pop(ctx, 'encrypt'),
            ),
            ListTile(
              leading: const Icon(Icons.enhanced_encryption_outlined),
              title: const Text('导入已加密的 .wemi'),
              subtitle: const Text('重新加密为 v3 并纳入管理'),
              onTap: () => Navigator.pop(ctx, 'import'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'encrypt') {
      await _importPlain();
    } else {
      await _importWemi();
    }
  }

  Future<void> _importPlain() async {
    final res = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (res == null || res.paths.isEmpty) return;
    await _runImportFlow(res.paths.whereType<String>().toList(),
        (path) async {
      final useMaster = await _askUseMasterPassword(p.basename(path));
      if (useMaster == null) return null;
      if (useMaster) {
        return ''; // 用主密码
      }
      final ctrl = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('设置文件密码'),
          content: TextField(
            controller: ctrl,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(
                labelText: '文件密码', border: OutlineInputBorder()),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('确定')),
          ],
        ),
      );
      if (ok != true || ctrl.text.isEmpty) return null;
      return ctrl.text;
    }, encryptPlain: true);
  }

  Future<void> _importWemi() async {
    final res = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.any,
    );
    if (res == null || res.paths.isEmpty) return;
    final wemis = res.paths
        .whereType<String>()
        .where((p0) => p0.toLowerCase().endsWith('.wemi'))
        .toList();
    if (wemis.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('未选择 .wemi 文件')));
      }
      return;
    }
    await _runImportFlow(wemis, (path) async {
      final ctrl = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('输入原文件密码'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(p.basename(path),
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 8),
              TextField(
                controller: ctrl,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(
                    labelText: '密码', border: OutlineInputBorder()),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('确定')),
          ],
        ),
      );
      if (ok != true || ctrl.text.isEmpty) return null;
      return ctrl.text;
    }, encryptPlain: false);
  }

  Future<void> _runImportFlow(
    List<String> paths,
    Future<String?> Function(String path) askPassword, {
    required bool encryptPlain,
  }) async {
    setState(() => _busy = true);
    var okCount = 0;
    var failCount = 0;
    for (final path in paths) {
      try {
        final pw = await askPassword(path);
        if (pw == null) continue; // 用户取消
        if (encryptPlain) {
          await VaultService.instance.encryptIntoVault(path,
              password: pw.isEmpty ? null : pw);
        } else {
          await VaultService.instance.importWemi(path, pw);
        }
        okCount++;
      } catch (e) {
        failCount++;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('${p.basename(path)}: $e')));
        }
      }
    }
    if (mounted) {
      setState(() => _busy = false);
      if (okCount > 0) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('导入完成：成功 $okCount 个'
                '${failCount > 0 ? '，失败 $failCount 个' : ''}')));
      }
      await _loadFiles();
    }
  }

  Future<bool?> _askUseMasterPassword(String name) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('加密方式'),
        content: Text('$name\n\n用主密码加密，还是单独设置密码？两种都会保存到密码库。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('单独设置密码')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('用主密码')),
        ],
      ),
    );
  }
}
