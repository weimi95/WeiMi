import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'rust_crypto.dart';
import 'exclude_service.dart';

/// 全盘文件名索引（方案A：Rust 多线程遍历 + 进程内存索引 + 落盘持久化 + 增量刷新）
///
/// - 首次使用全量建立，随后写入 `disk_index.bin`（应用文档目录）
/// - 之后启动优先从磁盘加载（毫秒级，搜索立即可用），再后台增量刷新
/// - Windows NTFS 卷走 USN journal 增量（方案B：Everything 同源技术，见 rust usn.rs），
///   非 NTFS 卷/异常自动回退目录遍历
/// - 搜索 = 文件名不区分大小写子串匹配，毫秒级
class DiskIndexService {
  static int? _cachedCount;
  static DateTime? _lastBuiltAt;
  /// 上次索引落盘时间（内存重建不写盘，落盘间隔超过 _persistMaxAge 才补写，
  /// 避免落盘索引无限腐化——v1.0.43 修复）
  static DateTime? _lastPersistAt;
  static const Duration _persistMaxAge = Duration(minutes: 30);
  static bool _building = false; // 防重入：全量构建进行中时不再叠加

  /// 是否把移动设备（U盘/移动硬盘，DRIVE_REMOVABLE）纳入索引（仅 Windows 有意义）。
  /// 注意：Isolate.run 出去的 isolate 不继承静态字段，跨 isolate 一律传 roots 值。
  static bool? _includeRemovable;
  static const String prefsKeyRemovable = 'index_include_removable';

  static bool get includeRemovable => _includeRemovable ?? false;

  /// 幂等读取「扫描索引移动设备」设置（默认关闭）
  static Future<void> loadRemovablePref() async {
    if (_includeRemovable != null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _includeRemovable = prefs.getBool(prefsKeyRemovable) ?? false;
      final roots = prefs.getStringList(prefsKeyRoots);
      if (roots != null && roots.isNotEmpty) {
        _customRoots = roots
            .map(normalizeRoot)
            .where((r) => r.isNotEmpty)
            .toList(growable: false);
      }
    } catch (_) {
      _includeRemovable = false;
    }
  }

  /// 用户指定的索引根（索引文件夹白名单）。非空时只索引这些根，
  /// 空则索引所有固定磁盘（默认行为）。支持盘符、子目录与 UNC 局域网共享。
  static List<String>? _customRoots;
  static const String prefsKeyRoots = 'index_roots';

  static bool get hasCustomRoots =>
      _customRoots != null && _customRoots!.isNotEmpty;

  /// 规整一个索引根：去首尾空白；盘符统一大写并补 \`:\`；UNC/路径去尾部分隔符。
  /// 返回空串表示无效。例：'d' → 'D:\'，'\\Cs07\f\' → '\\Cs07\f'。
  static String normalizeRoot(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';
    if (s.startsWith('\\\\')) {
      while (s.length > 2 && (s.endsWith('\\') || s.endsWith('/'))) {
        s = s.substring(0, s.length - 1);
      }
      return s;
    }
    final c = s.codeUnitAt(0);
    final isLetter = (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
    final colon = s.length > 1 && s.codeUnitAt(1) == 58; // ':'
    final bare = s.length == 1; // 只给了一个盘符字母
    if (isLetter && (colon || bare)) {
      s = s[0].toUpperCase() + (bare ? ':' : s.substring(1));
      while (s.endsWith('\\') || s.endsWith('/')) {
        s = s.substring(0, s.length - 1);
      }
      if (!s.contains('\\')) s = '$s:\\';
      return s;
    }
    while (s.endsWith('\\') || s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// 仅保存「索引文件夹」设置并更新内存态（不触发重建；重建由调用方在
  /// 离开设置页等合适时机做，避免每加一条就全量重建一次）。
  static Future<void> saveRootsSetting(List<String> roots) async {
    final normalized = <String>[];
    for (final r in roots) {
      final n = normalizeRoot(r);
      if (n.isNotEmpty && !normalized.contains(n)) normalized.add(n);
    }
    _customRoots = normalized.isEmpty ? null : normalized;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (normalized.isEmpty) {
        await prefs.remove(prefsKeyRoots);
      } else {
        await prefs.setStringList(prefsKeyRoots, normalized);
      }
    } catch (_) {}
  }

  /// 应用「扫描索引移动设备」设置变更：保存 + 立即全量重建 + 监视器按新根重拉
  static Future<void> applyRemovableSetting(bool value) async {
    _includeRemovable = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefsKeyRemovable, value);
    } catch (_) {}
    try {
      await buildIndex(defaultRoots(), persist: true);
      await ensureWatcher(); // 新根（含移动设备）的监视线程由此/由 drain 重拉
    } catch (_) {}
  }

