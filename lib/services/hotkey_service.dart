import 'dart:ffi';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../framework/setting_store.dart';
import 'quick_search_window.dart';

/// 全局「双击 Ctrl」检测（仅 Windows）。
///
/// 方案选型：hotkey_manager 类插件底层是 RegisterHotKey，只支持组合键，
/// 无法表达「双击 Ctrl」。这里用 GetAsyncKeyState 轮询：
/// - 每 80ms 采样一次左右 Ctrl 的异步按键状态（全局有效，前台游戏也照采）
/// - 350ms 内两次独立「按下-释放-按下」判定为双击
/// - 零原生依赖（dart:ffi 直调 user32.dll），无键盘钩子的消息循环/回调坑
///
/// 误触防控：判定窗口 350ms（与 Lertaro 的 100-300ms 同量级）；
/// 设置项 qs_enabled 可整体关闭。
class HotkeyService {
  HotkeyService._();
  static final HotkeyService instance = HotkeyService._();

  static const int _vkLCtrl = 0xA2;
  static const int _vkRCtrl = 0xA3;
  static const int _windowMs = 350;

  /// 双击 Ctrl 触发（由 QuickSearchWindow 挂接）。
  VoidCallback? onDoubleCtrl;

  Timer? _timer;
  bool _wasDown = false;
  int? _lastPressAt;
  bool _running = false;

  final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
  late final int Function(int) _getAsyncKeyState = _user32
      .lookupFunction<Int32 Function(Int32), int Function(int)>(
          'GetAsyncKeyState');

  /// 启动轮询（仅 Windows 有效；重复调用幂等）。
  void start() {
    if (_running || !Platform.isWindows) return;
    _running = true;
    _timer ??= Timer.periodic(const Duration(milliseconds: 80), _poll);
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
    _wasDown = false;
    _lastPressAt = null;
  }

  bool get _enabled => SettingStore.get<bool>('qs_enabled', true);

  void _poll(Timer timer) {
    if (!_enabled || WindowModeService.instance.isPopup) {
      // 关闭时或浮窗已开着（避免 Ctrl 操作误触收起）时不判定
      _wasDown = false;
      _lastPressAt = null;
      return;
    }
    const highBit = 0x8000;
    final down = (_getAsyncKeyState(_vkLCtrl) & highBit) != 0 ||
        (_getAsyncKeyState(_vkRCtrl) & highBit) != 0;
    final now = DateTime.now().microsecondsSinceEpoch ~/ 1000;

    if (down) {
      if (!_wasDown) {
        // 按下沿
        if (_lastPressAt != null && now - _lastPressAt! <= _windowMs) {
          _lastPressAt = null;
          _wasDown = true;
          try {
            onDoubleCtrl?.call();
          } catch (e) {
            debugPrint('hotkey: double-ctrl handler error: $e');
          }
          return;
        }
        _lastPressAt = now;
      }
      _wasDown = true;
    } else {
      _wasDown = false;
      // 超时未完成双击，清除待判定状态
      if (_lastPressAt != null && now - _lastPressAt! > _windowMs) {
        _lastPressAt = null;
      }
    }
  }
}
