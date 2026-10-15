import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/file_thumbnail.dart';
import 'rust_crypto.dart';
import 'windows_thumbnail_provider.dart';

/// 保险箱异常。code: wrongPassword | lockedOut | notSetup | io | ffi
class VaultException implements Exception {
  final String code;
  final String message;
  const VaultException(this.code, this.message);
  @override
  String toString() => message;
}

/// 防爆破状态
class VaultLockInfo {
  final bool lockedOut;
  final int remainingSec;
  final int failCount;
  const VaultLockInfo({
    required this.lockedOut,
    required this.remainingSec,
    required this.failCount,
  });
}

/// 微密保险箱服务：
/// - 密码库 <保险箱目录>/.weimi_keys（Argon2id KEK + AES-256-GCM，Rust vault.rs）
/// - 主密码/内容密钥/thumb_key 全在内存持有，锁定即清零
/// - 防爆破：.weimi_lock 连续错 5 次锁 5 分钟
/// - 闲置锁定：失焦/无操作 N 分钟自动锁（0=关闭）
class VaultService {
  VaultService._();
  static final VaultService instance = VaultService._();

  // ---- prefs keys（设置页共用）----
  static const String dirPrefKey = 'vault_directory';
  static const String idleMinPrefKey = 'vault_idle_lock_min';
  static const String lockOnExitPrefKey = 'vault_lock_on_exit';
  static const String biometricPrefKey = 'vault_biometric_enabled';
  static const String showInDirsPrefKey = 'vault_show_in_dirs';

  static const String keysName = '.weimi_keys';
  static const String lockName = '.weimi_lock';
  static const int maxAttempts = 5;
  static const int lockoutSec = 300;
  static const int thumbMaxPx = 320;

  static const Set<String> _imgExt = {
    'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'heic', 'heif',
  };
  static const Set<String> _videoExt = {
    'mp4', 'mov', 'avi', 'mkv', 'webm', 'm4v', '3gp', 'ts', 'flv', 'wmv',
  };

  // ---- 解锁态（锁定即清零）----
  bool _unlocked = false;
  Uint8List? _master; // utf-8 主密码字节
  Uint8List? _thumbKey; // 32B
  final Map<String, String> _entries = {}; // 文件名 -> 文件密码
  int _idleMin = 5;
  DateTime _lastActivity = DateTime.now();
  Timer? _idleTimer;

  bool get isUnlocked => _unlocked;
  Map<String, String> get entries =>
      _unlocked ? Map.unmodifiable(_entries) : const {};

  // ==================== 目录与偏好 ====================

  Future<String?> getVaultDir() async {
    final prefs = await SharedPreferences.getInstance();
    final dir = prefs.getString(dirPrefKey);
    if (dir == null || dir.isEmpty) return null;
    if (!await Directory(dir).exists()) return null;
    return dir;
  }

