import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import '../services/lan_transfer_service.dart';
import '../services/trusted_devices_service.dart';
import '../widgets/progress_dialog.dart';
import 'settings_screen.dart';
import 'transfer_history_screen.dart';

/// 微密飞传页（单进程方案）：直接调用本进程 LanTransferService 单例，
/// 不再经 IPC 转发。接收确认通过 service 的 confirmHandler 回调弹窗。
class LanTransferScreen extends StatefulWidget {
  final String? initialText;
  final List<String> initialFiles;

  const LanTransferScreen(
      {super.key, this.initialText, this.initialFiles = const []});

  @override
  State<LanTransferScreen> createState() => _LanTransferScreenState();
}

class _LanTransferScreenState extends State<LanTransferScreen> {
  final LanTransferService _svc = LanTransferService.instance;
  List<LanPeer> _peers = [];
  List<WebPeer> _webPeers = [];
  String _selfName = '本机';
  String _selfIp = '…';
  int _selfHttpPort = 0;
  bool _selfWebShare = true;
  Timer? _pollTimer;
  String? _pendingText;
  List<String> _pendingFiles = [];

  @override
  void initState() {
    super.initState();
    if (widget.initialText != null && widget.initialText!.isNotEmpty) {
      _pendingText = widget.initialText;
    } else if (widget.initialFiles.isNotEmpty) {
      _pendingFiles = widget.initialFiles;
    }
    // 打开飞传页即确保发现/接收已启动（幂等）。v1.0.37 重写时曾删掉此调用，
    // 导致 Android 端（main() 的 lan_autostart 未开时）不监听不广播、两边都搜不到设备。
    _svc.startDiscovery().catchError((_) {});
    _startPolling();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _poll();
    _pollTimer =
        Timer.periodic(const Duration(milliseconds: 1500), (_) => _poll());
  }

