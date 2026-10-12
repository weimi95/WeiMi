import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate' show Isolate, ReceivePort, SendPort;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:ffi/ffi.dart';
import 'package:path_provider/path_provider.dart';

/// GUID（16 字节）
final class _GUID extends ffi.Struct {
  @ffi.Uint32()
  external int data1;

  @ffi.Uint16()
  external int data2;

  @ffi.Uint16()
  external int data3;

  @ffi.Array.multi([8])
  external ffi.Array<ffi.Uint8> data4;
}

/// BITMAPINFOHEADER（40 字节）
final class _BITMAPINFOHEADER extends ffi.Struct {
  @ffi.Uint32()
  external int biSize;
  @ffi.Int32()
  external int biWidth;
  @ffi.Int32()
  external int biHeight;
  @ffi.Uint16()
  external int biPlanes;
  @ffi.Uint16()
  external int biBitCount;
  @ffi.Uint32()
  external int biCompression;
  @ffi.Uint32()
  external int biSizeImage;
  @ffi.Int32()
  external int biXPelsPerMeter;
  @ffi.Int32()
  external int biYPelsPerMeter;
  @ffi.Uint32()
  external int biClrUsed;
  @ffi.Uint32()
  external int biClrImportant;
}

/// BITMAPINFO（header + 1 个调色板占位项）
final class _BITMAPINFO extends ffi.Struct {
  external _BITMAPINFOHEADER bmiHeader;

  @ffi.Array.multi([1])
  external ffi.Array<ffi.Uint32> bmiColors;
}

/// GetObjectW 使用的 BITMAP（x64 下 32 字节：4x4 + 2x2 + 填充4 + 指针8）
final class _BITMAP extends ffi.Struct {
  @ffi.Int32()
  external int bmType;
  @ffi.Int32()
  external int bmWidth;
  @ffi.Int32()
  external int bmHeight;
  @ffi.Int32()
  external int bmWidthBytes;
  @ffi.Uint16()
  external int bmPlanes;
  @ffi.Uint16()
  external int bmBitsPixel;
  external ffi.Pointer<ffi.Void> bmBits;
}

/// IShellItemImageFactory.GetImage 的尺寸参数（按值传递）
final class _SIZE extends ffi.Struct {
  @ffi.Int32()
  external int cx;
  @ffi.Int32()
  external int cy;
}

/// 传给缩略图 isolate 的启动参数
class _ThumbCfg {
  final String cacheDir;
  final SendPort reply;
  const _ThumbCfg(this.cacheDir, this.reply);
}

/// Windows 真内容缩略图（方案B）：后台 isolate + COM IShellItemImageFactory。
///
/// - 主 isolate：缓存命中判断（键 = sha1(路径|mtime|大小)）、请求分发、失败负缓存
/// - 后台 isolate：CoInitializeEx(MTA) 一次，串行处理请求：
///   SHCreateItemFromParsingName(IID_IShellItemImageFactory)
///   → GetImage(256, THUMBNONLY|BIGGERSIZEOK) → GetDIBits 32bpp → alpha 合成白底
///   → 写 24bpp BMP 落盘缓存目录
/// - 用 ImageFactory 而非直接 BindToHandler(IThumbnailProvider) 的原因（实测）：
///   Explorer 对 PSD 等格式的缩略图存在 thumbcache 缓存里，GetImage 能读缓存；
///   直接 BindToHandler 绑定缩略图处理器返回 0x800401E5（MK_E_NOOBJECT）。
/// - 失败（无缩略图、COM 错误）返回 null，调用方回退方案A 系统图标或通用图标。
class WindowsThumbnailProvider {
  WindowsThumbnailProvider._();

  static const int _thumbSize = 256;
  // SIIGBF_THUMBNONLY | SIIGBF_BIGGERSIZEOK：只要真缩略图、允许更大图
  static const int _siigbfThumbOnly = 0x9;

  // IID_IShellItemImageFactory {BCC18B79-BA16-442F-80C4-8A59C30C463B}
  static const List<int> _iidImageFactory = [
    0xBCC18B79, 0xBA16, 0x442F, 0x80, 0xC4, 0x8A, 0x59, 0xC3, 0x0C, 0x46, 0x3B,
  ];

  // ---- 主 isolate 状态 ----
  static String? _cacheDir;
  static SendPort? _port;
  static Completer<void>? _starting;
  static ReceivePort? _responses;
  static bool _listening = false;
  static final Map<int, Completer<bool>> _pending = {};
  static final Set<String> _failedKeys = {};
  static int _seq = 0;