  Future<void> setVaultDir(String dir) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(dirPrefKey, dir);
  }

  Future<int> getIdleMinutes() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(idleMinPrefKey) ?? 5;
  }

  Future<void> setIdleMinutes(int minutes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(idleMinPrefKey, minutes);
    if (_unlocked) _idleMin = minutes;
  }

  Future<bool> getLockOnExit() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(lockOnExitPrefKey) ?? false;
  }

  Future<void> setLockOnExit(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(lockOnExitPrefKey, v);
  }

  /// 保险箱是否已配置（目录 + 密码库都在）
  Future<bool> isSetup() async {
    final dir = await getVaultDir();
    if (dir == null) return false;
    return File(p.join(dir, keysName)).exists();
  }

  // ==================== 防爆破 ====================

  File _lockFile(String dir) => File(p.join(dir, lockName));

  Future<VaultLockInfo> lockInfo(String dir) async {
    try {
      final f = _lockFile(dir);
      if (!await f.exists()) {
        return const VaultLockInfo(lockedOut: false, remainingSec: 0, failCount: 0);
      }
      final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final count = (m['count'] as num?)?.toInt() ?? 0;
      final until = (m['lockedUntil'] as num?)?.toInt() ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (until > now) {
        return VaultLockInfo(
          lockedOut: true,
          remainingSec: ((until - now) / 1000).ceil(),
          failCount: count,
        );
      }
      return VaultLockInfo(lockedOut: false, remainingSec: 0, failCount: count);
    } catch (_) {
      return const VaultLockInfo(lockedOut: false, remainingSec: 0, failCount: 0);
    }
  }

  Future<void> _recordFailure(String dir) async {
    final info = await lockInfo(dir);
    final count = info.lockedOut ? info.failCount : info.failCount + 1;
    int until = 0;
    if (count >= maxAttempts) {
      until = DateTime.now().add(const Duration(seconds: lockoutSec))
          .millisecondsSinceEpoch;
    }
    await _lockFile(dir).writeAsString(
      jsonEncode({'count': count, 'lockedUntil': until}),
    );
  }

  Future<void> _resetFailures(String dir) async {
    try {
      final f = _lockFile(dir);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  // ==================== 开锁 / 上锁 ====================

  /// 首次创建：目录 + 主密码 → 写空密码库
  Future<void> createVault(String dir, String master) async {
    if (master.length < 8) {
      throw const VaultException('weak', '主密码至少 8 位');
    }
    await Directory(dir).create(recursive: true);
    final keyFile = File(p.join(dir, keysName));
    if (await keyFile.exists()) {
      throw const VaultException('exists', '该目录已有保险箱密码库');
    }
    final masterBytes = Uint8List.fromList(utf8.encode(master));
    final json = jsonEncode({
      'ver': 1,
      'entries': <Map<String, dynamic>>[],
      'thumb_key': _randomThumbKeyHex(),
    });
    final sealed = _sealKeyring(masterBytes, Uint8List.fromList(utf8.encode(json)));
    await keyFile.writeAsBytes(sealed, flush: true);
    await setVaultDir(dir);
  }

  String _randomThumbKeyHex() {
    final rng = Random.secure();
    return List.generate(32, (_) => rng.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// 解锁。错误：lockedOut / notSetup / wrongPassword / io
  Future<void> unlock(String master) async {
    final dir = await getVaultDir();
    if (dir == null || !await File(p.join(dir, keysName)).exists()) {
      throw const VaultException('notSetup', '保险箱未设置');
    }
    final info = await lockInfo(dir);
    if (info.lockedOut) {
      throw VaultException('lockedOut',
          '错误次数过多，请 ${info.remainingSec} 秒后再试');
    }
    final masterBytes = Uint8List.fromList(utf8.encode(master));
    Uint8List sealed;
    try {
      sealed = await File(p.join(dir, keysName)).readAsBytes();
    } catch (e) {
      throw VaultException('io', '读取密码库失败: $e');
    }
    late final Uint8List json;
    try {
      json = _openKeyring(masterBytes, sealed);
    } on VaultException {
      await _recordFailure(dir);
      rethrow;
    }
    final kr = jsonDecode(utf8.decode(json)) as Map<String, dynamic>;
    _master = masterBytes;
    _thumbKey = _hexToBytes(kr['thumb_key'] as String);
    _entries.clear();
    for (final e in (kr['entries'] as List? ?? [])) {
      final m = e as Map<String, dynamic>;
      _entries[m['file'] as String] = m['password'] as String;
    }
    _unlocked = true;
    _idleMin = await getIdleMinutes();
    _lastActivity = DateTime.now();
    await _resetFailures(dir);
    _startIdleTimer();
  }

  /// 上锁：清零内存 + 清临时解密文件
  Future<void> lock() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    _master?..fillRange(0, _master!.length, 0);
    _master = null;
    _thumbKey?..fillRange(0, _thumbKey!.length, 0);
    _thumbKey = null;
    _entries.clear();
    _unlocked = false;
    await clearTempFiles();
  }

  /// 闲置计时：任何交互调 notifyActivity()
  void notifyActivity() {
    if (_unlocked) _lastActivity = DateTime.now();
  }

  void _startIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      if (!_unlocked) {
        _idleTimer?.cancel();
        return;
      }
      if (_idleMin <= 0) return;
      final idle = DateTime.now().difference(_lastActivity);
      if (idle.inMinutes >= _idleMin) {
        await lock();
      }
    });
  }

  // ==================== 密码库 ====================

  Future<void> _persist() async {
    final dir = await getVaultDir();
    if (dir == null || _master == null) {
      throw const VaultException('notSetup', '保险箱未解锁');
    }
    final json = jsonEncode({
      'ver': 1,
      'entries': _entries.entries
          .map((e) => {'file': e.key, 'password': e.value})
          .toList(),
      'thumb_key': _bytesToHex(_thumbKey!),
    });
    final sealed = _sealKeyring(
      _master!,
      Uint8List.fromList(utf8.encode(json)),
    );
    await File(p.join(dir, keysName)).writeAsBytes(sealed, flush: true);
  }

  String? passwordFor(String fileName) =>
      _unlocked ? _entries[p.basename(fileName)] : null;

  Future<void> saveEntry(String fileName, String password) async {
    _entries[p.basename(fileName)] = password;
    await _persist();
  }

  Future<void> removeEntry(String fileName) async {
    _entries.remove(p.basename(fileName));
    await _persist();
  }

  /// 改主密码：只用新 KEK 重封装密码库；箱内文件不动。
  /// 成功后更新内存 master。错误：wrongPassword。
  Future<void> changeMasterPassword(String oldPw, String newPw) async {
    final dir = await getVaultDir();
    if (dir == null) throw const VaultException('notSetup', '保险箱未设置');
    if (newPw.length < 8) throw const VaultException('weak', '新主密码至少 8 位');
    final keyFile = File(p.join(dir, keysName));
    final sealed = await keyFile.readAsBytes();
    final out = _changeMaster(
      sealed,
      Uint8List.fromList(utf8.encode(oldPw)),
      Uint8List.fromList(utf8.encode(newPw)),
    );
    await keyFile.writeAsBytes(out, flush: true);
    if (_unlocked) {
      _master?..fillRange(0, _master!.length, 0);
      _master = Uint8List.fromList(utf8.encode(newPw));
    }
  }

  // ==================== 文件操作 ====================

  /// 为源文件生成缩略图 JPEG 字节；不支持/失败返回 null
  Future<Uint8List?> makeThumbForFile(String srcPath) async {
    final ext = p.extension(srcPath).replaceFirst('.', '').toLowerCase();
    try {
      if (_imgExt.contains(ext)) {
        final f = File(srcPath);
        if (await f.length() > 64 * 1024 * 1024) return null;
        final bytes = await f.readAsBytes();
        return _genThumb(bytes, thumbMaxPx);
      }
      if (_videoExt.contains(ext)) {
        if (Platform.isAndroid) {
          return await FileThumbs.videoFrame(srcPath);
        }
        if (Platform.isWindows) {
          final cachePath = await WindowsThumbnailProvider.getThumbnailFile(srcPath);
          if (cachePath != null && await File(cachePath).exists()) {
            final raw = await File(cachePath).readAsBytes();
            return _genThumb(raw, thumbMaxPx);
          }
        }
        return null; // macOS/Linux 无抽帧器，如实显示类型图标
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  /// 加密任意文件进保险箱（v3）：生成缩略图 + 存密码映射。
  /// password 传 null 用主密码。返回箱内 .wemi 路径。
  Future<String> encryptIntoVault(
    String srcPath, {
    String? password,
    String? hint,
  }) async {
    _requireUnlocked();
    final dir = (await getVaultDir())!;
    final name = p.basename(srcPath);
    final dest = p.join(dir, '$name.wemi');
    final filePw = password ?? utf8.decode(_master!);
    final thumb = await makeThumbForFile(srcPath);
    _encryptFileV3(
      srcPath, dest,
      Uint8List.fromList(utf8.encode(filePw)),
      hint,
      thumb,
    );
    await saveEntry(dest, filePw);
    return dest;
  }

  /// 导入已有 .wemi（v1）：解密→重加密 v3 进箱→存映射→删原文件。
  Future<String> importWemi(String wemiPath, String password) async {
    _requireUnlocked();
    final dir = (await getVaultDir())!;
    final name = p.basename(wemiPath);
    if (!name.toLowerCase().endsWith('.wemi')) {
      throw const VaultException('io', '不是微密加密文件');
    }
    final dest = p.join(dir, name);
    final tmpDir = await _tmpDir();
    final plainTmp = p.join(tmpDir.path, 'import_${DateTime.now().millisecondsSinceEpoch}_$name');
    final plainName = name.substring(0, name.length - 5);
    try {
      RustCrypto.decryptFile(wemiPath, plainTmp,
          Uint8List.fromList(utf8.encode(password)),
          isMobile: _isMobile());
      final thumb = await makeThumbForFile(plainTmp);
      _encryptFileV3(
        plainTmp, dest,
        Uint8List.fromList(utf8.encode(password)),
        null,
        thumb,
      );
      await saveEntry(dest, password);
      // 导入成功后删除原文件（移动语义）
      try {
        await File(wemiPath).delete();
      } catch (_) {}
      return dest;
    } finally {
      try {
        await File(plainTmp).delete();
      } catch (_) {}
    }
  }

  /// 取箱内文件的缩略图明文（JPEG）；无缩略图返回 null
  Future<Uint8List?> thumbForFile(String vaultFilePath) async {
    _requireUnlocked();
    try {
      final data = _getThumbFromFile(vaultFilePath, _thumbKey!);
      return data.isEmpty ? null : data;
    } catch (_) {
      return null;
    }
  }

  /// 解密箱内文件到受管临时目录，返回明文路径。锁定时统一清理。
  Future<String> decryptToTemp(String vaultFilePath) async {
    _requireUnlocked();
    final pw = passwordFor(vaultFilePath);
    if (pw == null) {
      throw const VaultException('noEntry', '该文件未保存密码映射');
    }
    final tmpDir = await _tmpDir();
    final name = p.basename(vaultFilePath);
    final outName = name.toLowerCase().endsWith('.wemi')
        ? name.substring(0, name.length - 5)
        : name;
    final dest = p.join(
        tmpDir.path, '${DateTime.now().millisecondsSinceEpoch}_$outName');
    RustCrypto.decryptFile(vaultFilePath, dest,
        Uint8List.fromList(utf8.encode(pw)),
        isMobile: _isMobile());
    return dest;
  }

  /// 清理受管临时目录（锁定/退出调用）
  Future<void> clearTempFiles() async {
    try {
      final d = await _tmpDir();
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
  }

  void _requireUnlocked() {
    if (!_unlocked) throw const VaultException('notSetup', '保险箱未解锁');
  }

  bool _isMobile() => Platform.isAndroid || Platform.isIOS;

  Future<Directory> _tmpDir() async {
    final base = await getTemporaryDirectory();
    return Directory(p.join(base.path, 'vault_tmp'));
  }

  // ==================== FFI 绑定（rust_crypto vault.rs）====================

  static Uint8List _bytesOf(ffi.Pointer<ffi.Uint8> ptr, int len) =>
      Uint8List.fromList(ptr.asTypedList(len));

  static ffi.Pointer<ffi.Uint8> _allocBytes(Uint8List list) {
    final ptr = calloc<ffi.Uint8>(list.lengthInBytes == 0 ? 1 : list.lengthInBytes);
    for (var i = 0; i < list.lengthInBytes; i++) {
      ptr[i] = list[i];
    }
    return ptr;
  }

  /// 两段式输出：第一遍 out=null 拿长度，第二遍取数据
  static Uint8List _callEmit(
    int Function(ffi.Pointer<ffi.Uint8> out, ffi.Pointer<ffi.Size> outLen) invoke,
  ) {
    final lenPtr = calloc<ffi.Size>();
    try {
      final rc = invoke(ffi.nullptr, lenPtr);
      if (rc != 0) {
        throw VaultException('ffi', _ffiError(rc));
      }
      final len = lenPtr.value;
      if (len == 0) return Uint8List(0);
      final buf = calloc<ffi.Uint8>(len);
      try {
        final rc2 = invoke(buf, lenPtr);
        if (rc2 != 0) {
          throw VaultException('ffi', _ffiError(rc2));
        }
        return _bytesOf(buf, len);
      } finally {
        calloc.free(buf);
      }
    } finally {
      calloc.free(lenPtr);
    }
  }

  static String _ffiError(int rc) {
    if (rc == -1) return '参数错误';
    if (rc == -2) return '密码错误或数据损坏';
    return '加密库错误 ($rc)';
  }

  static Uint8List _sealKeyring(Uint8List master, Uint8List json) {
    final lib = RustCrypto.ensureLib();
    final fn = lib.lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Uint8>, ffi.Size,
          ffi.Pointer<ffi.Uint8>, ffi.Size,
          ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Size>,
        ),
        int Function(
          ffi.Pointer<ffi.Uint8>, int,
          ffi.Pointer<ffi.Uint8>, int,
          ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Size>,
        )>('vault_seal_keyring');
    final m = _allocBytes(master);
    final j = _allocBytes(json);
    try {
      return _callEmit((out, outLen) =>
          fn(m, master.length, j, json.length, out, outLen));
    } finally {
      calloc.free(m);
      calloc.free(j);
    }
  }

  static Uint8List _openKeyring(Uint8List master, Uint8List sealed) {
    final lib = RustCrypto.ensureLib();
    final fn = lib.lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Uint8>, ffi.Size,
          ffi.Pointer<ffi.Uint8>, ffi.Size,
          ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Size>,
        ),
        int Function(
          ffi.Pointer<ffi.Uint8>, int,
          ffi.Pointer<ffi.Uint8>, int,
          ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Size>,
        )>('vault_open_keyring');
    final m = _allocBytes(master);
    final d = _allocBytes(sealed);
    try {
      return _callEmit((out, outLen) =>
          fn(m, master.length, d, sealed.length, out, outLen));
    } finally {
      calloc.free(m);
      calloc.free(d);
    }
  }

  static Uint8List _changeMaster(Uint8List sealed, Uint8List oldPw, Uint8List newPw) {
    final lib = RustCrypto.ensureLib();
    final fn = lib.lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Uint8>, ffi.Size,
          ffi.Pointer<ffi.Uint8>, ffi.Size,
          ffi.Pointer<ffi.Uint8>, ffi.Size,
          ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Size>,
        ),
        int Function(
          ffi.Pointer<ffi.Uint8>, int,
          ffi.Pointer<ffi.Uint8>, int,
          ffi.Pointer<ffi.Uint8>, int,
          ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Size>,
        )>('vault_change_master_password');
    final d = _allocBytes(sealed);
    final o = _allocBytes(oldPw);
    final n = _allocBytes(newPw);
    try {
      return _callEmit((out, outLen) =>
          fn(d, sealed.length, o, oldPw.length, n, newPw.length, out, outLen));
    } finally {
      calloc.free(d);
      calloc.free(o);
      calloc.free(n);
    }
  }

  static Uint8List _genThumb(Uint8List src, int maxPx) {
    final lib = RustCrypto.ensureLib();
    final fn = lib.lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Uint8>, ffi.Size, ffi.Uint32,
          ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Size>,
        ),
        int Function(
          ffi.Pointer<ffi.Uint8>, int, int,
          ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Size>,
        )>('vault_gen_thumb');
    final s = _allocBytes(src);
    try {
      return _callEmit((out, outLen) => fn(s, src.length, maxPx, out, outLen));
    } finally {
      calloc.free(s);
    }
  }

  /// v3 加密（保险箱）。thumb 可为 null。
  static void _encryptFileV3(
    String inputPath,
    String outputPath,
    Uint8List password,
    String? hint,
    Uint8List? thumb,
  ) {
    final lib = RustCrypto.ensureLib();
    final fn = lib.lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>,
          ffi.Pointer<ffi.Uint8>, ffi.Size,
          ffi.Pointer<ffi.Char>,
          ffi.Pointer<ffi.Uint8>, ffi.Size,
          ffi.Pointer<ffi.Uint8>,
          ffi.Bool, ffi.Size,
        ),
        int Function(
          ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>,
          ffi.Pointer<ffi.Uint8>, int,
          ffi.Pointer<ffi.Char>,
          ffi.Pointer<ffi.Uint8>, int,
          ffi.Pointer<ffi.Uint8>,
          bool, int,
        )>('encrypt_file_v3');
    final inPtr = inputPath.toNativeUtf8().cast<ffi.Char>();
    final outPtr = outputPath.toNativeUtf8().cast<ffi.Char>();
    final pwPtr = _allocBytes(password);
    final hintPtr = (hint != null && hint.isNotEmpty)
        ? hint.toNativeUtf8().cast<ffi.Char>()
        : ffi.nullptr;
    final thumbPtr = (thumb != null && thumb.isNotEmpty)
        ? _allocBytes(thumb)
        : ffi.nullptr;
    final inst = VaultService.instance;
    final tkPtr = _allocBytes(inst._thumbKey ?? Uint8List(32));
    try {
      final rc = fn(
        inPtr, outPtr,
        pwPtr, password.length,
        hintPtr,
        thumbPtr, thumb?.length ?? 0,
        tkPtr,
        inst._isMobile(),
        Platform.numberOfProcessors,
      );
      if (rc != 0) throw VaultException('ffi', '加密失败 ($rc)');
    } finally {
      calloc.free(inPtr);
      calloc.free(outPtr);
      calloc.free(pwPtr);
      if (hintPtr != ffi.nullptr) calloc.free(hintPtr);
      if (thumbPtr != ffi.nullptr) calloc.free(thumbPtr);
      calloc.free(tkPtr);
    }
  }

  static Uint8List _getThumbFromFile(String path, Uint8List thumbKey) {
    final lib = RustCrypto.ensureLib();
    final fn = lib.lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Char>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Size>,
        ),
        int Function(
          ffi.Pointer<ffi.Char>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Size>,
        )>('vault_get_thumb_from_file');
    final pPtr = path.toNativeUtf8().cast<ffi.Char>();
    final tkPtr = _allocBytes(thumbKey);
    try {
      return _callEmit((out, outLen) => fn(pPtr, tkPtr, out, outLen));
    } finally {
      calloc.free(pPtr);
      calloc.free(tkPtr);
    }
  }

  static Uint8List _hexToBytes(String hex) {
    if (hex.length % 2 != 0) return Uint8List(0);
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static String _bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
