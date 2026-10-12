import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'rust_crypto.dart';

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

  /// 索引是否已建立（内存态，含从磁盘加载）。要求条数 > 0：
  /// 旧版 USN 路径曾把「0 条空索引」落盘成 disk_index.bin，若仅以非空判就绪会误判、
  /// 导致全盘搜索永远搜不到——因此空索引视为未就绪，prepareIndex 会强制全量重建。
  static bool get isBuilt => _cachedCount != null && _cachedCount! > 0;

  /// 已索引条数（未建立返回 null）
  static int? get indexedCount => isBuilt ? _cachedCount : null;

  /// 落盘文件路径
  static Future<String> _indexFilePath() async {
    final docs = await getApplicationDocumentsDirectory();
    return p.join(docs.path, 'disk_index.bin');
  }

  /// 是否存在已落盘的索引文件
  static Future<bool> hasSavedIndex() async {
    try {
      return await File(await _indexFilePath()).exists();
    } catch (_) {
      return false;
    }
  }

  /// 默认索引根：Windows 枚举所有存在的盘符，macOS /Users，Linux 常见挂载点，安卓内置存储
  static List<String> defaultRoots() {
    if (Platform.isWindows) {
      final roots = <String>[];
      for (var c = 65; c <= 90; c++) {
        final root = '${String.fromCharCode(c)}:\\';
        try {
          if (Directory(root).existsSync()) roots.add(root);
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
    final rc = await loadIndex();
    if (rc == 0 && isBuilt) return _cachedCount!;
    return buildIndex(defaultRoots());
  }

  /// 周期性重建（带节流）：距上次全量构建超过 [maxAge] 才重建，避免频繁全盘扫描。
  /// 用于托盘/定时刷新，保证新建/改名/删除的文件能被搜到（非 USN 的兜底实时刷新）。
  static Future<int> rebuildIfStale(
      {Duration maxAge = const Duration(minutes: 5)}) async {
    if (!isBuilt) return prepareIndex();
    final now = DateTime.now();
    if (_lastBuiltAt != null && now.difference(_lastBuiltAt!) < maxAge) {
      return _cachedCount!;
    }
    // 周期性刷新只更新内存索引，不重复写盘（避免约 100MB 索引文件频繁落盘）。
    // 落盘由首次 buildIndex（persist 默认 true）完成，作为下次启动的快速加载源。
    return buildIndex(defaultRoots(), persist: false);
  }

  // ==================== USN journal 索引（Windows NTFS，方案B） ====================

  /// USN 状态落盘文件路径
  static Future<String> _usnTablePath() async {
    final docs = await getApplicationDocumentsDirectory();
    return p.join(docs.path, 'usn_table.bin');
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

  /// 建立索引（全量），返回条数并落盘
  static Future<int> buildIndex(List<String> roots,
      {bool persist = true}) async {
    final n = await Isolate.run(() => _buildSync(List<String>.of(roots)));
    _cachedCount = n;
    _lastBuiltAt = DateTime.now();
    if (persist) await saveIndex();
    return n;
  }

  /// 从磁盘加载索引（成功返回 0 且 isBuilt=true）
  static Future<int> loadIndex() async {
    final path = await _indexFilePath();
    final rc = await Isolate.run(() => _loadSync(path));
    if (rc == 0) {
      _cachedCount = await count();
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

  static int _buildSync(List<String> roots) {
    if (roots.isEmpty) return -2;
    final lib = RustCrypto.ensureLib();
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

  /// 全盘搜索（后台 isolate），返回匹配文件路径列表
  static Future<List<String>> search(String query, {int limit = 300}) async {
    final q = query.trim();
    if (q.isEmpty || !isBuilt) return const [];
    return Isolate.run(() => _searchSync(q, limit));
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
}
