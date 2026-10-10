import 'dart:io';
import 'package:flutter/foundation.dart';

/// 桌面端开机自动启动
/// - Windows：HKCU ...\CurrentVersion\Run 注册表项（reg 命令，无需额外依赖）
/// - Linux：~/.config/autostart/*.desktop
/// - macOS：暂不支持（SMAppService 需平台通道，本版本跳过）
///
/// exePath / valueName 可指定目标：默认注册主程序；传 tray 进程的 exePath + 'WeiMiTray'
/// 即注册「开机自动启动飞传（托盘）」。
class AutostartService {
  AutostartService._();

  static const String _runKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

  static bool get supported => Platform.isWindows || Platform.isLinux;

  static Future<bool> isEnabled({String valueName = 'WeiMiFile'}) async {
    try {
      if (Platform.isWindows) {
        final r = await Process.run(
            'reg', ['query', _runKey, '/v', valueName]);
        return r.stdout.toString().contains(valueName);
      }
      if (Platform.isLinux) {
        final home = Platform.environment['HOME'] ?? '';
        if (home.isEmpty) return false;
        return File('$home/.config/autostart/${_desktopName(valueName)}')
            .exists();
      }
    } catch (e) {
      debugPrint('Autostart isEnabled failed: $e');
    }
    return false;
  }

  static Future<bool> setEnabled(bool enable,
      {String? exePath, String valueName = 'WeiMiFile'}) async {
    try {
      final exe = exePath ?? Platform.resolvedExecutable;
      if (Platform.isWindows) {
        if (enable) {
          final r = await Process.run('reg', [
            'add', _runKey, '/v', valueName, '/t', 'REG_SZ', '/d', '"$exe"', '/f'
          ]);
          return r.exitCode == 0;
        } else {
          final r = await Process.run(
              'reg', ['delete', _runKey, '/v', valueName, '/f']);
          return r.exitCode == 0;
        }
      }
      if (Platform.isLinux) {
        final home = Platform.environment['HOME'] ?? '';
        if (home.isEmpty) return false;
        final dir = Directory('$home/.config/autostart');
        if (!await dir.exists()) await dir.create(recursive: true);
        final f = File('$home/.config/autostart/${_desktopName(valueName)}');
        if (enable) {
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

  static String _desktopName(String valueName) =>
      '${valueName.toLowerCase()}.desktop';
}
