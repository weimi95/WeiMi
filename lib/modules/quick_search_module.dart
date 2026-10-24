import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../framework/module_registry.dart';
import '../framework/setting_store.dart';
import '../services/encryption_service.dart';
import '../services/file_operations_service.dart';
import '../services/lan_transfer_service.dart';
import '../services/system_open_service.dart';
import '../widgets/saved_filters_dialog.dart';

/// 快捷搜索浮窗模块（PC 端）。
///
/// 第一个完整模块：贡献自己的设置组（设置中心「快捷搜索」分类）
/// + 一批文件动作（浮窗动作面板取用；contexts 限定 quick_popup，
/// 与主界面右键菜单互不干扰）。
class QuickSearchModule extends FeatureModule {
  QuickSearchModule();

  @override
  String get id => 'quick_search';

  @override
  String get name => '快捷搜索';

  @override
  IconData get icon => Icons.keyboard_command_key;

  @override
  int get order => 15;

  @override
  bool get desktopOnly => true;

  @override
  List<SettingDef> get settings => [
        SettingDef(
          key: 'qs_enabled',
          title: '启用快捷搜索浮窗',
          icon: Icons.toggle_on_outlined,
          subtitle: '开启后，任意界面双击 Ctrl 呼出全盘搜索浮窗',
          type: SettingType.boolean,
          defaultValue: true,
          onChanged: (ctx, v) => QuickSearchActions.onEnabledChanged?.call(v as bool),
        ),
        SettingDef(
          key: 'qs_hide_on_blur',
          title: '失焦自动收起',
          icon: Icons.visibility_off_outlined,
          subtitle: '浮窗失去焦点时自动隐藏（Esc 随时可关）',
          type: SettingType.boolean,
          defaultValue: true,
        ),
        SettingDef(
          key: 'qs_result_limit',
          title: '搜索结果数量',
          icon: Icons.format_list_numbered,
          subtitle: '浮窗最多显示的匹配文件数',
          group: '浮窗行为',
          type: SettingType.integer,
          defaultValue: 50,
          min: 10,
          max: 200,
          divisions: 19,
        ),
        SettingDef(
          key: 'qs_show_actions',
          title: '显示文件动作按钮',
          icon: Icons.flash_on_outlined,
          subtitle: '浮窗结果行展示加密/解密/发送到手机等动作（关闭后仅能打开文件）',
          group: '浮窗行为',
          type: SettingType.boolean,
          defaultValue: true,
        ),
        SettingDef(
          key: 'search_pinyin',
          title: '拼音搜索',
          icon: Icons.abc_outlined,
          subtitle: '输入 douyin 或 dy 命中「抖音」等中文文件名（v1.2.6）',
          group: '搜索语法',
          type: SettingType.boolean,
          defaultValue: true,
        ),
        SettingDef(
          key: 'search_stat_filters',
          title: '大小/日期筛选语法',
          icon: Icons.filter_alt_outlined,
          subtitle:
              '搜索框支持 size:>100mb、dm:today、dc:2026-01-01 等筛选（默认关，需读文件元数据稍慢）',
          group: '搜索语法',
          type: SettingType.boolean,
          defaultValue: false,
        ),
        SettingDef(
          key: 'qs_search_delay',
          title: '输入搜索延迟',
          icon: Icons.speed_outlined,
          subtitle: '停止输入多久后开始搜索（主界面搜索框与浮窗共用）',
          group: '搜索语法',
          type: SettingType.choice,
          defaultValue: '120',
          options: const ['80', '120', '200', '400'],
          optionLabels: const {
            '80': '0.08 秒（最灵敏）',
            '120': '0.12 秒（默认）',
            '200': '0.2 秒',
            '400': '0.4 秒（最省电）',
          },
        ),
        SettingDef(
          key: 'qs_saved_filters',
          title: '自定义筛选器',
          icon: Icons.filter_alt_outlined,
          subtitle: '把常用「搜索词 + 开关」存为命名筛选器一键复用；支持导入/导出',
          group: '搜索语法',
          type: SettingType.custom,
          customTile: (ctx) => const _SavedFiltersTile(),
        ),
      ];

