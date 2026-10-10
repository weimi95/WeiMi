import 'dart:io';

import 'package:flutter/services.dart';

/// 用系统默认方式打开文件（内置查看器不支持的格式兜底）。
///
/// - 桌面：Windows `start`、macOS `open`、Linux `xdg-open`
/// - Android：ACTION_VIEW + FileProvider（支持 apk 安装、HEIC 相册等）
class SystemOpenService {
  static const _channel = MethodChannel('com.weimi95.weimi/file_association');

  /// 用系统方式打开本地文件。返回是否成功调起。
  static Future<bool> open(String filePath) async {
    try {
      if (Platform.isAndroid) {
        final ok = await _channel.invokeMethod<bool>('openWithSystem', {
          'path': filePath,
        });
        return ok == true;
      }
      if (Platform.isWindows) {
        // start 的第一个引号参数是窗口标题，必须占位
        final r = await Process.run(
          'cmd',
          ['/c', 'start', '', filePath],
          runInShell: false,
        );
        return r.exitCode == 0;
      }
      if (Platform.isMacOS) {
        final r = await Process.run('open', [filePath]);
        return r.exitCode == 0;
      }
      if (Platform.isLinux) {
        final r = await Process.run('xdg-open', [filePath]);
        return r.exitCode == 0;
      }
    } catch (_) {}
    return false;
  }
}
