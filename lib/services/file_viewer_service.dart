import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:file_picker/file_picker.dart' as file_picker;
import 'file_operations_service.dart';
import 'encryption_service.dart';
import 'system_open_service.dart';
import '../screens/video_player_screen.dart';
import '../screens/image_viewer_screen.dart';
import '../screens/audio_player_screen.dart';
import '../screens/text_viewer_screen.dart';
import '../screens/pdf_viewer_screen.dart';

class FileViewerService {
  /// 试探：Flutter 官方解码器能否解此文件（设备原生支持 heic 时为 true）。
  /// 仅 unknown 图片扩展名走到这里；失败即回退交系统打开。
  static Future<bool> _builtinDecodable(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      await codec.dispose();
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> openFile(
    BuildContext context,
    String filePath, {
    String? password,
    bool isEncrypted = false,
  }) async {
    FileType fileType;
    String actualFilePath = filePath;

    if (isEncrypted && password != null) {
      final extension = FileOperationsService.getFileExtension(filePath);
      if (extension == EncryptionService.encryptedExtension) {
        final originalName = EncryptionService.removeEncryptedExtension(
          filePath,
        );
        fileType = FileOperationsService.getFileType(originalName);
      } else {
        fileType = FileOperationsService.getFileType(filePath);
      }
    } else {
      fileType = FileOperationsService.getFileType(filePath);
    }

    if (fileType == FileType.unknown) {
      // v1.2.24：heic/heif/avif 等图片扩展名先试内置解码——设备原生支持时
      // （新安卓/iOS/macOS）统一走内置查看器，不再跳系统相册（体验割裂）；
      // 解不动（如桌面端）再交系统打开（apk 安装等）
      String? openTarget = filePath;
      if (isEncrypted && password != null) {
        // 加密文件先解密到临时目录，再交给系统
        try {
          final originalName = EncryptionService.removeEncryptedExtension(filePath);
          final tmpDir = await Directory.systemTemp.createTemp('weimi_open');
          openTarget = p.join(tmpDir.path, p.basename(originalName));
          await EncryptionService.decryptFileToPath(
            filePath, openTarget, password,
          );
        } catch (_) {
          openTarget = null;
        }
      }
      if (openTarget != null &&
          FileSystemEntity.typeSync(openTarget) != FileSystemEntityType.notFound) {
        final ext = FileOperationsService.getFileExtension(openTarget);
        if (['heic', 'heif', 'avif', 'hif'].contains(ext) &&
            await _builtinDecodable(openTarget)) {
          if (context.mounted) {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => ImageViewerScreen(
                  imagePath: openTarget!,
                  isEncrypted: false,
                ),
              ),
            );
            if (Platform.isAndroid) {
              try {
                await file_picker.FilePicker.platform.clearTemporaryFiles();
              } catch (e) {
                debugPrint('Failed to clear file_picker cache: $e');
              }
            }
          }
          return;
        }
        final r = await SystemOpenService.open(openTarget);
        if (r.ok) return;
        // 失败按原因兜底（apk 未授权→引导；无应用→打开方式）
        if (context.mounted) {
          await SystemOpenService.handleFailure(context, openTarget, r);
          return;
        }
      }
      if (isEncrypted) {
        throw Exception('不支持查看该文件类型。您可以通过"解密文件"功能解密后,使用其他软件查看');
      } else {
        throw Exception('系统中没有能打开此文件的应用');
      }
    }

    Widget? viewerScreen;

    switch (fileType) {
      case FileType.video:
        viewerScreen = VideoPlayerScreen(
          videoPath: actualFilePath,
          password: password,
          isEncrypted: isEncrypted,
        );
        break;
      case FileType.image:
        viewerScreen = ImageViewerScreen(
          imagePath: actualFilePath,
          password: password,
          isEncrypted: isEncrypted,
        );
        break;
      case FileType.audio:
        viewerScreen = AudioPlayerScreen(
          audioPath: actualFilePath,
          password: password,
          isEncrypted: isEncrypted,
        );
        break;
      case FileType.text:
        viewerScreen = TextViewerScreen(
          textPath: actualFilePath,
          password: password,
          isEncrypted: isEncrypted,
        );
        break;
      case FileType.pdf:
        viewerScreen = PDFViewerScreen(
          pdfPath: actualFilePath,
          password: password,
          isEncrypted: isEncrypted,
        );
        break;
      default:
        throw Exception('不支持查看该文件类型');
    }

    if (context.mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => viewerScreen!),
      );
      
      if (Platform.isAndroid) {
        try {
          await file_picker.FilePicker.platform.clearTemporaryFiles();
        } catch (e) {
          debugPrint('Failed to clear file_picker cache: $e');
        }
      }
    }
  }
}