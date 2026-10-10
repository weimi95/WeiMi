import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:system_tray/system_tray.dart';
import 'package:window_manager/window_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'services/lan_transfer_service.dart';
import 'services/tray_ipc_server.dart';
import 'services/tray_launcher.dart';

/// 独立托盘进程（无窗口）：常驻跑微密飞传 + 网页快传 + 本地 IPC 管理端口 + 系统托盘。
/// 主程序关闭后即退出，本进程仍在，托盘里只保留飞传能力。
/// 仅桌面端构建（android/ios 不跑此 entrypoint）。
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  // 隐藏窗口：托盘进程不需要可见窗口，但需 runApp 初始化插件
  await windowManager.setPreventClose(true);
  await windowManager.hide();

  await TrayLauncher.writePid('tray.pid');

  // 飞传兜底目录
  try {
    final docs = await getApplicationDocumentsDirectory();
    LanTransferService.instance.fallbackDir = docs.path;
  } catch (_) {}

  // 常驻飞传 + 发现（供主程序经 IPC 查询在线设备）
  await LanTransferService.instance.startReceiving();
  await LanTransferService.instance.startDiscovery();

  // 本地 IPC 管理端口（主程序经此调用飞传）
  final ipc = TrayIpcServer();
  await ipc.start();

  await _initSystemTray(ipc);

  // 无可见 UI 窗口（已 hide）
  runApp(const MaterialApp(home: SizedBox.shrink()));
}

Future<void> _initSystemTray(TrayIpcServer ipc) async {
  try {
    final dir = await getTemporaryDirectory();
    final name = Platform.isWindows ? 'tray_icon.ico' : 'tray_icon.png';
    final data = await rootBundle.load('assets/images/$name');
    final f = File('${dir.path}${Platform.pathSeparator}$name');
    await f.writeAsBytes(data.buffer.asUint8List());

    final tray = SystemTray();
    await tray.initSystemTray(
      title: '微密文件 · 飞传',
      iconPath: f.path,
      toolTip: '微密文件 · 飞传',
    );
    final menu = Menu();
    await menu.buildFrom([
      MenuItemLabel(
        label: '打开微密文件',
        onClicked: (_) async => TrayLauncher.openMainWindow(),
      ),
      MenuSeparator(),
      MenuItemLabel(
        label: '退出飞传',
        onClicked: (_) async {
          await ipc.stop();
          await LanTransferService.instance.stopReceiving();
          await TrayLauncher.removePid('tray.pid');
          exit(0);
        },
      ),
    ]);
    await tray.setContextMenu(menu);
    tray.registerSystemTrayEventHandler((eventName) async {
      if (eventName == kSystemTrayEventClick) {
        await TrayLauncher.openMainWindow();
      }
    });
  } catch (e) {
    debugPrint('tray init failed: $e');
  }
}
