import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import '../services/lan_transfer_service.dart';
import '../services/landrop_service.dart';
import '../services/transfer_history_service.dart';

/// 与单台设备的聊天式传输窗口（Flix 风格：历史记录按设备保存在这里）。
/// - 在线设备（peer != null）可发文件/文本；离线设备（peer == null）仅查看历史。
/// - 记录实时刷新（轮询 TransferHistoryService，避免引入额外流）。
class LanChatScreen extends StatefulWidget {
  final LanPeer? peer; // 在线设备对象（含地址/端口）；离线为 null
  final String peerKey; // 稳定会话 key（= TransferRecord.peerKey）
  final String displayName;
  final bool standalone; // true=自带 Scaffold+AppBar；false=仅 body（主页 tab 用）

  const LanChatScreen({
    super.key,
    this.peer,
    required this.peerKey,
    required this.displayName,
    this.standalone = true,
  });

  @override
  State<LanChatScreen> createState() => _LanChatScreenState();
}

class _LanChatScreenState extends State<LanChatScreen> {
  List<TransferRecord> _records = [];
  final TextEditingController _textCtl = TextEditingController();
  Timer? _timer;
  bool _sending = false;
  final ValueNotifier<String> _prog = ValueNotifier('');

  bool get _online => widget.peer != null;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(milliseconds: 700), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _textCtl.dispose();
    _prog.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final r = await TransferHistoryService.instance.recordsFor(widget.peerKey);
    if (mounted) setState(() => _records = r);
  }

  LandropDevice _toDev(LanPeer p) => LandropDevice(
        publicKey: p.ldPkB64 ?? p.id,
        name: p.name,
        type: '',
        address: p.ip,
        port: p.ldPort ?? p.httpPort,
        lastSeen: p.lastSeen,
      );

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red.shade700 : null,
    ));
  }

  Future<void> _pickAndSend() async {
    if (!_online || _sending) return;
    final res = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: true,
    );
    if (res == null || res.files.isEmpty) return;
    final files =
        res.files.where((f) => f.path != null).map((f) => f.path!).toList();
    if (files.isEmpty) return;
    await _sendFiles(files);
  }

  Future<void> _sendFiles(List<String> paths) async {
    if (!_online || _sending) return;
    setState(() => _sending = true);
    final peer = widget.peer!;
    try {
      if (peer.isLandrop) {
        final dev = _toDev(peer);
        String vc = '';
        if (!mounted) return;
        _showProg('准备发送…');
        final result = await LandropService.instance.sendFilesToDevice(
          dev,
          paths
              .map((fp) => LandropSendFile(path: fp, filename: p.basename(fp)))
              .toList(),
          onVerifCode: (code) {
            vc = code;
            _updateProg('正在发送…\n验证码 $code');
          },
          onProgress: (cur, sent, total) {
            _updateProg('正在发送 ${cur}…'
                '${vc.isNotEmpty ? '\n验证码 $vc' : ''}');
          },
        );
        _hideProg();
        _snack(result.ok ? '已发送' : '发送失败：${result.error}');
      } else {
        for (final path in paths) {
          final ok = await LanTransferService.instance.sendFile(
            peer: peer,
            filePath: path,
          );
          _snack(ok ? '已发送 ${p.basename(path)}' : '发送失败：${p.basename(path)}',
              error: !ok);
        }
      }
    } catch (e) {
      _hideProg();
      _snack('发送出错：$e', error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendText() async {
    if (!_online || _sending) return;
    final text = _textCtl.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    final peer = widget.peer!;
    try {
      if (peer.isLandrop) {
        final dev = _toDev(peer);
        String vc = '';
        _showProg('准备发送…');
        final result = await LandropService.instance.sendTextToDevice(
          dev,
          text,
          onVerifCode: (code) {
            vc = code;
            _updateProg('正在发送…\n验证码 $code');
          },
        );
        _hideProg();
        _snack(result.ok ? '已发送' : '发送失败：${result.error}');
      } else {
        final ok =
            await LanTransferService.instance.sendText(peer: peer, text: text);
        _snack(ok ? '已发送' : '发送失败', error: !ok);
      }
      if (mounted) _textCtl.clear();
    } catch (e) {
      _hideProg();
      _snack('发送出错：$e', error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _showProg(String msg) {
    _prog.value = msg;
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => ValueListenableBuilder<String>(
        valueListenable: _prog,
        builder: (_, v, __) => AlertDialog(
          content: Row(children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 16),
            Expanded(child: Text(v)),
          ]),
        ),
      ),
    );
  }

  void _updateProg(String msg) => _prog.value = msg;

  void _hideProg() {
    if (mounted && Navigator.canPop(context)) Navigator.pop(context);
  }

  void _onRecordTap(TransferRecord r) {
    if (r.kind == 'file' && r.path != null) {
      TransferHistoryService.instance.openParentDirectory(r.path!);
    }
  }

  void _onRecordLongPress(TransferRecord r) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (r.kind == 'text' && r.text != null)
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('复制文本'),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: r.text!));
                  Navigator.pop(ctx);
                  _snack('已复制');
                },
              ),
            if (r.kind == 'file' && r.path != null)
              ListTile(
                leading: const Icon(Icons.folder_open),
                title: const Text('在文件夹中显示'),
                onTap: () {
                  Navigator.pop(ctx);
                  TransferHistoryService.instance.openParentDirectory(r.path!);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('删除这条记录',
                  style: TextStyle(color: Colors.red)),
              onTap: () async {
                Navigator.pop(ctx);
                await TransferHistoryService.instance
                    .deleteRecords([r.id]);
                _load();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = Column(
      children: [
        Expanded(
          child: _records.isEmpty
              ? Center(
                  child: Text(
                    _online ? '还没有传输记录，发个文件试试' : '暂无与该设备的历史记录',
                    style: TextStyle(color: Colors.grey.shade500),
                  ),
                )
              : ListView.builder(
                  reverse: true,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  itemCount: _records.length,
                  itemBuilder: (ctx, i) {
                    // records 最新在前，reverse 后最旧在底部
                    final r = _records[_records.length - 1 - i];
                    return _Bubble(
                      record: r,
                      onTap: () => _onRecordTap(r),
                      onLongPress: () => _onRecordLongPress(r),
                    );
                  },
                ),
        ),
        _Composer(
          online: _online,
          sending: _sending,
          controller: _textCtl,
          onSendText: _sendText,
          onPick: _pickAndSend,
        ),
      ],
    );

    if (!widget.standalone) return body;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.displayName),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 12),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: _online ? Colors.green : Colors.grey,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              _online ? '在线' : '离线',
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        ],
      ),
      body: body,
    );
  }
}

