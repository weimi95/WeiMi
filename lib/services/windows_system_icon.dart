import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:ffi/ffi.dart';
import 'package:path_provider/path_provider.dart';

final class _RECT extends ffi.Struct {
  @ffi.Int32()
  external int left;
  @ffi.Int32()
  external int top;
  @ffi.Int32()
  external int right;
  @ffi.Int32()
  external int bottom;
}

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

final class _BITMAPINFO extends ffi.Struct {
  external _BITMAPINFOHEADER bmiHeader;

  @ffi.Array.multi([1])
  external ffi.Array<ffi.Uint32> bmiColors;
}

/// Windows 系统图标获取（方案A，通过 Shell API 拿「文件关联图标」）。
///
/// SHGetFileInfo 拿 HICON → DrawIconEx 绘到白底内存 DC → GetDIBits 拉
/// 24bpp 像素 → 组装 BMP 落盘缓存目录，供 Flutter `Image.file` 直接加载。
///
/// 用途：方案B（IThumbnailProvider 真内容缩略图）失败时的二级回退——
/// 没装对应缩略图提供程序时，至少显示 PS logo 等文件关联图标。
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
    const SHGFI_ICON = 0x100;
    const SHGFI_LARGEICON = 0x1;
    const FILE_ATTR_NORMAL = 0x80;
    const DI_NORMAL = 0x0003;
    const BI_RGB = 0;
    const iconW = 32; // SHGFI_LARGEICON 尺寸
    const iconH = 32;

    final shGetFileInfo = _sh32lib().lookupFunction<
        ffi.IntPtr Function(
            ffi.Pointer<ffi.Uint16>,
            ffi.Uint32,
            ffi.Pointer<ffi.Void>,
            ffi.Uint32,
            ffi.Uint32),
        int Function(ffi.Pointer<ffi.Uint16>, int, ffi.Pointer<ffi.Void>,
            int, int)>('SHGetFileInfoW');
    final getDC = _user32lib().lookupFunction<
        ffi.IntPtr Function(ffi.IntPtr), int Function(int)>('GetDC');
    final releaseDC = _user32lib().lookupFunction<
        ffi.Int32 Function(ffi.IntPtr, ffi.IntPtr),
        int Function(int, int)>('ReleaseDC');
    final createCompatibleDC = _gdi32lib().lookupFunction<
        ffi.IntPtr Function(ffi.IntPtr), int Function(int)>(
        'CreateCompatibleDC');
    final deleteDC = _gdi32lib().lookupFunction<
        ffi.Int32 Function(ffi.IntPtr), int Function(int)>('DeleteDC');
    final createCompatibleBitmap = _gdi32lib().lookupFunction<
        ffi.IntPtr Function(ffi.IntPtr, ffi.Int32, ffi.Int32),
        int Function(int, int, int)>('CreateCompatibleBitmap');
    final selectObject = _gdi32lib().lookupFunction<
        ffi.IntPtr Function(ffi.IntPtr, ffi.IntPtr),
        int Function(int, int)>('SelectObject');
    final deleteObject = _gdi32lib().lookupFunction<
        ffi.Int32 Function(ffi.IntPtr), int Function(int)>('DeleteObject');
    final createSolidBrush = _gdi32lib().lookupFunction<
        ffi.IntPtr Function(ffi.Uint32), int Function(int)>(
        'CreateSolidBrush');
    final fillRect = _user32lib().lookupFunction<
        ffi.Int32 Function(ffi.IntPtr, ffi.Pointer<_RECT>, ffi.IntPtr),
        int Function(int, ffi.Pointer<_RECT>, int)>('FillRect');
    final drawIconEx = _user32lib().lookupFunction<
        ffi.Int32 Function(
            ffi.IntPtr,
            ffi.Int32,
            ffi.Int32,
            ffi.IntPtr,
            ffi.Int32,
            ffi.Int32,
            ffi.Uint32,
            ffi.Pointer<ffi.Void>,
            ffi.Uint32),
        int Function(int, int, int, int, int, int, int, ffi.Pointer<ffi.Void>,
            int)>('DrawIconEx');
    final destroyIcon = _user32lib().lookupFunction<
        ffi.Int32 Function(ffi.IntPtr), int Function(int)>('DestroyIcon');
    final getDIBits = _gdi32lib().lookupFunction<
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

    // 1. SHGetFileInfo 拿文件关联 HICON
    final pathPtr = path.toNativeUtf16().cast<ffi.Uint16>();
    // sizeof(SHFILEINFOW) x64 = HICON(8) + iIcon(4) + dwAttributes(4)
    //   + szDisplayName[MAX_PATH*2=520] + szTypeName[80*2=160] = 696
    // shell32 会填满整个结构体，缓冲区必须 >= 696，否则越界写踩堆崩溃
    // （曾因用 536 导致 STATUS_HEAP_CORRUPTION / c0000374，见 2026-10-12 日志）
    const shfiSize = 696;
    final shfi = calloc<ffi.Uint8>(shfiSize);
    final hdcScreen = getDC(0);
    var hIcon = 0;
    try {
      // 返回值只是成功标志（恒为 1），真正的 HICON 在结构体首字段
      final ok = shGetFileInfo(pathPtr, FILE_ATTR_NORMAL, shfi.cast(), shfiSize,
          SHGFI_ICON | SHGFI_LARGEICON);
      hIcon = shfi.cast<ffi.Uint64>().value;
      if (ok == 0 || hIcon == 0) return null;

      // 2. 绘到白底内存 DC（白底兜住图标透明区域）
      final hdcMem = createCompatibleDC(hdcScreen);
      if (hdcMem == 0) return null;
      ffi.Pointer<ffi.Uint8>? pix;
      try {
        final hbmTarget = createCompatibleBitmap(hdcScreen, iconW, iconH);
        final oldBmp = selectObject(hdcMem, hbmTarget);
        final brush = createSolidBrush(0x00FFFFFF);
        final rect = calloc<_RECT>();
        rect.ref.left = 0;
        rect.ref.top = 0;
        rect.ref.right = iconW;
        rect.ref.bottom = iconH;
        fillRect(hdcMem, rect, brush);
        calloc.free(rect);
        deleteObject(brush);
        drawIconEx(hdcMem, 0, 0, hIcon, iconW, iconH, 0, ffi.nullptr,
            DI_NORMAL);
        selectObject(hdcMem, oldBmp); // GetDIBits 要求位图不在 DC 里选中

        // 3. GetDIBits 拉 24bpp BGR（负 biHeight = top-down）
        final bmi = calloc<_BITMAPINFO>();
        bmi.ref.bmiHeader.biSize = 40;
        bmi.ref.bmiHeader.biWidth = iconW;
        bmi.ref.bmiHeader.biHeight = -iconH;
        bmi.ref.bmiHeader.biPlanes = 1;
        bmi.ref.bmiHeader.biBitCount = 24;
        bmi.ref.bmiHeader.biCompression = BI_RGB;
        final rowBytes = (iconW * 3 + 3) & ~3;
        pix = calloc<ffi.Uint8>(rowBytes * iconH);
        final copied = getDIBits(hdcMem, hbmTarget, 0, iconH,
            pix.cast<ffi.Void>(), bmi, 0 /*DIB_RGB_COLORS*/);
        calloc.free(bmi);
        deleteObject(hbmTarget);
        if (copied == 0) return null;

        // 4. 组装 24bpp BMP（top-down 数据按行反转写 bottom-up）
        final bmp =
            _buildBmp(pix.asTypedList(rowBytes * iconH), iconW, iconH, rowBytes);
        File(target).writeAsBytesSync(bmp);
        return target;
      } finally {
        deleteDC(hdcMem);
        if (pix != null) calloc.free(pix);
      }
    } finally {
      calloc.free(pathPtr);
      calloc.free(shfi);
      if (hIcon != 0) destroyIcon(hIcon);
      if (hdcScreen != 0) releaseDC(0, hdcScreen);
    }
  }

  static void _put32(Uint8List list, int offset, int value) {
    list[offset] = value & 0xFF;
    list[offset + 1] = (value >> 8) & 0xFF;
    list[offset + 2] = (value >> 16) & 0xFF;
    list[offset + 3] = (value >> 24) & 0xFF;
  }

  /// 24bpp BMP 组装（rgb 为 top-down 像素，BMP 文件要求 bottom-up）
  static Uint8List _buildBmp(Uint8List rgb, int w, int h, int rowBytes) {
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
    _put32(bmp, 22, h);
    bmp[26] = 1; // biPlanes
    bmp[28] = 24; // biBitCount
    _put32(bmp, 34, pixSize);

    for (var y = 0; y < h; y++) {
      final src = (h - 1 - y) * rowBytes;
      final dst = 54 + y * rowBytes;
      bmp.setRange(dst, dst + rowBytes, rgb, src);
    }
    return bmp;
  }
}
