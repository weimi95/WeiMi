import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../framework/module_registry.dart';
import '../framework/setting_store.dart';
import '../services/daemon_service.dart';
import '../services/landrop_service.dart';
import '../services/lan_transfer_service.dart';
import '../services/localsend_service.dart';
import '../services/receive_notify_service.dart';
import '../services/transfer_history_service.dart';
import '../services/trusted_devices_service.dart';

/// 微密飞传模块：网页快传 / 可被发现 / 接收通知 / 接收目录 / 本机名称 /
/// 信任设备 / LocalSend 兼容 / LANDrop 兼容。
class LanTransferModule extends FeatureModule {
  LanTransferModule();

  @override
  String get id => 'lan_transfer';

  @override
  String get name => '微密飞传';

  @override
  IconData get icon => Icons.send_outlined;

  @override
  int get order => 10;

  @override
  List<SettingDef> get settings => [
        SettingDef(
          key: 'lan_web_share_enabled',
          title: '网页快传',
          icon: Icons.language,
          subtitle: '浏览器打开 http://本机IP:端口 即可发送文件/文本给本机，免确认直接接收',
          type: SettingType.boolean,
          defaultValue: true,
          onChanged: (ctx, v) =>
              LanTransferService.instance.setWebShareEnabled(v as bool),
        ),
        SettingDef(
          key: 'lan_discover_enabled',
          title: '可被发现',
          icon: Icons.radar,
          subtitle: '关闭后停止局域网广播，其他设备搜不到本机（网页快传不受影响）',
          type: SettingType.boolean,
          defaultValue: true,
          onChanged: (ctx, v) async {
            await LanTransferService.instance.setDiscoverEnabled(v as bool);
            if (ctx.mounted) {
              ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                content: Text(v == true
                    ? '已开启：其他设备可搜索到本机（网页快传不受影响）'
                    : '已关闭：其他设备搜索不到本机（网页快传仍可用）'),
                duration: const Duration(seconds: 2),
              ));
            }
          },
        ),
        SettingDef(
          key: 'lan_localsend_enabled',
          title: 'LocalSend 兼容',
          icon: Icons.swap_horiz,
          subtitle: '与 LocalSend App 互收互发文件。若同机装着两个 App，'
              '设备列表只显示一条（自动合并）；关闭后不再广播/扫描 LocalSend 设备',
          type: SettingType.boolean,
          defaultValue: true,
          onChanged: (ctx, v) async {
            await LocalSendService.instance.setEnabled(v as bool);
            if (ctx.mounted) {
              ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                content: Text(v == true
                    ? '已开启：可与 LocalSend 设备互传'
                    : '已关闭：不再发现/连接 LocalSend 设备'),
                duration: const Duration(seconds: 2),
              ));
            }
          },
        ),
        SettingDef(
          key: 'lan_landrop_enabled',
          title: 'LANDrop 兼容',
          icon: Icons.public,
          subtitle: '与 LANDrop App 互收互发文件/文本（UDP 52637 发现 + TCP 加密传输）。'
              '首次接收需核对 6 位验证码，可勾选信任后免确认；关闭后不再广播/连接 LANDrop 设备',
          type: SettingType.boolean,
          defaultValue: true,
          onChanged: (ctx, v) async {
            await LandropService.instance.setEnabled(v as bool);
            if (ctx.mounted) {
              ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                content: Text(v == true
                    ? '已开启：可发现并连接 LANDrop 设备（含真 LANDrop App）'
                    : '已关闭：不再发现/连接 LANDrop 设备'),
                duration: const Duration(seconds: 2),
              ));
            }
          },
        ),
        SettingDef(
          key: 'lan_untrusted_mode',
          title: '未信任设备请求',
          icon: Icons.front_hand_outlined,
          subtitle: '等待确认：弹窗询问，超时自动拒收（时限可调，默认 30 秒）；'
              '直接拒绝：不询问立即拒收。拒收在传输记录里留痕',
          type: SettingType.choice,
          defaultValue: 'confirm',
          options: ['confirm', 'reject'],
          optionLabels: {'confirm': '等待用户确认', 'reject': '直接拒绝'},
          group: '未信任设备请求',
          onChanged: (ctx, v) {
            // 同步策略给守护进程（Windows 守护进程模式下由它负责接收）
            if (Platform.isWindows) {
              unawaited(DaemonService.pushConfig(uiActive: true));
            }
            if (ctx.mounted) {
              ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                content: Text(v == 'reject'
                    ? '已设为直接拒绝：未信任设备的请求立即拒收（传输记录留痕）'
                    : '已设为等待确认：未信任设备请求弹窗询问，30 秒未确认自动拒收'),
                duration: const Duration(seconds: 2),
              ));
            }
          },
        ),
        SettingDef(
          key: 'lan_untrusted_timeout',
          title: '等待确认时限',
          icon: Icons.timer_outlined,
          subtitle: '未信任请求弹窗等待的秒数，超时自动拒收（选「直接拒绝」时无效）',
          type: SettingType.integer,
          defaultValue: 30,
          min: 10,
          max: 120,
          divisions: 22,
          group: '未信任设备请求',
          onChanged: (ctx, v) {
            if (Platform.isWindows) {
              unawaited(DaemonService.pushConfig(uiActive: true));
            }
          },
        ),
        SettingDef(
          key: 'notify_receive_done',
          title: '接收完成通知',
          icon: Icons.notifications_active_outlined,
          subtitle: '收到文件/文本后提示一下（电脑为系统通知，点通知可打开文件所在目录；手机为应用内横幅）',
          type: SettingType.boolean,
          defaultValue: true,
          onChanged: (ctx, v) =>
              ReceiveNotifyService.instance.setEnabled(v as bool),
        ),
        SettingDef(
          key: 'lan_offline_presend',
          title: '离线预发送',
          icon: Icons.schedule_send_outlined,
          subtitle: '设备离线时在聊天窗发送的文件/文本先排队，设备上线后自动发出；'
              '关闭后离线设备只能查看历史记录',
          type: SettingType.boolean,
          defaultValue: true,
        ),
        SettingDef(
          key: 'lan_receive_dir',
          title: '接收保存目录',
          type: SettingType.custom,
          customTile: (ctx) => const _ReceiveDirTile(),
        ),
        SettingDef(
          key: 'transfer_history_retention_days',
          title: '传输记录保留时长',
          icon: Icons.history_toggle_off,
          subtitle: '超过保留时长的传输记录自动清除（只清记录，不动已接收的文件）。'
              '上限 500 条，超出时最旧的先被挤掉',
          type: SettingType.choice,
          defaultValue: '30',
          options: const ['0', '7', '30', '90'],
          optionLabels: const {
            '0': '永久保留',
            '7': '保留 7 天',
            '30': '保留 30 天',
            '90': '保留 90 天',
          },
          onChanged: (ctx, v) async {
            final days = int.tryParse('$v') ?? 30;
            final removed = await TransferHistoryService.instance
                .setRetentionDays(days);
            if (ctx.mounted) {
              ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                content: Text(days <= 0
                    ? '已设为永久保留传输记录'
                    : (removed > 0
                        ? '已设为保留 $days 天，清除了 $removed 条过期记录'
                        : '已设为保留 $days 天')),
                duration: const Duration(seconds: 2),
              ));
            }
          },
        ),
        SettingDef(
          key: 'lan_open_recv_folder',
          title: '接收后自动打开文件夹',
          icon: Icons.folder_open_outlined,
          subtitle: '收到文件后自动打开保存目录（配合上面的通知）',
          type: SettingType.boolean,
          defaultValue: false,
          visible: () => !Platform.isAndroid && !Platform.isIOS,
          onChanged: (ctx, v) =>
              ReceiveNotifyService.instance.setOpenDir(v as bool),
        ),
        SettingDef(
          key: 'lan_self_name',
          title: '本机名称',
          type: SettingType.custom,
          customTile: (ctx) => const _SelfNameTile(),
        ),
        SettingDef(
          key: 'lan_trusted_devices',
          title: '信任设备',
          type: SettingType.custom,
          customTile: (ctx) => const _TrustedDevicesTile(),
        ),
      ];

  @override
  List<FileActionDef> get fileActions => const [];
}

