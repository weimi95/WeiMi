import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/windows_system_icon.dart';
import '../services/windows_thumbnail_provider.dart';

/// 文件类型信息（图标 + 颜色）
class FileTypeInfo {
  final IconData icon;
  final Color color;
  const FileTypeInfo(this.icon, this.color);
}

/// 文件类型分类（用于筛选）
enum FileCategory { all, image, video, audio, doc, archive, installer, encrypted, other }

class FileThumbs {
  FileThumbs._();

  static const _channel =
      MethodChannel('com.weimi95.weimi/video_thumb');

  /// 视频抽帧内存缓存
  static final Map<String, Uint8List?> _videoCache = {};
  /// 图片宽高比缓存（宽/高），瀑布流布局用
  static final Map<String, double> _aspectCache = {};

  /// 只读访问（瀑布流布局查询）
  static Map<String, double> get aspectCache => _aspectCache;

  static const video = {
    'mp4', 'avi', 'mkv', 'mov', 'wmv', 'flv', 'ts', '3gp',
    'webm', 'm4v', 'rmvb', 'rm', 'mpg', 'mpeg', 'vob',
  };
  static const image = {
    'jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic', 'heif',
    'tiff', 'tif', 'svg', 'ico',
  };
  static const audio = {
    'mp3', 'wav', 'flac', 'aac', 'm4a', 'ogg', 'wma', 'ape', 'opus',
  };
  static const doc = {
    'txt', 'md', 'json', 'xml', 'csv', 'log', 'pdf', 'doc', 'docx',
    'xls', 'xlsx', 'ppt', 'pptx', 'html', 'htm', 'epub', 'mobi',
    'rtf', 'wps', 'et', 'dps',
  };
  static const archive = {
    'zip', 'rar', '7z', 'tar', 'gz', 'tgz', 'bz2', 'xz', 'cab', 'iso',
  };
  static const installer = {
    'exe', 'msi', 'apk', 'dmg', 'pkg', 'deb', 'rpm', 'appimage', 'msix',
  };
  static const encrypted = {'wemi', 'kyl'};

  static String ext(String name) =>
      name.contains('.') ? name.split('.').last.toLowerCase() : '';

  static bool isImage(String name) => image.contains(ext(name));
  static bool isVideo(String name) => video.contains(ext(name));
  static bool isAudio(String name) => audio.contains(ext(name));

  /// 按扩展名给出类型图标（文件管理器风格）
  static FileTypeInfo infoFor(String name) {
    final e = ext(name);
    if (name.endsWith('.wemi')) {
      return const FileTypeInfo(Icons.lock, Colors.orange);
    }
    if (video.contains(e)) {
      return const FileTypeInfo(Icons.movie_outlined, Colors.purple);
    }
    if (image.contains(e)) {
      return const FileTypeInfo(Icons.image_outlined, Colors.teal);
    }
    if (audio.contains(e)) {
      return const FileTypeInfo(Icons.music_note_outlined, Colors.pink);
    }
    if (e == 'pdf') {
      return const FileTypeInfo(Icons.picture_as_pdf_outlined, Colors.red);
    }
    if (doc.contains(e)) {
      return const FileTypeInfo(Icons.description_outlined, Colors.blue);
    }
    if (archive.contains(e)) {
      return const FileTypeInfo(Icons.folder_zip_outlined, Color(0xFFB8860B));
    }
    return const FileTypeInfo(Icons.insert_drive_file_outlined, Colors.grey);
  }

  static FileCategory categoryOf(String name) {
    final e = ext(name);
    // 加密文件最优先（.wemi/.kyl 不参与常规分类）
    if (encrypted.contains(e)) return FileCategory.encrypted;
    if (image.contains(e)) return FileCategory.image;
    if (video.contains(e)) return FileCategory.video;
    if (audio.contains(e)) return FileCategory.audio;
    if (doc.contains(e)) return FileCategory.doc;
    if (archive.contains(e)) return FileCategory.archive;
    if (installer.contains(e)) return FileCategory.installer;
    return FileCategory.other;
  }

  /// Android 原生视频抽帧（返回 JPEG 字节；不支持时返回 null）
  static Future<Uint8List?> videoFrame(String path) async {
    if (!Platform.isAndroid) return null;
    if (_videoCache.containsKey(path)) return _videoCache[path];
    try {
      final data = await _channel.invokeMethod<Uint8List>(
        'getVideoThumbnail',
        {'path': path, 'width': 256},
      );
      _videoCache[path] = data;
      return data;
    } catch (_) {
      _videoCache[path] = null;
      return null;
    }
  }

