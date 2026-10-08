import 'dart:async';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import '../services/lan_transfer_service.dart';
import '../widgets/progress_dialog.dart';

/// 局域网传输页：同 WiFi 下发现设备、互传文件（对标 Landrop，明文原样收发）
/// - 发送：选设备 → 选文件 → 直传
/// - 接收：对方来文件时弹窗确认，落盘到「加密文件存放目录」
class LanTransferScreen extends StatefulWidget {
  const LanTransferScreen({super.key});

  @override
  State<LanTransferScreen> createState() => _LanTransferScreenState();
}

class _LanTransferScreenState extends State<LanTransferScreen> {
  final LanTransferService _svc = LanTransferService.instance;
  List<LanPeer> _peers = [];
  String _ip = '…';
  StreamSubscription<LanEvent>? _sub;

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
          SnackBar(content: Text('已拒收「${e.name}」')),
        );
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
            Text('文件：${req.fileName}'),
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

  // ============ 发送流程 ============

  Future<void> _startSend() async {
    if (_peers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('尚未发现附近设备，请确认对方也打开本页且连同一 WiFi')),
      );
      return;
    }

    // 1. 选设备
    LanPeer? peer;
    if (_peers.length == 1) {
      peer = _peers.first;
    } else {
      peer = await showDialog<LanPeer>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('发送到哪台设备？'),
          children: [
            for (final d in _peers)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, d),
                child: ListTile(
                  leading: const Icon(Icons.devices),
                  title: Text(d.name),
                  subtitle: Text(d.ip),
                ),
              ),
          ],
        ),
      );
    }
    if (peer == null || !mounted) return;

    // 2. 选文件
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty || !mounted) return;
    final files =
        result.files.where((f) => f.path != null).map((f) => f.path!).toList();
    if (files.isEmpty) return;

    // 3. 逐个明文直传
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

      final ok = await _svc.sendFile(
        peer: peer,
        filePath: files[i],
      );
      if (ok) {
        okCount++;
      } else {
        failCount++;
      }
    }

    if (mounted) {
      ProgressDialog.hide(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            '发送完成：成功 $okCount，失败 $failCount（发给 ${peer.name}）'),
        backgroundColor: failCount == 0 ? Colors.green : Colors.orange,
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
      appBar: AppBar(title: const Text('局域网传输')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _startSend,
        icon: const Icon(Icons.send),
        label: const Text('发送文件'),
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
                    '正在搜索同一 WiFi 下的设备…\n对方需打开微密文件的「局域网传输」页',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                  ),
                ],
              ),
            )
          else
            ..._peers.map((d) => Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: ListTile(
                    leading: const Icon(Icons.devices, color: Colors.teal),
                    title: Text(d.name,
                        style: const TextStyle(fontWeight: FontWeight.w500)),
                    subtitle: Text('${d.ip}:${d.httpPort}',
                        style: const TextStyle(fontSize: 12)),
                    trailing: const Icon(Icons.send, size: 18, color: Colors.blue),
                    onTap: _startSend,
                  ),
                )),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '说明：发送与接收双方须连接同一 WiFi；接收的文件默认存入「加密文件存放目录」（未设置时存入应用目录）。',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
          ),
        ],
      ),
    );
  }
}
