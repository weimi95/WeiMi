import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'share_receive_service.dart';

/// 接收完成通知服务：
/// - PC（Win/mac/Linux）：系统通知（local_notifier），点击打开文件所在目录
/// - Android：应用内横幅（ScaffoldMessenger，经全局 navigatorKey）
/// 行为口径（老板拍板）：信任设备/网页直收 + 完成提示；非信任设备仍走
/// confirmHandler 弹窗（接收/拒绝），本服务只负责「完成」通知。
class ReceiveNotifyService {
  ReceiveNotifyService._();
  static final ReceiveNotifyService instance = ReceiveNotifyService._();

  static const String _kEnabledKey = 'notify_receive_done';
  static const String _kOpenDirKey = 'lan_open_recv_folder';

  bool _enabled = true;
  bool _openDir = false;
  bool _desktopReady = false;
  bool get isDesktop => !Platform.isAndroid && !Platform.isIOS;
  bool get enabled => _enabled;
  bool get openDir => _openDir;

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_kEnabledKey) ?? true;
      _openDir = prefs.getBool(_kOpenDirKey) ?? false;
    } catch (_) {}
    if (isDesktop) {
      try {
        await localNotifier.setup(appName: '微密文件');
        _desktopReady = true;
      } catch (_) {}
    }
  }

  Future<void> setEnabled(bool v) async {
    _enabled = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kEnabledKey, v);
    } catch (_) {}
  }

  /// 收到文件后自动打开保存目录（仅电脑端生效）
  Future<void> setOpenDir(bool v) async {
    _openDir = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kOpenDirKey, v);
    } catch (_) {}
  }

  /// 收到文件（App / 网页 / WS 三条管线共用）
  void fileDone(String name, String from, String path) {
    _fire('已接收文件「$name」（来自 $from）', revealPath: path);
    if (isDesktop && _openDir) {
      unawaited(_openContainingFolder(path));
    }
  }

  /// 收到文本
  void textDone(String from, String text) {
    final t = text.replaceAll('\n', ' ');
    final preview = t.length > 40 ? '${t.substring(0, 40)}…' : t;
    _fire('收到 $from 的文本：$preview');
  }

  /// 未信任设备的请求被拒收（自动拒收/超时/直接拒绝模式），也要让机主知道
  void rejected(String name, String from) {
    _fire('已拒收来自 $from 的「$name」（未信任设备）。'
        '可在 设置-微密飞传-信任设备 添加后请对方重发');
  }

  void _fire(String body, {String? revealPath}) {
    if (!_enabled) return;
    if (isDesktop) {
      _desktopNotify(body, revealPath);
    } else {
      _androidBanner(body);
    }
  }

  void _desktopNotify(String body, String? revealPath) {
    if (!_desktopReady) return;
    try {
      final n = LocalNotification(title: '微密飞传', body: body);
      if (revealPath != null) {
        n.onClick = () => _revealInFileManager(revealPath);
      }
      n.show();
    } catch (_) {}
  }

  void _androidBanner(String body) {
    final ctx = ShareReceiveService.navigatorKey.currentContext;
    if (ctx == null) return;
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        content: Text(body),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  /// 在系统文件管理器里定位文件（与加解密历史页同口径）
  Future<void> _revealInFileManager(String path) async {
    try {
      if (Platform.isWindows) {
        // explorer /select 需要反斜杠路径
        final win = path.replaceAll('/', '\\');
        await Process.run('explorer.exe', ['/select,', win]);
      } else if (Platform.isMacOS) {
        await Process.run('open', ['-R', path]);
      } else if (Platform.isLinux) {
        final dir = File(path).parent.path;
        await Process.run('xdg-open', [dir]);
      }
    } catch (_) {}
  }

  /// 打开文件所在目录（不选中）
  Future<void> _openContainingFolder(String path) async {
    try {
      final dir = File(path).parent.path;
      if (Platform.isWindows) {
        await Process.run('explorer.exe', [dir.replaceAll('/', '\\')]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [dir]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [dir]);
      }
    } catch (_) {}
  }
}
