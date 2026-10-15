import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../framework/module_registry.dart';
import '../framework/setting_store.dart';
import '../services/vault_biometric.dart';
import '../services/vault_service.dart';

/// 微密保险箱模块：目录 / 锁定策略 / 改主密码 / 生物识别 / 密码库备份。
class VaultModule extends FeatureModule {
  VaultModule();

  @override
  String get id => 'vault';

  @override
  String get name => '保险箱';

  @override
  IconData get icon => Icons.lock_outline;

  @override
  int get order => 25;

  bool get _bioPlatform =>
      Platform.isAndroid || Platform.isMacOS;

  @override
  List<SettingDef> get settings => [
        SettingDef(
          key: 'vault_dir',
          title: '保险箱目录',
          icon: Icons.folder_special_outlined,
          type: SettingType.custom,
          customTile: (ctx) => const _VaultDirTile(),
        ),
        SettingDef(
          key: VaultService.showInDirsPrefKey,
          title: '在我的目录显示保险箱入口',
          icon: Icons.bookmarks_outlined,
          subtitle: '关闭后，文件页「我的目录」列表不再显示保险箱入口（右上角菜单仍可进入）',
          type: SettingType.boolean,
          defaultValue: true,
        ),
        SettingDef(
          key: VaultService.idleMinPrefKey,
          title: '闲置自动上锁（分钟）',
          icon: Icons.timer_outlined,
          subtitle: '无操作达到设定时间后自动上锁，0 表示不自动锁',
          type: SettingType.integer,
          defaultValue: 5,
          min: 0,
          max: 60,
          divisions: 60,
        ),
        SettingDef(
          key: VaultService.lockOnExitPrefKey,
          title: '切到后台立即上锁',
          icon: Icons.phonelink_lock_outlined,
          subtitle: '严格模式：最小化或切后台即上锁（重新进入需输主密码）',
          type: SettingType.boolean,
          defaultValue: false,
        ),
        if (_bioPlatform)
          SettingDef(
            key: VaultService.biometricPrefKey,
            title: '生物识别快捷解锁',
            icon: Icons.fingerprint,
            subtitle: '指纹/人脸验证通过后自动解锁（主密码密文安全保存）',
            type: SettingType.custom,
            customTile: (ctx) => const _BiometricTile(),
          ),
        SettingDef(
          key: 'vault_change_master',
          title: '修改主密码',
          icon: Icons.password_outlined,
          subtitle: '只重新加密密码库，箱内文件不受影响',
          type: SettingType.custom,
          customTile: (ctx) => const _ChangeMasterTile(),
        ),
        SettingDef(
          key: 'vault_backup',
          title: '备份密码库',
          icon: Icons.backup_outlined,
          subtitle: '导出 .weimi_keys 备份文件；密码库是唯一命门，建议定期备份',
          type: SettingType.custom,
          customTile: (ctx) => const _BackupTile(),
        ),
      ];

  @override
  List<FileActionDef> get fileActions => const [];
}

/// 保险箱目录
class _VaultDirTile extends StatefulWidget {
  const _VaultDirTile();

  @override
  State<_VaultDirTile> createState() => _VaultDirTileState();
}

class _VaultDirTileState extends State<_VaultDirTile> {
  String? _dir;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = await VaultService.instance.getVaultDir();
    if (!mounted) return;
    setState(() {
      _dir = d;
      _loaded = true;
    });
  }

  Future<void> _change() async {
    try {
      final res = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择新的保险箱目录',
      );
      if (res == null || res.isEmpty) return;
      // 若已解锁，换目录前先上锁（新目录的密码库需要重新解锁）
      if (VaultService.instance.isUnlocked) {
        await VaultService.instance.lock();
      }
      await VaultService.instance.setVaultDir(res);
      if (!mounted) return;
      setState(() => _dir = res);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('目录已更新，首次进入需设置或解锁保险箱')));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.folder_special_outlined),
      title: const Text('保险箱目录', style: TextStyle(fontSize: 14)),
      subtitle: Text(
        _loaded ? (_dir ?? '未设置') : '…',
        style: const TextStyle(fontSize: 12),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: _change,
    );
  }
}

