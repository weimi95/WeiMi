import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 主程序（GUI）与托盘进程（飞传）之间的互相拉起 / 存活探测 / pidfile 管理。
///
/// 两进程同目录部署：主程序名 weimi_file，托盘名 weimi_tray（macOS 为并列的 .app）。
/// 通过应用文档目录的 pidfile（main.pid / tray.pid）互相判断对方是否在运行，
/// 避免重复启动多实例。
class TrayLauncher {
  static Future<String> get _docsDir async =>
      (await getApplicationDocumentsDirectory()).path;

  /// 主程序可执行文件绝对路径（跨平台）。
  static Future<String> mainExePath() async {
    final dir = p.dirname(Platform.resolvedExecutable);
    if (Platform.isWindows) return p.join(dir, 'weimi.exe'); // Windows BINARY_NAME=weimi
    if (Platform.isLinux) return p.join(dir, 'weimi_file');
    if (Platform.isMacOS) {
      final appParent = p.dirname(p.dirname(p.dirname(dir)));
      return p.join(
          appParent, 'weimi_file.app', 'Contents', 'MacOS', 'weimi_file');
    }
    return p.join(dir, 'weimi_file');
  }

  /// 托盘进程可执行文件绝对路径（跨平台）。
  static Future<String> trayExePath() async {
    final dir = p.dirname(Platform.resolvedExecutable);
    if (Platform.isWindows) return p.join(dir, 'weimi_tray.exe');
    if (Platform.isLinux) return p.join(dir, 'weimi_tray');
    if (Platform.isMacOS) {
      final appParent = p.dirname(p.dirname(p.dirname(dir)));
      return p.join(
          appParent, 'weimi_tray.app', 'Contents', 'MacOS', 'weimi_tray');
    }
    return p.join(dir, 'weimi_tray');
  }

  static Future<String> _pidFile(String name) async =>
      p.join(await _docsDir, name);

  /// 通过 pidfile 判断某进程是否在运行（跨平台进程存活检测）。
  static Future<bool> isRunning(String pidFileName) async {
    final f = File(await _pidFile(pidFileName));
    if (!await f.exists()) return false;
    final pid = int.tryParse((await f.readAsString()).trim());
    if (pid == null) return false;
    if (Platform.isWindows) {
      try {
        final r = await Process.run('tasklist', ['/FI', 'PID eq $pid'],
            runInShell: true);
        return r.stdout.toString().contains('$pid');
      } catch (_) {
        return false;
      }
    }
    // POSIX：kill -0 <pid> 不发送真实信号，仅检测进程是否存在
    try {
      final r = await Process.run('kill', ['-0', '$pid']);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<void> writePid(String pidFileName) async {
    try {
      await File(await _pidFile(pidFileName)).writeAsString('$pid');
    } catch (_) {}
  }

  static Future<void> removePid(String pidFileName) async {
    try {
      await File(await _pidFile(pidFileName)).delete();
    } catch (_) {}
  }

  /// 拉起托盘进程（若未运行）。detached 不阻塞主程序。
  static Future<void> ensureTrayRunning() async {
    if (await isRunning('tray.pid')) return;
    final exe = await trayExePath();
    try {
      await Process.start(exe, [],
          runInShell: true, mode: ProcessStartMode.detached);
    } catch (e) {
      debugPrint('ensureTrayRunning failed: $e');
    }
  }

  /// 打开主程序（若未运行）。
  static Future<void> openMainWindow() async {
    if (await isRunning('main.pid')) return;
    final exe = await mainExePath();
    try {
      await Process.start(exe, [],
          runInShell: true, mode: ProcessStartMode.detached);
    } catch (e) {
      debugPrint('openMainWindow failed: $e');
    }
  }
}
