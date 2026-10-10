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
/// - 增量刷新：比对各根目录 mtime，未变跳过重扫，仅重扫变化的盘/目录
/// - 搜索 = 文件名不区分大小写子串匹配，毫秒级
class DiskIndexService {
  static int? _cachedCount;

  /// 索引是否已建立（内存态，含从磁盘加载）
  static bool get isBuilt => _cachedCount != null && _cachedCount! >= 0;

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

  /// 准备索引：已建立直接返回；否则尝试从磁盘加载（加载成功后后台增量刷新），
  /// 加载失败则全量重建并落盘。
  static Future<int> prepareIndex() async {
    if (isBuilt) return _cachedCount!;
    final rc = await loadIndex();
    if (rc == 0 && isBuilt) {
      // 后台增量刷新，不阻塞调用方
      unawaited(refreshIndex().then((_) {}));
      return _cachedCount!;
    }
    return buildIndex(defaultRoots());
  }

  /// 建立索引（全量），返回条数并落盘
  static Future<int> buildIndex(List<String> roots) async {
    final n = await Isolate.run(() => _buildSync(List<String>.of(roots)));
    _cachedCount = n;
    await saveIndex();
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
