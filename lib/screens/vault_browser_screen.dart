import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

// file_operations_service 导出 FileType，与 file_picker 的 FileType 冲突
// （本文件 _importWemi 用 file_picker 的 FileType.any），故 hide 掉前者
import '../services/file_operations_service.dart' hide FileType;
import '../services/file_viewer_service.dart';
import '../services/history_service.dart';
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
  final Set<String> _noPwFiles = {}; // 无密码映射的文件路径（宫格标灰标）
  bool _busy = false;

  // 设置引导输入
  final _pw1Ctrl = TextEditingController();
  final _pw2Ctrl = TextEditingController();
  String _chosenDir = '';

  // 锁定屏输入
  final _unlockCtrl = TextEditingController();
  bool _canBiometric = false;
  bool _bioCan = false; // 设备支持且已录入指纹
  bool _bioEnabled = false; // 设置开关
  bool _bioHas = false; // 已保存主密码密文
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
        setState(() {
          _bioCan = canBio;
          _bioEnabled = enabled;
          _bioHas = has;
          _canBiometric = canBio && enabled && has;
        });
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
    return Scaffold(
      appBar: AppBar(title: const Text('微密保险箱')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _body(),
    );
  }

  Widget _body() {
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
              Row(
                children: [
                  Icon(Icons.info_outline,
                      size: 15, color: Colors.grey.shade600),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '箱内文件加密保存，进入需主密码；主密码一旦忘记无法找回。',
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade600),
                    ),
                  ),
                ],
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
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.create_new_folder_outlined),
                label: Text(_busy ? '创建中…' : '创建保险箱'),
                onPressed: (!_busy && valid) ? _createVault : null,
              ),
              if (!valid && !_busy) ...[
                const SizedBox(height: 8),
                Text(
                  _setupInvalidReason(),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
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

  /// 创建按钮不可用时的具体原因（直接告诉用户差在哪，而不是点了没反应）
  String _setupInvalidReason() {
    if (_chosenDir.isEmpty) return '请先选择保险箱目录';
    if (_pw1Ctrl.text.length < 8) return '主密码至少 8 位';
    if (_pw1Ctrl.text != _pw2Ctrl.text) return '两次输入的主密码不一致';
    return '';
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
              ] else if (_bioEnabled && _bioCan && !_bioHas) ...[
                const SizedBox(height: 12),
                Text(
                  '生物识别待录入：输入主密码解锁一次并完成指纹验证，'
                  '之后即可用指纹解锁',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 12, color: Colors.grey.shade600),
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
        final r = await VaultBiometricService.saveMaster(pw);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(r.ok
                  ? '指纹已录入，锁定后可用指纹解锁'
                  : '指纹录入未完成：${r.error}，下次用主密码解锁时会再次尝试')));
        }
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
      final r = await VaultBiometricService.loadMaster();
      if (!r.ok || r.master == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(r.error ?? '生物识别验证未通过')));
        }
        return;
      }
      await VaultService.instance.unlock(r.master!);
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
    final noPw = _noPwFiles.contains(f.path);
    return GestureDetector(
      onTap: () => _openVaultFile(f),
      onSecondaryTap: () => _showFileMenu(f),
      onLongPress: () => _showFileMenu(f),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Column(
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
            if (noPw)
              Positioned(
                left: 4,
                top: 4,
                child: _noPwBadge(),
              ),
          ],
        ),
      ),
    );
  }

  /// 宫格角标：该文件没有密码映射，点开要补密码
  Widget _noPwBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text('未存密码',
          style: TextStyle(fontSize: 9, color: Colors.white)),
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
      _noPwFiles
        ..clear()
        ..addAll(list
            .where((f) =>
                VaultService.instance.passwordFor(f.path) == null)
            .map((f) => f.path));
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

  /// 打开/解密共用的「拿明文」流程：
  /// - 有映射：直接解；-2 时先静默试主密码（映射丢了/写错了但文件是主密码
  ///   加密的），成功则顺手修正映射；仍失败弹「补密码」对话框
  /// - 无映射：先静默试主密码，失败弹「输入文件密码」对话框（验证通过才保存）
  /// 返回明文路径；用户取消返回 null。
  Future<String?> _resolvePlainFile(FileSystemEntity f) async {
    VaultService.instance.notifyActivity();
    final pw = VaultService.instance.passwordFor(f.path);
    if (pw != null) {
      try {
        return await VaultService.instance.decryptToTemp(f.path);
      } on VaultException catch (e) {
        if (e.code != 'wrongPassword') rethrow;
        final master = VaultService.instance.masterPassword;
        if (master != null) {
          final plain =
              await VaultService.instance.tryDecryptToTemp(f.path, master);
          if (plain != null) {
            try {
              await VaultService.instance.saveEntry(f.path, master);
            } catch (_) {}
            _markPwResolved(f.path);
            return plain;
          }
        }
        return _askFilePassword(f, recover: true);
      }
    }
    final master = VaultService.instance.masterPassword;
    if (master != null) {
      final plain = await VaultService.instance.tryDecryptToTemp(f.path, master);
      if (plain != null) {
        try {
          await VaultService.instance.saveEntry(f.path, master);
        } catch (_) {}
        _markPwResolved(f.path);
        return plain;
      }
    }
    return _askFilePassword(f);
  }

  /// 密码映射补齐后刷新宫格角标
  void _markPwResolved(String path) {
    if (!mounted) return;
    setState(() => _noPwFiles.remove(path));
  }

  Future<void> _openVaultFile(FileSystemEntity f) async {
    setState(() => _busy = true);
    try {
      final plainPath = await _resolvePlainFile(f);
      if (plainPath == null || !mounted) return;
      await FileViewerService.openFile(context, plainPath,
          isEncrypted: false);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_friendlyError('$e'))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 「输入文件密码」对话框：先尝试验证，通过才写入密码库
  ///（防止错密码污染映射，导致以后每次都解不开）。
  /// recover=true 表示「保存的密码解不开」的补救场景。返回明文路径。
  Future<String?> _askFilePassword(FileSystemEntity f,
      {bool recover = false}) async {
    final ctrl = TextEditingController();
    String? errorText;
    bool verifying = false;
    String? plainPath;
    String? usedPw;
    String? saveError;
    Future<void> verify(BuildContext ctx, void Function(void Function()) setDialogState) async {
      final input = ctrl.text;
      if (input.isEmpty) return;
      setDialogState(() {
        verifying = true;
        errorText = null;
      });
      final plain =
          await VaultService.instance.tryDecryptToTemp(f.path, input);
      if (plain == null) {
        setDialogState(() {
          verifying = false;
          errorText = '密码不正确（或文件已损坏）';
        });
        return;
      }
      String? saveErr;
      try {
        await VaultService.instance.saveEntry(f.path, input);
      } catch (e) {
        saveErr = '$e'; // 内存映射已更新，本次可开；持久化失败仅提示
      }
      plainPath = plain;
      usedPw = input;
      if (saveErr != null) saveError = saveErr;
      if (ctx.mounted) Navigator.pop(ctx, true);
    }
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(recover ? '密码不正确' : '输入文件密码'),
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
                enabled: !verifying,
                decoration: InputDecoration(
                  labelText: '密码',
                  border: const OutlineInputBorder(),
                  errorText: errorText,
                ),
                onSubmitted:
                    verifying ? null : (_) => verify(ctx, setDialogState),
              ),
              const SizedBox(height: 8),
              Text(
                recover
                    ? '保存的密码无法解开该文件。请输入导入时设置的文件密码'
                        '（主密码已自动尝试过）。验证通过后自动更新保存的密码。'
                    : '该文件没有保存密码。请输入导入时设置的文件密码'
                        '（主密码已自动尝试过）。验证通过后自动保存，之后点击即开。',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: verifying ? null : () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed:
                  verifying ? null : () => verify(ctx, setDialogState),
              child: verifying
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('确定'),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    if (ok != true || plainPath == null) return null;
    if (saveError != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('密码正确，但保存到密码库失败：$saveError')));
    }
    _markPwResolved(f.path);
    // 补密码成功：若还有别的文件缺映射，问一句要不要用同一密码批量尝试
    if (usedPw != null) await _offerBatchSamePassword(f, usedPw!);
    return plainPath;
  }

  Future<void> _offerBatchSamePassword(FileSystemEntity done, String pw) async {
    final rest = _files
        .where((f) => f.path != done.path && _noPwFiles.contains(f.path))
        .toList();
    if (rest.isEmpty || !mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('批量补密码'),
        content: Text('还有 ${rest.length} 个文件没有保存密码。'
            '要用刚才这个密码批量尝试吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('不用')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('试试')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    var fixed = 0;
    for (final f in rest) {
      final plain = await VaultService.instance.tryDecryptToTemp(f.path, pw);
      if (plain != null) {
        try {
          await VaultService.instance.saveEntry(f.path, pw);
        } catch (_) {}
        _noPwFiles.remove(f.path);
        fixed++;
      }
    }
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(fixed > 0
              ? '批量补密码完成：$fixed 个文件已保存'
              : '批量尝试失败：这些文件的密码不同')));
    }
  }

  /// 把 Rust 层的英文错误码翻成界面可读中文
  String _friendlyError(String raw) {
    if (raw.contains('code: -2')) return '密码不正确或文件已损坏';
    if (raw.contains('code: -1')) return '参数错误';
    return raw;
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
        final plainPath = await _askFilePassword(f, recover: hasPw);
        if (plainPath != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('密码已验证并保存到保险箱密码库')));
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
      final plainPath = await _resolvePlainFile(f);
      if (plainPath == null || !mounted) return;
      final outDir = await FilePicker.platform.getDirectoryPath(
          dialogTitle: '选择导出位置');
      if (outDir == null) return;
      // 明文临时文件名带时间戳前缀，导出时剥掉
      final cleanName =
          p.basename(plainPath).replaceFirst(RegExp(r'^\d+_'), '');
      final outPath = p.join(outDir, cleanName);
      await File(plainPath).copy(outPath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已导出：${p.basename(outPath)}')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_friendlyError('$e'))));
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
    final originals = <String>[]; // 加密进箱成功的原文件（用于删原文件询问）
    for (final path in paths) {
      try {
        final pw = await askPassword(path);
        if (pw == null) continue; // 用户取消
        if (encryptPlain) {
          await VaultService.instance.encryptIntoVault(path,
              password: pw.isEmpty ? null : pw);
          originals.add(path);
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
      // 加密新文件进箱后询问是否删除原文件（与主界面加密行为对齐；
      // importWemi 是移动语义，导入时已自动删除，不再询问）
      if (encryptPlain && originals.isNotEmpty) {
        await _askDeleteOriginals(originals);
      }
    }
  }

  /// 加密完成后询问是否删除原文件：保留 / 移到回收站 / 永久删除，
  /// 复用主界面的删除偏好（DeletePreferenceService）
  Future<void> _askDeleteOriginals(List<String> originalPaths) async {
    if (originalPaths.isEmpty || !mounted) return;

    final savedPref = await DeletePreferenceService.getSavedPreference();
    if (savedPref != null) {
      await _executeDeleteOriginals(originalPaths, savedPref);
      return;
    }
    if (!mounted) return;

    DeleteAction? selectedAction;
    bool rememberChoice = false;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('加密完成'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('是否删除原始文件？文件已安全存入保险箱。'),
              const SizedBox(height: 8),
              Text(
                '已加密文件数：${originalPaths.length}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Checkbox(
                    value: rememberChoice,
                    onChanged: (v) {
                      setDialogState(() => rememberChoice = v ?? false);
                    },
                  ),
                  GestureDetector(
                    onTap: () => setDialogState(
                        () => rememberChoice = !rememberChoice),
                    child: const Text('记住我的选择'),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                selectedAction = DeleteAction.keep;
                Navigator.pop(dialogContext, true);
              },
              child: const Text('保留'),
            ),
            TextButton(
              onPressed: () {
                selectedAction = DeleteAction.recycleBin;
                Navigator.pop(dialogContext, true);
              },
              child: const Text('移到回收站'),
            ),
            TextButton(
              onPressed: () async {
                final second = await showDialog<bool>(
                  context: dialogContext,
                  builder: (c2) => AlertDialog(
                    title: const Text('永久删除警告'),
                    content: const Text('永久删除的文件无法恢复，确定吗？'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(c2, false),
                          child: const Text('取消')),
                      TextButton(
                          onPressed: () => Navigator.pop(c2, true),
                          child: const Text('确定',
                              style: TextStyle(color: Colors.red))),
                    ],
                  ),
                );
                if (second == true) {
                  selectedAction = DeleteAction.permanent;
                  if (dialogContext.mounted) Navigator.pop(dialogContext, true);
                }
              },
              child: const Text('永久删除',
                  style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true && selectedAction != null) {
      await DeletePreferenceService.savePreference(
          rememberChoice, selectedAction);
      await _executeDeleteOriginals(originalPaths, selectedAction);
    }
  }

  Future<void> _executeDeleteOriginals(
      List<String> originalPaths, DeleteAction action) async {
    if (action == DeleteAction.keep) return;
    var deleted = 0;
    for (final path in originalPaths) {
      try {
        if (await FileOperationsService.deleteOriginal(path)) deleted++;
      } catch (_) {}
    }
    if (deleted > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('已删除原文件：$deleted 个')));
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