  /// 图片宽高比（宽/高），只读图片头不解码全图；失败返回 null
  static Future<double?> aspectRatio(String path) async {
    if (_aspectCache.containsKey(path)) return _aspectCache[path];
    try {
      if (await File(path).length() > 32 * 1024 * 1024) return null;
      final bytes = await File(path).readAsBytes();
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final ratio = descriptor.width / descriptor.height;
      descriptor.dispose();
      buffer.dispose();
      _aspectCache[path] = ratio;
      return ratio;
    } catch (_) {
      return null;
    }
  }
}

/// 文件缩略图组件：
/// - 图片：真实缩略图（解码降采样省内存）
/// - 视频：Android 原生抽帧；Windows 走系统缩略图拿首帧
/// - 其他：Windows 走 IThumbnailProvider 真内容缩略图（三级回退），其余平台按扩展名彩色图标
class FileThumbnail extends StatelessWidget {
  final String path;
  final String name;
  final double size;

  const FileThumbnail({
    super.key,
    required this.path,
    required this.name,
    this.size = 42,
  });

  @override
  Widget build(BuildContext context) {
    if (FileThumbs.isImage(name)) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(path),
          width: size,
          height: size,
          fit: BoxFit.cover,
          cacheWidth: 256,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => _iconBox(),
        ),
      );
    }
    if (FileThumbs.isVideo(name)) {
      // Windows：系统缩略图拿视频首帧（无 provider 退系统图标/通用图标）
      if (Platform.isWindows) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: _WindowsPreview(path: path, name: name, size: size,
              video: true),
        );
      }
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: FutureBuilder<Uint8List?>(
          future: FileThumbs.videoFrame(path),
          builder: (context, snap) {
            final data = snap.data;
            if (data != null) {
              return Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(data,
                      fit: BoxFit.cover, gaplessPlayback: true),
                  const Center(
                    child: Icon(Icons.play_arrow,
                        color: Colors.white, size: 22),
                  ),
                ],
              );
            }
            return _iconBox();
          },
        ),
      );
    }
    // Windows 桌面：真内容缩略图 -> 系统图标 -> 通用图标的三级回退
    // （PSD 显示画面、docx/pdf 显示文档预览、无 provider 显示类型 logo）
    if (Platform.isWindows) {
      return _WindowsPreview(path: path, name: name, size: size);
    }
    return _iconBox();
  }

  Widget _iconBox() {
    final info = FileThumbs.infoFor(name);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: info.color.withAlpha(20),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(info.icon, size: size * 0.52, color: info.color),
    );
  }
}

/// Windows 缩略图加载（三级回退）：
/// 1. 方案B IThumbnailProvider 真内容缩略图（PSD 画面 / 视频首帧等）
/// 2. 方案A 系统文件关联图标（PS logo 等）
/// 3. Flutter 通用类型图标
class _WindowsPreview extends StatefulWidget {
  final String path;
  final String name;
  final double size;
  final bool video;

  const _WindowsPreview({
    required this.path,
    required this.name,
    required this.size,
    this.video = false,
  });

  @override
  State<_WindowsPreview> createState() => _WindowsPreviewState();
}

class _WindowsPreviewState extends State<_WindowsPreview> {
  String? _bmpPath;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _WindowsPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _bmpPath = null;
      _load();
    }
  }

  Future<void> _load() async {
    // 方案B 失败（未装对应程序、无 provider）时回退方案A 系统图标
    final bmpPath = await WindowsThumbnailProvider.getThumbnailFile(
            widget.path) ??
        await WindowsSystemIcon.getIconFile(widget.path);
    if (bmpPath != null && mounted) {
      setState(() => _bmpPath = bmpPath);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = _bmpPath == null ? null : File(_bmpPath!);
    if (f != null && f.existsSync()) {
      final img = Image.file(f,
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
          gaplessPlayback: true);
      if (!widget.video) return img;
      return Stack(
        fit: StackFit.expand,
        children: [
          img,
          const Center(
            child: Icon(Icons.play_arrow, color: Colors.white, size: 22),
          ),
        ],
      );
    }
    // 加载未完成或失败时展示通用 Flutter 图标
    final info = FileThumbs.infoFor(widget.name);
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: info.color.withAlpha(20),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(info.icon, size: widget.size * 0.52, color: info.color),
    );
  }
}
