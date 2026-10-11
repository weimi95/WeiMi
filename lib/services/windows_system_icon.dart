import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:ffi/ffi.dart';
import 'package:path_provider/path_provider.dart';

/// Windows 系统图标获取（通过 Shell API 拿「文件关联图标」）。
///
/// 用 SHGetFileInfo 从 Windows Shell 拿到文件类型对应的 HICON，再 GDI 绘制到
/// 内存 DC 并导出为 BMP 文件，供 Flutter `Image.file` 直接加载。
///
/// 用途：让 Flutter 应用显示 Windows 原生图标（如 PSD 显示 PS logo），
/// 而不是应用自己内置的通用文件图标。
///
/// 非 Windows 平台 [getIconFile] 恒返回 null，调用方自行 fallback。
class WindowsSystemIcon {
  WindowsSystemIcon._();

  static final bool _isWin = Platform.isWindows;

  // DLL 句柄惰性加载
  static ffi.DynamicLibrary? _sh32;
  static ffi.DynamicLibrary? _user32;
  static ffi.DynamicLibrary? _gdi32;

  static ffi.DynamicLibrary _sh32lib() {
    if (!_isWin) throw UnsupportedError('Windows only');
    return _sh32 ??= ffi.DynamicLibrary.open('shell32.dll');
  }

  static ffi.DynamicLibrary _user32lib() {
    if (!_isWin) throw UnsupportedError('Windows only');
    return _user32 ??= ffi.DynamicLibrary.open('user32.dll');
  }

  static ffi.DynamicLibrary _gdi32lib() {
    if (!_isWin) throw UnsupportedError('Windows only');
    return _gdi32 ??= ffi.DynamicLibrary.open('gdi32.dll');
  }

  /// 获取文件的系统图标，导出为标准 BMP 到应用缓存目录。
  /// [path] 文件绝对路径；返回图标文件路径，null 表示非 Windows 或失败。
  /// Flutter 端可直接用 `Image.file(File(path))` 加载返回的 BMP。
  ///
  /// 缓存键 = sha1(路径|mtime|大小)，与方案B 共用 `wemi_thumbs` 目录
  /// （文件名带 `.icon.bmp` 后缀区分），文件变更自动失效重生成。
  static Future<String?> getIconFile(String path) async {
    if (!_isWin || path.isEmpty) return null;
    final key = await _cacheKey(path);
    if (key == null) return null;
    final cacheDir = await _cacheDirPath();
    final target = '$cacheDir\\$key.icon.bmp';
    if (File(target).existsSync()) return target;
    try {
      final result = _exportIconToBmp(path, target);
      return result;
    } catch (_) {
      return null;
    }
  }

