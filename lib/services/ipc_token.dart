import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 托盘 IPC 鉴权 token + 管理端口。
///
/// 托盘进程（tray_main.dart）启动时生成随机 token、绑定端口后写入共享文件；
/// 主程序读取 (端口, token) 后用于调用托盘的本地管理端口（127.0.0.1），
/// 防止本机其他程序随意调用托盘飞传端口。
///
/// 共享文件落在与主程序相同的应用文档目录（同 app id 两进程路径一致）。
class IpcToken {
  static String? _cachedToken;
  static int? _cachedPort;

  /// 托盘进程调用：确保 token 存在并写入共享文件（含 IPC 端口）。
  static Future<String> ensure(int port) async {
    if (_cachedToken != null) {
      _cachedPort = port;
      await _write(port, _cachedToken!);
      return _cachedToken!;
    }
    final f = File(await _path());
    if (await f.exists()) {
      final raw = (await f.readAsString()).trim();
      String? t;
      if (raw.startsWith('{')) {
        try {
          final m = json.decode(raw) as Map<String, dynamic>;
          t = m['token']?.toString();
          if (t != null && t.isNotEmpty) _cachedPort = m['port'] as int?;
        } catch (_) {}
      } else if (raw.isNotEmpty) {
        t = raw; // 兼容旧纯 token 格式
      }
      if (t != null && t.isNotEmpty) _cachedToken = t;
    }
    _cachedToken ??= _generate();
    _cachedPort = port;
    await _write(port, _cachedToken!);
    return _cachedToken!;
  }

  /// 主程序调用：读取托盘写下的 (端口, token)；托盘未启动返回 null。
  static Future<(int, String)?> read() async {
    if (_cachedToken != null && _cachedPort != null) {
      return (_cachedPort!, _cachedToken!);
    }
    final f = File(await _path());
    if (!await f.exists()) return null;
    final raw = (await f.readAsString()).trim();
    if (raw.startsWith('{')) {
      try {
        final m = json.decode(raw) as Map<String, dynamic>;
        final t = m['token']?.toString();
        final port = m['port'] as int?;
        if (t != null && t.isNotEmpty && port != null) {
          _cachedToken = t;
          _cachedPort = port;
          return (port, t);
        }
      } catch (_) {}
    }
    return null;
  }

  static Future<String> _path() async {
    final docs = await getApplicationDocumentsDirectory();
    return p.join(docs.path, 'ipc_token.txt');
  }

  static Future<void> _write(int port, String token) async {
    try {
      final f = File(await _path());
      await f.writeAsString(json.encode({'port': port, 'token': token}));
    } catch (_) {}
  }

  static String _generate() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