/// 生物识别开关（Android / macOS）
class _BiometricTile extends StatefulWidget {
  const _BiometricTile();

  @override
  State<_BiometricTile> createState() => _BiometricTileState();
}

class _BiometricTileState extends State<_BiometricTile> {
  bool _enabled = false;
  bool _loaded = false;
  bool _canAuth = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _canAuth = await VaultBiometricService.canAuth();
    final v = await VaultBiometricService.isEnabled();
    if (!mounted) return;
    setState(() {
      _enabled = v;
      _loaded = true;
    });
  }

  Future<void> _toggle(bool v) async {
    if (v) {
      // 开启时先验证一次，确保可用
      final ok = await VaultBiometricService.canAuth();
      if (!ok) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('设备不支持或未录入生物识别'),
            backgroundColor: Colors.red));
        return;
      }
    }
    await VaultBiometricService.setEnabled(v);
    if (!mounted) return;
    setState(() => _enabled = v);
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: const Icon(Icons.fingerprint),
      title: const Text('生物识别快捷解锁', style: TextStyle(fontSize: 14)),
      subtitle: Text(
        _canAuth
            ? '指纹/人脸验证通过后自动解锁'
            : '设备不支持或未录入生物识别',
        style: const TextStyle(fontSize: 12),
      ),
      value: _enabled,
      onChanged: _loaded ? _toggle : null,
    );
  }
}

/// 修改主密码
class _ChangeMasterTile extends StatelessWidget {
  const _ChangeMasterTile();

  Future<void> _change(BuildContext context) async {
    final oldCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final new2Ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改主密码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: oldCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: '当前主密码', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: newCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: '新主密码（至少 8 位）',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: new2Ctrl,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: '确认新主密码', border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确定')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    if (newCtrl.text.length < 8 || newCtrl.text != new2Ctrl.text) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('新密码至少 8 位且两次输入一致'),
          backgroundColor: Colors.red));
      return;
    }
    try {
      await VaultService.instance
          .changeMasterPassword(oldCtrl.text, newCtrl.text);
      // 生物识别密文是旧主密码加密的，改密后必须清除重录
      await VaultBiometricService.removeMaster();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('主密码已修改'), backgroundColor: Colors.green));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.password_outlined),
      title: const Text('修改主密码', style: TextStyle(fontSize: 14)),
      subtitle: const Text('只重新加密密码库，箱内文件不受影响',
          style: TextStyle(fontSize: 12)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _change(context),
    );
  }
}

/// 备份密码库
class _BackupTile extends StatelessWidget {
  const _BackupTile();

  Future<void> _backup(BuildContext context) async {
    final dir = await VaultService.instance.getVaultDir();
    if (dir == null || !context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('保险箱未设置')));
      return;
    }
    try {
      final outDir = await FilePicker.platform
          .getDirectoryPath(dialogTitle: '选择备份保存位置');
      if (outDir == null) return;
      final src = File('$dir/.weimi_keys');
      if (!await src.exists()) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('密码库文件不存在')));
        return;
      }
      final ts = DateTime.now().millisecondsSinceEpoch;
      final dest =
          File('$outDir/weimi_keys_backup_$ts.keys');
      await src.copy(dest.path);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('已备份到 ${dest.path}'),
          backgroundColor: Colors.green));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.backup_outlined),
      title: const Text('备份密码库', style: TextStyle(fontSize: 14)),
      subtitle: const Text(
          '导出 .weimi_keys 加密备份；主密码无法找回，密码库丢失即无法开箱',
          style: TextStyle(fontSize: 12)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _backup(context),
    );
  }
}

/// prefs 快捷读（供别处展示默认值）
Future<int> vaultIdleMinutesPref() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getInt(VaultService.idleMinPrefKey) ?? 5;
}
