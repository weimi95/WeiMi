import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:system_tray/system_tray.dart';
import 'package:window_manager/window_manager.dart';
import 'disk_index_service.dart';
import 'daemon_service.dart';
import 'lan_transfer_service.dart';
import 'quick_search_window.dart';
import 'share_receive_service.dart';

/// 托盘策略（v1.0.47 起双模式）：
/// - 守护进程模式（Windows 默认开）：weimi_daemon.exe 托管托盘+飞传（约 10MB），
///   关窗 = UI 进程直接退出（Flutter 引擎内存归零）；UI 运行期间守护进程让出端口。
/// - 自托管模式（守护进程缺失/被关）：维持 v1.0.37 单进程方案——关窗收托盘，
///   进程常驻（收托盘时释放索引+图片缓存瘦身）。
class TrayService {
  TrayService._();
  static final TrayService instance = TrayService._();

  bool _initialized = false;
  bool _lean = false;
  bool _daemonMode = false; // 守护进程接管托盘+飞传
  final SystemTray _tray = SystemTray();

  /// 是否处于守护进程模式（诊断/设置页展示用）。
  bool get daemonMode => _daemonMode;

  /// 关闭按钮行为设置：
  /// - 'prompt'（默认）：弹确认框问「收托盘 / 退出」
  /// - 'minimize'：静默收托盘（保持原行为）
  /// - 'quit'：静默退出
  String get closeAction => _closeAction;
  String _closeAction = 'prompt';

  static const String _kCloseAction = 'tray_close_action';

