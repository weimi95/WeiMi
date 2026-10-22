import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'lan_transfer_service.dart';
import 'transfer_history_service.dart';
import '../framework/setting_store.dart';

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
  static const String _kHistOffset = 'daemon_hist_offset';

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
        // 未信任请求策略同步给守护进程（confirm=等待确认 / reject=直接拒绝）
        'untrusted_confirm':
            SettingStore.get<String>('lan_untrusted_mode', 'confirm') !=
                'reject',
        'untrusted_confirm_secs': () {
          final v = SettingStore.get<int>('lan_untrusted_timeout', 30);
          return v < 5 ? 5 : v;
        }(),
        // 接收后自动打开文件夹（托盘模式收文件由守护进程执行开目录）
        'open_recv_dir': SettingStore.get<bool>('lan_open_recv_folder', false),
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
      // 必须显式 UTF-8 编码：codeUnits 是 UTF-16 码元，Socket.add 逐字节截断，
      // 中文路径（receive_dir 等）会被守护进程 lossy 解码成 U+FFFD 乱码目录
      sock.add(utf8.encode('$line\n'));
      await sock.flush();
      sock.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 写一行并等守护进程回一行 JSON（confirm/get_pending 用）。
  static Future<Map<String, dynamic>?> _sendRecv(String line) async {
    Socket? sock;
    try {
      sock = await Socket.connect('127.0.0.1', _configPort,
          timeout: const Duration(milliseconds: 1500));
      sock.add('$line\n'.codeUnits);
      await sock.flush();
      final txt = await utf8.decoder
          .bind(sock)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 5));
      return json.decode(txt) as Map<String, dynamic>;
    } catch (_) {
      return null;
    } finally {
      sock?.destroy();
    }
  }

  /// 取走守护进程挂着的未信任请求（取走即弹出确认框，由 UI 决定）。
  static Future<List<Map<String, dynamic>>> fetchPending() async {
    try {
      final res = await _sendRecv('{"cmd":"get_pending"}');
      if (res == null) return const [];
      final list = res['pending'];
      if (list is! List) return const [];
      return list.whereType<Map>().map((e) {
        return e.map((k, v) => MapEntry(k as String, v));
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  /// 回传确认结果。返回 false = 该请求已被守护进程超时清理。
  static Future<bool> sendConfirm(String token, bool accept) async {
    final res = await _sendRecv(
        jsonEncode({'cmd': 'confirm', 'token': token, 'accept': accept}));
    return res != null && res['found'] == true;
  }

  /// 把守护进程期间收到的文件/文本记录（daemon_transfers.jsonl）合并进
  /// UI 传输历史。按字节偏移增量读取（prefs 存已读偏移），不会重复入账。
  static Future<void> mergeDaemonHistory() async {
    try {
      if (!Platform.isWindows) return;
      final docs = await getApplicationDocumentsDirectory();
      final f = File(
          '${docs.path}${Platform.pathSeparator}daemon_transfers.jsonl');
      if (!f.existsSync()) return;
      final prefs = await SharedPreferences.getInstance();
      var offset = prefs.getInt(_kHistOffset) ?? 0;
      final size = f.lengthSync();
      if (size < offset) offset = 0; // 文件被清空过，从头读
      if (size == offset) return;
      final raf = await f.open();
      try {
        await raf.setPosition(offset);
        final bytes = await raf.read(size - offset);
        final text = utf8.decode(bytes, allowMalformed: true);
        var lines = text.split('\n');
        var consumed = bytes.length;
        if (!text.endsWith('\n') && lines.isNotEmpty) {
          // 末尾半行（守护进程还在写）：留到下轮
          consumed -= utf8.encode(lines.last).length;
          lines = lines.sublist(0, lines.length - 1);
        }
        for (final raw in lines) {
          final line = raw.trim();
          if (line.isEmpty) continue;
          try {
            final j = json.decode(line) as Map<String, dynamic>;
            final ms = (j['time'] as num?)?.toInt() ?? 0;
            await TransferHistoryService.instance.add(TransferRecord(
              id: 'dm-$ms-${j['name'] ?? ''}',
              kind: (j['kind'] as String?) ?? 'file',
              direction: 'in',
              name: (j['name'] as String?) ?? '',
              path: j['path'] as String?,
              text: j['text'] as String?,
              size: (j['size'] as num?)?.toInt() ?? 0,
              peerName: (j['peerName'] as String?) ?? '',
              time: ms > 0
                  ? DateTime.fromMillisecondsSinceEpoch(ms)
                  : DateTime.now(),
              ok: (j['ok'] as bool?) ?? true,
            ));
          } catch (_) {}
        }
        if (consumed > 0) await prefs.setInt(_kHistOffset, offset + consumed);
      } finally {
        await raf.close();
      }
    } catch (_) {}
  }
}
