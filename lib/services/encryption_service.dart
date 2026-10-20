import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'rust_crypto.dart';

bool get _isMobilePlatform {
  return Platform.isAndroid || Platform.isIOS;
}

class DecryptResult {
  final Uint8List? data;
  final String? tempFilePath;
  final bool isLargeFile;

  DecryptResult._({this.data, this.tempFilePath, required this.isLargeFile});

  factory DecryptResult.inMemory(Uint8List data) {
    return DecryptResult._(data: data, isLargeFile: false);
  }

  factory DecryptResult.tempFile(String path) {
    return DecryptResult._(tempFilePath: path, isLargeFile: true);
  }
}

class EncryptionService {
  static const String magicString = 'WEIMI_LOCK';
  static const String encryptedExtension = 'wemi';
  static const int version = 1;
  static const int headerSize = 14;
  static const int maxHintLength = 32;

  static int get chunkSize {
    return _isMobilePlatform
        ? 128 * 1048576
        : 256 * 1048576;
  }

  static Future<void> encryptFile(
    String inputPath,
    String outputPath,
    String password, {
    String? hint,
  }) async {
    final startTime = DateTime.now();
    final inputFile = File(inputPath);

    if (!await inputFile.exists()) {
      throw Exception('Input file does not exist');
    }

    final fileSize = await inputFile.length();
    if (kDebugMode) {
      debugPrint(
        '[ENCRYPT] Starting encryption: fileSize=$fileSize',
      );
    }

    final passwordBytes = utf8.encode(password);
    
    try {
      RustCrypto.encryptFile(
        inputPath,
        outputPath,
        Uint8List.fromList(passwordBytes),
        hint: hint,
        isMobile: _isMobilePlatform,
      );

      if (kDebugMode) {
        final duration = DateTime.now().difference(startTime);
        debugPrint(
          '[ENCRYPT] Encryption completed in ${duration.inMilliseconds}ms',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[ENCRYPT] Encryption failed: $e');
      }
      rethrow;
    }
  }

  static Future<bool> isEncryptedFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      return false;
    }

