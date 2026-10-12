import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../services/autostart_service.dart';
import '../services/lan_transfer_service.dart';
import '../services/tray_service.dart';
import '../services/trusted_devices_service.dart';
import '../services/receive_notify_service.dart';
import 'exclude_settings_screen.dart';

/// 设置页（单进程方案：直接调本进程 LanTransferService 单例）
/// - 微密飞传：网页快传开关、本机名称、信任设备
/// - 通用：清理缓存
/// - 桌面端：开机自动启动微密文件（常驻托盘）
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _webShare = true;
  bool _recvNotify = true;
  bool _autostartTray = false;
  String _selfName = '本机';
  List<MapEntry<String, String>> _trusted = [];
  String _receiveDir = '';
  bool _openRecvDir = false;
  bool _discoverEnabled = true;
  bool _isDesktop = false;
  /// 关闭按钮行为：'prompt' | 'minimize' | 'quit'
  String _closeAction = 'prompt';

  @override
  void initState() {
    super.initState();
    _isDesktop = !Platform.isAndroid && !Platform.isIOS;
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final svc = LanTransferService.instance;
    if (mounted) {
      setState(() {
        _webShare = svc.webShareEnabled;
        _selfName = svc.selfName.isEmpty ? '本机' : svc.selfName;
        _recvNotify = ReceiveNotifyService.instance.enabled;
        _receiveDir = svc.receiveDir;
        _openRecvDir = ReceiveNotifyService.instance.openDir;
        _discoverEnabled = svc.discoverEnabled;
      });
    }
    // 信任设备列表来自本进程持久化文件，强制重读最新内容
    await TrustedDevices.instance.reload();
    if (mounted) setState(() => _trusted = TrustedDevices.instance.all);
    if (_isDesktop) {
      if (AutostartService.supported) {
        final enabled =
            await AutostartService.isEnabled(valueName: 'WeiMiFile');
        if (mounted) setState(() => _autostartTray = enabled);
      }
      _closeAction = TrayService.instance.closeAction;
      if (mounted) setState(() {});
    }
  }

  Future<void> _pickCloseAction() async {
    final cur = TrayService.instance.closeAction;
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('点右上角关闭按钮时'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _closeActionRadio(ctx, 'prompt', '弹窗询问（默认）',
                '每次弹确认框问「收进托盘 / 退出」', cur),
            _closeActionRadio(ctx, 'minimize', '直接收进托盘',
                '静默最小化，微密飞传后台常驻', cur),
            _closeActionRadio(ctx, 'quit', '直接退出程序',
                '静默退出，需从托盘图标重新打开', cur),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        ],
      ),
    );
    if (picked != null && mounted) {
      await TrayService.instance.setCloseAction(picked);
      setState(() => _closeAction = picked);
    }
  }

  Widget _closeActionRadio(BuildContext ctx, String value, String title,
      String subtitle, String cur) {
    final selected = cur == value;
    return RadioListTile<String>(
      value: value,
      groupValue: cur,
      onChanged: (v) => Navigator.pop(ctx, v),
      contentPadding: const EdgeInsets.only(bottom: 4),
      dense: true,
      title: Text(title,
          style: TextStyle(
              fontWeight: selected ? FontWeight.bold : FontWeight.normal)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
    );
  }

  Future<void> _toggleWebShare(bool v) async {
    await LanTransferService.instance.setWebShareEnabled(v);
    if (mounted) setState(() => _webShare = v);
  }

  Future<void> _toggleRecvNotify(bool v) async {
    await ReceiveNotifyService.instance.setEnabled(v);
    if (mounted) setState(() => _recvNotify = v);
  }

  Future<void> _toggleOpenRecvDir(bool v) async {
    await ReceiveNotifyService.instance.setOpenDir(v);
    if (mounted) setState(() => _openRecvDir = v);
  }

  Future<void> _toggleDiscover(bool v) async {
    await LanTransferService.instance.setDiscoverEnabled(v);
    if (mounted) {
      setState(() => _discoverEnabled = v);
      _snack(v
          ? '已开启：其他设备可搜索到本机（网页快传不受影响）'
          : '已关闭：其他设备搜索不到本机（网页快传仍可用）');
    }
  }

  Future<void> _pickReceiveDir() async {
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
    if (mounted) setState(() => _receiveDir = dir);
    _snack('飞传接收文件将保存到：$dir');
  }

  Future<void> _openReceiveDir() async {
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _toggleAutostartTray(bool v) async {
    final ok = await AutostartService.setEnabled(v,
        exePath: Platform.resolvedExecutable, valueName: 'WeiMiFile');
    if (mounted) {
      setState(() => _autostartTray = ok ? v : _autostartTray);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? (v ? '已开启开机自动启动微密文件' : '已关闭开机自动启动微密文件')
            : '设置失败，请检查系统权限'),
        backgroundColor: ok ? Colors.green : Colors.red,
      ));
    }
  }

  Future<void> _editName() async {
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

  Future<void> _removeTrusted(String id) async {
    await TrustedDevices.instance.remove(id);
    await TrustedDevices.instance.reload();
    if (mounted) setState(() => _trusted = TrustedDevices.instance.all);
  }

  Future<void> _clearCache() async {
    int cleared = 0;
    try {
      final tmp = await getTemporaryDirectory();
      cleared = await _dirSize(tmp);
      // 清空临时目录内容（保留目录本身）
      if (await tmp.exists()) {
        await for (final e in tmp.list()) {
          try {
            await e.delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {}
    // Android 上顺带清 file_picker 缓存
    if (Platform.isAndroid) {
      try {
        await FilePicker.platform.clearTemporaryFiles();
      } catch (_) {}
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('已清理 ${_fmtSize(cleared)} 缓存'),
        backgroundColor: Colors.green,
      ));
    }
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
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          _sectionHeader('微密飞传'),
          SwitchListTile(
            secondary: const Icon(Icons.language),
            title: const Text('网页快传'),
            subtitle: const Text(
                '浏览器打开 http://本机IP:端口 即可发送文件/文本给本机，免确认直接接收'),
            value: _webShare,
            onChanged: _toggleWebShare,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.radar),
            title: const Text('可被发现'),
            subtitle: const Text(
                '关闭后停止局域网广播，其他设备搜不到本机（网页快传不受影响）'),
            value: _discoverEnabled,
            onChanged: _toggleDiscover,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.notifications_active_outlined),
            title: const Text('接收完成通知'),
            subtitle: const Text(
                '收到文件/文本后提示一下（电脑为系统通知，点通知可打开文件所在目录；手机为应用内横幅）'),
            value: _recvNotify,
            onChanged: _toggleRecvNotify,
          ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('接收保存目录'),
            subtitle: Text(_receiveDir.isEmpty
                ? '跟随「加密文件存放目录」'
                : _receiveDir),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_receiveDir.isNotEmpty)
                  TextButton(
                    onPressed: _openReceiveDir,
                    child: const Text('打开', style: TextStyle(fontSize: 12)),
                  ),
                const Icon(Icons.chevron_right),
              ],
            ),
            onTap: _pickReceiveDir,
          ),
          if (_isDesktop)
            SwitchListTile(
              secondary: const Icon(Icons.folder_open_outlined),
              title: const Text('接收后自动打开文件夹'),
              subtitle: const Text('收到文件后自动打开保存目录（配合上面的通知）'),
              value: _openRecvDir,
              onChanged: _toggleOpenRecvDir,
            ),
          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: const Text('本机名称'),
            subtitle: Text(_selfName),
            trailing: const Icon(Icons.chevron_right),
            onTap: _editName,
          ),
          ListTile(
            leading: const Icon(Icons.verified_user_outlined),
            title: const Text('信任设备'),
            subtitle: Text(
                '${_trusted.length} 台 · 信任过的设备发来文件/文本免确认直接接收'),
          ),
          if (_trusted.isEmpty)
            const Padding(
              padding: EdgeInsets.only(left: 56, right: 16, bottom: 8),
              child: Text('暂无信任设备。在飞传页点设备右侧菜单「添加信任」。',
                  style: TextStyle(fontSize: 12)),
            )
          else
            ..._trusted.map((e) => ListTile(
                  contentPadding: const EdgeInsets.only(left: 56, right: 8),
                  leading: const Icon(Icons.devices, size: 20),
                  title: Text(e.value, style: const TextStyle(fontSize: 14)),
                  trailing: TextButton(
                    onPressed: () => _removeTrusted(e.key),
                    child: const Text('移除',
                        style: TextStyle(color: Colors.red)),
                  ),
                )),
          const Divider(),
          _sectionHeader('全盘搜索'),
          ListTile(
            leading: const Icon(Icons.folder_off_outlined),
            title: const Text('排除文件夹'),
            subtitle: const Text('这些文件夹不扫描不索引，可加快搜索、省内存'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (context) => const ExcludeSettingsScreen()),
              );
            },
          ),
          const Divider(),
          _sectionHeader('通用'),
          ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('清理缓存'),
            subtitle: const Text('预览缩略图、分享中转等临时文件'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _clearCache,
          ),
          if (_isDesktop) ...[
            const Divider(),
            _sectionHeader('桌面端'),
            if (AutostartService.supported)
              SwitchListTile(
                secondary: const Icon(Icons.power_settings_new),
                title: const Text('开机自动启动微密文件'),
                subtitle: const Text(
                    '登录系统后自动运行微密文件并常驻托盘，可随时从托盘退出'),
                value: _autostartTray,
                onChanged: _toggleAutostartTray,
              ),
            ListTile(
              leading: const Icon(Icons.close_fullscreen_outlined),
              title: const Text('点右上角关闭按钮时'),
              subtitle: Text(_closeAction == 'prompt'
                  ? '弹窗询问（默认）'
                  : (_closeAction == 'minimize' ? '直接收进托盘' : '直接退出程序')),
              trailing: const Icon(Icons.chevron_right),
              onTap: _pickCloseAction,
            ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: Colors.blue.shade700,
        ),
      ),
    );
  }
}
