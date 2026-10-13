import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 设置项控件类型。
/// [custom] 为逃生舱：复杂交互（选目录、进二级页面、热键录制）由模块
/// 通过 [SettingDef.customTile] 自绘整块 ListTile，其余类型由设置页渲染。
enum SettingType {
  boolean,
  integer,
  decimal,
  text,
  choice,
  custom,
}

/// 一条设置声明。模块通过 [FeatureModule.settings] 贡献给设置中心，
/// 设置页按分类渲染，读写统一走 [SettingStore]。
class SettingDef {
  const SettingDef({
    required this.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.type = SettingType.boolean,
    this.defaultValue,
    this.options,
    this.optionLabels,
    this.group,
    this.min,
    this.max,
    this.divisions,
    this.onChanged,
    this.customTile,
    this.visible,
  });

  /// SharedPreferences 键（全局唯一，建议加模块前缀，如 'qs_enabled'）。
  final String key;

  /// 设置项标题。
  final String title;

  /// 副标题/说明（可空）。
  final String? subtitle;

  /// 设置项图标（可空）。
  final IconData? icon;

  final SettingType type;

  /// 默认值；读取时类型不符也回落到它。
  final dynamic defaultValue;

  /// [SettingType.choice] 的选项列表（顺序即展示顺序）。
  final List<String>? options;

  /// choice 的「值 → 展示名」映射（可空；为空时值与展示同名）。
  /// 用于兼容历史英文值（如 'prompt' 展示为「弹窗询问」）。
  final Map<String, String>? optionLabels;

  /// 分类内二级分组标题（可空，同 group 的设置项渲染在同一小节）。
  final String? group;

  /// [SettingType.decimal]/[SettingType.integer] 的滑块范围。
  final double? min;
  final double? max;
  final int? divisions;

  /// 值变更回调（写盘成功后触发；context 用于弹 SnackBar 等即时反馈）。
  final void Function(BuildContext context, dynamic value)? onChanged;

  /// [SettingType.custom] 的自绘整块（含导航/选择逻辑）。
  final WidgetBuilder? customTile;

  /// 动态显隐（如仅桌面端可见的项）；默认始终可见。
  final bool Function()? visible;

  bool get isVisibleNow => visible?.call() ?? true;
}

/// 统一设置存取层：所有模块的偏好都走这里。
///
/// - 读写：[get]/[set]，落 SharedPreferences；
/// - 订阅：[listen] 返回 ValueNotifier，set 时同键监听者全部刷新
///   （设置改了相关服务自动响应，无需各模块自己管 prefs）。
class SettingStore {
  SettingStore._();

  static SharedPreferences? _prefs;
  static bool _initializing = false;
  static final Map<String, ValueNotifier<dynamic>> _notifiers = {};

  /// main.dart runApp 前调用一次。
  static Future<void> init() async {
    if (_prefs != null || _initializing) return;
    _initializing = true;
    try {
      _prefs = await SharedPreferences.getInstance();
    } catch (_) {
      _prefs = null;
    } finally {
      _initializing = false;
    }
  }

  /// 同步读取（[init] 完成后可用；未就绪时回落默认值）。
  static T get<T>(String key, T defaultValue) {
    final prefs = _prefs;
    if (prefs == null) return defaultValue;
    try {
      final v = prefs.get(key);
      if (v is T) return v;
    } catch (_) {}
    return defaultValue;
  }

  /// 写入并广播。value 支持 bool/int/double/String，其它类型忽略。
  static Future<void> set(String key, dynamic value) async {
    final prefs = _prefs;
    if (prefs != null) {
      try {
        if (value is bool) {
          await prefs.setBool(key, value);
        } else if (value is int) {
          await prefs.setInt(key, value);
        } else if (value is double) {
          await prefs.setDouble(key, value);
        } else if (value is String) {
          await prefs.setString(key, value);
        } else {
          return;
        }
      } catch (_) {
        return;
      }
    }
    _notifiers[key]?.value = value;
  }

  /// 订阅某个键的变更（同键共享一个 notifier；无监听者时也保留最近值）。
  static ValueNotifier<T> listen<T>(String key, T defaultValue) {
    var n = _notifiers[key];
    if (n == null) {
      n = ValueNotifier<dynamic>(get(key, defaultValue));
      _notifiers[key] = n;
    }
    return n as ValueNotifier<T>;
  }

  /// 注销某个键的 notifier（模块卸载/测试用；正常流程用不到）。
  static void disposeListener(String key) {
    _notifiers.remove(key)?.dispose();
  }
}