  static Future<String> _cacheDirPath() async {
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

  static String? _exportIconToBmp(String path, String target) {
    // Windows SDK 常量
    const SHGFI_ICON = 0x100;
    const SHGFI_LARGEICON = 0x1;
    const FILE_ATTR_NORMAL = 0x80;
    const DI_NORMAL = 0x0003;
    const STOCK_NULL_BRUSH = 7;
    const BI_RGB = 0;

    // 路径 UTF-16（含终止符）
    final path16 = Uint16List.fromList([...path.codeUnits, 0]);
    final pathPtr = path16.buffer.asPointer<ffi.Void>();

    // lookup 各 Win32 API
    // 规则：第一个类型参数（NativeType）用 ffi.Xxx 前缀；
    // 第二个（DartType）：int 裸用，Pointer/原语类型用 ffi. 前缀。
    final shGetFileInfo = _sh32lib().lookupFunction<
        ffi.IntPtr Function(
            ffi.Pointer<ffi.Void>, ffi.IntPtr,
            ffi.Pointer<ffi.Void>, ffi.IntPtr, ffi.IntPtr),
        ffi.IntPtr Function(
            ffi.Pointer<ffi.Void>, int,
            ffi.Pointer<ffi.Void>, int, int)>(
        'SHGetFileInfoW');
    final getIconInfo = _user32lib().lookupFunction<
        int Function(ffi.IntPtr, ffi.Pointer<ffi.Void>),
        int Function(int, ffi.Pointer<ffi.Void>)>(
        'GetIconInfo');
    final deleteObject = _gdi32lib().lookupFunction<
        int Function(ffi.IntPtr),
        int Function(int)>(
        'DeleteObject');
    final getObject = _gdi32lib().lookupFunction<
        int Function(ffi.IntPtr, ffi.IntPtr, ffi.Pointer<ffi.Void>),
        int Function(int, int, ffi.Pointer<ffi.Void>)>(
        'GetObjectW');
    final getDC = _user32lib().lookupFunction<
        ffi.IntPtr Function(ffi.IntPtr),
        int Function(int)>(
        'GetDC');
    final releaseDC = _user32lib().lookupFunction<
        int Function(ffi.IntPtr, ffi.IntPtr),
        int Function(int, int)>(
        'ReleaseDC');
    final createCompatibleDC = _gdi32lib().lookupFunction<
        ffi.IntPtr Function(ffi.IntPtr),
        int Function(int)>(
        'CreateCompatibleDC');
    final deleteDC = _gdi32lib().lookupFunction<
        int Function(ffi.IntPtr),
        int Function(int)>(
        'DeleteDC');
    final createCompatibleBitmap = _gdi32lib().lookupFunction<
        ffi.IntPtr Function(ffi.IntPtr, ffi.IntPtr, ffi.IntPtr),
        int Function(int, int, int)>(
        'CreateCompatibleBitmap');
    final selectObject = _gdi32lib().lookupFunction<
        ffi.IntPtr Function(ffi.IntPtr, ffi.IntPtr),
        int Function(int, int)>(
        'SelectObject');
    final selectStockObject = _gdi32lib().lookupFunction<
        ffi.IntPtr Function(ffi.IntPtr),
        int Function(int)>(
        'SelectStockObject');
    final drawIconEx = _user32lib().lookupFunction<
        int Function(ffi.IntPtr, ffi.IntPtr, ffi.IntPtr, ffi.IntPtr,
            ffi.IntPtr, ffi.IntPtr, ffi.IntPtr, ffi.IntPtr, ffi.IntPtr),
        int Function(int, int, int, int, int, int, int, int, int)>(
        'DrawIconEx');
    final createSolidBrush = _gdi32lib().lookupFunction<
        ffi.IntPtr Function(ffi.IntPtr),
        int Function(int)>(
        'CreateSolidBrush');
    final fillRect = _gdi32lib().lookupFunction<
        int Function(ffi.IntPtr, ffi.Pointer<ffi.Void>, ffi.IntPtr),
        int Function(int, ffi.Pointer<ffi.Void>, int)>(
        'FillRect');
    final getDIBits = _gdi32lib().lookupFunction<
        int Function(ffi.IntPtr, ffi.IntPtr, ffi.IntPtr, ffi.IntPtr,
            ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>, ffi.IntPtr),
        int Function(int, int, int, int, ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Void>, int)>(
        'GetDIBits');

    // 分配 SHFILEINFO buffer（48 字节，只读前 8 字节的 hIcon）
    final shfi = calloc<ffi.Uint8>().calloc(48);
    shGetFileInfo.invoke(pathPtr, FILE_ATTR_NORMAL, shfi, 48,
        SHGFI_ICON | SHGFI_LARGEICON);
    final hIcon = shfi.elementAt(0).cast<ffi.Int64>().value;
    shfi.free();

    if (hIcon == 0) return null;

    try {
      // GetIconInfo -> ICONINFO {BOOL fIcon; DWORD xHotspot; DWORD yHotspot; HBITMAP hbmMask; HBITMAP hbmColor;}
      // 64 位下 sizeof(ICONINFO)=32，偏移：fIcon@0, xHotspot@4, yHotspot@8, hbmMask@16, hbmColor@24
      final gii = calloc<ffi.Uint8>().calloc(32);
      getIconInfo.invoke(hIcon, gii.address);
      final fIcon = gii.elementAt(0).cast<ffi.Int32>().value;
      final hbmMask = gii.elementAt(16).cast<ffi.Int64>().value;
      final hbmColor = gii.elementAt(24).cast<ffi.Int64>().value;
      gii.free();

      if (hbmMask != 0) deleteObject.invoke(hbmMask);
      if (hbmColor != 0) deleteObject.invoke(hbmColor);

      // fIcon==0 表示彩色图标，优先用彩色位图；否则退回遮罩位图
      final hbm = (fIcon == 0 && hbmColor != 0) ? hbmColor : hbmMask;
      if (hbm == 0) return null;

      // GetObject -> BITMAP {LONG type; LONG width; LONG height; ...}
      final bm = calloc<ffi.Uint8>().calloc(28);
      getObject.invoke(hbm, 28, bm.address);
      final w = bm.elementAt(4).cast<ffi.Int32>().value;
      final h = bm.elementAt(8).cast<ffi.Int32>().value;
      bm.free();

      if (w <= 0 || h <= 0 || w > 256 || h > 256) return null;

      // 创建内存 DC + 位图
      final hdcScreen = getDC.invoke(0);
      final hdcMem = createCompatibleDC.invoke(hdcScreen);
      final hbmTarget = createCompatibleBitmap.invoke(hdcScreen, w, h);
      selectObject.invoke(hdcMem, hbmTarget);

      // 填白色背景（透明区域显示为白）
      final brush = createSolidBrush.invoke(0x00FFFFFF);
      final rect = calloc<ffi.Uint8>().calloc(16);
      rect.elementAt(0).cast<ffi.Int32>().value = 0;
      rect.elementAt(4).cast<ffi.Int32>().value = 0;
      rect.elementAt(8).cast<ffi.Int32>().value = w;
      rect.elementAt(12).cast<ffi.Int32>().value = h;
      fillRect.invoke(hdcMem, rect.address, brush);
      rect.free();
      deleteObject.invoke(brush);

      // DrawIconEx 绘制图标到 DC（Windows 自动处理遮罩+透明）
      drawIconEx.invoke(hdcMem, 0, 0, w, h, hIcon, 0, 0, DI_NORMAL);

      // BITMAPINFO（24-bit BGR，top-down 用负 biHeight）
      final bmi = calloc<ffi.Uint8>().calloc(40);
      bmi.elementAt(0).cast<ffi.Int32>().value = 40;
      bmi.elementAt(4).cast<ffi.Int32>().value = w;
      bmi.elementAt(8).cast<ffi.Int32>().value = -h;
      bmi.elementAt(12).cast<ffi.Int16>().value = 1;
      bmi.elementAt(14).cast<ffi.Int16>().value = 24;
      bmi.elementAt(16).cast<ffi.Int32>().value = BI_RGB;

      // 拉像素到 buffer
      final rowBytes = ((w * 3 + 3) & ~3); // 行 4 字节对齐
      final pixSize = rowBytes * h;
      final pix = calloc<ffi.Uint8>().calloc(pixSize);
      final copied = getDIBits.invoke(
          hdcMem, hbmTarget, 0, h, pix.address, bmi.address, 0);
      bmi.free();

      selectObject.invoke(hdcMem, selectStockObject.invoke(STOCK_NULL_BRUSH));
      deleteObject.invoke(hbmTarget);
      deleteDC.invoke(hdcMem);
      releaseDC.invoke(0, hdcScreen);

      if (copied == 0) {
        pix.free();
        return null;
      }

      // 组装 BMP 文件（BITMAPFILEHEADER 14 字节 + BITMAPINFOHEADER 40 字节 + 像素）
      final bmp = Uint8List(14 + 40 + pixSize);
      // BITMAPFILEHEADER: "BM", fileSize(4 LE), reserved(4)=0, offset(4 LE)=54
      bmp[0] = 0x42;
      bmp[1] = 0x4D;
      final fileSize = 14 + 40 + pixSize;
      bmp[2] = fileSize & 0xFF;
      bmp[3] = (fileSize >> 8) & 0xFF;
      bmp[4] = (fileSize >> 16) & 0xFF;
      bmp[5] = (fileSize >> 24) & 0xFF;
      // offset = 54
      bmp[10] = 54;
      // BITMAPINFOHEADER: biSize(4 LE)=40, biWidth(4 LE), biHeight(4 LE), biPlanes(2)=1, biBitCount(2)=24, biCompression(4)=0, biSizeImage(4)=pixSize
      bmp[14] = 40;
      bmp[18] = w & 0xFF;
      bmp[19] = (w >> 8) & 0xFF;
      bmp[20] = (w >> 16) & 0xFF;
      bmp[21] = (w >> 24) & 0xFF;
      bmp[22] = h & 0xFF;
      bmp[23] = (h >> 8) & 0xFF;
      bmp[24] = (h >> 16) & 0xFF;
      bmp[25] = (h >> 24) & 0xFF;
      bmp[26] = 1;
      bmp[28] = 24;
      bmp[36] = pixSize & 0xFF;
      bmp[37] = (pixSize >> 8) & 0xFF;
      bmp[38] = (pixSize >> 16) & 0xFF;
      bmp[39] = (pixSize >> 24) & 0xFF;

      // 复制像素：GetDIBits 用负 biHeight 时数据是 top-down，标准 BMP 要求 bottom-up
      // 所以按行反转写入 bmp[54..]
      final rowsCount = (pixSize / rowBytes).toInt();
      for (int y = 0; y < rowsCount; y++) {
        final srcRowStart = y * rowBytes;
        final dstRowStart = (rowsCount - 1 - y) * rowBytes + 54;
        for (int x = 0; x < rowBytes; x++) {
          bmp[dstRowStart + x] = pix.elementAt(srcRowStart + x).value;
        }
      }

      pix.free();

      // 写入缓存文件
      File(target).writeAsBytesSync(bmp);
      return target;
    } finally {
      deleteObject.invoke(hIcon);
    }
  }
}
