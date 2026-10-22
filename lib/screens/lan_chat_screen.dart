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
  final Set<String> _selected = {};
  bool _selecting = false;
  bool _searching = false;
  final TextEditingController _searchCtl = TextEditingController();

  // 发送进度速度统计（进度对话框用）
  DateTime _progLastT = DateTime.now();
  int _progLastSent = 0;
  double _progSpeed = 0; // 字节/秒
  String _progVc = ''; // 当前验证码（LANDrop）

  bool get _isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  bool get _online => widget.peer != null;

  @override
  void initState() {
    super.initState();
    TransferHistoryService.instance.markRead(widget.peerKey);
    _load();
    _timer = Timer.periodic(const Duration(milliseconds: 700), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _textCtl.dispose();
    _searchCtl.dispose();
    _prog.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final r = await TransferHistoryService.instance.recordsFor(widget.peerKey);
    if (!mounted) return;
    _records = r;
    // 停留在此会话期间持续标已读（仅在有未读时写盘，避免每 700ms 白写）
    final latest = r.isNotEmpty ? r.first.time : null;
    if (latest != null &&
        TransferHistoryService.instance.isUnread(widget.peerKey, latest)) {
      await TransferHistoryService.instance.markRead(widget.peerKey);
    }
    setState(() {});
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
        _resetProgStats();
        if (!mounted) return;
        _showProg('准备发送…');
        final result = await LandropService.instance.sendFilesToDevice(
          dev,
          paths
              .map((fp) => LandropSendFile(path: fp, filename: p.basename(fp)))
              .toList(),
          onVerifCode: (code) => _progVc = code,
          onProgress: (cur, sent, total) => _onSendProgress(sent, total),
        );
        _hideProg();
        _snack(result.ok ? '已发送' : '发送失败：${result.error}');
      } else {
        for (final path in paths) {
          _resetProgStats();
          if (!mounted) return;
          _showProg('准备发送 ${p.basename(path)}…');
          final ok = await LanTransferService.instance.sendFile(
            peer: peer,
            filePath: path,
            onProgress: (sent, total) => _onSendProgress(sent, total),
          );
          _hideProg();
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
        _resetProgStats();
        _showProg('准备发送…');
        final result = await LandropService.instance.sendTextToDevice(
          dev,
          text,
          onVerifCode: (code) => _progVc = code,
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

  /// 桌面端粘贴发送：读剪贴板文本直接发出（Flix 0.1.4/0.1.5 风格）。
  Future<void> _pasteSend() async {
    if (!_online || _sending) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      _snack('剪贴板没有文本内容');
      return;
    }
    _textCtl.text = text;
    await _sendText();
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

  void _resetProgStats() {
    _progLastT = DateTime.now();
    _progLastSent = 0;
    _progSpeed = 0;
    _progVc = '';
  }

  /// 发送进度回调：更新对话框里的百分比与实时速度。
  void _onSendProgress(int sent, int total) {
    final now = DateTime.now();
    final dt = now.difference(_progLastT).inMilliseconds;
    if (dt >= 300 && sent >= _progLastSent) {
      _progSpeed = (sent - _progLastSent) / (dt / 1000);
      _progLastSent = sent;
      _progLastT = now;
    }
    final pct = total > 0 ? ' ${sent * 100 ~/ total}%' : '';
    final spd = _progSpeed > 0 ? ' · ${_fmtSpeed(_progSpeed)}' : '';
    final vc = _progVc.isNotEmpty ? '\n验证码 $_progVc' : '';
    _prog.value = '正在发送…$pct$spd$vc';
  }

  String _fmtSpeed(double bps) {
    if (bps < 1024) return '${bps.toStringAsFixed(0)} B/s';
    if (bps < 1024 * 1024) return '${(bps / 1024).toStringAsFixed(1)} KB/s';
    return '${(bps / 1024 / 1024).toStringAsFixed(1)} MB/s';
  }

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

  void _toggleSelect(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
    });
  }

  void _onItemTap(TransferRecord r) {
    if (_selecting) {
      _toggleSelect(r.id);
      return;
    }
    _onRecordTap(r);
  }

  void _onItemLongPress(TransferRecord r) {
    if (_selecting) {
      _toggleSelect(r.id);
      return;
    }
    _onRecordLongPress(r);
  }

  void _exitSelect() => setState(() {
        _selecting = false;
        _selected.clear();
      });

  Future<void> _deleteSelected() async {
    final ids = List<String>.from(_selected);
    await TransferHistoryService.instance.deleteRecords(ids);
    setState(() {
      _selected.clear();
      _selecting = false;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final q = _searching ? _searchCtl.text.trim().toLowerCase() : '';
    final filtered = q.isEmpty
        ? _records
        : _records.where((r) {
            final name = r.name.toLowerCase();
            final text = (r.text ?? '').toLowerCase();
            return name.contains(q) || text.contains(q);
          }).toList();

    Widget list;
    if (filtered.isEmpty) {
      list = Center(
        child: Text(
          _online ? '还没有传输记录，发个文件试试' : '暂无与该设备的历史记录',
          style: TextStyle(color: Colors.grey.shade500),
        ),
      );
    } else {
      final items = _buildChatItems(filtered, !_selecting);
      list = ListView.builder(
        reverse: true,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: items.length,
        itemBuilder: (ctx, i) {
          final it = items[items.length - 1 - i];
          if (it is _StackItem) {
            return _StackBubble(
              recs: it.recs,
              selecting: _selecting,
              selectedIds: _selected,
              onTap: _onItemTap,
              onLongPress: _onItemLongPress,
            );
          }
          final r = (it as _SingleItem).r;
          return _Bubble(
            record: r,
            selected: _selected.contains(r.id),
            selecting: _selecting,
            onTap: () => _onItemTap(r),
            onLongPress: () => _onItemLongPress(r),
          );
        },
      );
    }

    final body = Column(
      children: [
        if (_searching)
          _SearchBar(
            controller: _searchCtl,
            onChanged: () => setState(() {}),
            onClose: () => setState(() {
              _searching = false;
              _searchCtl.clear();
            }),
          ),
        if (_selecting)
          _SelectionBar(
            count: _selected.length,
            onDelete: _deleteSelected,
            onCancel: _exitSelect,
          ),
        Expanded(child: list),
        _Composer(
          online: _online,
          sending: _sending,
          controller: _textCtl,
          onSendText: _sendText,
          onPick: _pickAndSend,
          onPaste: _isDesktop ? _pasteSend : null,
        ),
      ],
    );

    if (!widget.standalone) return body;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.displayName),
        actions: [
          if (!_selecting && !_searching) ...[
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: '搜索',
              onPressed: () => setState(() => _searching = true),
            ),
            IconButton(
              icon: const Icon(Icons.checklist),
              tooltip: '多选',
              onPressed: () => setState(() => _selecting = true),
            ),
          ],
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
  final bool selected;
  final bool selecting;
  const _Bubble({
    required this.record,
    required this.onTap,
    required this.onLongPress,
    this.selected = false,
    this.selecting = false,
  });

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
            border: !record.ok
                ? Border.all(color: Colors.red.shade300)
                : (selected
                    ? Border.all(color: accent, width: 2)
                    : null),
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
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _fmtTime(record.time),
                      style:
                          TextStyle(fontSize: 10, color: Colors.grey.shade500),
                    ),
                    if (selected)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: const Icon(Icons.check_circle,
                            size: 14, color: Colors.green),
                      ),
                  ],
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
  final VoidCallback? onPaste; // 桌面端粘贴发送（null=不显示按钮）
  const _Composer({
    required this.online,
    required this.sending,
    required this.controller,
    required this.onSendText,
    required this.onPick,
    this.onPaste,
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
          if (onPaste != null)
            IconButton(
              icon: const Icon(Icons.content_paste),
              tooltip: '粘贴并发送剪贴板文本',
              onPressed: sending ? null : onPaste,
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

String _fmtSizeStr(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
}

// ============ 聊天项分组（堆叠气泡） ============
abstract class _ChatItem {
  bool get out;
}

class _SingleItem extends _ChatItem {
  final TransferRecord r;
  _SingleItem(this.r);
  @override
  bool get out => r.direction == 'out';
}

class _StackItem extends _ChatItem {
  final List<TransferRecord> recs;
  _StackItem(this.recs);
  @override
  bool get out => recs.first.direction == 'out';
}

/// 把记录按「同方向连续文件」分组：连续文件合成一个堆叠气泡。
List<_ChatItem> _buildChatItems(List<TransferRecord> recs, bool stack) {
  final items = <_ChatItem>[];
  List<TransferRecord>? run;
  String? runDir;
  void flush() {
    if (run == null) return;
    if (run!.length == 1) {
      items.add(_SingleItem(run![0]));
    } else {
      items.add(_StackItem(List<TransferRecord>.from(run!)));
    }
    run = null;
    runDir = null;
  }

  for (final r in recs) {
    if (stack && r.kind == 'file' && runDir == r.direction) {
      run!.add(r);
    } else {
      flush();
      if (stack && r.kind == 'file') {
        run = [r];
        runDir = r.direction;
      } else {
        items.add(_SingleItem(r));
      }
    }
  }
  flush();
  return items;
}

class _StackBubble extends StatefulWidget {
  final List<TransferRecord> recs;
  final bool selecting;
  final Set<String> selectedIds;
  final void Function(TransferRecord) onTap;
  final void Function(TransferRecord) onLongPress;
  const _StackBubble({
    required this.recs,
    required this.selecting,
    required this.selectedIds,
    required this.onTap,
    required this.onLongPress,
  });
  @override
  State<_StackBubble> createState() => _StackBubbleState();
}

class _StackBubbleState extends State<_StackBubble> {
  bool _expanded = false;
  @override
  Widget build(BuildContext context) {
    final out = widget.recs.first.direction == 'out';
    final accent = Theme.of(context).colorScheme.primary;
    final count = widget.recs.length;
    return Align(
      alignment: out ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 280),
        decoration: BoxDecoration(
          color: out ? accent.withAlpha(28) : Colors.grey.shade200,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Row(
                children: [
                  Icon(Icons.folder_zip_outlined,
                      size: 16, color: out ? accent : Colors.grey.shade700),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '$count 个文件 · 点击${_expanded ? '收起' : '展开'}',
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
            if (_expanded)
              ...widget.recs.map((r) => GestureDetector(
                    onTap: () => widget.onTap(r),
                    onLongPress: () => widget.onLongPress(r),
                    child: Container(
                      margin: const EdgeInsets.only(top: 4),
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: widget.selecting &&
                                widget.selectedIds.contains(r.id)
                            ? accent.withAlpha(40)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(r.name,
                                style: const TextStyle(fontSize: 13))),
                          const SizedBox(width: 6),
                          Text(_fmtSizeStr(r.size),
                              style: TextStyle(
                                  fontSize: 11, color: Colors.grey.shade600)),
                        ],
                      ),
                    ),
                  )),
          ],
        ),
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onChanged;
  final VoidCallback onClose;
  const _SearchBar(
      {required this.controller,
      required this.onChanged,
      required this.onClose});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
        color: Colors.grey.shade100,
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '搜索文件名 / 文本',
                  border: OutlineInputBorder(),
                  isCollapsed: true,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
                onChanged: (_) => onChanged(),
              ),
            ),
            IconButton(icon: const Icon(Icons.close), onPressed: onClose),
          ],
        ),
      );
}

class _SelectionBar extends StatelessWidget {
  final int count;
  final VoidCallback onDelete;
  final VoidCallback onCancel;
  const _SelectionBar(
      {required this.count, required this.onDelete, required this.onCancel});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        color: Theme.of(context).colorScheme.primary.withAlpha(20),
        child: Row(
          children: [
            Text('已选 $count 项',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            TextButton(onPressed: onCancel, child: const Text('取消')),
            TextButton(
              onPressed: onDelete,
              child: const Text('删除', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      );
}