/// 接收保存目录：选目录 / 打开 / 恢复默认（复杂交互，自绘整块）。
class _ReceiveDirTile extends StatefulWidget {
  const _ReceiveDirTile();

  @override
  State<_ReceiveDirTile> createState() => _ReceiveDirTileState();
}

class _ReceiveDirTileState extends State<_ReceiveDirTile> {
  String _receiveDir = '';
  String _effectiveDir = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final svc = LanTransferService.instance;
    String eff = '';
    try {
      eff = await svc.effectiveReceiveDir();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _receiveDir = svc.receiveDir;
      _effectiveDir = eff;
    });
  }

  Future<void> _pick() async {
    final picked = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择飞传接收文件的保存目录');
    if (picked == null || picked.isEmpty || !mounted) return;
    // Android 的目录选择器返回 SAF URI（primary:Download），转成真实路径
    var dir = picked;
    if (Platform.isAndroid && !picked.startsWith('/')) {
      final parts = picked.split(':');
      dir = parts.length == 2 ? '/storage/emulated/0${parts[1]}' : '';
    }
    if (dir.isEmpty || !await Directory(dir).exists()) {
      _snack('该目录不可用，已取消');
      return;
    }
    await LanTransferService.instance.setReceiveDir(dir);
    if (!mounted) return;
    setState(() {
      _receiveDir = dir;
      _effectiveDir = dir;
    });
    _snack('飞传接收文件将保存到：$dir');
  }

  Future<void> _reset() async {
    await LanTransferService.instance.setReceiveDir('');
    if (!mounted) return;
    String eff = '';
    try {
      eff = await LanTransferService.instance.effectiveReceiveDir();
    } catch (_) {}
    setState(() {
      _receiveDir = '';
      _effectiveDir = eff;
    });
    _snack(eff.isEmpty ? '已恢复默认接收目录' : '已恢复默认接收目录：$eff');
  }

  Future<void> _open() async {
    final dir = _receiveDir.trim();
    if (dir.isEmpty) return;
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', [dir.replaceAll('/', '\\')]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [dir]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [dir]);
      }
    } catch (_) {}
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.download_outlined),
      title: const Text('接收保存目录', style: TextStyle(fontSize: 14)),
      subtitle: Text(
        _receiveDir.isEmpty
            ? (_effectiveDir.isEmpty ? '默认：文档目录/微密飞传接收' : '默认：$_effectiveDir')
            : _receiveDir,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_receiveDir.isNotEmpty) ...[
            TextButton(
              onPressed: _open,
              child: const Text('打开', style: TextStyle(fontSize: 12)),
            ),
            TextButton(
              onPressed: _reset,
              child: const Text('默认', style: TextStyle(fontSize: 12)),
            ),
          ],
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: _pick,
    );
  }
}

