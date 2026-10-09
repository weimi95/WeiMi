import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// 文件信息（用于列表展示）
class FileItem {
  final String name;
  final String fullPath;
  final bool isDirectory;
  final int size; // bytes, 0 for directories
  final DateTime? modified;
  final bool isEncrypted; // .wemi / .kyl

  FileItem({
    required this.name,
    required this.fullPath,
    required this.isDirectory,
    required this.size,
    this.modified,
    this.isEncrypted = false,
  });

  bool get isWemi => name.toLowerCase().endsWith('.wemi');
  bool get isKyl => name.toLowerCase().endsWith('.kyl');
  bool get isEncryptedFile => isWemi || isKyl;
  bool get isViewable =>
      isImage || isVideo || isAudio || isText || isPdf;

  bool get isImage => ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic'].contains(ext);
  bool get isVideo => ['mp4', 'avi', 'mkv', 'mov', 'wmv', 'flv'].contains(ext);
  bool get isAudio => ['mp3', 'wav', 'flac', 'aac', 'm4a', 'ogg'].contains(ext);
  bool get isText => ['txt', 'md', 'json', 'xml', 'csv', 'yaml', 'log'].contains(ext);
  bool get isPdf => ext == 'pdf';

  String get ext => path.extension(fullPath).replaceFirst('.', '').toLowerCase();

  String get humanSize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    if (size < 1024 * 1024 * 1024) return '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(size / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  @override
  String toString() => '$name (${isDirectory ? "📁" : "📄"}) ${humanSize}';
}

/// 「我的电脑」虚拟路径：listDirectory 对它返回磁盘/挂载点列表（桌面端）
const String kMyComputerPath = 'weimi://my-computer';

/// 遍历目录，返回扁平文件列表
Future<List<FileItem>> listDirectory(String dirPath) async {
  if (dirPath == kMyComputerPath) return _listMyComputer();

  final dir = Directory(dirPath);
  if (!await dir.exists()) return [];

  final items = <FileItem>[];
  await for (final entity in dir.list()) {
    final name = path.basename(entity.path);
    if (name.startsWith('.')) continue; // 跳过隐藏文件
    final stat = await entity.stat();
    items.add(FileItem(
      name: name,
      fullPath: entity.path,
      isDirectory: entity is Directory,
      size: stat.size,
      modified: stat.modified,
      isEncrypted: name.toLowerCase().endsWith('.wemi') ||
          name.toLowerCase().endsWith('.kyl'),
    ));
  }
  // 目录优先，按名称排序
  items.sort((a, b) {
    if (a.isDirectory != b.isDirectory) {
      return a.isDirectory ? -1 : 1;
    }
    return a.name.compareTo(b.name);
  });
  return items;
}

/// 列出电脑上的所有磁盘/挂载点（Windows 盘符、macOS /Volumes、Linux /media /mnt /）
Future<List<FileItem>> _listMyComputer() async {
  final items = <FileItem>[];
  if (Platform.isWindows) {
    for (var c = 65; c <= 90; c++) {
      final root = '${String.fromCharCode(c)}:\\';
      try {
        if (Directory(root).existsSync()) {
          items.add(FileItem(
            name: root,
            fullPath: root,
            isDirectory: true,
            size: 0,
          ));
        }
      } catch (_) {}
    }
  } else if (Platform.isMacOS) {
    final dir = Directory('/Volumes');
    if (dir.existsSync()) {
      try {
        await for (final e in dir.list()) {
          final name = path.basename(e.path);
          if (name.startsWith('.')) continue;
          items.add(FileItem(
              name: name, fullPath: e.path, isDirectory: true, size: 0));
        }
      } catch (_) {}
    }
  } else if (Platform.isLinux) {
    items.add(FileItem(
        name: '/', fullPath: '/', isDirectory: true, size: 0));
    for (final base in ['/media', '/mnt']) {
      final d = Directory(base);
      if (!d.existsSync()) continue;
      try {
        await for (final e in d.list()) {
          items.add(FileItem(
              name: e.path, fullPath: e.path, isDirectory: true, size: 0));
        }
      } catch (_) {}
    }
  }
  return items;
}

/// 获取 WeiMi Vault 目录（应用私有目录）
Future<String> getWeimiVaultPath() async {
  final dir = await getApplicationDocumentsDirectory();
  return path.join(dir.path, 'weimi_vault');
}

/// 确保 WeiMi Vault 目录存在
Future<void> ensureWeimiVault() async {
  final vaultDir = Directory(await getWeimiVaultPath());
  if (!await vaultDir.exists()) {
    await vaultDir.create(recursive: true);
  }
}
