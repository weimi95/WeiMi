import 'dart:io';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart' as file_picker;
import 'package:path/path.dart' as p;
import '../services/encryption_service.dart';

class FileOperationsService {
  static const MethodChannel _fileOpsChannel =
      MethodChannel('com.weimi95.weimi/file_association');

  /// 通过系统分享菜单分享文件（仅 Android）。返回 false = 平台不支持或失败。
  static Future<bool> shareFiles(List<String> paths) async {
    if (!Platform.isAndroid || paths.isEmpty) return false;
    try {
      final ok = await _fileOpsChannel.invokeMethod<bool>(
        'shareFiles',
        {'paths': paths},
      );
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  /// 选择一个目标目录（移动/复制用）
  static Future<String?> pickDirectory(String title) async {
    return file_picker.FilePicker.platform.getDirectoryPath(dialogTitle: title);
  }

  /// 目标目录内唯一化文件名：重名追加 " (n)" 序号
  static Future<String> _uniqueTarget(String dir, String name) async {
    final ext = p.extension(name);
    final base = p.basenameWithoutExtension(name);
    var target = p.join(dir, name);
    var i = 1;
    while (await File(target).exists()) {
      target = p.join(dir, '$base ($i)$ext');
      i++;
    }
    return target;
  }

  /// 批量复制文件到目标目录，返回 (成功数, 失败数)
  static Future<List<int>> copyFilesTo(
      List<String> paths, String destDir) async {
    int ok = 0, fail = 0;
    for (final path in paths) {
      try {
        final f = File(path);
        if (!await f.exists()) {
          fail++;
          continue;
        }
        final target =
            await _uniqueTarget(destDir, p.basename(path));
        await f.copy(target);
        ok++;
      } catch (_) {
        fail++;
      }
    }
    return [ok, fail];
  }

  /// 批量移动文件到目标目录（同分区 rename，跨分区 copy+delete），返回 (成功数, 失败数)
  static Future<List<int>> moveFilesTo(
      List<String> paths, String destDir) async {
    int ok = 0, fail = 0;
    for (final path in paths) {
      try {
        final f = File(path);
        if (!await f.exists()) {
          fail++;
          continue;
        }
        final target =
            await _uniqueTarget(destDir, p.basename(path));
        try {
          await f.rename(target);
        } catch (_) {
          await f.copy(target);
          await f.delete();
        }
        ok++;
      } catch (_) {
        fail++;
      }
    }
    return [ok, fail];
  }

  /// 重命名文件（重名返回 false）
  static Future<bool> renameFile(String path, String newName) async {
    try {
      final f = File(path);
      if (!await f.exists()) return false;
      final target = p.join(p.dirname(path), newName);
      if (await File(target).exists()) return false;
      await f.rename(target);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 批量选文件，返回 [{path: 缓存/真实路径, identifier: 原始 content:// URI（可能为 null）}]
  static Future<List<Map<String, String?>>> pickMultipleFilesWithOrigin() async {
    final result = await file_picker.FilePicker.platform
        .pickFiles(type: file_picker.FileType.any, allowMultiple: true);

    if (result != null && result.files.isNotEmpty) {
      return result.files
          .where((file) => file.path != null)
          .map((file) => {'path': file.path!, 'identifier': file.identifier})
          .toList();
    }
    return [];
  }

  /// 删除原始文件。
  /// Android 上 file_picker 返回的 path 是应用缓存副本，真实文件须通过
  /// 原生 MethodChannel 按 content:// URI 删除；其他平台直接删路径。
  static Future<bool> deleteOriginal(String path, {String? identifier}) async {
    if (Platform.isAndroid) {
      try {
        final target =
            (identifier != null && identifier.isNotEmpty) ? identifier : path;
        final ok = await _fileOpsChannel.invokeMethod<bool>(
          'deleteFile',
          {'path': target},
        );
        if (ok == true) return true;
        // 原生失败兜底：path 本身可能就是真实路径（旧版选择器/直读场景）
        final f = File(path);
        if (await f.exists()) {
          await f.delete();
          return true;
        }
        return false;
      } catch (_) {
        return false;
      }
    }
    try {
      final f = File(path);
      if (await f.exists()) {
        await f.delete();
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }
  static Future<List<String>> pickFilesForDecryption() async {
    file_picker.FilePickerResult? result = await file_picker.FilePicker.platform
        .pickFiles(type: file_picker.FileType.any, allowMultiple: true);

    if (result != null && result.files.isNotEmpty) {
      return result.files
          .where((file) => file.path != null)
          .map((file) => file.path!)
          .toList();
    }
    return [];
  }

  static Future<String?> pickFile() async {
    file_picker.FilePickerResult? result = await file_picker.FilePicker.platform
        .pickFiles(type: file_picker.FileType.any, allowMultiple: false);

    if (result != null && result.files.isNotEmpty) {
      return result.files.single.path;
    }
    return null;
  }

  static Future<List<String>> pickMultipleFiles() async {
    file_picker.FilePickerResult? result = await file_picker.FilePicker.platform
        .pickFiles(type: file_picker.FileType.any, allowMultiple: true);

    if (result != null && result.files.isNotEmpty) {
      return result.files
          .where((file) => file.path != null)
          .map((file) => file.path!)
          .toList();
    }
    return [];
  }

  static Future<String?> pickOutputDirectory() async {
    String? outputPath = await file_picker.FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select Output Directory',
    );
    return outputPath;
  }

  static Future<void> encryptFile(
    String inputPath,
    String outputDirectory,
    String password, {
    String? hint,
  }) async {
    final file = File(inputPath);
    final fileName = file.path.split(Platform.pathSeparator).last;

    final outputName = EncryptionService.addEncryptedExtension(fileName);
    final outputPath = '$outputDirectory${Platform.pathSeparator}$outputName';

    await EncryptionService.encryptFile(
      inputPath,
      outputPath,
      password,
      hint: hint,
    );
  }

  static Future<void> decryptFile(
    String inputPath,
    String outputDirectory,
    String password,
  ) async {
    final file = File(inputPath);
    final fileName = file.path.split(Platform.pathSeparator).last;

    final outputName = EncryptionService.removeEncryptedExtension(fileName);
    final outputPath = '$outputDirectory${Platform.pathSeparator}$outputName';

    await EncryptionService.decryptFileToPath(inputPath, outputPath, password);
  }

  static String getFileExtension(String filePath) {
    return filePath.split('.').last.toLowerCase();
  }

  static FileType getFileType(String filePath) {
    final ext = getFileExtension(filePath);

    if (['mp4', 'avi', 'mkv', 'mov', 'wmv', 'flv'].contains(ext)) {
      return FileType.video;
    } else if (['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp'].contains(ext)) {
      return FileType.image;
    } else if (['mp3', 'wav', 'flac', 'aac', 'm4a', 'ogg'].contains(ext)) {
      return FileType.audio;
    } else if (['txt', 'md', 'json', 'xml', 'csv'].contains(ext)) {
      return FileType.text;
    } else if (ext == 'pdf') {
      return FileType.pdf;
    } else {
      return FileType.unknown;
    }
  }
}

enum FileType { video, image, audio, text, pdf, unknown }