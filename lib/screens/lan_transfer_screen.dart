import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import '../services/lan_transfer_service.dart';
import '../services/trusted_devices_service.dart';
import '../widgets/progress_dialog.dart';
import 'settings_screen.dart';

/// 微密飞传页：同 WiFi 下发现设备、互传文件/文本（对标 Landrop，明文原样收发）
/// - 发送：选设备 → 选文件/输入文本 → 直传
/// - 接收：信任设备免确认直收；未信任设备弹窗确认；落盘到「加密文件存放目录」
/// - 支持系统分享直达（initialText / initialFiles 自动发送）
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
  String _ip = '…';
  StreamSubscription<LanEvent>? _sub;
  bool _autoSendDone = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // 确认弹窗回调（HTTP 处理在主 isolate 事件循环里调用，可以直接弹 UI）
    _svc.confirmHandler = _showIncomingConfirm;
    _sub ??= _svc.events.listen((e) {
      if (!mounted) return;
      if (e.type == LanEventType.peersChanged) {
        setState(() => _peers = _svc.peers);
      } else if (e.type == LanEventType.incomingDone) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('已接收「${e.name}」（来自 ${e.from}）'),
          backgroundColor: Colors.green,
        ));
      } else if (e.type == LanEventType.incomingFailed) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('接收「${e.name}」失败: ${e.error}'),
          backgroundColor: Colors.red,
        ));
      } else if (e.type == LanEventType.incomingRejected) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('已拒收「${e.name}」（未信任 ${e.from}，长按设备可添加信任）')),
        );
      } else if (e.type == LanEventType.incomingText) {
        _showReceivedText(e.content ?? '', e.from ?? '未知设备');
      }
    });

    await _svc.startDiscovery();
    final ip = await _svc.localIPv4();
    if (mounted) {
      setState(() {
        _ip = ip ?? '未知';
        _peers = _svc.peers;
      });
    }
    _autoSendIfNeeded();
  }

  /// 系统分享直达：等设备出现后自动发送
  Future<void> _autoSendIfNeeded() async {
    if (_autoSendDone) return;
    final hasPayload =
        (widget.initialText != null && widget.initialText!.isNotEmpty) ||
            widget.initialFiles.isNotEmpty;
    if (!hasPayload) return;
    _autoSendDone = true;
    // 最多等 15 秒发现设备
    for (int i = 0; i < 30; i++) {
      if (!mounted) return;
      if (_peers.isNotEmpty) break;
      await Future.delayed(const Duration(milliseconds: 500));
      // peers 由事件流更新，这里手动同步一次防止事件窗口错过
      setState(() => _peers = _svc.peers);
    }
    if (!mounted) return;
    if (_peers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('未发现附近设备，可等设备出现后点右下角发送'),
        duration: Duration(seconds: 5),
      ));
      return;
    }
    final peer = await _pickPeer();
    if (peer == null || !mounted) return;
    if (widget.initialText != null && widget.initialText!.isNotEmpty) {
      await _sendTextTo(peer, widget.initialText!);
    } else if (widget.initialFiles.isNotEmpty) {
      await _sendFilesTo(peer, widget.initialFiles);
    }
  }

  @override
  void dispose() {
    _svc.confirmHandler = null;
    _svc.stopDiscovery();
    _sub?.cancel();
    _sub = null;
    super.dispose();
  }

  // ============ 接收确认弹窗 ============

  Future<bool> _showIncomingConfirm(IncomingRequest req) async {
    if (!mounted) return false;
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('收到传输请求'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('设备：${req.senderName}',
                style: const TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: 6),
            Text('内容：${req.fileName}'),
            const SizedBox(height: 2),
            Text('大小：${_fmtSize(req.fileSize)}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('拒收'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('接收'),
          ),
        ],
      ),
    );
    return accepted == true;
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
          decoration: const InputDecoration(
              hintText: '输入要发送的文本内容'),
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
        content: Text(ok ? '文本已发送给 ${peer.name}' : '发送失败：${_svc.lastSendError}'),
        backgroundColor: ok ? Colors.green : Colors.red,
      ));
    }
  }

  // ============ 信任设备 ============

  Future<void> _toggleTrust(LanPeer d) async {
    final trusted = TrustedDevices.instance.isTrustedSync(d.id);
    if (trusted) {
      await TrustedDevices.instance.remove(d.id);
    } else {
      await TrustedDevices.instance.add(d.id, d.name);
    }
    if (mounted) {
      setState(() => _peers = _svc.peers);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(trusted
            ? '已取消信任「${d.name}」，之后接收其文件需再次确认'
            : '已信任「${d.name}」，之后其发来的文件/文本免确认直接接收'),
      ));
    }
  }

  // ============ 其他 UI 动作 ============

  Future<void> _editName() async {
    final controller = TextEditingController(text: _svc.selfName);
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
      await _svc.setSelfName(r);
      setState(() {});
    }
  }

  Future<void> _toggleReceive(bool on) async {
    if (on) {
      await _svc.startReceiving();
    } else {
      await _svc.stopReceiving();
    }
    if (mounted) setState(() {});
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
                        _svc.selfName.isEmpty ? '本机' : _svc.selfName,
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
                Text('本机 IP：$_ip',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _svc.isReceiving ? '允许接收文件' : '已暂停接收',
                      style: TextStyle(
                        fontSize: 13,
                        color: _svc.isReceiving
                            ? Colors.green.shade700
                            : Colors.grey,
                      ),
                    ),
                    Switch(
                      value: _svc.isReceiving,
                      onChanged: _toggleReceive,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
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
                            text: 'http://$_ip:${_svc.httpPortActual}'));
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已复制网页快传地址')));
                      },
                    ),
                  ],
                ),
                Text('http://$_ip:${_svc.httpPortActual}',
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.teal)),
                const SizedBox(height: 4),
                Text(
                  _svc.webShareEnabled
                      ? '同一 WiFi 下任何设备用浏览器打开此地址，即可发送文件/文本给本机（免确认直接接收，重名自动加序号）'
                      : '网页快传已在设置中关闭',
                  style: TextStyle(
                      fontSize: 12,
                      color: _svc.webShareEnabled
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
              final trusted = TrustedDevices.instance.isTrustedSync(d.id);
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
                  onTap: () => _startSendFilesTo(d),
                ),
              );
            }),
          const SizedBox(height: 12),
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
