import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import '../screens/lan_transfer_screen.dart';

/// 系统分享接收（Android SEND / SEND_MULTIPLE）：
/// 任何 App 点「分享」→ 选「微密文件」→ 拉起飞传页直接发送。
class ShareReceiveService {
  ShareReceiveService._();
  static final ShareReceiveService instance = ShareReceiveService._();

  static const MethodChannel _channel =
      MethodChannel('com.weimi95.weimi/share');

  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  /// Dart 侧 onShare 回调是否已注册（native onNewIntent 早于 Dart 初始化时缓存）
  bool _handlerReady = false;
  Map<String, dynamic>? _pendingNativePush;

  Future<void> init() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onShare') {
        final payload = Map<String, dynamic>.from(call.arguments as Map);
        _handlePayload(payload);
      }
      return null;
    });
    _handlerReady = true;
    // 冷启动：主动拉一次
    try {
      final raw = await _channel.invokeMethod('getInitialShare');
      if (raw != null) {
        final payload = Map<String, dynamic>.from(raw as Map);
        _handlePayload(payload);
      }
    } catch (e) {
      debugPrint('getInitialShare failed: $e');
    }
    // native 早于 handler 注册推过来的缓存
    if (_pendingNativePush != null) {
      final p = _pendingNativePush!;
      _pendingNativePush = null;
      _handlePayload(p);
    }
  }

  void _handlePayload(Map<String, dynamic> payload) {
    if (!_handlerReady) {
      _pendingNativePush = payload;
      return;
    }
    final text = payload['text'] as String?;
    final paths = (payload['paths'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .where((e) => e.isNotEmpty)
        .toList();
    if ((text == null || text.isEmpty) && paths.isEmpty) return;
    // 等 Navigator 就绪后跳飞传页
    Future.delayed(const Duration(milliseconds: 600), () {
      final ctx = navigatorKey.currentContext;
      if (ctx == null) return;
      Navigator.of(ctx).push(MaterialPageRoute(
        builder: (_) => LanTransferScreen(
          initialText: (text == null || text.isEmpty) ? null : text,
          initialFiles: paths,
        ),
      ));
    });
  }
}

/// Android 前台服务保活（微密飞传后台持续可被发现/接收）
class TransferForegroundService {
  TransferForegroundService._();
  static const MethodChannel _channel =
      MethodChannel('com.weimi95.weimi/transfer');

  static Future<void> start() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('startForeground');
    } catch (e) {
      debugPrint('startForeground failed: $e');
    }
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('stopForeground');
    } catch (e) {
      debugPrint('stopForeground failed: $e');
    }
  }
}