  /// 读取持久化的关闭行为设置（main.dart runApp 前调用）。
  Future<void> loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _closeAction = prefs.getString(_kCloseAction) ?? 'prompt';
    } catch (_) {}
  }

  /// 设置关闭行为并持久化。
  Future<void> setCloseAction(String action) async {
    _closeAction = action;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCloseAction, action);
    } catch (_) {}
  }

  /// 桌面端初始化：窗口管理 + 托盘 + 启动常驻飞传（仅调用一次）。
  Future<void> initDesktop() async {
    if (_initialized) return;
    _initialized = true;

    // 缩略图缓存字节限额 64MB（默认只限张数不限字节，宫格/瀑布流狂滚会吃上百 MB）
    try {
      PaintingBinding.instance.imageCache.maximumSizeBytes = 64 << 20;
    } catch (_) {}

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

    // 守护进程模式：确保 weimi_daemon.exe 在跑并推配置（ui_active=true，
    // 守护进程让出端口给 UI）；成功则 UI 不再自建托盘，关窗即退出 UI 进程。
    if (await DaemonService.enabled()) {
      _daemonMode = await DaemonService.ensureRunning();
      if (_daemonMode) {
        await DaemonService.pushConfig(uiActive: true);
        // 守护进程可能正挂着未信任设备的待确认请求（它为此拉起了主界面）：
        // 等窗口就绪后拉取并逐个弹确认框
        unawaited(Future.delayed(
            const Duration(milliseconds: 2500), _checkDaemonPending));
      }
    }

    // 主程序自身常驻跑微密飞传（替代原独立托盘进程的飞传）
    // 按设置决定是否广播发现（「可被发现」关闭时仍保留 HTTP 接收端口）
    await LanTransferService.instance.applyDiscoverSetting();

    // 目录变更实时监视（ReadDirectoryChangesW）：新建/删除/改名秒级进索引
    unawaited(DiskIndexService.ensureWatcher());

    if (!_daemonMode) {
      await _initSystemTray();
    }
    // 全局接收确认：无论飞传页是否打开，非信任设备发来均弹窗提示（收托盘时也弹）
    LanTransferService.instance.confirmHandler = _globalConfirmRequest;

    // 全盘索引定时刷新（目录遍历方案A，已验证可靠）：每 30s 检查一次，
    // 距上次全量构建超过 5 分钟才重建（rebuildIfStale 内部节流 + _building 防重入）。
    // 不再要求 isBuilt：只加载过旧落盘索引也要刷新（新建文件才进得了索引）。
    // USN 路径已移出搜索关键路径。
    Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(DiskIndexService.rebuildIfStale());
    });
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
      debugPrint('tray: initSystemTray ok');

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

      try {
        await _tray.setContextMenu(menu);
      } catch (e, st) {
        debugPrint('tray: setContextMenu failed: $e\n$st');
      }

      // Windows 上 setContextMenu 只「设置」菜单，右键不会自动弹出，
      // 必须在 kSystemTrayEventRightClick 里显式 popUpContextMenu()。
      // 左键 -> 打开主窗口；右键 -> 弹出菜单（含「退出」）。
      _tray.registerSystemTrayEventHandler((eventName) async {
        if (eventName == kSystemTrayEventRightClick) {
          await _tray.popUpContextMenu();
        } else if (eventName == kSystemTrayEventClick) {
          await openMainWindow();
        }
      });
    } catch (e, st) {
      debugPrint('tray init failed: $e\n$st');
    }
  }

  /// 从托盘打开主窗口：恢复窗口并退出瘦身模式。
  Future<void> openMainWindow() async {
    // 若当前是浮窗态，先恢复主窗口几何与内容（否则会以浮窗形态显示）
    if (WindowModeService.instance.isPopup) {
      await WindowModeService.instance.hidePopup(openMain: true);
      return;
    }
    await exitLeanMode();
    await windowManager.show();
    await windowManager.focus();
  }

  /// 真正退出（托盘菜单「退出」/ 关闭确认「退出程序」）。
  /// 守护进程模式下先通知守护进程一并退出，托盘不留残留。
  Future<void> exitApp() async {
    if (_daemonMode) {
      try {
        await DaemonService.pushConfig(uiActive: false, quit: true);
      } catch (_) {}
    }
    try {
      await LanTransferService.instance.stopReceiving();
    } catch (_) {}
    // 先删托盘图标再退进程：否则 exit(0) 瞬间终止，Explorer 里残留
    // 幽灵托盘图标（要鼠标移上去才清理）。destroy 失败不阻退出。
    try {
      await _tray.destroy();
    } catch (e) {
      debugPrint('tray: destroy failed: $e');
    }
    exit(0);
  }

  /// 守护进程模式关窗：把飞传交给守护进程，UI 进程直接退出。
  /// 守护进程不在或推送失败时返回 false（调用方回退自托管收托盘）。
  Future<bool> handOffToDaemon() async {
    if (!_daemonMode) return false;
    try {
      final ok = await DaemonService.pushConfig(uiActive: false);
      if (ok) {
        await _tray.destroy().catchError((_) {});
        exit(0);
      }
    } catch (_) {}
    return false;
  }

  /// 收托盘瘦身：隐藏窗口 + 清空图片缓存 + 释放全盘索引内存。
  /// 索引下次搜索前由 prepareIndex 从磁盘毫秒级加载或重建，无感恢复。
  Future<void> enterLeanMode() async {
    if (_lean) return;
    _lean = true;
    // 复位浮窗态：收托盘后下次双击 Ctrl 应直接呼出浮窗
    WindowModeService.instance.popupMode.value = false;
    try {
      await windowManager.hide();
    } catch (_) {}
    try {
      PaintingBinding.instance.imageCache.clear();
    } catch (_) {}
    try {
      await DiskIndexService.releaseMemory();
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
    final action = TrayService.instance.closeAction;
    // 守护进程模式：收托盘路径（prompt/minimize）变成 UI 退出 + 守护进程接管；
    // closeAction='quit' 表示用户明确要求关闭即完全退出，不走接管。
    if (action != 'quit' && await TrayService.instance.handOffToDaemon()) {
      return;
    }
    if (action == 'quit') {
      // 静默退出
      await TrayService.instance.exitApp();
    } else if (action == 'minimize') {
      // 静默收托盘（保持原行为）
      await TrayService.instance.enterLeanMode();
    } else {
      // 'prompt'（默认）：弹确认框问「收托盘 / 退出」
      await _showCloseConfirm();
    }
  }

  @override
  void onWindowFocus() async {
    await TrayService.instance.exitLeanMode();
  }

  @override
  void onWindowBlur() {
    // 浮窗态失焦自动收起（设置项 qs_hide_on_blur 可关）
    WindowModeService.instance.onWindowBlur();
  }
}