  @override
  List<FileActionDef> get fileActions => [
        FileActionDef(
          id: 'qs_open',
          title: '打开',
          icon: Icons.open_in_new_outlined,
          order: 10,
          onExecute: (ctx, path) => _openFile(ctx, path),
        ),
        FileActionDef(
          id: 'qs_encrypt',
          title: '加密',
          icon: Icons.lock_outline,
          order: 20,
          visible: (path) => !path.toLowerCase().endsWith('.wemi'),
          onExecute: (ctx, path) => _encryptFile(ctx, path),
        ),
        FileActionDef(
          id: 'qs_decrypt',
          title: '解密',
          icon: Icons.lock_open_outlined,
          order: 30,
          visible: (path) => path.toLowerCase().endsWith('.wemi'),
          onExecute: (ctx, path) => _decryptFile(ctx, path),
        ),
        FileActionDef(
          id: 'qs_send_phone',
          title: '发送到手机',
          icon: Icons.send_to_mobile_outlined,
          order: 40,
          onExecute: (ctx, path) => _sendToPhone(ctx, path),
        ),
        FileActionDef(
          id: 'qs_open_folder',
          title: '打开所在路径',
          icon: Icons.folder_open_outlined,
          order: 50,
          onExecute: (ctx, path) => _revealInFileManager(ctx, path),
        ),
        FileActionDef(
          id: 'qs_copy_path',
          title: '复制完整路径',
          icon: Icons.content_copy,
          order: 60,
          onExecute: (ctx, path) => _copyPath(ctx, path),
        ),
      ];
}

/// 模块级动作实现（供 FileActionDef 回调引用）。
class QuickSearchActions {
  QuickSearchActions._();

  /// 启用开关变化时的钩子（hotkey_service 监听 qs_enabled）。
  static void Function(bool enabled)? onEnabledChanged;
}

/// 设置中心「自定义筛选器」入口：打开管理对话框（新建/编辑/删除/导入/导出）。
class _SavedFiltersTile extends StatelessWidget {
  const _SavedFiltersTile();

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.filter_alt_outlined),
      title: const Text('自定义筛选器', style: TextStyle(fontSize: 14)),
      subtitle: const Text('管理命名筛选器，支持导入/导出', style: TextStyle(fontSize: 12)),
      trailing: const Icon(Icons.chevron_right, size: 20),
      onTap: () => unawaited(SavedFiltersDialog.show(context)),
    );
  }
}

Future<void> _openFile(BuildContext context, String path) async {
  if (path.toLowerCase().endsWith('.wemi')) {
    // 加密文件不能直接打开，引导解密
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('加密文件'),
        content: const Text('该文件已加密，需要先解密才能打开。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('去解密'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await _decryptFile(context, path);
    }
    return;
  }
  final r = await SystemOpenService.open(path);
  if (!r.ok && context.mounted) {
    if (r.needUnknownSources) {
      await SystemOpenService.handleFailure(context, path, r);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有找到能打开该文件的程序')),
      );
    }
  }
}

Future<void> _encryptFile(BuildContext context, String path) async {
  final vaultDir = SettingStore.get<String>('weimi_vault_dir', '');
  String? outputDir = vaultDir.isNotEmpty ? vaultDir : null;
  outputDir ??= await FileOperationsService.pickOutputDirectory();
  if (outputDir == null || !context.mounted) return;

  final result = await _passwordDialog(context,
      title: '设置加密密码', hintField: true);
  if (result == null || !context.mounted) return;

  try {
    await FileOperationsService.encryptFile(
      path,
      outputDir,
      result['password']!,
      hint: result['hint'],
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('加密成功')),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('加密失败: $e'), backgroundColor: Colors.red),
      );
    }
  }
}