  /// 索引条数通知器（搜索框提示「xx个文件」用；加载/构建/增量合并后更新）
  static final ValueNotifier<int?> countNotifier = ValueNotifier(null);

  /// 索引是否已建立（内存态，含从磁盘加载）。要求条数 > 0：
  /// 旧版 USN 路径曾把「0 条空索引」落盘成 disk_index.bin，若仅以非空判就绪会误判、
  /// 导致全盘搜索永远搜不到——因此空索引视为未就绪，prepareIndex 会强制全量重建。
  static bool get isBuilt => _cachedCount != null && _cachedCount! > 0;

  /// 已索引条数（未建立返回 null）
  static int? get indexedCount => isBuilt ? _cachedCount : null;

  /// 索引数据目录。桌面端优先放在程序目录下的 Data 子目录——与软件本体同目录，
  /// 便携版整个文件夹拷走/删掉时索引随之走，不留隐藏残留（对齐 Everything 把
  /// .db 放程序目录的做法）。程序目录不可写（装到 Program Files）时回退到
  /// 应用文档目录。移动端无程序目录概念，用私有文档目录。
  static Future<String> _indexDataDir() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      try {
        final dir = p.join(p.dirname(Platform.resolvedExecutable), 'Data');
        await Directory(dir).create(recursive: true);
        // 探测写权限：建目录成功不代表可写（Program Files 下某些 UAC 重定向场景），
        // 落个探针文件实测一遍，失败则回退文档目录
        final probe = File(p.join(dir, '.weimi_probe'));
        if (await probe.exists()) {
          await probe.delete();
        } else {
          await probe.writeAsString('');
          await probe.delete();
        }
        return dir;
      } catch (_) {}
    }
    final docs = await getApplicationDocumentsDirectory();
    return docs.path;
  }

  /// 一次性迁移标记（旧索引从文档目录搬到数据目录）
  static bool _migrated = false;

  /// 落盘文件路径
  static Future<String> _indexFilePath() async {
    if (!_migrated) {
      _migrated = true;
      await _migrateLegacyIndex();
    }
    return p.join(await _indexDataDir(), 'disk_index.bin');
  }

  /// 旧版本把索引落在「文档」目录（disk_index.bin / usn_table.bin），
  /// 升级后一次性搬到数据目录，避免 128MB 索引白扫一遍。搬移而非复制，
  /// 保证磁盘上只有一份。
  static Future<void> _migrateLegacyIndex() async {
    try {
      final dataDir = await _indexDataDir();
      final docs = (await getApplicationDocumentsDirectory()).path;
      if (p.equals(dataDir, docs)) return;
      for (final name in const ['disk_index.bin', 'usn_table.bin']) {
        final src = p.join(docs, name);
        final dst = p.join(dataDir, name);
        if (await File(src).exists() && !await File(dst).exists()) {
          await File(src).rename(dst);
        }
      }
    } catch (_) {}
  }

  /// 是否存在已落盘的索引文件
  static Future<bool> hasSavedIndex() async {
    try {
      return await File(await _indexFilePath()).exists();
    } catch (_) {
      return false;
    }
  }

  /// kernel32 GetDriveTypeW（DRIVE_REMOVABLE=2）。static final 惰性初始化，
  /// 仅在 Platform.isWindows 分支内访问，其他平台不会触碰。
  /// 注意 Utf16 在 package:ffi 里（不在 dart:ffi），按本文件 import 约定裸用。
  static final int Function(ffi.Pointer<Utf16>) _getDriveType = ffi
      .DynamicLibrary.open('kernel32.dll')
      .lookupFunction<ffi.Uint32 Function(ffi.Pointer<Utf16>),
          int Function(ffi.Pointer<Utf16>)>('GetDriveTypeW');

  /// 是否可移动磁盘（U盘/移动硬盘；注意部分 USB 移动硬盘会报 DRIVE_FIXED，视为固定盘始终索引）
  static bool _isRemovableDrive(String root) {
    try {
      final ptr = root.toNativeUtf16();
      try {
        return _getDriveType(ptr) == 2; // DRIVE_REMOVABLE
      } finally {
        calloc.free(ptr);
      }
    } catch (_) {
      return false;
    }
  }

  /// 默认索引根：用户在「索引文件夹」里配置的白名单优先（非空即只索引这些根）；
  /// 否则 Windows 枚举所有存在的盘符（可按设置排除移动设备），
  /// macOS /Users，Linux 常见挂载点，安卓内置存储
  static List<String> defaultRoots() {
    if (hasCustomRoots) {
      return List<String>.of(_customRoots!);
    }
    if (Platform.isWindows) {
      final roots = <String>[];
      final allowRemovable = includeRemovable;
      for (var c = 65; c <= 90; c++) {
        final root = '${String.fromCharCode(c)}:\\';
        try {
          if (!Directory(root).existsSync()) continue;
          if (!allowRemovable && _isRemovableDrive(root)) continue;
          roots.add(root);
        } catch (_) {}
      }
      return roots;
    }
    if (Platform.isMacOS) return ['/Users'];
    if (Platform.isLinux) {
      final home = Platform.environment['HOME'] ?? '';
      final roots = <String>{};
      for (final base in ['/home', '/media', '/mnt']) {
        if (Directory(base).existsSync()) roots.add(base);
      }
      if (home.isNotEmpty) roots.add(home);
      return roots.toList();
    }
    if (Platform.isAndroid) return ['/storage/emulated/0'];
    return [];
  }

  /// 准备索引：已建立直接返回；否则从磁盘加载（毫秒级），无落盘则全量目录遍历建索引。
  ///
  /// 说明：全盘搜索统一走**已验证可靠的目录遍历（方案A）**，与旧「全盘搜索」小窗同源。
  /// USN journal 路径已移出搜索关键路径（沙箱无法验证 DeviceIoControl、曾两次真机翻车），
  /// 后续若要在真机验证后重新启用，再切回 usn 分支即可。
  /// 注意：若磁盘上加载到 0 条空索引（旧版 USN 时代落盘的遗留），isBuilt 会判为未就绪，
  /// 此处强制全量重建——否则升级后全盘搜索仍会「搜不到」。
  static Future<int> prepareIndex() async {
    if (isBuilt) return _cachedCount!;
    await loadRemovablePref(); // 先读设置再定 roots（移动设备开关）
    final rc = await loadIndex();
    if (rc == 0 && isBuilt) {
      unawaited(startupHealthCheck()); // 从磁盘加载的索引做一次健康度抽样
      return _cachedCount!;
    }
    return buildIndex(defaultRoots());
  }

  // ==================== 启动自检（索引健康度抽样，v1.0.47） ====================

  static bool _healthChecked = false;

  /// 启动自检：随机抽样索引条目比对磁盘，缺失率 > 5% 判定索引腐化
  /// （大量删除/移动/换盘未同步），后台自动全量重建（顺带落盘）。
  /// 每个进程生命周期只对「从磁盘加载」的索引执行一次；全量新建的索引不检。
  static Future<void> startupHealthCheck() async {
    if (_healthChecked || !isBuilt) return;
    _healthChecked = true;
    try {
      final count = _cachedCount ?? 0;
      if (count <= 0) return;
      final n = count < 200 ? count : 200;
      final sample = await Isolate.run(() => _sampleSync(n));
      if (sample.isEmpty) return;
      var missing = 0;
      for (final path in sample) {
        try {
          if (!File(path).existsSync()) missing++;
        } catch (_) {
          missing++;
        }
      }
      if (missing / sample.length > 0.05) {
        // 含 UNC 局域网根时禁用自动重建：共享掉线会让抽样大量「缺失」，
        // 触发反复重建把整个索引清空；恢复在线后由周期刷新自然补回
        if (hasCustomRoots && _customRoots!.any((r) => r.startsWith('\\\\'))) {
          return;
        }
        await buildIndex(defaultRoots(), persist: true);
      }
    } catch (_) {
      // 自检失败不影响主流程
    }
  }

  /// 从 Rust 索引随机抽 n 条路径（两次调用须同 seed 保证取样一致）。
  static List<String> _sampleSync(int n) {
    final lib = RustCrypto.ensureLib();
    final fn = lib.lookupFunction<
        ffi.Int32 Function(ffi.Uint64, ffi.Size, ffi.Pointer<ffi.Uint8>,
            ffi.Pointer<ffi.Size>),
        int Function(int, int, ffi.Pointer<ffi.Uint8>,
            ffi.Pointer<ffi.Size>)>('index_sample');
    final seed = DateTime.now().microsecondsSinceEpoch & 0x7FFFFFFFFFFFFFFF;
    final lenPtr = calloc<ffi.Size>();
    try {
      var rc = fn(seed, n, ffi.nullptr, lenPtr);
      if (rc != 0) return const [];
      var len = lenPtr.value;
      if (len == 0) return const [];
      final buf = calloc<ffi.Uint8>(len);
      try {
        rc = fn(seed, n, buf, lenPtr);
        if (rc != 0) return const [];
        len = lenPtr.value;
        final text =
            utf8.decode(buf.asTypedList(len), allowMalformed: true);
        return text.split('\n').where((e) => e.isNotEmpty).toList();
      } finally {
        calloc.free(buf);
      }
    } finally {
      calloc.free(lenPtr);
    }
  }

  /// 索引是否明显过期（加载自旧落盘文件或距上次构建超过 [maxAge]）。
  /// 空结果搜索兜底重建用：搜不到时先看索引新不新，旧就重建后重搜。
  static bool isStale({Duration maxAge = const Duration(minutes: 2)}) {
    if (!isBuilt) return true;
    final t = _lastBuiltAt;
    if (t == null) return true;
    return DateTime.now().difference(t) > maxAge;
  }

  /// 周期性重建（带节流）：距上次全量构建超过 [maxAge] 才重建，避免频繁全盘扫描。
  /// 用于托盘/定时刷新，保证新建/改名/删除的文件能被搜到（非 USN 的兜底实时刷新）。
  static Future<int> rebuildIfStale(
      {Duration maxAge = const Duration(minutes: 5)}) async {
    if (_building) return _cachedCount ?? 0; // 上一轮还在扫，别叠加
    if (!isBuilt) return prepareIndex();
    await loadRemovablePref();
    final now = DateTime.now();
    if (_lastBuiltAt != null && now.difference(_lastBuiltAt!) < maxAge) {
      return _cachedCount!;
    }
    // 周期性刷新默认只更新内存索引，不重复写盘（避免约 100MB 索引文件频繁落盘）。
    // 但若距上次落盘已超过 _persistMaxAge，本次重建顺带 persist——
    // 否则落盘索引会无限腐化（v1.0.43 修复：32 小时前的旧索引反复加载，
    // 每次重启都丢一批 watcher 启动前新建的文件）。
    final needPersist = _lastPersistAt == null ||
        now.difference(_lastPersistAt!) >= _persistMaxAge;
    return buildIndex(defaultRoots(), persist: needPersist);
  }

  // ==================== USN journal 索引（Windows NTFS，方案B） ====================

  /// USN 状态落盘文件路径（与索引同目录）
  static Future<String> _usnTablePath() async {
    return p.join(await _indexDataDir(), 'usn_table.bin');
  }

  /// 是否存在 NTFS 卷且 journal 可查询（QUERY 被安全软件拦截时返回 false，走遍历）
  static Future<bool> _usnPreferred() async {
    try {
      return await Isolate.run(() {
        final lib = RustCrypto.ensureLib();
        final fn = lib.lookupFunction<ffi.Int32 Function(ffi.Pointer<ffi.Char>),
            int Function(ffi.Pointer<ffi.Char>)>('usn_volume_supported');
        for (final root in defaultRoots()) {
          final ptr = root.toNativeUtf8().cast<ffi.Char>();
          try {
            if (fn(ptr) == 1) return true;
          } finally {
            calloc.free(ptr);
          }
        }
        return false;
      });
    } catch (_) {
      return false;
    }
  }

  /// 初始化空索引（USN 全量重建前）
  static Future<void> _initEmptyIndex() async {
    await Isolate.run(() {
      final lib = RustCrypto.ensureLib();
      final fn =
          lib.lookupFunction<ffi.Int32 Function(), int Function()>('index_init');
      fn();
    });
    _cachedCount = 0;
  }

  /// 加载 USN 目录 FRN 表（启动时紧接 loadIndex）
  static Future<bool> _loadUsnTable() async {
    try {
      final path = await _usnTablePath();
      final rc = await Isolate.run(() => _usnTableLoadSync(path));
      return rc == 0;
    } catch (_) {
      return false;
    }
  }

  /// USN 增量同步（替代 index_refresh 的 Windows 路径）。
  /// full=true 时强制每卷全量 ENUM。返回总条数，负数错误。
  /// 有变更才落盘（避免 30s 定时器反复写 100MB 索引文件）。
  static Future<int> syncUsn({bool full = false}) async {
    if (!Platform.isWindows || !isBuilt) return -1;
    final roots = defaultRoots();
    try {
      final before = await _usnChanges();
      final n = await Isolate.run(() => _usnSyncSync(roots, full));
      if (n < 0) return n;
      final after = await _usnChanges();
      _cachedCount = n;
      if (full || after != before) {
        await saveIndex();
        await _saveUsnTable();
      }
      return n;
    } catch (_) {
      return -1;
    }
  }

  static Future<int> _usnChanges() async {
    return Isolate.run(() {
      final lib = RustCrypto.ensureLib();
      final fn = lib.lookupFunction<ffi.Uint64 Function(), int Function()>(
          'usn_changes');
      return fn();
    });
  }

  static Future<int> _saveUsnTable() async {
    final path = await _usnTablePath();
    return Isolate.run(() => _usnTableSaveSync(path));
  }

  static int _usnSyncSync(List<String> roots, bool full) {
    final lib = RustCrypto.ensureLib();
    final name = full ? 'usn_rebuild' : 'usn_sync';
    final fn = lib.lookupFunction<
        ffi.Int64 Function(
            ffi.Pointer<ffi.Pointer<ffi.Char>>, ffi.Size),
        int Function(
            ffi.Pointer<ffi.Pointer<ffi.Char>>, int)>(name);
    final ptrs = calloc<ffi.Pointer<ffi.Char>>(roots.length);
    for (var i = 0; i < roots.length; i++) {
      ptrs[i] = roots[i].toNativeUtf8().cast<ffi.Char>();
    }
    try {
      return fn(ptrs, roots.length);
    } finally {
      for (var i = 0; i < roots.length; i++) {
        calloc.free(ptrs[i]);
      }
      calloc.free(ptrs);
    }
  }

  static int _usnTableSaveSync(String path) {
    final lib = RustCrypto.ensureLib();
    final fn = lib.lookupFunction<ffi.Int32 Function(ffi.Pointer<ffi.Char>),
        int Function(ffi.Pointer<ffi.Char>)>('usn_table_save');
    final ptr = path.toNativeUtf8().cast<ffi.Char>();
    try {
      return fn(ptr);
    } finally {
      calloc.free(ptr);
    }
  }

  static int _usnTableLoadSync(String path) {
    final lib = RustCrypto.ensureLib();
    final fn = lib.lookupFunction<ffi.Int32 Function(ffi.Pointer<ffi.Char>),
        int Function(ffi.Pointer<ffi.Char>)>('usn_table_load');
    final ptr = path.toNativeUtf8().cast<ffi.Char>();
    try {
      return fn(ptr);
    } finally {
      calloc.free(ptr);
    }
  }

  /// 建立索引（全量），返回条数并落盘。构建前先下发用户排除列表（Everything 式排除文件夹）
  static Future<int> buildIndex(List<String> roots,
      {bool persist = true}) async {
    if (_building) return _cachedCount ?? 0;
    _building = true;
    try {
      final excludes = await ExcludeService.load();
      final n =
          await Isolate.run(() => _buildSync(List<String>.of(roots), excludes));
      _cachedCount = n;
      _lastBuiltAt = DateTime.now();
      countNotifier.value = n;
      if (persist) {
        await saveIndex();
        _lastPersistAt = DateTime.now();
      }
      return n;
    } finally {
      _building = false;
    }
  }

  /// 从磁盘加载索引（成功返回 0 且 isBuilt=true）。
  /// 加载后把 _lastBuiltAt 设为索引文件 mtime——否则托盘定时器/空结果兜底
  /// 无法判断「这份索引有多旧」，过期判断会失真。
  static Future<int> loadIndex() async {
    final path = await _indexFilePath();
    final rc = await Isolate.run(() => _loadSync(path));
    if (rc == 0) {
      _cachedCount = await count();
      countNotifier.value = _cachedCount;
      try {
        final f = File(path);
        if (await f.exists()) {
          final m = (await f.stat()).modified;
          _lastBuiltAt = m;
          _lastPersistAt = m;
        }
      } catch (_) {}
    }
    return rc;
  }

  /// 落盘当前索引
  static Future<int> saveIndex() async {
    final path = await _indexFilePath();
    return Isolate.run(() => _saveSync(path));
  }

  /// 增量刷新（比对根 mtime，仅重扫变化盘），返回刷新后条数并落盘
  static Future<int> refreshIndex() async {
    final roots = defaultRoots();
    final n = await Isolate.run(() => _refreshSync(List<String>.of(roots)));
    if (n >= 0) {
      _cachedCount = n;
      await saveIndex();
    }
    return n;
  }

  /// 当前条数（FFI）
  static Future<int> count() async {
    return Isolate.run(() => _countSync());
  }

  /// 释放索引内存（收托盘/隐藏窗口时调用，降低常驻内存）。
  /// Rust 侧 drop 路径 Vec + MTIMES 表 + 根列表，Dart 侧计数清零。
  /// 下次搜索前 prepareIndex/rebuildIfStale 会从磁盘加载（毫秒级）或全量重建，无感恢复。
  static Future<void> releaseMemory() async {
    try {
      await Isolate.run(() {
        final lib = RustCrypto.ensureLib();
        final fn = lib.lookupFunction<ffi.Void Function(), void Function()>(
            'index_free');
        fn();
      });
    } catch (_) {}
    _cachedCount = null;
    _lastBuiltAt = null;
    countNotifier.value = null;
  }

  /// 释放进程级索引内存 + 删除落盘文件（下次搜索自动重建）
  static Future<void> freeIndex() async {
    await Isolate.run(() => _freeSync());
    if (Platform.isWindows) {
      await Isolate.run(() {
        final lib = RustCrypto.ensureLib();
        final fn =
            lib.lookupFunction<ffi.Void Function(), void Function()>(
                'usn_table_free');
        fn();
      });
      try {
        final f = File(await _usnTablePath());
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    _cachedCount = null;
    countNotifier.value = null;
    try {
      final f = File(await _indexFilePath());
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  static void _freeSync() {
    final lib = RustCrypto.ensureLib();
    final freeFn = lib
        .lookupFunction<ffi.Void Function(), void Function()>('index_free');
    freeFn();
  }

  static int _buildSync(List<String> roots, List<String> excludes) {
    if (roots.isEmpty) return -2;
    final lib = RustCrypto.ensureLib();

    // 下发排除列表（空列表=清除），index_build 遍历时生效
    if (excludes.isNotEmpty) {
      final setFn = lib.lookupFunction<
          ffi.Int32 Function(
              ffi.Pointer<ffi.Pointer<ffi.Char>>, ffi.Size),
          int Function(ffi.Pointer<ffi.Pointer<ffi.Char>>, int)>(
          'index_set_excludes');
      final exPtrs = calloc<ffi.Pointer<ffi.Char>>(excludes.length);
      for (var i = 0; i < excludes.length; i++) {
        exPtrs[i] = excludes[i].toNativeUtf8().cast<ffi.Char>();
      }
      try {
        setFn(exPtrs, excludes.length);
      } finally {
        for (var i = 0; i < excludes.length; i++) {
          calloc.free(exPtrs[i]);
        }
        calloc.free(exPtrs);
      }
    }

    final buildFn = lib.lookupFunction<
        ffi.Int64 Function(
            ffi.Pointer<ffi.Pointer<ffi.Char>>, ffi.Size),
        int Function(
            ffi.Pointer<ffi.Pointer<ffi.Char>>, int)>('index_build');
    final ptrs = calloc<ffi.Pointer<ffi.Char>>(roots.length);
    for (var i = 0; i < roots.length; i++) {
      ptrs[i] = roots[i].toNativeUtf8().cast<ffi.Char>();
    }
    try {
      return buildFn(ptrs, roots.length);
    } finally {
      for (var i = 0; i < roots.length; i++) {
        calloc.free(ptrs[i]);
      }
      calloc.free(ptrs);
    }
  }

  static int _saveSync(String path) {
    final lib = RustCrypto.ensureLib();
    final fn = lib.lookupFunction<ffi.Int32 Function(ffi.Pointer<ffi.Char>),
        int Function(ffi.Pointer<ffi.Char>)>('index_save');
    final ptr = path.toNativeUtf8().cast<ffi.Char>();
    try {
      return fn(ptr);
    } finally {
      calloc.free(ptr);
    }
  }

  static int _loadSync(String path) {
    final lib = RustCrypto.ensureLib();
    final fn = lib.lookupFunction<ffi.Int32 Function(ffi.Pointer<ffi.Char>),
        int Function(ffi.Pointer<ffi.Char>)>('index_load');
    final ptr = path.toNativeUtf8().cast<ffi.Char>();
    try {
      return fn(ptr);
    } finally {
      calloc.free(ptr);
    }
  }

  static int _refreshSync(List<String> roots) {
    final lib = RustCrypto.ensureLib();
    final fn = lib.lookupFunction<
        ffi.Int64 Function(ffi.Pointer<ffi.Pointer<ffi.Char>>, ffi.Size),
        int Function(ffi.Pointer<ffi.Pointer<ffi.Char>>, int)>('index_refresh');
    final ptrs = calloc<ffi.Pointer<ffi.Char>>(roots.length);
    for (var i = 0; i < roots.length; i++) {
      ptrs[i] = roots[i].toNativeUtf8().cast<ffi.Char>();
    }
    try {
      return fn(ptrs, roots.length);
    } finally {
      for (var i = 0; i < roots.length; i++) {
        calloc.free(ptrs[i]);
      }
      calloc.free(ptrs);
    }
  }

  static int _countSync() {
    final lib = RustCrypto.ensureLib();
    final fn =
        lib.lookupFunction<ffi.Int64 Function(), int Function()>('index_count');
    return fn();
  }

  /// 全盘搜索（后台 isolate），返回匹配文件路径列表。
  /// 结果按用户排除列表兜底过滤（覆盖从旧落盘索引加载、排除规则后改的场景）
  static Future<List<String>> search(String query, {int limit = 300}) async {
    final q = query.trim();
    if (q.isEmpty || !isBuilt) return const [];
    final excludes = await ExcludeService.load();
    final res = await Isolate.run(() => _searchSync(q, limit));
    if (excludes.isEmpty || res.isEmpty) return res;
    return res
        .where((path) => !ExcludeService.isExcluded(path, excludes))
        .toList();
  }

  static List<String> _searchSync(String query, int limit) {
    final lib = RustCrypto.ensureLib();
    final searchFn = lib.lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Char>, ffi.Size,
            ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Size>),
        int Function(ffi.Pointer<ffi.Char>, int, ffi.Pointer<ffi.Uint8>,
            ffi.Pointer<ffi.Size>)>('index_search');
    final qPtr = query.toNativeUtf8().cast<ffi.Char>();
    final lenPtr = calloc<ffi.Size>();
    try {
      var rc = searchFn(qPtr, limit, ffi.nullptr, lenPtr);
      if (rc != 0) return const [];
      var len = lenPtr.value;
      if (len == 0) return const [];
      final buf = calloc<ffi.Uint8>(len);
      try {
        rc = searchFn(qPtr, limit, buf, lenPtr);
        if (rc != 0) return const [];
        len = lenPtr.value;
        final text =
            utf8.decode(buf.asTypedList(len), allowMalformed: true);
        return text.split('\n').where((e) => e.isNotEmpty).toList();
      } finally {
        calloc.free(buf);
      }
    } finally {
      calloc.free(qPtr);
      calloc.free(lenPtr);
    }
  }

  // ==================== 目录变更实时监视（ReadDirectoryChangesW，桌面端） ====================

  static Timer? _watchTimer;
  static bool _watchStarting = false;

  /// 启动目录变更监视 + 2s 轮询增量合并（仅 Windows；内部幂等）。
  /// 监视线程在 Rust 侧常驻，变更目录路径入事件池，这里周期 drain 合并进索引。
  static Future<void> ensureWatcher() async {
    if (!Platform.isWindows || _watchTimer != null || _watchStarting) return;
    _watchStarting = true;
    try {
      await loadRemovablePref();
      final roots = defaultRoots(); // 主 isolate 算好（isolate 不继承静态设置）
      await Isolate.run(() => _watchStartSync(roots));
      _watchTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        unawaited(_drainWatchEvents());
      });
    } catch (_) {
    } finally {
      _watchStarting = false;
    }
  }

  static void _watchStartSync(List<String> roots) {
    final lib = RustCrypto.ensureLib();
    final fn = lib.lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Pointer<ffi.Char>>, ffi.Size),
        int Function(ffi.Pointer<ffi.Pointer<ffi.Char>>, int)>(
        'index_watch_start');
    final ptrs = calloc<ffi.Pointer<ffi.Char>>(roots.length);
    for (var i = 0; i < roots.length; i++) {
      ptrs[i] = roots[i].toNativeUtf8().cast<ffi.Char>();
    }
    try {
      fn(ptrs, roots.length);
    } finally {
      for (var i = 0; i < roots.length; i++) {
        calloc.free(ptrs[i]);
      }
      calloc.free(ptrs);
    }
  }

  /// 取走监视事件并增量合并。每轮先调 index_watch_start（幂等），
  /// 让溢出退出的根被重新拉起。增量合并后不落盘（重启后旧索引 + 定时全量兜底）。
  static Future<void> _drainWatchEvents() async {
    try {
      if (_building) return; // 全量构建中：事件留在 Rust 池，等下一轮
      await loadRemovablePref();
      final roots = defaultRoots(); // 主 isolate 算好；幂等重启监视（溢出/失败/新增根由此拉起）
      await Isolate.run(() => _watchStartSync(roots));
      final rootPrefixes =
          roots.map((r) => r.toLowerCase()).toSet();
      final payload = await Isolate.run(() => _watchDrainSync());
      if (payload.isEmpty) return;
      var dirty = 0;
      final overflowRoots = <String>{};
      for (final line in payload.split('\n')) {
        if (line.length < 2) continue;
        final tag = line[0];
        final arg = line.substring(1);
        if (tag == 'O') {
          overflowRoots.add(arg);
        } else if (tag == 'U' && isBuilt) {
          // 过滤已不在索引范围内的根（如关闭「扫描移动设备」后旧监视线程的残留事件），
          // 否则 index_update_dir 会把已重建掉的条目再并回去
          final dl = arg.toLowerCase();
          if (!rootPrefixes.any((r) => dl.startsWith(r))) continue;
          dirty += await Isolate.run(() => _updateDirsSync([arg]));
        }
      }
      // 溢出 = 监视线程已死，全量重建补齐（_building 防并发叠加），
      // 下一轮 drain 的 index_watch_start 会重新拉起线程
      if (overflowRoots.isNotEmpty && !_building) {
        unawaited(buildIndex(roots, persist: false));
      }
      if (dirty > 0) {
        _cachedCount = await count();
        countNotifier.value = _cachedCount;
        // 注意：不刷新 _lastBuiltAt。增量合并不代表全量构建刚发生过——
        // 若在此续期，托盘 rebuildIfStale 的 5 分钟退避将永远满足，
        // 全量重建被永久压制（v1.0.43 修复：旧索引+启动前丢失事件
        // 导致新文件永远搜不到的根因）。
      }
    } catch (_) {}
  }

  static String _watchDrainSync() {
    final lib = RustCrypto.ensureLib();
    final fn = lib.lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Size>),
        int Function(ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Size>)>(
        'index_watch_drain');
    final lenPtr = calloc<ffi.Size>();
    try {
      var rc = fn(ffi.nullptr, lenPtr);
      if (rc != 0) return '';
      var len = lenPtr.value;
      if (len == 0) return '';
      final buf = calloc<ffi.Uint8>(len);
      try {
        rc = fn(buf, lenPtr);
        if (rc != 0) return '';
        len = lenPtr.value;
        return utf8.decode(buf.asTypedList(len), allowMalformed: true);
      } finally {
        calloc.free(buf);
      }
    } finally {
      calloc.free(lenPtr);
    }
  }

  /// 批量增量合并目录，返回成功合并的目录数
  static int _updateDirsSync(List<String> dirs) {
    if (dirs.isEmpty) return 0;
    final lib = RustCrypto.ensureLib();
    final fn = lib.lookupFunction<ffi.Int32 Function(ffi.Pointer<ffi.Char>),
        int Function(ffi.Pointer<ffi.Char>)>('index_update_dir');
    var ok = 0;
    for (final d in dirs) {
      final ptr = d.toNativeUtf8().cast<ffi.Char>();
      try {
        if (fn(ptr) == 0) ok++;
      } catch (_) {
      } finally {
        calloc.free(ptr);
      }
    }
    return ok;
  }
}
