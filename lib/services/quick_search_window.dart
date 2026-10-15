import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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

  /// 浮窗两态尺寸：刚呼出 = 搜索框 + 快捷方式区（常驻条），
  /// 输入内容后展开成完整结果窗（快捷条仍在）。
  static const Size popupCollapsedSize = Size(680, 140);
  static const Size popupExpandedSize = Size(680, 520);

  /// 浮窗 → 主界面要带过去的搜索词（「打开主界面」时由浮窗写入，
  /// 主界面 WeiMiVaultScreenState.initState 消费）。
  String? pendingMainQuery;
  String? takePendingQuery() {
    final q = pendingMainQuery;
    pendingMainQuery = null;
    return q;
  }

  /// 守护进程浮窗会话：UI 由守护进程在双击 Ctrl 时冷启拉起（--page=popup）。
  /// 浮窗收起（Esc/失焦/双击 Ctrl）后 UI 没必要继续占内存，
  /// 通过 [onPopupDismissed] 回调交接回守护进程并退出。
  static bool daemonPopupSession = false;
  static Future<void> Function()? onPopupDismissed;

  /// 置为 true 时浮窗失焦不自动收起（打开系统文件选择器等原生子对话框期间，
  /// 否则选择器一抢焦点浮窗连带上层的添加对话框一起被收掉）。
  static bool suppressBlurHide = false;

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

  /// 呼出浮窗：先在隐藏态完成「切内容 + 改尺寸」（resize 会清空缓冲，
  /// 必须发生在 show 之前），等浮窗渲染出一帧后再上屏——不闪空白。
  Future<void> showPopup() async {
    _popupExpanded = true;
    try {
      if (_savedSize == null) {
        _savedSize = await windowManager.getSize();
        _savedPosition = await windowManager.getPosition();
      }
      // 不置顶：与普通窗口一致（前台时在上，弹系统文件对话框等不被挡）。
      await windowManager.setSize(popupExpandedSize);
      await windowManager.center();
    } catch (e) {
      debugPrint('popup resize failed: $e');
    }
    popupMode.value = true;
    // 等浮窗内容先渲染出一帧再 show（超时兜底：引擎不产帧也不能卡死）。
    await SchedulerBinding.instance.endOfFrame
        .timeout(const Duration(milliseconds: 500), onTimeout: () {});
    try {
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
  /// false 时仅隐藏窗口（失焦/Esc）。守护进程浮窗会话下隐藏即交接退出。
  Future<void> hidePopup({bool openMain = false}) async {
    if (!isPopup) {
      if (openMain) await _restoreNormal();
      return;
    }
    popupMode.value = false;
    if (openMain) {
      daemonPopupSession = false; // 留在主界面，会话结束
      await _restoreNormal();
      return;
    }
    try {
      await windowManager.hide();
    } catch (_) {}
    final session = daemonPopupSession;
    daemonPopupSession = false;
    if (session) {
      final cb = onPopupDismissed;
      if (cb != null) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        try {
          await cb();
        } catch (_) {}
      }
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
    if (suppressBlurHide) return;
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
