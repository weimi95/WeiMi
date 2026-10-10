import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:system_tray/system_tray.dart';
import 'package:window_manager/window_manager.dart';
import 'services/lan_transfer_service.dart';
import 'services/share_receive_service.dart';

/// 单进程托盘：主程序自身常驻托盘。
///
/// 关窗 = 收托盘（隐藏窗口 + 清空图片缓存瘦身），微密飞传仍在后台跑；
/// 托盘菜单「退出」= 真正退出进程。相比双进程（独立托盘进程）方案，
/// 少一个 Flutter 引擎实例 + 无 IPC 层，结构更简单、生命周期可控。
class TrayService {
  TrayService._();
  static final TrayService instance = TrayService._();

  bool _initialized = false;
  bool _lean = false;
  final SystemTray _tray = SystemTray();

  /// 桌面端初始化：窗口管理 + 托盘 + 启动常驻飞传（仅调用一次）。
  Future<void> initDesktop() async {
    if (_initialized) return;
    _initialized = true;

    await windowManager.ensureInitialized();
    const opts = WindowOptions(
      size: Size(1100, 800),
      minimumSize: Size(700, 500),
      title: '微密文件',
    );
    await windowManager.waitUntilReadyToShow(opts, () async {
      await windowManager.show();
      // 关窗不退出，由 _WindowListener 收进托盘
      await windowManager.setPreventClose(true);
    });
    windowManager.addListener(_WindowListener());

    // 主程序自身常驻跑微密飞传（替代原独立托盘进程的飞传）
    await LanTransferService.instance.startReceiving();
    await LanTransferService.instance.startDiscovery();

    await _initSystemTray();
    // 全局接收确认：无论飞传页是否打开，非信任设备发来均弹窗提示（收托盘时也弹）
    LanTransferService.instance.confirmHandler = _globalConfirmRequest;
  }

  Future<void> _initSystemTray() async {
    try {
      final dir = await getTemporaryDirectory();
      final name = Platform.isWindows ? 'tray_icon.ico' : 'tray_icon.png';
      final data = await rootBundle.load('assets/images/$name');
      final f = File('${dir.path}${Platform.pathSeparator}$name');
      await f.writeAsBytes(data.buffer.asUint8List());

      await _tray.initSystemTray(
        title: '微密文件 · 飞传',
        iconPath: f.path,
        toolTip: '微密文件 · 飞传',
      );
      final menu = Menu();
      await menu.buildFrom([
        MenuItemLabel(
          label: '打开微密文件',
          onClicked: (_) async => openMainWindow(),
        ),
        MenuSeparator(),
        MenuItemLabel(
          label: '退出',
          onClicked: (_) async => exitApp(),
        ),
      ]);
      await _tray.setContextMenu(menu);
      _tray.registerSystemTrayEventHandler((eventName) async {
        if (eventName == kSystemTrayEventClick) {
          await openMainWindow();
        }
      });
    } catch (e) {
      debugPrint('tray init failed: $e');
    }
  }

  /// 从托盘打开主窗口：恢复窗口并退出瘦身模式。
  Future<void> openMainWindow() async {
    await exitLeanMode();
    await windowManager.show();
    await windowManager.focus();
  }

  /// 真正退出（托盘菜单「退出」）。
  Future<void> exitApp() async {
    try {
      await LanTransferService.instance.stopReceiving();
    } catch (_) {}
    exit(0);
  }

  /// 收托盘瘦身：隐藏窗口 + 清空图片缓存（缩略图等占大头）。
  Future<void> enterLeanMode() async {
    if (_lean) return;
    _lean = true;
    try {
      await windowManager.hide();
    } catch (_) {}
    try {
      PaintingBinding.instance.imageCache.clear();
    } catch (_) {}
  }

  /// 退出瘦身（窗口重新可见时调用）。
  Future<void> exitLeanMode() async {
    if (!_lean) return;
    _lean = false;
  }
}

class _WindowListener extends WindowListener {
  @override
  void onWindowClose() async {
    // 关窗 = 收托盘，不退出进程
    await TrayService.instance.enterLeanMode();
  }

  @override
  void onWindowFocus() async {
    await TrayService.instance.exitLeanMode();
  }
}

String _fmtSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

/// 全局接收确认弹窗：非信任设备发来文件/文本时由 LanTransferService 调用。
/// 弹窗前先恢复主窗口（收托盘隐藏时也能看到），信任设备已在 _decideAccept 直收、不会到这里。
Future<bool> _globalConfirmRequest(IncomingRequest req) async {
  await TrayService.instance.openMainWindow();
  final ctx = ShareReceiveService.navigatorKey.currentContext;
  if (ctx == null) return false;
  final accepted = await showDialog<bool>(
    context: ctx,
    barrierDismissible: false,
    builder: (c) => AlertDialog(
      title: const Text('收到传输请求'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('设备：${req.senderName}',
              style: const TextStyle(fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
          Text('内容：${req.fileName}'),
          const SizedBox(height: 2),
          Text('大小：${_fmtSize(req.fileSize)}'),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(c, false), child: const Text('拒收')),
        TextButton(
            onPressed: () => Navigator.pop(c, true), child: const Text('接收')),
      ],
    ),
  );
  return accepted == true;
}
