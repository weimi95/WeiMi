import 'package:flutter/material.dart';

import 'setting_store.dart';

/// 一个可被宿主调用的文件动作（加密/解密/飞传/打开所在路径…）。
///
/// 模块贡献的动作同时出现在：主界面右键菜单、快捷搜索浮窗动作面板——
/// 注册一次，两处复用，这就是模块化的第一个收益。
class FileActionDef {
  const FileActionDef({
    required this.id,
    required this.title,
    required this.icon,
    this.order = 100,
    this.contexts = const ['context_menu', 'quick_popup'],
    this.visible,
    this.onExecute,
  });

  /// 全局唯一 id（如 'encrypt'）。
  final String id;

  final String title;
  final IconData icon;

  /// 排序权重，小者靠前。
  final int order;

  /// 允许出现的场景：'context_menu'（主界面右键）/ 'quick_popup'（搜索浮窗）。
  final List<String> contexts;

  /// 是否对某个路径显示（如解密只对 .wemi）。null = 始终显示。
  final bool Function(String path)? visible;

  /// 执行回调。context 用于弹对话框/SnackBar。
  final void Function(BuildContext context, String path)? onExecute;

  bool visibleFor(String path) => visible?.call(path) ?? true;

  bool inContext(String contextId) => contexts.contains(contextId);
}

/// 一个功能模块。每个模块向框架注册：
/// - [settings]：自己的设置项（渲染进设置中心对应分类）
/// - [fileActions]：自己贡献的文件动作（右键菜单/浮窗动作面板取用）
///
/// 新增功能 = 新建模块文件 + 在 [ModuleRegistry.bootstrap] 注册，
/// 不改动任何主线代码。
///
/// 注意：字段由子类以 getter override 提供（见 LanTransferModule 等），
/// 构造参数仅作默认值/测试直传用，故均为可选。
class FeatureModule {
  const FeatureModule({
    this.id = '',
    this.name = '',
    this.icon = Icons.extension,
    this.order = 100,
    this.desktopOnly = false,
    this.settings = const [],
    this.fileActions = const [],
  });

  /// 唯一 id（如 'quick_search'）。
  final String id;

  /// 设置中心里的分类名（如 '快捷搜索'）。
  final String name;

  final IconData icon;

  /// 分类排序权重，小者靠前。
  final int order;

  /// 仅桌面端注册（如快捷浮窗依赖 Windows 热键）。
  final bool desktopOnly;

  final List<SettingDef> settings;
  final List<FileActionDef> fileActions;

  /// 当前平台是否注册该模块。
  bool get supported {
    if (!desktopOnly) return true;
    // desktopOnly 模块在桌面端注册；安卓/iOS 不注册
    return _isDesktop;
  }

  static bool _isDesktop = false;

  /// main.dart 启动时设置一次（桌面 = Win/macOS/Linux）。
  static void setPlatform(bool isDesktop) {
    _isDesktop = isDesktop;
  }
}

/// 模块注册表（进程内单例）。
class ModuleRegistry {
  ModuleRegistry._();

  static final List<FeatureModule> _modules = [];
  static bool _bootstrapped = false;

  /// 注册模块（重复 id 后者覆盖前者）。
  static void register(FeatureModule m) {
    _modules.removeWhere((x) => x.id == m.id);
    _modules.add(m);
    _modules.sort((a, b) => a.order.compareTo(b.order));
  }

  /// 已注册且当前平台支持的模块（按 order）。
  static List<FeatureModule> get modules =>
      List.unmodifiable(_modules.where((m) => m.supported));

  static FeatureModule? module(String id) {
    for (final m in _modules) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// 取某个场景下对某路径可见的动作（按 order 排序）。
  static List<FileActionDef> actionsFor(String path, {required String contextId}) {
    final out = <FileActionDef>[];
    for (final m in modules) {
      for (final a in m.fileActions) {
        if (!a.inContext(contextId)) continue;
        if (!a.visibleFor(path)) continue;
        out.add(a);
      }
    }
    out.sort((a, b) => a.order.compareTo(b.order));
    return out;
  }

  /// 所有模块贡献的设置项（按模块 order 摊平，供设置页渲染）。
  static List<FeatureModule> get settingModules => modules;

  static bool get bootstrapped => _bootstrapped;

  /// 标记已引导（由 bootstrap 函数在注册完内置模块后调用）。
  static void markBootstrapped() {
    _bootstrapped = true;
  }
}