class _Bubble extends StatelessWidget {
  final TransferRecord record;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  const _Bubble(
      {required this.record, required this.onTap, required this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final out = record.direction == 'out';
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return Align(
      alignment: out ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          constraints: const BoxConstraints(maxWidth: 280),
          decoration: BoxDecoration(
            color: out ? accent.withAlpha(28) : Colors.grey.shade200,
            borderRadius: BorderRadius.circular(12),
            border: record.ok
                ? null
                : Border.all(color: Colors.red.shade300),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    record.kind == 'text'
                        ? Icons.chat_bubble_outline
                        : Icons.insert_drive_file_outlined,
                    size: 16,
                    color: out ? accent : Colors.grey.shade700,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      record.kind == 'text'
                          ? (record.text ?? record.name)
                          : record.name,
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                ],
              ),
              if (record.kind == 'file')
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    _fmtSize(record.size),
                    style:
                        TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                ),
              if (!record.ok && record.note != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    record.note!,
                    style:
                        TextStyle(fontSize: 11, color: Colors.red.shade600),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  _fmtTime(record.time),
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _fmtSize(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

class _Composer extends StatelessWidget {
  final bool online;
  final bool sending;
  final TextEditingController controller;
  final VoidCallback onSendText;
  final VoidCallback onPick;
  const _Composer({
    required this.online,
    required this.sending,
    required this.controller,
    required this.onSendText,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    if (!online) {
      return Container(
        padding: const EdgeInsets.all(14),
        color: Colors.grey.shade100,
        child: Text(
          '设备当前离线，仅可查看历史记录。设备上线后可在此发送文件/文本。',
          style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
          textAlign: TextAlign.center,
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.attach_file),
            tooltip: '发送文件/文件夹',
            onPressed: sending ? null : onPick,
          ),
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(
                hintText: '输入文本，回车发送',
                border: OutlineInputBorder(),
                isCollapsed: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              onSubmitted: (_) => onSendText(),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            icon: sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send),
            onPressed: sending ? null : onSendText,
          ),
        ],
      ),
    );
  }
}