  /// 获取文件的真内容缩略图（BMP 路径）。
  /// 返回 null 表示非 Windows / 提取失败（调用方回退方案A 或通用图标）。
  static Future<String?> getThumbnailFile(String path) async {
    if (!Platform.isWindows || path.isEmpty) return null;
    _cacheDir ??= await _resolveCacheDir();
    final key = await _cacheKey(path);
    if (key == null) return null;
    if (_failedKeys.contains(key)) return null;

    final target = '${_cacheDir!}\\$key.thumb.bmp';
    if (File(target).existsSync()) return target;

    final ok = await _request(path, key);
    if (!ok) {
      _failedKeys.add(key);
      return null;
    }
    return File(target).existsSync() ? target : null;
  }

  static Future<String> _resolveCacheDir() async {
    final tmp = await getTemporaryDirectory();
    final dir = '${tmp.path}\\wemi_thumbs';
    Directory(dir).createSync(recursive: true);
    return dir;
  }

  static Future<String?> _cacheKey(String path) async {
    try {
      final st = await File(path).stat();
      if (st.type != FileSystemEntityType.file) return null;
      final raw = '$path|${st.modified.millisecondsSinceEpoch}|${st.size}';
      return crypto.sha1.convert(raw.codeUnits).toString();
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _request(String path, String key) async {
    try {
      await _ensurePort();
      final port = _port;
      if (port == null) return false;
      final completer = Completer<bool>();
      final id = _seq++;
      _pending[id] = completer;
      port.send({'id': id, 'path': path, 'key': key});
      return await completer.future
          .timeout(const Duration(seconds: 15), onTimeout: () => false);
    } catch (_) {
      return false;
    }
  }

  static Future<void> _ensurePort() async {
    if (_port != null) return;
    if (_starting != null) {
      await _starting!.future;
      return;
    }
    final starting = Completer<void>();
    _starting = starting;
    try {
      _responses ??= ReceivePort();
      if (!_listening) {
        _responses!.listen(_onResponse);
        _listening = true;
      }
      await Isolate.spawn(
        _isolateMain,
        _ThumbCfg(_cacheDir!, _responses!.sendPort),
      );
      await starting.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
    } catch (_) {
      starting.complete();
    }
  }

  static void _onResponse(dynamic msg) {
    if (msg is SendPort) {
      _port = msg;
      _starting?.complete();
      return;
    }
    if (msg is Map) {
      final id = msg['id'] as int;
      final completer = _pending.remove(id);
      if (completer != null && !completer.isCompleted) {
        completer.complete(msg['ok'] == true);
      }
    }
  }

  // ================= 后台 isolate =================

  static void _isolateMain(_ThumbCfg cfg) {
    try {
      final ole32 = ffi.DynamicLibrary.open('ole32.dll');
      final coInitializeEx = ole32.lookupFunction<
          ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Uint32),
          int Function(ffi.Pointer<ffi.Void>, int)>('CoInitializeEx');
      // COINIT_MULTITHREADED（后台线程无消息泵，不用 STA）
      coInitializeEx(ffi.nullptr, 0);
    } catch (_) {
      // COM 已被初始化或初始化失败都继续，提取时自会报错
    }
    final port = ReceivePort();
    cfg.reply.send(port.sendPort);
    port.listen((msg) {
      if (msg is! Map) return;
      final path = msg['path'] as String;
      final key = msg['key'] as String;
      bool ok = false;
      try {
        ok = _extractToCache(path, cfg.cacheDir, key);
      } catch (_) {
        ok = false;
      }
      cfg.reply.send({'id': msg['id'] as int, 'ok': ok});
    });
  }

  static ffi.Pointer<_GUID> _makeGuid(int d1, int d2, int d3, List<int> d4) {
    final g = calloc<_GUID>();
    g.ref.data1 = d1;
    g.ref.data2 = d2;
    g.ref.data3 = d3;
    for (var i = 0; i < 8; i++) {
      g.ref.data4[i] = d4[i];
    }
    return g;
  }

  /// COM vtable 第 idx 个槽位的函数指针
  static ffi.Pointer<ffi.Void> _vt(ffi.Pointer<ffi.Void> obj, int idx) {
    return obj.cast<ffi.Pointer<ffi.Pointer<ffi.Void>>>().value[idx];
  }

  /// COM Release（vtable 槽位 2）
  static void _release(ffi.Pointer<ffi.Void> obj) {
    try {
      _vt(obj, 2)
          .cast<ffi.NativeFunction<ffi.Uint32 Function(ffi.Pointer<ffi.Void>)>>()
          .asFunction<int Function(ffi.Pointer<ffi.Void>)>()(obj);
    } catch (_) {}
  }

  /// 单个文件的完整提取链路。成功写出 BMP 返回 true。
  static bool _extractToCache(String path, String cacheDir, String key) {
    final shell32 = ffi.DynamicLibrary.open('shell32.dll');
    final gdi32 = ffi.DynamicLibrary.open('gdi32.dll');

    final shCreateItem = shell32.lookupFunction<
        ffi.Int32 Function(
            ffi.Pointer<ffi.Uint16>,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<_GUID>,
            ffi.Pointer<ffi.Pointer<ffi.Void>>),
        int Function(
            ffi.Pointer<ffi.Uint16>,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<_GUID>,
            ffi.Pointer<ffi.Pointer<ffi.Void>>)>(
        'SHCreateItemFromParsingName');
    final getObjectW = gdi32.lookupFunction<
        ffi.Int32 Function(ffi.IntPtr, ffi.Uint32, ffi.Pointer<_BITMAP>),
        int Function(int, int, ffi.Pointer<_BITMAP>)>('GetObjectW');
    final createCompatibleDC = gdi32.lookupFunction<
        ffi.IntPtr Function(ffi.IntPtr), int Function(int)>(
        'CreateCompatibleDC');
    final deleteDC = gdi32.lookupFunction<
        ffi.Int32 Function(ffi.IntPtr), int Function(int)>('DeleteDC');
    final deleteObject = gdi32.lookupFunction<
        ffi.Int32 Function(ffi.IntPtr), int Function(int)>('DeleteObject');
    final getDIBits = gdi32.lookupFunction<
        ffi.Int32 Function(
            ffi.IntPtr,
            ffi.IntPtr,
            ffi.Uint32,
            ffi.Uint32,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<_BITMAPINFO>,
            ffi.Uint32),
        int Function(int, int, int, int, ffi.Pointer<ffi.Void>,
            ffi.Pointer<_BITMAPINFO>, int)>('GetDIBits');

    final iidFactory = _makeGuid(_iidImageFactory[0], _iidImageFactory[1],
        _iidImageFactory[2], _iidImageFactory.sublist(3));

    final pathPtr = path.toNativeUtf16().cast<ffi.Uint16>();
    final itemPtr = calloc<ffi.Pointer<ffi.Void>>();
    final hbmpPtr = calloc<ffi.IntPtr>();
    ffi.Pointer<ffi.Uint8>? pix;
    ffi.Pointer<_BITMAPINFO>? bmi;

    try {
      // 1. 路径 -> IShellItemImageFactory（GetImage 能读 Explorer 的 thumbcache）
      final hr1 = shCreateItem(pathPtr, ffi.nullptr, iidFactory, itemPtr);
      final item = itemPtr.value;
      if (hr1 < 0 || item.address == 0) return false;

      // 2. IShellItemImageFactory.GetImage(256, THUMBNONLY|BIGGERSIZEOK) -> HBITMAP
      //    vtable: 0=QI 1=AddRef 2=Release 3=GetImage
      final getImage = _vt(item, 3).cast<
              ffi.NativeFunction<
                  ffi.Int32 Function(ffi.Pointer<ffi.Void>, _SIZE, ffi.Uint32,
                      ffi.Pointer<ffi.IntPtr>)>>()
          .asFunction<
              int Function(ffi.Pointer<ffi.Void>, _SIZE, int,
                  ffi.Pointer<ffi.IntPtr>)>();
      final size = calloc<_SIZE>();
      size.ref.cx = _thumbSize;
      size.ref.cy = _thumbSize;
      final hr3 = getImage(item, size.ref, _siigbfThumbOnly, hbmpPtr);
      calloc.free(size);
      _release(item);
      if (hr3 < 0) return false;

      final hbmpRaw = hbmpPtr.value;
      // GDI 句柄只有低 32 位有效（高位可能被符号扩展污染）
      final hbmp = hbmpRaw & 0xFFFFFFFF;
      if (hbmp == 0) return false;

      try {
        // 4. HBITMAP 尺寸
        final bm = calloc<_BITMAP>();
        final got = getObjectW(hbmp, 32, bm);
        final w = got != 0 ? bm.ref.bmWidth : 0;
        final h = got != 0 ? bm.ref.bmHeight : 0;
        calloc.free(bm);
        if (w <= 0 || h <= 0 || w > 2048 || h > 2048) return false;

        // 5. GetDIBits 拉 32bpp BGRA（top-down）
        final hdc = createCompatibleDC(0);
        if (hdc == 0) return false;
        try {
          bmi = calloc<_BITMAPINFO>();
          bmi!.ref.bmiHeader.biSize = 40;
          bmi!.ref.bmiHeader.biWidth = w;
          bmi!.ref.bmiHeader.biHeight = -h; // 负值 = top-down
          bmi!.ref.bmiHeader.biPlanes = 1;
          bmi!.ref.bmiHeader.biBitCount = 32;
          bmi!.ref.bmiHeader.biCompression = 0; // BI_RGB
          bmi!.ref.bmiHeader.biSizeImage = w * h * 4;

          pix = calloc<ffi.Uint8>(w * h * 4);
          final copied =
              getDIBits(hdc, hbmp, 0, h, pix!.cast<ffi.Void>(), bmi!,
                  0 /*DIB_RGB_COLORS*/);
          if (copied == 0) return false;

          final bgra = pix!.asTypedList(w * h * 4);

          // 6. BGRA -> RGB（alpha 通道存在非 255 值时按 alpha 合成到白底；
          //    GetImage 不返回 WTSAT 标志，逐像素扫描代替）
          var hasAlpha = false;
          for (var i = 3; i < bgra.length; i += 4) {
            if (bgra[i] != 255) {
              hasAlpha = true;
              break;
            }
          }
          final rgb = Uint8List(w * h * 3);
          for (var i = 0, j = 0; i < w * h; i++) {
            var r = bgra[i * 4 + 2];
            var g = bgra[i * 4 + 1];
            var b = bgra[i * 4];
            if (hasAlpha) {
              final a = bgra[i * 4 + 3];
              if (a != 255) {
                r = (r * a + 255 * (255 - a)) ~/ 255;
                g = (g * a + 255 * (255 - a)) ~/ 255;
                b = (b * a + 255 * (255 - a)) ~/ 255;
              }
            }
            rgb[j++] = r;
            rgb[j++] = g;
            rgb[j++] = b;
          }

          // 7. 组装 24bpp BMP 落盘
          final bmp = _buildBmp(rgb, w, h);
          File('$cacheDir\\$key.thumb.bmp').writeAsBytesSync(bmp);
          return true;
        } finally {
          deleteDC(hdc);
        }
      } finally {
        deleteObject(hbmp);
      }
    } catch (_) {
      return false;
    } finally {
      calloc.free(pathPtr);
      calloc.free(iidFactory);
      calloc.free(itemPtr);
      calloc.free(hbmpPtr);
      if (pix != null) calloc.free(pix!);
      if (bmi != null) calloc.free(bmi!);
    }
  }

  static void _put32(Uint8List list, int offset, int value) {
    list[offset] = value & 0xFF;
    list[offset + 1] = (value >> 8) & 0xFF;
    list[offset + 2] = (value >> 16) & 0xFF;
    list[offset + 3] = (value >> 24) & 0xFF;
  }

  /// 24bpp BMP 组装（rgb 为 top-down，BMP 文件要求 bottom-up，行反转写入）
  static Uint8List _buildBmp(Uint8List rgb, int w, int h) {
    final rowBytes = (w * 3 + 3) & ~3; // BMP 行 4 字节对齐
    final pixSize = rowBytes * h;
    final fileSize = 54 + pixSize;
    final bmp = Uint8List(fileSize);

    // BITMAPFILEHEADER（14 字节）
    bmp[0] = 0x42;
    bmp[1] = 0x4D;
    _put32(bmp, 2, fileSize);
    _put32(bmp, 10, 54);

    // BITMAPINFOHEADER（40 字节）
    _put32(bmp, 14, 40);
    _put32(bmp, 18, w);
    _put32(bmp, 22, h); // 正值 = bottom-up
    bmp[26] = 1; // biPlanes
    bmp[28] = 24; // biBitCount
    _put32(bmp, 30, 0); // BI_RGB
    _put32(bmp, 34, pixSize);

    for (var y = 0; y < h; y++) {
      final src = (h - 1 - y) * w * 3;
      final dst = 54 + y * rowBytes;
      bmp.setRange(dst, dst + w * 3, rgb, src);
      // 行尾填充字节保持 0
    }
    return bmp;
  }
}