    try {
      final bytes = await file.openRead(0, magicString.length).first;
      final magic = String.fromCharCodes(bytes);
      return magic == magicString;
    } catch (e) {
      return false;
    }
  }

  static Future<String?> getPasswordHint(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      return null;
    }

    try {
      final hint = RustCrypto.getHintFromFile(filePath);
      return hint.isEmpty ? null : hint;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[HINT] Failed to get hint: $e');
      }
      return null;
    }
  }

  static Future<DecryptResult> decryptFile(
    String filePath,
    String password,
  ) async {
    final startTime = DateTime.now();
    final file = File(filePath);

    if (!await file.exists()) {
      throw Exception('File does not exist');
    }

    final fileSize = await file.length();

    if (kDebugMode) {
      debugPrint('[DECRYPT] Starting decryption: fileSize=$fileSize');
    }

    final passwordBytes = utf8.encode(password);
    
    try {
      final isLargeFile = (fileSize - headerSize - 1) > chunkSize;
      
      if (isLargeFile) {
        final tempDir = await getTemporaryDirectory();
        final originalExtension = _getOriginalExtension(filePath);
        final tempFile = File(
          path.join(
            tempDir.path,
            'weimi_file_${DateTime.now().millisecondsSinceEpoch}$originalExtension',
          ),
        );

        if (kDebugMode) {
          debugPrint('[DECRYPT] Large file, decrypting to temp file: ${tempFile.path}');
        }

        RustCrypto.decryptFile(
          filePath,
          tempFile.path,
          Uint8List.fromList(passwordBytes),
          isMobile: _isMobilePlatform,
        );

        if (kDebugMode) {
          final duration = DateTime.now().difference(startTime);
          debugPrint(
            '[DECRYPT] Decryption to temp file completed in ${duration.inMilliseconds}ms',
          );
        }

        return DecryptResult.tempFile(tempFile.path);
      } else {
        if (kDebugMode) {
          debugPrint('[DECRYPT] Small file, decrypting to memory');
        }

        final decryptedData = RustCrypto.decryptFileToMemory(
          filePath,
          Uint8List.fromList(passwordBytes),
          isMobile: _isMobilePlatform,
        );

        if (kDebugMode) {
          final duration = DateTime.now().difference(startTime);
          debugPrint(
            '[DECRYPT] Decryption to memory completed in ${duration.inMilliseconds}ms, size: ${decryptedData.length}',
          );
        }

        return DecryptResult.inMemory(decryptedData);
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[DECRYPT] Decryption failed: $e');
      }
      throw _friendlyDecryptError(e);
    }
  }

  /// 把 Rust 层英文错误码翻成中文：-2=密码错/损坏，-1=参数错
  static Exception _friendlyDecryptError(Object e) {
    final msg = e.toString();
    if (msg.contains('code: -2')) {
      return Exception('密码不正确或文件已损坏');
    }
    if (msg.contains('code: -1')) {
      return Exception('参数错误');
    }
    return e is Exception ? e : Exception(msg);
  }

  static String _getOriginalExtension(String encryptedPath) {
    final name = path.basenameWithoutExtension(encryptedPath);
    final lastDot = name.lastIndexOf('.');
    if (lastDot != -1) {
      return name.substring(lastDot);
    }
    return '';
  }

  static Future<void> decryptFileToPath(
    String inputPath,
    String outputPath,
    String password,
  ) async {
    final startTime = DateTime.now();
    final inputFile = File(inputPath);

    if (!await inputFile.exists()) {
      throw Exception('Input file does not exist');
    }

    final fileSize = await inputFile.length();
    if (kDebugMode) {
      debugPrint(
        '[DECRYPT_TO_PATH] Starting decryption: fileSize=$fileSize',
      );
    }

    final passwordBytes = utf8.encode(password);

    try {
      RustCrypto.decryptFile(
        inputPath,
        outputPath,
        Uint8List.fromList(passwordBytes),
        isMobile: _isMobilePlatform,
      );

      if (kDebugMode) {
        final duration = DateTime.now().difference(startTime);
        final outputSize = await File(outputPath).length();
        debugPrint(
          '[DECRYPT_TO_PATH] Decryption completed in ${duration.inMilliseconds}ms, output size: $outputSize',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[DECRYPT_TO_PATH] Decryption failed: $e');
      }
      throw _friendlyDecryptError(e);
    }
  }

  static String addEncryptedExtension(String filename) {
    return '$filename.$encryptedExtension';
  }

  static String removeEncryptedExtension(String filename) {
    if (filename.endsWith('.$encryptedExtension')) {
      return filename.substring(0, filename.length - encryptedExtension.length - 1);
    }
    return filename;
  }

  // ---- 归档容器（文件夹加密）----

  static const String archiveMagic = 'WEMI_FARC';
  static const String archiveExtension = 'wemi';

  static Future<bool> isArchiveFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      return false;
    }
    try {
      final bytes = await file.openRead(0, archiveMagic.length).first;
      if (bytes.length < archiveMagic.length) return false;
      return String.fromCharCodes(bytes) == archiveMagic;
    } catch (e) {
      return false;
    }
  }

  /// 打包文件夹 → 单文件 .wemi 归档（输出建议 `<文件夹名>.wemi`）
  static Future<void> packFolder(
    String dirPath,
    String outputPath,
    String password, {
    String? hint,
  }) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      throw Exception('文件夹不存在');
    }
    final passwordBytes = utf8.encode(password);
    if (passwordBytes.isEmpty) {
      throw Exception('密码不能为空');
    }
    try {
      RustCrypto.packFolder(
        dirPath,
        outputPath,
        Uint8List.fromList(passwordBytes),
        hint: hint,
        isMobile: _isMobilePlatform,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[PACK_FOLDER] failed: $e');
      }
      throw _friendlyArchiveError(e);
    }
  }

  /// 归档清单信息
  static Future<ArchiveListing> listArchive(
    String archivePath,
    String password,
  ) async {
    final file = File(archivePath);
    if (!await file.exists()) {
      throw Exception('文件不存在');
    }
    final passwordBytes = utf8.encode(password);
    if (passwordBytes.isEmpty) {
      throw Exception('密码不能为空');
    }

    final Map<String, dynamic> result;
    try {
      result = RustCrypto.archiveList(
        archivePath,
        Uint8List.fromList(passwordBytes),
      );
    } catch (e) {
      throw _friendlyArchiveError(e);
    }

    if (result['ok'] != true) {
      final code = result['code'] as int?;
      if (code == -3) {
        throw Exception('不是微密归档文件');
      }
      throw Exception('密码不正确或归档已损坏');
    }

    final entries = <ArchiveEntry>[];
    for (final item in (result['entries'] as List<dynamic>? ?? [])) {
      final m = item as Map<String, dynamic>;
      entries.add(ArchiveEntry(
        path: m['p'] as String,
        size: (m['s'] as num).toInt(),
      ));
    }
    return ArchiveListing(
      entries: entries,
      dirs: (result['dirs'] as List<dynamic>? ?? [])
          .map((d) => d as String)
          .toList(),
      hint: result['hint'] as String?,
    );
  }

  /// 解包整个归档到 outputDir（还原目录树）
  static Future<void> unpackArchive(
    String archivePath,
    String outputDir,
    String password,
  ) async {
    final passwordBytes = utf8.encode(password);
    if (passwordBytes.isEmpty) {
      throw Exception('密码不能为空');
    }
    try {
      RustCrypto.unpackArchive(
        archivePath,
        outputDir,
        Uint8List.fromList(passwordBytes),
      );
    } catch (e) {
      throw _friendlyArchiveError(e);
    }
  }

  /// 选择性解密：只抽取 paths 中的相对路径；空列表 = 全部
  static Future<void> extractSelected(
    String archivePath,
    String outputDir,
    String password,
    List<String> paths,
  ) async {
    final passwordBytes = utf8.encode(password);
    if (passwordBytes.isEmpty) {
      throw Exception('密码不能为空');
    }
    try {
      RustCrypto.extractSelected(
        archivePath,
        outputDir,
        Uint8List.fromList(passwordBytes),
        paths,
      );
    } catch (e) {
      throw _friendlyArchiveError(e);
    }
  }

  /// 归档错误码 → 中文（与 Rust archive.rs 的返回码对应）
  static Exception _friendlyArchiveError(Object e) {
    final msg = e.toString();
    if (msg.contains('code: -2')) {
      return Exception('密码不正确或归档已损坏');
    }
    if (msg.contains('code: -3')) {
      return Exception('不是微密归档文件');
    }
    if (msg.contains('code: -5')) {
      return Exception('归档含有非法路径，已中止');
    }
    if (msg.contains('code: -6')) {
      return Exception('没有匹配的文件');
    }
    return e is Exception ? e : Exception(msg);
  }

  /// 打包/解包进度（明文字节数）：done / total。total=0 表示未启动。
  static ({int done, int total}) archiveProgress() {
    return RustCrypto.archiveProgress();
  }
}

/// 归档清单条目
class ArchiveEntry {
  final String path;
  final int size;
  ArchiveEntry({required this.path, required this.size});
}

/// 归档清单（listArchive 返回）
class ArchiveListing {
  final List<ArchiveEntry> entries;
  final List<String> dirs;
  final String? hint;
  ArchiveListing({required this.entries, required this.dirs, this.hint});

  int get totalSize => entries.fold(0, (sum, e) => sum + e.size);
}