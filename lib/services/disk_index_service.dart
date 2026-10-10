import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'rust_crypto.dart';

/// 全盘文件名索引（方案A：Rust 多线程遍历 + 进程内存索引）
///
/// - 索引随应用会话存在（内存态），每次启动首次使用时重建
/// - 搜索 = 文件名不区分大小写子串匹配，毫秒级
/// - 建索引/搜索都在后台 isolate 跑，不卡 UI
class DiskIndexService {
  static int? _cachedCount;

  /// 索引是否已建立
  static bool get isBuilt => _cachedCount != null && _cachedCount! >= 0;

  /// 已索引条数（未建立返回 null）
  static int? get indexedCount => isBuilt ? _cachedCount : null;

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

  /// 建立索引（阻塞至完成，后台 isolate 中执行），返回索引条数
  static Future<int> buildIndex(List<String> roots) async {
    final n = await Isolate.run(() => _buildSync(List<String>.of(roots)));
    _cachedCount = n;
    return n;
  }

  /// 释放进程级索引内存（下次搜索自动重建）
  static Future<void> freeIndex() async {
    await Isolate.run(() => _freeSync());
    _cachedCount = null;
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
