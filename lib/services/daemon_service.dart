import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'lan_transfer_service.dart';

/// 原生守护进程（weimi_daemon.exe，Windows）桥接。
///
/// 职责：UI 启动时确保守护进程在跑并推配置（ui_active=true，守护进程让出
/// 网络端口）；关窗收托盘时推 ui_active=false 并直接退出 UI 进程——托盘
/// 与飞传由守护进程接管（约 10MB），Flutter 引擎完全退出（内存归零）。
///
/// 协议：TCP 127.0.0.1:52349，一行 JSON，写完即关连接。
/// 守护进程缺失时可静默拉起（与 weimi.exe 同目录）。
class DaemonService {
  DaemonService._();

  static const int _configPort = 52349;
  static const String _kEnabled = 'daemon_enabled';

  /// 是否启用守护进程模式（默认开，仅桌面端生效）。
  static Future<bool> enabled() async {
    if (!Platform.isWindows) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_kEnabled) ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 守护进程是否在跑（TCP 探测配置端口）。
  static Future<bool> ping() async {
    try {
      final s = await Socket.connect('127.0.0.1', _configPort,
          timeout: const Duration(milliseconds: 800));
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 确保守护进程在跑；不在则从主程序同目录拉起。返回是否就绪。
  static Future<bool> ensureRunning() async {
    if (await ping()) return true;
    try {
      final exe = Platform.resolvedExecutable;
      final dir = File(exe).parent.path;
      final daemon = File('$dir\\weimi_daemon.exe');
      if (!daemon.existsSync()) return false;
      await Process.start(
        daemon.path,
        const [],
        mode: ProcessStartMode.detached,
      );
      // 等它起来（窗口+托盘初始化）
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (await ping()) return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 推配置给守护进程。uiActive=true 表示 UI 在跑（守护进程让出端口）；
  /// quit=true 要求守护进程退出。
  static Future<bool> pushConfig({
    required bool uiActive,
    bool quit = false,
  }) async {
    try {
      if (quit) {
        return _sendLine('{"cmd":"quit"}');
      }
      final lan = LanTransferService.instance;
      final docs = await getApplicationDocumentsDirectory();
      final receiveDir = await lan.effectiveReceiveDir();
      final cfg = <String, dynamic>{
        'cmd': 'apply',
        'device_id': lan.identityId,
        'device_name': lan.selfName,
        'discover_enabled': lan.discoverEnabled,
        'web_share_enabled': lan.webShareEnabled,
        'receive_dir': receiveDir,
        'docs_dir': docs.path,
        'exe_path': Platform.resolvedExecutable,
        'ui_active': uiActive,
      };
      return _sendLine(jsonEncode(cfg));
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _sendLine(String line) async {
    try {
      final sock = await Socket.connect('127.0.0.1', _configPort,
          timeout: const Duration(milliseconds: 1500));
      sock.add('$line\n'.codeUnits);
      await sock.flush();
      sock.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }
}
