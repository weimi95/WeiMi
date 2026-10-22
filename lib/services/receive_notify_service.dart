import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'lan_transfer_service.dart';
import 'share_receive_service.dart';
import '../screens/transfer_history_screen.dart';

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

  /// 同批聚合（老板拍板）：手机一次共享多文件 = 逐个回调 fileDone。
  /// - 通知：同设备 3 秒内的多个文件合成一条（单文件仍用原文案）
  /// - 自动开目录：一批全部完成才开一次，不每个文件弹一次文件夹
  /// 批次结束判据 = 距最后一个文件完成 3 秒 且 该设备无进行中的接收
  /// （大文件串行传输时等最后一个传完再汇总，不会中途拆批）。
  final Map<String, _RecvBatch> _recvBatches = {};

  /// 拒收通知同设备聚合：一批连拒多个文件只提示一次
  final Map<String, _RecvBatch> _rejBatches = {};

  /// 收到文件（App / 网页 / WS 三条管线共用）
  void fileDone(String name, String from, String path) {
    final b = _recvBatches.putIfAbsent(from, () => _RecvBatch());
    b.add(name, path);
    b.timer?.cancel();
    // 首个文件收完且该设备无在途接收 → 立即开目录（恢复 v1.1.01 前
    // 「收完即开」的即时性；同批后续文件不再重复开，flush 只补通知）。
    if (!b.opened &&
        isDesktop &&
        _openDir &&
        !LanTransferService.instance.hasActiveIncomingByName(from)) {
      b.opened = true;
      unawaited(_openContainingFolder(b.dir));
    }
    b.timer = Timer(const Duration(seconds: 3), () => _flushRecv(from));
  }

  void _flushRecv(String from) {
    // 该设备还有文件在传 → 等最后一个完成（3 秒后重查，批次保留）
    if (LanTransferService.instance.hasActiveIncomingByName(from)) {
      final b = _recvBatches[from];
      b?.timer?.cancel();
      b?.timer = Timer(const Duration(seconds: 3), () => _flushRecv(from));
      return;
    }
    final b = _recvBatches.remove(from);
    if (b == null) return;
    final body = b.count == 1
        ? '已接收文件「${b.firstName}」（来自 $from）'
        : '已接收来自 $from 的 ${b.count} 个文件';
    _fire(body,
        revealPath: b.count == 1 ? b.firstPath : null, revealDir: b.dir);
    // 目录已在首文件完成时开过（b.opened）就不再重复开
    if (isDesktop && _openDir && !b.opened) {
      unawaited(_openContainingFolder(b.dir));
    }
  }

  /// 收到文本（点击通知 → 飞传传输记录页）
  void textDone(String from, String text) {
    final t = text.replaceAll('\n', ' ');
    final preview = t.length > 40 ? '${t.substring(0, 40)}…' : t;
    _fire('收到 $from 的文本：$preview', openHistory: true);
  }

  /// 未信任设备的请求被拒收（自动拒收/超时/直接拒绝模式），也要让机主知道。
  /// 同设备 3 秒内连拒多个文件只提示一次（聚合为「N 个文件/文本」）。
  void rejected(String name, String from) {
    final b = _rejBatches.putIfAbsent(from, () => _RecvBatch());
    b.add(name, '');
    b.timer?.cancel();
    b.timer = Timer(const Duration(seconds: 3), () {
      final bb = _rejBatches.remove(from);
      if (bb == null) return;
      final what = bb.count == 1 ? '「${bb.firstName}」' : '${bb.count} 个文件/文本';
      _fire('已拒收来自 $from 的 $what（未信任设备）。'
          '可在 设置-微密飞传-信任设备 添加后请对方重发',
          openHistory: true);
    });
  }

  void _fire(String body, {String? revealPath, String? revealDir, bool openHistory = false}) {
    if (!_enabled) return;
    if (isDesktop) {
      _desktopNotify(body, revealPath, revealDir, openHistory);
    } else {
      _androidBanner(body);
    }
  }

  void _desktopNotify(
      String body, String? revealPath, String? revealDir, bool openHistory) {
    if (!_desktopReady) return;
    try {
      final n = LocalNotification(title: '微密飞传', body: body);
      if (revealPath != null) {
        n.onClick = () => _revealInFileManager(revealPath);
      } else if (revealDir != null) {
        n.onClick = () => unawaited(_openContainingFolder(revealDir));
      } else if (openHistory) {
        n.onClick = _openTransferHistory;
      }
      n.show();
    } catch (_) {}
  }

  /// 点击通知 → 唤起主窗口并打开飞传传输记录页
  void _openTransferHistory() {
    unawaited(() async {
      try {
        if (isDesktop) {
          await windowManager.show();
          await windowManager.focus();
        }
      } catch (_) {}
      final ctx = ShareReceiveService.navigatorKey.currentContext;
      if (ctx == null) return;
      try {
        Navigator.of(ctx).push(MaterialPageRoute(
            builder: (_) => const TransferHistoryScreen()));
      } catch (_) {}
    }());
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
      final dir = path;
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

/// 一批接收/拒收的累积器：首个文件名/路径、目录、计数、debounce 定时器。
class _RecvBatch {
  int count = 0;
  String firstName = '';
  String firstPath = '';
  String dir = '';
  bool opened = false; // 目录已自动开过（首文件完成即开，一批只开一次）
  Timer? timer;

  void add(String name, String path) {
    count++;
    if (firstName.isEmpty) {
      firstName = name;
      firstPath = path;
      dir = path.isEmpty ? '' : File(path).parent.path;
    }
  }
}
