import 'dart:io';

import 'module_registry.dart';
import '../modules/language_module.dart';
import '../modules/lan_transfer_module.dart';
import '../modules/disk_index_module.dart';
import '../modules/general_module.dart';
import '../modules/quick_search_module.dart';

/// 注册全部内置模块。main.dart 启动时调用一次。
///
/// 新增功能的姿势：新建模块文件（实现 FeatureModule，贡献
/// settings/fileActions）→ 在这里加一行 register。主线代码零改动。
void bootstrapModules() {
  // 桌面 = Win/macOS/Linux；安卓/iOS 不注册 desktopOnly 模块
  FeatureModule.setPlatform(!Platform.isAndroid && !Platform.isIOS);

  ModuleRegistry.register(LanguageModule());
  ModuleRegistry.register(LanTransferModule());
  ModuleRegistry.register(DiskIndexModule());
  ModuleRegistry.register(GeneralModule());
  ModuleRegistry.register(QuickSearchModule());

  ModuleRegistry.markBootstrapped();
}
