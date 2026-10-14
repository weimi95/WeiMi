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
/// - 每 30ms 采样一次左右 Ctrl 的异步按键状态（全局有效，前台游戏也照采）
/// - 350ms 内两次独立「按下-释放-按下」判定为双击，且两次之间释放
///   间隔 ≥60ms（过滤长按中途抖动/键点弹跳被误判成第二击）
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

  /// 两次按下之间必须的真实释放间隔。小于此值视为长按中途的按键抖动
  /// （一次毛刺 = 第二个按下沿，落进窗口就会误触发）。
  static const int _minReleaseGapMs = 60;

  /// 双击 Ctrl 触发（由 QuickSearchWindow 挂接）。
  VoidCallback? onDoubleCtrl;

  Timer? _timer;
  bool _wasDown = false;
  int? _lastPressAt; // 第一次按下的时刻（候选）
  int? _releasedAt; // 候选按下后的释放时刻
  bool _running = false;

  final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
  late final int Function(int) _getAsyncKeyState = _user32
      .lookupFunction<Int32 Function(Int32), int Function(int)>(
          'GetAsyncKeyState');

  /// 启动轮询（仅 Windows 有效；重复调用幂等）。
  void start() {
    if (_running || !Platform.isWindows) return;
    _running = true;
    _timer ??= Timer.periodic(const Duration(milliseconds: 30), _poll);
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
    _wasDown = false;
    _lastPressAt = null;
    _releasedAt = null;
  }

  bool get _enabled => SettingStore.get<bool>('qs_enabled', true);

  void _poll(Timer timer) {
    if (!_enabled || WindowModeService.instance.isPopup) {
      // 关闭时或浮窗已开着（避免 Ctrl 操作误触收起）时不判定
      _wasDown = false;
      _lastPressAt = null;
      _releasedAt = null;
      return;
    }
    const highBit = 0x8000;
    final down = (_getAsyncKeyState(_vkLCtrl) & highBit) != 0 ||
        (_getAsyncKeyState(_vkRCtrl) & highBit) != 0;
    final now = DateTime.now().microsecondsSinceEpoch ~/ 1000;

    if (down) {
      if (!_wasDown) {
        // 按下沿
        final lp = _lastPressAt;
        final rel = _releasedAt;
        if (lp != null && rel != null && now - lp <= _windowMs) {
          if (now - rel >= _minReleaseGapMs) {
            // 真实双击：第二次按下前有足够长的释放间隔
            _lastPressAt = null;
            _releasedAt = null;
            _wasDown = true;
            try {
              onDoubleCtrl?.call();
            } catch (e) {
              debugPrint('hotkey: double-ctrl handler error: $e');
            }
            return;
          }
          // 释放间隔太短：按点弹跳，视作同一次按压延续，保留候选
        } else {
          _lastPressAt = now;
          _releasedAt = null;
        }
      }
      _wasDown = true;
    } else {
      if (_lastPressAt != null && _releasedAt == null) {
        _releasedAt = now; // 候选按压的释放沿
      }
      _wasDown = false;
      // 超时未完成双击，清除待判定状态
      if (_lastPressAt != null && now - _lastPressAt! > _windowMs) {
        _lastPressAt = null;
        _releasedAt = null;
      }
    }
  }
}