/// 本机名称（对方设备列表里显示的名字）。
class _SelfNameTile extends StatefulWidget {
  const _SelfNameTile();

  @override
  State<_SelfNameTile> createState() => _SelfNameTileState();
}

class _SelfNameTileState extends State<_SelfNameTile> {
  String _selfName = '本机';

  @override
  void initState() {
    super.initState();
    final svc = LanTransferService.instance;
    _selfName = svc.selfName.isEmpty ? '本机' : svc.selfName;
  }

  Future<void> _edit() async {
    final controller =
        TextEditingController(text: _selfName == '本机' ? '' : _selfName);
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('本机名称'),
        content: TextField(
          controller: controller,
          maxLength: 20,
          decoration: const InputDecoration(hintText: '对方设备列表里显示的名字'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('保存')),
        ],
      ),
    );
    if (r != null && r.trim().isNotEmpty && mounted) {
      await LanTransferService.instance.setSelfName(r.trim());
      setState(() => _selfName = r.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.badge_outlined),
      title: const Text('本机名称', style: TextStyle(fontSize: 14)),
      subtitle: Text(_selfName, style: const TextStyle(fontSize: 12)),
      trailing: const Icon(Icons.chevron_right),
      onTap: _edit,
    );
  }
}

/// 信任设备列表（信任过的设备免确认直收）。
class _TrustedDevicesTile extends StatefulWidget {
  const _TrustedDevicesTile();

  @override
  State<_TrustedDevicesTile> createState() => _TrustedDevicesTileState();
}

class _TrustedDevicesTileState extends State<_TrustedDevicesTile> {
  List<MapEntry<String, String>> _trusted = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await TrustedDevices.instance.reload();
    if (!mounted) return;
    setState(() => _trusted = TrustedDevices.instance.all);
  }

  Future<void> _remove(String id) async {
    await TrustedDevices.instance.remove(id);
    await TrustedDevices.instance.reload();
    if (!mounted) return;
    setState(() => _trusted = TrustedDevices.instance.all);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: const Icon(Icons.verified_user_outlined),
          title: const Text('信任设备', style: TextStyle(fontSize: 14)),
          subtitle: Text('${_trusted.length} 台 · 信任过的设备发来文件/文本免确认直接接收'
              '（微密设备在飞传页右键「添加信任」；LANDrop 设备在首次接收确认框勾选）',
              style: const TextStyle(fontSize: 12)),
        ),
        if (_trusted.isEmpty)
          const Padding(
            padding: EdgeInsets.only(left: 56, right: 16, bottom: 8),
            child: Text('暂无信任设备。在飞传页点设备右侧菜单「添加信任」，'
                '或在 LANDrop 首次接收的确认框里勾选信任。',
                style: TextStyle(fontSize: 12)),
          )
        else
          ..._trusted.map((e) => ListTile(
                contentPadding: const EdgeInsets.only(left: 56, right: 8),
                leading: const Icon(Icons.devices, size: 20),
                title: Text(e.value, style: const TextStyle(fontSize: 14)),
                trailing: TextButton(
                  onPressed: () => _remove(e.key),
                  child: const Text('移除',
                      style: TextStyle(color: Colors.red)),
                ),
              )),
      ],
    );
  }
}
