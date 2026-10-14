import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../framework/module_registry.dart';
import '../framework/setting_store.dart';
import '../services/autostart_service.dart';
import '../services/tray_service.dart';

/// 通用模块：清理缓存（全平台）+ 桌面端子组（开机自启 / 关闭按钮行为）。
class GeneralModule extends FeatureModule {
  GeneralModule();

  @override
  String get id => 'general';

  @override
  String get name => '通用';

  @override
  IconData get icon => Icons.settings_outlined;

  @override
  int get order => 30;

  bool get _isDesktop => !Platform.isAndroid && !Platform.isIOS;

  @override
  List<SettingDef> get settings => [
        SettingDef(
          key: 'general_clear_cache',
          title: '清理缓存',
          type: SettingType.custom,
          customTile: (ctx) => const _ClearCacheTile(),
        ),
        // 搜索历史条数：主界面搜索框与 PC 快捷浮窗共用（key 未变，prefs 兼容）
        SettingDef(
          key: 'qs_history_limit',
          title: '保留搜索历史条数',
          icon: Icons.history_outlined,
          group: '搜索',
          subtitle: '搜索框聚焦无输入时展示历史，0 表示不记录历史',
          type: SettingType.integer,
          defaultValue: 10,
          min: 0,
          max: 50,
          divisions: 50,
        ),
        if (_isDesktop)
          SettingDef(
            key: 'autostart_enabled',
            title: '开机自动启动微密文件',
            group: '桌面端',
            type: SettingType.custom,
            customTile: (ctx) => const _AutostartTile(),
          ),
        if (_isDesktop && Platform.isWindows)
          SettingDef(
            key: 'daemon_enabled',
            title: '后台省内存模式（守护进程）',
            icon: Icons.memory_outlined,
            group: '桌面端',
            subtitle: '关窗后主程序退出，托盘与飞传交给轻量守护进程（约 10MB）；重启应用后生效',
            type: SettingType.boolean,
            defaultValue: true,
            visible: () => _isDesktop && Platform.isWindows,
          ),
        SettingDef(
          key: 'tray_close_action',
          title: '点右上角关闭按钮时',
          icon: Icons.close_fullscreen_outlined,
          group: '桌面端',
          type: SettingType.choice,
          defaultValue: 'prompt',
          options: const ['prompt', 'minimize', 'quit'],
          optionLabels: const {
            'prompt': '弹窗询问（默认）',
            'minimize': '直接收进托盘',
            'quit': '直接退出程序',
          },
          visible: () => _isDesktop,
          onChanged: (ctx, v) => TrayService.instance.setCloseAction(v as String),
        ),
      ];

  @override
  List<FileActionDef> get fileActions => const [];
}

/// 清理缓存（临时目录 + file_picker 缓存）。
class _ClearCacheTile extends StatelessWidget {
  const _ClearCacheTile();

  Future<void> _clear(BuildContext context) async {
    int cleared = 0;
    try {
      final tmp = await getTemporaryDirectory();
      cleared = await _dirSize(tmp);
      if (await tmp.exists()) {
        await for (final e in tmp.list()) {
          try {
            await e.delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {}
    if (Platform.isAndroid) {
      try {
        await FilePicker.platform.clearTemporaryFiles();
      } catch (_) {}
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('已清理 ${_fmtSize(cleared)} 缓存'),
      backgroundColor: Colors.green,
    ));
  }

  Future<int> _dirSize(Directory dir) async {
    int total = 0;
    try {
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File) {
          try {
            total += await e.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.cleaning_services_outlined),
      title: const Text('清理缓存', style: TextStyle(fontSize: 14)),
      subtitle: const Text('预览缩略图、分享中转等临时文件',
          style: TextStyle(fontSize: 12)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _clear(context),
    );
  }
}

/// 开机自启：初始值是异步查询（AutostartService.isEnabled），自绘整块。
class _AutostartTile extends StatefulWidget {
  const _AutostartTile();

  @override
  State<_AutostartTile> createState() => _AutostartTileState();
}

class _AutostartTileState extends State<_AutostartTile> {
  bool _enabled = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final v = await AutostartService.isEnabled(valueName: 'WeiMiFile');
    if (!mounted) return;
    setState(() {
      _enabled = v;
      _loaded = true;
    });
  }

  Future<void> _toggle(bool v) async {
    final ok = await AutostartService.setEnabled(v,
        exePath: Platform.resolvedExecutable, valueName: 'WeiMiFile');
    if (!mounted) return;
    setState(() => _enabled = ok ? v : _enabled);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? (v ? '已开启开机自动启动微密文件' : '已关闭开机自动启动微密文件')
          : '设置失败，请检查系统权限'),
      backgroundColor: ok ? Colors.green : Colors.red,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: const Icon(Icons.power_settings_new),
      title: const Text('开机自动启动微密文件', style: TextStyle(fontSize: 14)),
      subtitle: const Text('登录系统后自动运行微密文件并常驻托盘，可随时从托盘退出',
          style: TextStyle(fontSize: 12)),
      value: _enabled,
      onChanged: _loaded ? _toggle : null,
    );
  }
}
