import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../framework/setting_store.dart';

/// 主窗口的三种状态：
/// - normal：正常主界面（由托盘打开）
/// - popup：快捷搜索浮窗（双击 Ctrl 呼出）
/// - （hidden 即窗口 hide，收托盘/浮窗收起时进入）
class WindowModeService {
  WindowModeService._();
  static final WindowModeService instance = WindowModeService._();

  final ValueNotifier<bool> popupMode = ValueNotifier<bool>(false);

  /// 浮窗两态尺寸：刚呼出只有搜索框（窄条），输入内容后展开成完整结果窗。
  static const Size popupCollapsedSize = Size(680, 64);
  static const Size popupExpandedSize = Size(680, 480);

  /// 浮窗 → 主界面要带过去的搜索词（「打开主界面」时由浮窗写入，
  /// 主界面 WeiMiVaultScreenState.initState 消费）。
  String? pendingMainQuery;
  String? takePendingQuery() {
    final q = pendingMainQuery;
    pendingMainQuery = null;
    return q;
  }

  Size? _savedSize;
  Offset? _savedPosition;
  bool _switching = false;
  bool _popupExpanded = false;

  bool get isPopup => popupMode.value;

  /// 双击 Ctrl → 切换浮窗显隐。
  Future<void> togglePopup() async {
    if (_switching) return;
    _switching = true;
    try {
      if (isPopup) {
        await hidePopup();
      } else {
        await showPopup();
      }
    } finally {
      _switching = false;
    }
  }

  /// 呼出浮窗：先切内容（窗口以浮窗形态显示，不闪主界面），
  /// 再保存主窗口几何 → 窄条居中置顶（只显示搜索框，输入后展开）。
  Future<void> showPopup() async {
    popupMode.value = true;
    _popupExpanded = false;
    try {
      if (_savedSize == null) {
        _savedSize = await windowManager.getSize();
        _savedPosition = await windowManager.getPosition();
      }
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setSize(popupCollapsedSize);
      await windowManager.center();
      await windowManager.show();
      await windowManager.focus();
    } catch (e) {
      debugPrint('popup show failed: $e');
    }
  }

  /// 浮窗在窄条/完整两态之间切换（由浮窗 UI 在输入内容/清空时调用）。
  Future<void> setPopupExpanded(bool expanded) async {
    if (_popupExpanded == expanded) return;
    _popupExpanded = expanded;
    try {
      await windowManager.setSize(
          expanded ? popupExpandedSize : popupCollapsedSize);
      if (expanded) {
        await windowManager.center();
      }
    } catch (e) {
      debugPrint('popup resize failed: $e');
    }
  }

  /// 收起浮窗。
  /// [openMain] = true 时恢复并显示主界面（浮窗内「打开主界面」入口）；
  /// false 时仅隐藏窗口（失焦/Esc）。
  Future<void> hidePopup({bool openMain = false}) async {
    if (!isPopup) {
      if (openMain) await _restoreNormal();
      return;
    }
    popupMode.value = false;
    if (openMain) {
      await _restoreNormal();
    } else {
      try {
        await windowManager.hide();
      } catch (_) {}
    }
  }

  /// 恢复正常主窗口：几何还原 + 取消置顶。
  Future<void> _restoreNormal() async {
    try {
      await windowManager.setAlwaysOnTop(false);
      if (_savedSize != null) {
        await windowManager.setSize(_savedSize!);
      }
      if (_savedPosition != null) {
        await windowManager.setPosition(_savedPosition!);
      }
      await windowManager.show();
      await windowManager.focus();
    } catch (e) {
      debugPrint('restore normal failed: $e');
    }
  }

  /// 失焦处理：浮窗态且设置允许时自动收起（由 _WindowListener 调用）。
  void onWindowBlur() {
    if (!isPopup) return;
    if (SettingStore.get<bool>('qs_hide_on_blur', true)) {
      unawaited(hidePopup());
    }
  }

  /// 「去主界面展示全部结果」：带上当前搜索词，恢复主界面。
  Future<void> openMainWithQuery(String? query) async {
    final q = query?.trim();
    if (q != null && q.isNotEmpty) pendingMainQuery = q;
    await hidePopup(openMain: true);
  }
}