Future<void> _decryptFile(BuildContext context, String path) async {
  String? hint;
  try {
    hint = await EncryptionService.getPasswordHint(path);
  } catch (_) {}
  final result =
      await _passwordDialog(context, title: '输入解密密码', hint: hint);
  if (result == null || !context.mounted) return;
  final password = result['password']!;

  final outputDir = await FileOperationsService.pickOutputDirectory();
  if (outputDir == null || !context.mounted) return;

  try {
    await FileOperationsService.decryptFile(path, outputDir, password);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('解密成功')),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('解密失败: $e'), backgroundColor: Colors.red),
      );
    }
  }
}

/// 发送到手机：弹局域网在线设备选择。
Future<void> _sendToPhone(BuildContext context, String path) async {
  final svc = LanTransferService.instance;
  final peers = svc.peers;
  if (peers.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有发现在线设备（请确认手机与电脑在同一局域网）')),
      );
    }
    return;
  }
  if (!context.mounted) return;
  final picked = await showModalBottomSheet<int>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(14),
            child: Text('发送到设备',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
          ),
          for (var i = 0; i < peers.length; i++)
            ListTile(
              leading: const Icon(Icons.phone_android_outlined),
              title: Text(peers[i].name, style: const TextStyle(fontSize: 14)),
              subtitle: Text(peers[i].ip, style: const TextStyle(fontSize: 12)),
              onTap: () => Navigator.pop(ctx, i),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (picked == null || !context.mounted) return;
  final ok = await svc.sendFile(peer: peers[picked], filePath: path);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? '已发送到 ${peers[picked].name}' : '发送失败：${svc.lastSendError}'),
        backgroundColor: ok ? Colors.green : Colors.red,
      ),
    );
  }
}

Future<void> _revealInFileManager(BuildContext context, String path) async {
  try {
    if (Platform.isWindows) {
      await Process.run('explorer', ['/select,$path']);
    } else if (Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [File(path).parent.path]);
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('打开失败: $e'), backgroundColor: Colors.red),
      );
    }
  }
}

Future<void> _copyPath(BuildContext context, String path) async {
  await Clipboard.setData(ClipboardData(text: path));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('路径已复制'), duration: Duration(seconds: 1)),
    );
  }
}

/// 密码对话框（加密/解密共用）。返回 {'password':..,'hint':..} 或 null。
Future<Map<String, String>?> _passwordDialog(
  BuildContext context, {
  required String title,
  bool hintField = false,
  String? hint,
}) async {
  final pwController = TextEditingController();
  final pw2Controller = TextEditingController();
  final hintController = TextEditingController(text: hint ?? '');
  final formKey = GlobalKey<FormState>();
  return showDialog<Map<String, String>>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Form(
        key: formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: pwController,
              autofocus: true,
              obscureText: true,
              decoration: const InputDecoration(labelText: '密码（4-32 位）'),
              validator: (v) {
                if (v == null || v.length < 4 || v.length > 32) return '密码长度 4-32 位';
                return null;
              },
            ),
            if (hintField) ...[
              TextFormField(
                controller: pw2Controller,
                obscureText: true,
                decoration: const InputDecoration(labelText: '确认密码'),
                validator: (v) =>
                    v != pwController.text ? '两次输入的密码不一致' : null,
              ),
              TextFormField(
                controller: hintController,
                decoration: const InputDecoration(
                    labelText: '密码提示（可选，32 字内）'),
                maxLength: 32,
              ),
            ] else if (hint != null && hint.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('提示：$hint',
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        TextButton(
          onPressed: () {
            if (formKey.currentState?.validate() ?? false) {
              Navigator.pop(ctx, {
                'password': pwController.text,
                'hint': hintController.text,
              });
            }
          },
          child: const Text('确定'),
        ),
      ],
    ),
  );
}
