import 'dart:io';

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
      // 内置查看器不支持的格式 → 交给系统打开（apk 安装、HEIC 相册等）
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
        final ok = await SystemOpenService.open(openTarget);
        if (ok) return;
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