/// 关闭按钮确认弹窗：
/// - 用户点右上角关闭 → preventClose=true 让事件冒泡到这里 → 弹窗询问。
/// - 「收进托盘」：调 enterLeanMode() 隐藏窗口 + 清空图片缓存，进程常驻。
/// - 「退出程序」：先标记 _lean 防弹窗关闭后窗口再闪一下，再真退出。
Future<void> _showCloseConfirm() async {
  final ctx = ShareReceiveService.navigatorKey.currentContext;
  if (ctx == null) {
    // Navigator 未就绪（极端情况）时降级为静默收托盘
    await TrayService.instance.enterLeanMode();
    return;
  }
  final daemonMode = TrayService.instance.daemonMode;
  final choice = await showDialog<bool>(
    context: ctx,
    barrierDismissible: false,
    builder: (c) => AlertDialog(
      title: const Text('关闭微密文件'),
      content: Text(daemonMode
          ? '选择「收进后台」后，主程序会退出（几乎不占内存），\n托盘和微密飞传由轻量守护进程（约 10MB）继续运行；\n选择「退出程序」则连守护进程一起完全关闭。'
          : '选择「收进托盘」后，程序会继续在后台运行（微密飞传保持可用）；\n选择「退出程序」则完全关闭应用。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('收进后台'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(c, true),
          child: const Text('退出程序', style: TextStyle(color: Colors.red)),
        ),
      ],
    ),
  );
  if (choice == true) {
    // 先收托盘（隐藏窗口，避免退出瞬间窗口闪一下），再真退出
    await TrayService.instance.enterLeanMode();
    await TrayService.instance.exitApp();
  } else {
    await TrayService.instance.enterLeanMode();
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
  return showIncomingConfirmDialog(
    ctx,
    senderName: req.senderName,
    content: req.fileName,
    sizeBytes: req.fileSize,
    isText: req.fileName == '一条文本消息',
    countdownSec: LanTransferService.confirmTimeoutSecs(),
  );
}

/// 未信任设备请求确认框（PC UI 态 / 手机端 / 守护进程拉起 UI 三路共用）。
/// 带 30 秒倒计时，超时自动按「拒收」处理。
Future<bool> showIncomingConfirmDialog(
  BuildContext ctx, {
  required String senderName,
  required String content,
  required int sizeBytes,
  bool isText = false,
  int countdownSec = 30,
}) async {
  final accepted = await showDialog<bool>(
    context: ctx,
    barrierDismissible: false,
    builder: (c) => _ConfirmCountdownDialog(
      senderName: senderName,
      content: content,
      sizeBytes: sizeBytes,
      isText: isText,
      countdownSec: countdownSec,
    ),
  );
  return accepted == true;
}

class _ConfirmCountdownDialog extends StatefulWidget {
  final String senderName;
  final String content;
  final int sizeBytes;
  final bool isText;
  final int countdownSec;

  const _ConfirmCountdownDialog({
    required this.senderName,
    required this.content,
    required this.sizeBytes,
    required this.isText,
    required this.countdownSec,
  });

  @override
  State<_ConfirmCountdownDialog> createState() =>
      _ConfirmCountdownDialogState();
}

class _ConfirmCountdownDialogState extends State<_ConfirmCountdownDialog> {
  late int _remain;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _remain = widget.countdownSec;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _remain--);
      if (_remain <= 0) {
        Navigator.pop(context, false); // 超时 = 拒收
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('未信任设备的传输请求'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('设备：${widget.senderName}',
              style: const TextStyle(fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
          Text('内容：${widget.content}'),
          const SizedBox(height: 2),
          Text(widget.isText
              ? '大小：${_fmtSize(widget.sizeBytes)}（约）'
              : '大小：${_fmtSize(widget.sizeBytes)}'),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.timer_outlined,
                  size: 16, color: Colors.orange.shade700),
              const SizedBox(width: 4),
              Text(
                '$_remain 秒内未确认将自动拒收',
                style: TextStyle(
                    fontSize: 12, color: Colors.orange.shade800),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _remain / widget.countdownSec,
              minHeight: 4,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('拒收')),
        TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('接收')),
      ],
    );
  }
}

/// 守护进程态：守护进程收到未信任请求后会拉起主界面并把待确认请求挂在
/// PENDING 里，UI 起来后到这里取走并弹确认框，决定经配置通道回传。
Future<void> _checkDaemonPending() async {
  try {
    final pending = await DaemonService.fetchPending();
    if (pending.isEmpty) return;
    final ctx = ShareReceiveService.navigatorKey.currentContext;
    if (ctx == null) return;
    for (final j in pending) {
      final token = j['token'] as String?;
      if (token == null || token.isEmpty) continue;
      final ok = await showIncomingConfirmDialog(
        ctx,
        senderName: (j['from'] as String?) ?? '未知设备',
        content: (j['name'] as String?) ?? '',
        sizeBytes: (j['size'] as num?)?.toInt() ?? 0,
        isText: j['isText'] == true,
        countdownSec: LanTransferService.confirmTimeoutSecs(),
      );
      final found = await DaemonService.sendConfirm(token, ok);
      if (!found) {
        final sctx = ShareReceiveService.navigatorKey.currentContext;
        if (sctx != null && sctx.mounted) {
          ScaffoldMessenger.of(sctx).showSnackBar(const SnackBar(
            content: Text('该请求已超时自动拒收，请让对方重新发送'),
            backgroundColor: Colors.orange,
          ));
        }
      }
      if (!ok) break; // 拒了一个，剩下的（同一设备连发）不再逐个打扰
    }
  } catch (_) {}
}
