import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import '../services/autostart_service.dart';
import '../services/lan_transfer_service.dart';
import '../services/trusted_devices_service.dart';

/// 设置页
/// - 微密飞传：启动时自动开启、本机名称、信任设备管理
/// - 通用：清理缓存
/// - 桌面端：关闭时最小化到托盘、开机自动启动
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _autoStartLan = false;
  bool _webShare = true;
  bool _closeToTray = true;
  bool _autostart = false;
  List<MapEntry<String, String>> _trusted = [];
  bool _isDesktop = false;

  @override
  void initState() {
    super.initState();
    _isDesktop = !Platform.isAndroid && !Platform.isIOS;
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    await TrustedDevices.instance.load();
    if (!mounted) return;
    setState(() {
      _autoStartLan = prefs.getBool('lan_autostart') ?? false;
      _closeToTray = prefs.getBool('desk_close_to_tray') ?? true;
      _trusted = TrustedDevices.instance.all;
    });
    if (mounted) {
      setState(() => _webShare = LanTransferService.instance.webShareEnabled);
    }
    if (AutostartService.supported) {
      final enabled = await AutostartService.isEnabled();
      if (mounted) setState(() => _autostart = enabled);
    }
  }

  Future<void> _toggleAutoStartLan(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('lan_autostart', v);
    if (v) await LanTransferService.instance.startReceiving();
    if (mounted) setState(() => _autoStartLan = v);
  }

  Future<void> _toggleWebShare(bool v) async {
    await LanTransferService.instance.setWebShareEnabled(v);
    if (mounted) setState(() => _webShare = v);
  }

  Future<void> _toggleCloseToTray(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('desk_close_to_tray', v);
    try {
      await windowManager.setPreventClose(v);
    } catch (_) {}
    if (mounted) setState(() => _closeToTray = v);
  }

  Future<void> _toggleAutostart(bool v) async {
    final ok = await AutostartService.setEnabled(v);
    if (mounted) {
      setState(() => _autostart = ok ? v : _autostart);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? (v ? '已开启开机自动启动' : '已关闭开机自动启动')
            : '设置失败，请检查系统权限'),
        backgroundColor: ok ? Colors.green : Colors.red,
      ));
    }
  }

  Future<void> _editName() async {
    final controller =
        TextEditingController(text: LanTransferService.instance.selfName);
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
    if (r != null && mounted) {
      await LanTransferService.instance.setSelfName(r);
      setState(() {});
    }
  }

  Future<void> _removeTrusted(String id) async {
    await TrustedDevices.instance.remove(id);
    if (mounted) {
      setState(() => _trusted = TrustedDevices.instance.all);
    }
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
            secondary: const Icon(Icons.sensors),
            title: const Text('启动时自动开启飞传'),
            subtitle: const Text('打开软件即允许附近设备发现本机并传输文件'),
            value: _autoStartLan,
            onChanged: _toggleAutoStartLan,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.language),
            title: const Text('网页快传'),
            subtitle: const Text(
                '浏览器打开 http://本机IP:端口 即可发送文件/文本给本机，免确认直接接收'),
            value: _webShare,
            onChanged: _toggleWebShare,
          ),
          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: const Text('本机名称'),
            subtitle: Text(LanTransferService.instance.selfName),
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
            SwitchListTile(
              secondary: const Icon(Icons.picture_in_picture_alt),
              title: const Text('关闭时最小化到托盘'),
              subtitle: const Text('点关闭按钮不退出，从系统托盘恢复或退出'),
              value: _closeToTray,
              onChanged: _toggleCloseToTray,
            ),
            if (AutostartService.supported)
              SwitchListTile(
                secondary: const Icon(Icons.power_settings_new),
                title: const Text('开机自动启动'),
                subtitle: const Text('登录系统后自动运行微密文件'),
                value: _autostart,
                onChanged: _toggleAutostart,
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