  Future<void> _poll() async {
    if (!mounted) return;
    final ip = await _svc.localIPv4() ?? '';
    if (!mounted) return;
    setState(() {
      _peers = _svc.peers;
      _webPeers = _svc.webPeers;
      _selfName = _svc.selfName.isEmpty ? '本机' : _svc.selfName;
      _selfIp = ip;
      _selfHttpPort = _svc.httpPortActual;
      _selfWebShare = _svc.webShareEnabled;
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _showReceivedText(String text, String from) async {
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('来自「$from」的文本'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 400, maxWidth: 500),
          child: SingleChildScrollView(child: SelectableText(text)),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已复制到剪贴板')));
            },
            child: const Text('复制'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  // ============ 发送流程 ============

  Future<void> _startSendMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('发送文件'),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: const Text('发送文本'),
              onTap: () => Navigator.pop(ctx, 'text'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'file') {
      _startSendFiles();
    } else if (choice == 'text') {
      _startSendText();
    }
  }

  Future<LanPeer?> _pickPeer() async {
    if (_peers.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('尚未发现附近设备，请确认对方也打开本页且连同一 WiFi')),
        );
      }
      return null;
    }
    if (_peers.length == 1) return _peers.first;
    if (!mounted) return null;
    return showDialog<LanPeer>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('发送到哪台设备？'),
        children: [
          for (final d in _peers)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, d),
              child: ListTile(
                leading: Icon(
                  d.trusted ? Icons.verified_user : Icons.devices,
                  color: d.trusted ? Colors.green : null,
                ),
                title: Text(d.name),
                subtitle: Text(d.ip),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _startSendFiles() async {
    final peer = await _pickPeer();
    if (peer == null || !mounted) return;

    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty || !mounted) return;
    final files =
        result.files.where((f) => f.path != null).map((f) => f.path!).toList();
    if (files.isEmpty) return;
    await _sendFilesTo(peer, files);
  }

  Future<void> _sendFilesTo(LanPeer peer, List<String> files) async {
    int okCount = 0;
    int failCount = 0;
    for (int i = 0; i < files.length; i++) {
      final name = p.basename(files[i]);
      if (mounted) {
        if (i == 0) {
          ProgressDialog.show(
            context,
            title: '正在发送',
            currentProgress: i,
            totalProgress: files.length,
            currentFileName: name,
          );
        } else {
          ProgressDialog.update(
            context,
            title: '正在发送',
            currentProgress: i,
            totalProgress: files.length,
            currentFileName: name,
          );
        }
      }

      final ok = await _svc.sendFile(peer: peer, filePath: files[i]);
      if (ok) {
        okCount++;
      } else {
        failCount++;
      }
    }

    if (mounted) {
      ProgressDialog.hide(context);
      final detail = failCount > 0 && _svc.lastSendError.isNotEmpty
          ? '\n失败原因：${_svc.lastSendError}'
          : '';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            '发送完成：成功 $okCount，失败 $failCount（发给 ${peer.name}）$detail'),
        backgroundColor: failCount == 0 ? Colors.green : Colors.orange,
        duration: const Duration(seconds: 6),
      ));
    }
  }

  Future<void> _startSendText() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('发送文本'),
        content: TextField(
          controller: controller,
          maxLines: 6,
          autofocus: true,
          maxLength: 10000,
          decoration: const InputDecoration(hintText: '输入要发送的文本内容'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('下一步')),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty || !mounted) return;
    final peer = await _pickPeer();
    if (peer == null || !mounted) return;
    await _sendTextTo(peer, text);
  }

  Future<void> _sendTextTo(LanPeer peer, String text) async {
    if (mounted) {
      ProgressDialog.show(
        context,
        title: '正在发送文本',
        currentProgress: 1,
        totalProgress: 1,
      );
    }
    final ok = await _svc.sendText(peer: peer, text: text);
    if (mounted) {
      ProgressDialog.hide(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? '文本已发送给 ${peer.name}'
            : '发送失败：${_svc.lastSendError}'),
        backgroundColor: ok ? Colors.green : Colors.red,
      ));
    }
  }

  /// 分享直达：把挂起的待发送内容发给选定设备，完成后清空
  Future<void> _sendPendingTo(LanPeer peer) async {
    if (_pendingText != null && _pendingText!.isNotEmpty) {
      final text = _pendingText!;
      await _sendTextTo(peer, text);
      if (mounted) setState(() => _pendingText = null);
    } else if (_pendingFiles.isNotEmpty) {
      final files = List<String>.from(_pendingFiles);
      await _sendFilesTo(peer, files);
      if (mounted) setState(() => _pendingFiles = []);
    }
  }

  /// 设备点击：有待发内容直接发，否则走选文件流程
  Future<void> _onDeviceTap(LanPeer d) async {
    if (_pendingText != null || _pendingFiles.isNotEmpty) {
      await _sendPendingTo(d);
    } else {
      await _startSendFilesTo(d);
    }
  }

  // ============ 网页客户端（WS 房间） ============

  Future<void> _onWebPeerTap(WebPeer w) async {
    if (_pendingText != null && _pendingText!.isNotEmpty) {
      final text = _pendingText!;
      await _sendWebTextTo(w, text);
      if (mounted) setState(() => _pendingText = null);
    } else if (_pendingFiles.isNotEmpty) {
      final files = List<String>.from(_pendingFiles);
      await _sendWebFiles(w, files);
      if (mounted) setState(() => _pendingFiles = []);
    } else {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty || !mounted) return;
      final files = result.files
          .where((f) => f.path != null)
          .map((f) => f.path!)
          .toList();
      if (files.isEmpty) return;
      await _sendWebFiles(w, files);
    }
  }

  Future<void> _sendWebFiles(WebPeer w, List<String> files) async {
    int ok = 0, fail = 0;
    for (int i = 0; i < files.length; i++) {
      if (mounted) {
        if (i == 0) {
          ProgressDialog.show(context,
              title: '正在发送',
              currentProgress: i,
              totalProgress: files.length,
              currentFileName: p.basename(files[i]));
        } else {
          ProgressDialog.update(context,
              title: '正在发送',
              currentProgress: i,
              totalProgress: files.length,
              currentFileName: p.basename(files[i]));
        }
      }
      final r = await _svc.sendWebFile(w, files[i]);
      r ? ok++ : fail++;
    }
    if (mounted) {
      ProgressDialog.hide(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            '发送完成：成功 $ok，失败 $fail（发给网页客户端「${w.name}」）'
            '${fail > 0 && _svc.lastSendError.isNotEmpty ? '\n${_svc.lastSendError}' : ''}'),
        backgroundColor: fail == 0 ? Colors.green : Colors.orange,
      ));
    }
  }

  Future<void> _sendWebTextTo(WebPeer w, String text) async {
    if (mounted) {
      ProgressDialog.show(context,
          title: '正在发送文本', currentProgress: 1, totalProgress: 1);
    }
    final ok = await _svc.sendWebText(w, text);
    if (mounted) {
      ProgressDialog.hide(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? '文本已发送给网页客户端「${w.name}」'
            : '发送失败：${_svc.lastSendError}'),
        backgroundColor: ok ? Colors.green : Colors.red,
      ));
    }
  }

  Future<void> _startSendTextToWeb(WebPeer w) async {
    final controller = TextEditingController();
    if (!mounted) return;
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('发送文本给「${w.name}」'),
        content: TextField(
          controller: controller,
          maxLines: 6,
          autofocus: true,
          maxLength: 10000,
          decoration: const InputDecoration(hintText: '输入要发送的文本内容'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('发送')),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty || !mounted) return;
    await _sendWebTextTo(w, text);
  }

  // ============ 信任设备 ============

  Future<void> _toggleTrust(LanPeer d) async {
    if (d.trusted) {
      await TrustedDevices.instance.remove(d.id);
    } else {
      await TrustedDevices.instance.add(d.id, d.name);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(d.trusted
            ? '已取消信任「${d.name}」，之后接收其文件/文本需再次确认'
            : '已信任「${d.name}」，之后其发来的文件/文本免确认直接接收'),
      ));
    }
  }

  // ============ 其他 UI 动作 ============

  Future<void> _editName() async {
    final controller = TextEditingController(text: _selfName);
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
      await _svc.setSelfName(r.trim());
      setState(() => _selfName = r.trim());
    }
  }

  String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  // ============ UI ============

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('微密飞传'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: '传输记录',
            onPressed: () {
              Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const TransferHistoryScreen()));
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '设置',
            onPressed: () {
              Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen()));
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _startSendMenu,
        icon: const Icon(Icons.send),
        label: const Text('发送'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          // 本机信息卡
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.blue.withAlpha(15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.blue.withAlpha(50)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.smartphone, size: 20, color: Colors.blue),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _selfName.isEmpty ? '本机' : _selfName,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 15),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit, size: 18),
                      tooltip: '改名',
                      onPressed: _editName,
                    ),
                  ],
                ),
                Text('本机 IP：$_selfIp',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                const SizedBox(height: 8),
                Text(
                  '允许接收文件（托盘常驻）',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.green.shade700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // 分享直达：待发送内容卡
          if (_pendingText != null || _pendingFiles.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.amber.withAlpha(30),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.amber.withAlpha(90)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.share_outlined,
                      size: 20, color: Colors.amber),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _pendingText != null
                          ? '待发送文本：${_pendingText!.length > 30 ? '${_pendingText!.substring(0, 30)}…' : _pendingText!}'
                          : '待发送 ${_pendingFiles.length} 个文件，点击下方设备即发送',
                      style:
                          const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        setState(() {
                          _pendingText = null;
                          _pendingFiles = [];
                        }),
                    child: const Text('取消'),
                  ),
                ],
              ),
            ),
          // 网页快传地址卡（Snapdrop 式：浏览器打开即可发文件给本机）
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.teal.withAlpha(15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.teal.withAlpha(50)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.language, size: 20, color: Colors.teal),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text('网页快传',
                          style: TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 15)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 18),
                      tooltip: '复制地址',
                      onPressed: () {
                        Clipboard.setData(ClipboardData(
                            text: 'http://$_selfIp:$_selfHttpPort'));
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已复制网页快传地址')));
                      },
                    ),
                  ],
                ),
                Text('http://$_selfIp:$_selfHttpPort',
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.teal)),
                const SizedBox(height: 4),
                Text(
                  _selfWebShare
                      ? '同一 WiFi 下任何设备用浏览器打开此地址，即可发送文件/文本给本机（免确认直接接收，重名自动加序号）'
                      : '网页快传已在设置中关闭',
                  style: TextStyle(
                      fontSize: 12,
                      color: _selfWebShare
                          ? Colors.grey.shade600
                          : Colors.orange),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // 附近设备
          Row(
            children: [
              Icon(Icons.radar, size: 18, color: Colors.grey.shade600),
              const SizedBox(width: 6),
              Text(
                '附近设备（${_peers.length}）',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade600,
                ),
              ),
              const SizedBox(width: 8),
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_peers.isEmpty)
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  Icon(Icons.wifi_find, size: 40, color: Colors.grey.shade400),
                  const SizedBox(height: 10),
                  Text(
                    '正在搜索同一 WiFi 下的设备…\n对方需打开微密文件的「微密飞传」页',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                  ),
                ],
              ),
            )
          else
            ..._peers.map((d) {
              final trusted = d.trusted;
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: trusted ? Colors.green.shade300 : Colors.grey.shade300),
                ),
                child: ListTile(
                  leading: Icon(
                    trusted ? Icons.verified_user : Icons.devices,
                    color: trusted ? Colors.green : Colors.teal,
                  ),
                  title: Text(d.name,
                      style: const TextStyle(fontWeight: FontWeight.w500)),
                  subtitle: Text(
                      '${d.ip}:${d.httpPort}${trusted ? ' · 已信任' : ''}',
                      style: const TextStyle(fontSize: 12)),
                  trailing: PopupMenuButton<String>(
                    icon: const Icon(Icons.more_horiz, size: 20),
                    onSelected: (v) {
                      if (v == 'send_file') {
                        _startSendFilesTo(d);
                      } else if (v == 'send_text') {
                        _startSendTextTo(d);
                      } else if (v == 'trust') {
                        _toggleTrust(d);
                      }
                    },
                    itemBuilder: (ctx) => [
                      const PopupMenuItem(
                          value: 'send_file',
                          child: Row(children: [
                            Icon(Icons.insert_drive_file_outlined, size: 18),
                            SizedBox(width: 8),
                            Text('发送文件'),
                          ])),
                      const PopupMenuItem(
                          value: 'send_text',
                          child: Row(children: [
                            Icon(Icons.chat_bubble_outline, size: 18),
                            SizedBox(width: 8),
                            Text('发送文本'),
                          ])),
                      PopupMenuItem(
                          value: 'trust',
                          child: Row(children: [
                            Icon(
                                trusted
                                    ? Icons.remove_moderator_outlined
                                    : Icons.add_moderator_outlined,
                                size: 18),
                            const SizedBox(width: 8),
                            Text(trusted ? '取消信任' : '添加信任'),
                          ])),
                    ],
                  ),
                  onTap: () => _onDeviceTap(d),
                ),
              );
            }),
          const SizedBox(height: 12),
          // 网页客户端（Snapdrop 式 WS 房间成员，可与本机互发）
          if (_webPeers.isNotEmpty) ...[
            Row(
              children: [
                Icon(Icons.language, size: 18, color: Colors.grey.shade600),
                const SizedBox(width: 6),
                Text(
                  '网页客户端（${_webPeers.length}）· 浏览器打开上面的快传地址即可加入',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ..._webPeers.map((w) {
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.teal.shade300),
                ),
                child: ListTile(
                  leading: const Icon(Icons.language, color: Colors.teal),
                  title: Text(w.name,
                      style: const TextStyle(fontWeight: FontWeight.w500)),
                  subtitle: Text('网页客户端 · ${w.ip}',
                      style: const TextStyle(fontSize: 12)),
                  trailing: IconButton(
                    icon: const Icon(Icons.chat_bubble_outline, size: 20),
                    tooltip: '发送文本',
                    onPressed: () => _startSendTextToWeb(w),
                  ),
                  onTap: () => _onWebPeerTap(w),
                ),
              );
            }),
            const SizedBox(height: 4),
          ],
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '说明：发送与接收双方须连接同一 WiFi；接收的文件默认存入「加密文件存放目录」（未设置时存入应用目录）；信任过的设备免确认直接接收。',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _startSendFilesTo(LanPeer peer) async {
    if (!mounted) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty || !mounted) return;
    final files =
        result.files.where((f) => f.path != null).map((f) => f.path!).toList();
    if (files.isEmpty) return;
    await _sendFilesTo(peer, files);
  }

  Future<void> _startSendTextTo(LanPeer peer) async {
    final controller = TextEditingController();
    if (!mounted) return;
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('发送文本给「${peer.name}」'),
        content: TextField(
          controller: controller,
          maxLines: 6,
          autofocus: true,
          maxLength: 10000,
          decoration: const InputDecoration(hintText: '输入要发送的文本内容'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('发送')),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty || !mounted) return;
    await _sendTextTo(peer, text);
  }
}
