import 'dart:io';
import 'package:flutter/foundation.dart';

/// 桌面端开机自动启动
/// - Windows：HKCU ...\CurrentVersion\Run 注册表项（reg 命令，无需额外依赖）
/// - Linux：~/.config/autostart/*.desktop
/// - macOS：暂不支持（SMAppService 需平台通道，本版本跳过）
class AutostartService {
  AutostartService._();

  static const String _runKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const String _valueName = 'WeiMiFile';

  static bool get supported => Platform.isWindows || Platform.isLinux;

  static Future<bool> isEnabled() async {
    try {
      if (Platform.isWindows) {
        final r = await Process.run(
            'reg', ['query', _runKey, '/v', _valueName]);
        return r.stdout.toString().contains(_valueName);
      }
      if (Platform.isLinux) {
        final home = Platform.environment['HOME'] ?? '';
        if (home.isEmpty) return false;
        return File('$home/.config/autostart/weimi_file.desktop').exists();
      }
    } catch (e) {
      debugPrint('Autostart isEnabled failed: $e');
    }
    return false;
  }

  static Future<bool> setEnabled(bool enable) async {
    try {
      if (Platform.isWindows) {
        if (enable) {
          final exe = Platform.resolvedExecutable;
          final r = await Process.run('reg', [
            'add', _runKey, '/v', _valueName, '/t', 'REG_SZ', '/d', '"$exe"', '/f'
          ]);
          return r.exitCode == 0;
        } else {
          final r = await Process.run(
              'reg', ['delete', _runKey, '/v', _valueName, '/f']);
          return r.exitCode == 0;
        }
      }
      if (Platform.isLinux) {
        final home = Platform.environment['HOME'] ?? '';
        if (home.isEmpty) return false;
        final dir = Directory('$home/.config/autostart');
        if (!await dir.exists()) await dir.create(recursive: true);
        final f = File('$home/.config/autostart/weimi_file.desktop');
        if (enable) {
          final exe = Platform.resolvedExecutable;
          await f.writeAsString('[Desktop Entry]\n'
              'Type=Application\n'
              'Name=微密文件\n'
              'Exec=$exe\n'
              'X-GNOME-Autostart-enabled=true\n');
          return true;
        } else {
          if (await f.exists()) await f.delete();
          return true;
        }
      }
    } catch (e) {
      debugPrint('Autostart setEnabled failed: $e');
    }
    return false;
  }
}
