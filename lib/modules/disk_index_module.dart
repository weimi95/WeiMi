import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';

import '../framework/module_registry.dart';
import '../framework/setting_store.dart';
import '../services/disk_index_service.dart';
import '../screens/exclude_settings_screen.dart';
import '../screens/index_roots_screen.dart';

/// 全盘搜索模块：扫描范围（移动设备）/ 排除文件夹。
class DiskIndexModule extends FeatureModule {
  DiskIndexModule();

  @override
  String get id => 'disk_index';

  @override
  String get name => '全盘搜索';

  @override
  IconData get icon => Icons.travel_explore;

  @override
  int get order => 20;

  @override
  List<SettingDef> get settings => [
        SettingDef(
          key: 'index_include_removable',
          title: '扫描索引移动设备',
          icon: Icons.usb,
          subtitle: 'U盘、移动硬盘等可移动磁盘纳入全盘索引（改动后自动重建索引）',
          type: SettingType.boolean,
          defaultValue: false,
          visible: () => Platform.isWindows,
          onChanged: (ctx, v) =>
              unawaited(DiskIndexService.applyRemovableSetting(v as bool)),
        ),
        SettingDef(
          key: 'index_roots',
          title: '索引文件夹',
          type: SettingType.custom,
          visible: () =>
              Platform.isWindows || Platform.isMacOS || Platform.isLinux,
          customTile: (ctx) => const _RootsTile(),
        ),
        SettingDef(
          key: 'index_excludes',
          title: '排除文件夹',
          type: SettingType.custom,
          customTile: (ctx) => const _ExcludeTile(),
        ),
      ];

  @override
  List<FileActionDef> get fileActions => const [];
}

/// 索引文件夹：跳二级设置页（索引根白名单，支持局域网共享）。
class _RootsTile extends StatelessWidget {
  const _RootsTile();

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.folder_special_outlined),
      title: const Text('索引文件夹', style: TextStyle(fontSize: 14)),
      subtitle: const Text('指定只扫描和索引哪些磁盘 / 文件夹，支持局域网共享',
          style: TextStyle(fontSize: 12)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
              builder: (context) => const IndexRootsScreen()),
        );
      },
    );
  }
}

/// 排除文件夹：跳二级设置页。
class _ExcludeTile extends StatelessWidget {
  const _ExcludeTile();

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.folder_off_outlined),
      title: const Text('排除文件夹', style: TextStyle(fontSize: 14)),
      subtitle: const Text('这些文件夹不扫描不索引，可加快搜索、省内存',
          style: TextStyle(fontSize: 12)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
              builder: (context) => const ExcludeSettingsScreen()),
        );
      },
    );
  }
}
