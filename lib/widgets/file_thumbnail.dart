import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 文件类型信息（图标 + 颜色）
class FileTypeInfo {
  final IconData icon;
  final Color color;
  const FileTypeInfo(this.icon, this.color);
}

/// 文件类型分类（用于筛选）
enum FileCategory { all, image, video, audio, doc, archive, other }

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

  static const video = {'mp4', 'avi', 'mkv', 'mov', 'wmv', 'flv', 'ts', '3gp'};
  static const image = {'jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic'};
  static const audio = {'mp3', 'wav', 'flac', 'aac', 'm4a', 'ogg'};
  static const doc = {
    'txt', 'md', 'json', 'xml', 'csv', 'log', 'pdf', 'doc', 'docx',
    'xls', 'xlsx', 'ppt', 'pptx', 'html', 'htm'
  };
  static const archive = {'zip', 'rar', '7z', 'tar', 'gz'};

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
    if (image.contains(e)) return FileCategory.image;
    if (video.contains(e)) return FileCategory.video;
    if (audio.contains(e)) return FileCategory.audio;
    if (doc.contains(e)) return FileCategory.doc;
    if (archive.contains(e)) return FileCategory.archive;
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
/// - 视频：Android 原生抽帧，桌面端退化为图标
/// - 其他：按扩展名的彩色类型图标
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
