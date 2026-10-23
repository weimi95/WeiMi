import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:cross_file/cross_file.dart';
import 'package:path/path.dart' as p;
import '../framework/setting_store.dart';
import '../services/lan_transfer_service.dart';
import '../services/landrop_service.dart';
import '../services/pending_send_service.dart';
import '../services/transfer_history_service.dart';
import '../services/windows_thumbnail_provider.dart';
import '../widgets/file_thumbnail.dart';

/// 与单台设备的聊天式传输窗口（Flix 风格：历史记录按设备保存在这里）。
/// - 在线设备（peer != null）可发文件/文本；离线设备发送自动进**待发送队列**，
///   设备上线后自动发出（Flix 1.5.1/1.7.0 的离线预发送）。
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

  /// 消息列表滚动控制（微信式：最新消息贴底部，新消息自动滚到底）
  final ScrollController _scrollCtl = ScrollController();
  bool _firstLoad = true;
  bool _dragging = false; // 桌面端文件拖入悬停中（高亮提示层）

  // 发送进度速度统计（进度对话框用）
  DateTime _progLastT = DateTime.now();
  int _progLastSent = 0;
  double _progSpeed = 0; // 字节/秒
  String _progVc = ''; // 当前验证码（LANDrop）

  bool get _isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// 实时设备对象：每轮从服务按会话 key 重新取（widget.peer 只是打开那一刻的
  /// 快照，设备重连后 ip/port 可能变化）。null = 离线。
  LanPeer? _livePeer;
  List<PendingSend> _pending = [];
  bool _flushTried = false; // 本次在线期间已尝试过队列 flush（避免反复重试）

  bool get _online => _livePeer != null;

  /// 离线预发送开关（设置-微密飞传；默认开）。关闭后离线设备只读。
  bool get _presend => SettingStore.get<bool>('lan_offline_presend', true);

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
    _scrollCtl.dispose();
    _prog.dispose();
    super.dispose();
  }

  /// 滚到消息底部（最新一条）。仅在「本就贴近底部」或首次加载时自动滚，
  /// 不打断用户往上翻历史。700ms 轮询刷新同理。
  void _scrollToBottom({bool force = false}) {
    if (!_scrollCtl.hasClients) return;
    final pos = _scrollCtl.position;
    final atBottom = pos.pixels >= pos.maxScrollExtent - 60;
    if (!force && !atBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtl.hasClients) return;
      final target = _scrollCtl.position.maxScrollExtent;
      if (target <= 0) return;
      _scrollCtl.animateTo(target,
          duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
    });
  }

  /// 按会话 key 找活设备。必须走 LandropService.mergeInto 合并口径——
  /// LANDrop 设备不在 LanTransferService.peers 里，不合并会导致列表页
  /// 显示在线、点进聊天窗却判离线（v1.2.11 修复根因）。
  LanPeer? _peerById(String key) {
    for (final p in LandropService.mergeInto(
        LanTransferService.instance.peers)) {
      if (p.id == key) return p;
    }
    return null;
  }

  Future<void> _load() async {
    final r = await TransferHistoryService.instance.recordsFor(widget.peerKey);
    if (!mounted) return;
    _records = r;
    // 实时设备对象同步 + 待发送队列刷新（listFor 载入后为纯内存过滤，零 IO）
    _livePeer = _peerById(widget.peerKey);
    _pending = await PendingSendService.instance.listFor(widget.peerKey);
    if (!mounted) return;
    // 停留在此会话期间持续标已读（仅在有未读时写盘，避免每 700ms 白写）
    final latest = r.isNotEmpty ? r.first.time : null;
    if (latest != null &&
        TransferHistoryService.instance.isUnread(widget.peerKey, latest)) {
      await TransferHistoryService.instance.markRead(widget.peerKey);
    }
    // 设备在线且有排队内容 → 自动发出（每次在线期间只试一轮，失败留下轮再试）
    if (_online && _pending.isNotEmpty && !_flushTried) {
      _flushTried = true;
      unawaited(PendingSendService.instance
          .flushFor(_livePeer!)
          .whenComplete(_load));
      return;
    }
    if (!_online) _flushTried = false;
    setState(() {});
    _scrollToBottom(force: _firstLoad);
    _firstLoad = false;
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
    if (_sending) return;
    final res = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: true,
    );
    if (res == null || res.files.isEmpty) return;
    final files =
        res.files.where((f) => f.path != null).map((f) => f.path!).toList();
    if (files.isEmpty) return;
    await _sendPaths(files);
  }

  /// 桌面端拖入发送：资源管理器拖文件/文件夹进聊天窗，松手即发
  /// （离线自动转待发送队列，与附件按钮同一链路）。
  Future<void> _onDropFiles(List<XFile> files) async {
    if (_sending) return;
    final paths =
        files.where((f) => f.path.isNotEmpty).map((f) => f.path!).toList();
    if (paths.isEmpty) return;
    await _sendPaths(paths);
  }

  /// 发送一组路径（文件/文件夹混合）：展开目录保留层级 → 在线直发 / 离线排队。
  Future<void> _sendPaths(List<String> paths) async {
    final entries = await _expandEntries(paths);
    if (entries.isEmpty || !mounted) return;
    final hasDir = entries.any((e) => e.isDir);
    if (!_online) {
      if (!_presend) {
        _snack('设备离线，无法发送（可在 设置-微密飞传 开启「离线预发送」）');
        return;
      }
      if (hasDir) {
        _snack('文件夹暂不支持离线排队，请设备在线时发送', error: true);
        return;
      }
      await _enqueueFiles(entries.map((e) => e.absPath).toList());
      return;
    }
    await _sendEntries(entries);
  }

  /// 展开待发送条目：文件原样；目录递归收文件，relativeName 保留相对层级
  /// （LANDrop filename 支持 '/'；微密协议 sendFile 有 relativeName 参数）。
  Future<List<_SendEntry>> _expandEntries(List<String> paths) async {
    final out = <_SendEntry>[];
    for (final path in paths) {
      bool isDir = false;
      try {
        isDir = FileSystemEntity.isDirectorySync(path);
      } catch (_) {}
      if (!isDir) {
        if (File(path).existsSync()) {
          out.add(_SendEntry(absPath: path, relativeName: p.basename(path)));
        }
        continue;
      }
      final base = p.basename(path);
      try {
        await for (final e in Directory(path).list(recursive: true)) {
          if (e is File) {
            out.add(_SendEntry(
              absPath: e.path,
              relativeName: '$base/${p.relative(e.path, from: path)}',
              isDir: true,
            ));
          }
        }
      } catch (_) {}
    }
    return out;
  }

  Future<void> _sendEntries(List<_SendEntry> entries) async {
    final peer = _livePeer;
    if (peer == null || _sending) return;
    setState(() => _sending = true);
    try {
      if (peer.isLandrop) {
        final dev = _toDev(peer);
        _resetProgStats();
        if (!mounted) return;
        _showProg('准备发送…');
        final result = await LandropService.instance.sendFilesToDevice(
          dev,
          entries
              .map((e) =>
                  LandropSendFile(path: e.absPath, filename: e.relativeName))
              .toList(),
          onVerifCode: (code) => _progVc = code,
          onProgress: (cur, sent, total) => _onSendProgress(sent, total),
        );
        _hideProg();
        _snack(result.ok ? '已发送 ${entries.length} 个项目' : '发送失败：${result.error}');
      } else {
        for (final e in entries) {
          _resetProgStats();
          if (!mounted) return;
          _showProg('准备发送 ${p.basename(e.absPath)}…');
          final ok = await LanTransferService.instance.sendFile(
            peer: peer,
            filePath: e.absPath,
            relativeName: e.relativeName,
            onProgress: (sent, total) => _onSendProgress(sent, total),
          );
          _hideProg();
          _snack(ok ? '已发送 ${e.relativeName}' : '发送失败：${e.relativeName}',
              error: !ok);
          if (!ok) break;
        }
      }
    } catch (e) {
      _hideProg();
      _snack('发送出错：$e', error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 离线入队：文件
  Future<void> _enqueueFiles(List<String> paths) async {
    final ok = await PendingSendService.instance.enqueue(PendingSend(
      id: newPendingId(),
      peerKey: widget.peerKey,
      peerName: widget.displayName,
      kind: 'file',
      paths: paths,
      createdAt: DateTime.now(),
    ));
    _snack(ok ? '设备离线，已加入待发送队列，上线后自动发出' : '加入待发送队列失败', error: !ok);
    _load();
  }

  /// 离线入队：文本
  Future<void> _enqueueText(String text) async {
    final ok = await PendingSendService.instance.enqueue(PendingSend(
      id: newPendingId(),
      peerKey: widget.peerKey,
      peerName: widget.displayName,
      kind: 'text',
      text: text,
      createdAt: DateTime.now(),
    ));
    _snack(ok ? '设备离线，已加入待发送队列，上线后自动发出' : '加入待发送队列失败', error: !ok);
    _load();
  }

  Future<void> _sendText() async {
    if (_sending) return;
    final text = _textCtl.text.trim();
    if (text.isEmpty) return;
    if (!_online) {
      if (!_presend) {
        _snack('设备离线，无法发送（可在 设置-微密飞传 开启「离线预发送」）');
        return;
      }
      await _enqueueText(text);
      if (mounted) _textCtl.clear();
      return;
    }
    await _sendTextTo(_livePeer!, text);
    if (mounted) _textCtl.clear();
  }

  Future<void> _sendTextTo(LanPeer peer, String text) async {
    if (_sending) return;
    setState(() => _sending = true);
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
              leading: const Icon(Icons.shortcut),
              title: const Text('转发给其他设备'),
              onTap: () {
                Navigator.pop(ctx);
                _forwardRecord(r);
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

  /// 一键转发：把收到的文件/文本直接发给另一台在线设备（Flix 1.3.0 风格）。
  Future<void> _forwardRecord(TransferRecord r) async {
    final peers = LanTransferService.instance.peers
        .where((p0) => p0.id != widget.peerKey)
        .toList();
    if (!mounted) return;
    if (peers.isEmpty) {
      _snack('附近没有其他在线设备，无法转发');
      return;
    }
    final picked = await showDialog<LanPeer>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('转发给'),
        children: peers
            .map((p0) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, p0),
                  child: Row(children: [
                    const Icon(Icons.devices, size: 20),
                    const SizedBox(width: 10),
                    Flexible(child: Text(p0.name)),
                  ]),
                ))
            .toList(),
      ),
    );
    if (picked == null || !mounted) return;
    if (r.kind == 'text') {
      if (r.text == null || r.text!.isEmpty) return;
      await _sendTextTo(picked, r.text!);
    } else {
      if (r.path == null || !File(r.path!).existsSync()) {
        _snack('原文件不存在，无法转发', error: true);
        return;
      }
      await _sendEntries([
        _SendEntry(absPath: r.path!, relativeName: p.basename(r.path!))
      ]);
    }
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
    if (filtered.isEmpty && _pending.isEmpty) {
      list = Center(
        child: Text(
          _online ? '还没有传输记录，发个文件试试' : '暂无与该设备的历史记录',
          style: TextStyle(color: Colors.grey.shade500),
        ),
      );
    } else {
      // 微信式布局：时间正序（旧→新），最新消息贴输入框。
      // _records/_pending 均「最新在前」存储，展示前反转；堆叠分组按正序
      // 连续同方向文件合成一个气泡（展开列表内也是先发的在上）。
      final items = _buildChatItems(filtered.reversed.toList(), !_selecting);
      items.addAll(_pending.reversed.map((s) => _PendingItem(s)));
      list = ListView.builder(
        controller: _scrollCtl,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: items.length,
        itemBuilder: (ctx, i) {
          final it = items[i];
          if (it is _PendingItem) {
            return _PendingBubble(
              item: it.s,
              onCancel: () async {
                await PendingSendService.instance.remove(it.s.id);
                _load();
              },
            );
          }
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
          isDesktop: _isDesktop,
          online: _online,
          presend: _presend,
          sending: _sending,
          controller: _textCtl,
          onSendText: _sendText,
          onPick: _pickAndSend,
          onPaste: _isDesktop ? _pasteSend : null,
        ),
      ],
    );

    // 桌面端：整个聊天区接受文件拖入（松手即发，离线自动排队）
    final content = _isDesktop
        ? _wrapBody(DropTarget(
            onDragEntered: (_) => setState(() => _dragging = true),
            onDragExited: (_) => setState(() => _dragging = false),
            onDragDone: (d) {
              setState(() => _dragging = false);
              _onDropFiles(d.files);
            },
            child: body,
          ))
        : _wrapBody(body);

    if (!widget.standalone) return content;
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
      body: content,
    );
  }

  Widget _wrapBody(Widget inner) {
    if (!_dragging) return inner;
    return Stack(
      children: [
        inner,
        Positioned.fill(
          child: IgnorePointer(
            child: Container(
              margin: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withAlpha(24),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: Theme.of(context).colorScheme.primary, width: 2),
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.move_to_inbox,
                        size: 40,
                        color: Theme.of(context).colorScheme.primary),
                    const SizedBox(height: 8),
                    Text(
                      '松手发送到 ${widget.displayName}',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.bold),
                    ),
                    const Text('离线设备将自动加入待发送队列',
                        style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
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
    // 图片/视频文件气泡顶部显示缩略图（复用文件页底层能力）
    final showThumb = record.kind == 'file' &&
        record.path != null &&
        (FileThumbs.isImage(record.name) || FileThumbs.isVideo(record.name));
    return Align(
      alignment: out ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
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
              if (showThumb)
                _ChatThumb(path: record.path!, name: record.name),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey.shade600),
                        ),
                      ),
                    if (!record.ok && record.note != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          record.note!,
                          style: TextStyle(
                              fontSize: 11, color: Colors.red.shade600),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _fmtTime(record.time),
                            style: TextStyle(
                                fontSize: 10, color: Colors.grey.shade500),
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

/// 聊天文件气泡缩略图（图片/视频）：微信式——按图片真实宽高比自适应尺寸
/// （竖图限高、横图限宽），完整显示不裁切（BoxFit.contain）。
/// 复用文件页底层能力——图片 Image.file 降采样、视频 Windows 走系统缩略图
/// 首帧 / Android 原生抽帧，加载失败或文件已删时回退类型图标盒。
class _ChatThumb extends StatefulWidget {
  final String path;
  final String name;
  final double fallbackHeight; // 宽高比未知时的占位高度
  const _ChatThumb({
    required this.path,
    required this.name,
    this.fallbackHeight = 140,
  });

  @override
  State<_ChatThumb> createState() => _ChatThumbState();
}

class _ChatThumbState extends State<_ChatThumb> {
  // 微信式尺寸约束：横图限宽、竖图限高，过窄/过扁时兜最小边保证可点。
  static const double _maxW = 210, _maxH = 260, _minW = 64, _minH = 48;

  Size? _ratio; // 内容真实宽高比（解码小图获得，等比不变形）

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant _ChatThumb old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path || old.name != widget.name) {
      _ratio = null;
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final name = widget.name;
    Size? ratio;
    try {
      if (FileThumbs.isImage(name)) {
        ratio = await _decodeFile(widget.path);
      } else if (FileThumbs.isVideo(name)) {
        if (Platform.isWindows) {
          final tp =
              await WindowsThumbnailProvider.getThumbnailFile(widget.path);
          if (tp != null && File(tp).existsSync()) ratio = await _decodeFile(tp);
        } else {
          final data = await FileThumbs.videoFrame(widget.path);
          if (data != null) ratio = await _decodeBytes(data);
        }
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() => _ratio = ratio);
  }

  Future<Size?> _decodeFile(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      return await _decodeBytes(bytes);
    } catch (_) {
      return null;
    }
  }

  /// 小尺寸解码只为拿宽高比（targetWidth=96 省内存，等比不变形；
  /// instantiateImageCodec 没有 cacheWidth 参数，CI 3.38.3 实证）。
  Future<Size?> _decodeBytes(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(
          bytes,
          targetWidth: 96,
          allowUpscaling: false);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      final s = Size(img.width.toDouble(), img.height.toDouble());
      img.dispose();
      codec.dispose();
      if (s.width <= 0 || s.height <= 0) return null;
      return s;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isImg = FileThumbs.isImage(widget.name);
    final isVid = FileThumbs.isVideo(widget.name);
    if (!isImg && !isVid) return const SizedBox.shrink();
    if (_ratio == null) {
      // 宽高比未解析（加载中/失败）：固定占位盒
      return _fallbackBox(_maxW, widget.fallbackHeight);
    }
    final r = _ratio!.width / _ratio!.height;
    double w = _maxW, h = w / r;
    if (h > _maxH) {
      h = _maxH;
      w = h * r;
    }
    if (w < _minW) w = _minW;
    if (h < _minH) h = _minH;
    Widget content;
    if (isImg) {
      content = Image.file(
        File(widget.path),
        fit: BoxFit.contain,
        cacheWidth: 560,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => _fallbackBox(w, h),
      );
    } else if (Platform.isWindows) {
      content = FutureBuilder<String?>(
        future: WindowsThumbnailProvider.getThumbnailFile(widget.path),
        builder: (ctx, snap) {
          final bp = snap.data;
          if (bp != null && File(bp).existsSync()) {
            return Image.file(
              File(bp),
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => _fallbackBox(w, h),
            );
          }
          return _fallbackBox(w, h);
        },
      );
    } else {
      content = FutureBuilder<Uint8List?>(
        future: FileThumbs.videoFrame(widget.path),
        builder: (ctx, snap) {
          final data = snap.data;
          if (data != null) {
            return Image.memory(
              data,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => _fallbackBox(w, h),
            );
          }
          return _fallbackBox(w, h);
        },
      );
    }
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(11)),
      child: SizedBox(
        width: w,
        height: h,
        child: Stack(
          children: [
            Positioned.fill(child: content),
            if (isVid)
              const Center(
                child: Icon(Icons.play_circle_outline,
                    color: Colors.white, size: 34),
              ),
          ],
        ),
      ),
    );
  }

  Widget _fallbackBox(double w, double h) {
    final info = FileThumbs.infoFor(widget.name);
    return Container(
      width: w,
      height: h,
      color: info.color.withAlpha(20),
      child: Center(child: Icon(info.icon, size: 40, color: info.color)),
    );
  }
}

class _Composer extends StatefulWidget {
  final bool isDesktop;
  final bool online;
  final bool presend; // 离线预发送开关（offline && !presend → 只读灰条）
  final bool sending;
  final TextEditingController controller;
  final VoidCallback onSendText;
  final VoidCallback onPick;
  final VoidCallback? onPaste; // 桌面端粘贴发送（null=不显示按钮）
  const _Composer({
    required this.isDesktop,
    required this.online,
    this.presend = true,
    required this.sending,
    required this.controller,
    required this.onSendText,
    required this.onPick,
    this.onPaste,
  });

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final FocusNode _focus = FocusNode(debugLabel: 'chat-composer');

  @override
  void initState() {
    super.initState();
    // TextField 没有 onKeyEvent 参数（CI Flutter 3.38.3 实证编译不过），
    // 挂到它使用的 FocusNode 上：节点级回调先于默认换行插入行为，
    // 返回 handled 即吞掉 Enter 兑现「回车发送」。
    _focus.onKeyEvent = _onKey;
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  /// 桌面端键盘策略（对齐微信 PC 版）：Enter 发送、Shift+Enter 换行。
  /// Flutter 多行 TextField 的 Enter 默认插换行，必须在此拦截才兑现
  /// 「回车发送」；发送中吞掉 Enter 防重复发送。
  /// 仅桌面生效：手机软键盘动作键走 onSubmitted，不拦。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!widget.isDesktop) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final isEnter = event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!isEnter) return KeyEventResult.ignored;
    if (HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored; // Shift+Enter 换行
    }
    if (widget.sending) return KeyEventResult.handled;
    widget.onSendText();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.online && !widget.presend) {
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!widget.online)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: Colors.orange.shade50,
            child: Row(
              children: [
                Icon(Icons.schedule,
                    size: 14, color: Colors.orange.shade800),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '设备离线：现在发送会先排队，设备上线后自动发出',
                    style: TextStyle(
                        fontSize: 12, color: Colors.orange.shade900),
                  ),
                ),
              ],
            ),
          ),
        Container(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: Colors.grey.shade300)),
          ),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.attach_file),
                tooltip: widget.online ? '发送文件/文件夹' : '选择要排队的文件',
                onPressed: widget.sending ? null : widget.onPick,
              ),
              if (widget.onPaste != null && widget.online)
                IconButton(
                  icon: const Icon(Icons.content_paste),
                  tooltip: '粘贴并发送剪贴板文本',
                  onPressed: widget.sending ? null : widget.onPaste,
                ),
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  focusNode: _focus,
                  minLines: 1,
                  // 桌面：最多 4 行（Shift+Enter 换行）；手机：单行 + 动作键发送
                  maxLines: widget.isDesktop ? 4 : 1,
                  textInputAction:
                      widget.isDesktop ? null : TextInputAction.send,
                  onSubmitted:
                      widget.isDesktop ? null : (_) => widget.onSendText(),
                  decoration: InputDecoration(
                    hintText: widget.isDesktop
                        ? 'Enter 发送 · Shift+Enter 换行'
                        : '输入文本…',
                    border: const OutlineInputBorder(),
                    isCollapsed: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                ),
              ),
              // 桌面端发送入口 = Enter / 拖拽（右下角按钮冗余，v1.2.13 去掉）；
              // 手机无物理键盘，保留发送/排队按钮。
              if (!widget.isDesktop) ...[
                const SizedBox(width: 6),
                IconButton(
                  icon: widget.sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(widget.online ? Icons.send : Icons.schedule_send),
                  tooltip: widget.online ? '发送' : '加入待发送队列',
                  onPressed: widget.sending ? null : widget.onSendText,
                ),
              ],
            ],
          ),
        ),
      ],
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

/// 待发送队列项（不参与堆叠分组）。
class _PendingItem extends _ChatItem {
  final PendingSend s;
  _PendingItem(this.s);
  @override
  bool get out => true;
}

/// 待发送气泡：排队的文件/文本，长按可取消。
class _PendingBubble extends StatelessWidget {
  final PendingSend item;
  final VoidCallback onCancel;
  const _PendingBubble({required this.item, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final body = item.kind == 'text'
        ? (item.text ?? '')
        : (item.paths.length == 1
            ? p.basename(item.paths.first)
            : '${item.paths.length} 个文件');
    return Align(
      alignment: Alignment.centerRight,
      child: GestureDetector(
        onLongPress: onCancel,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          constraints: const BoxConstraints(maxWidth: 280),
          decoration: BoxDecoration(
            color: Colors.orange.shade50,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.orange.shade200),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    item.kind == 'text'
                        ? Icons.chat_bubble_outline
                        : Icons.insert_drive_file_outlined,
                    size: 16,
                    color: accent,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      body,
                      style: const TextStyle(fontSize: 14),
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.schedule,
                        size: 11, color: Colors.orange.shade800),
                    const SizedBox(width: 3),
                    Text(
                      '待发送 · 设备上线后自动发出 · 长按取消',
                      style: TextStyle(
                          fontSize: 10, color: Colors.orange.shade800),
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

/// 待发送条目：绝对路径 + 展示/传输用名（目录展开后带相对层级）。
class _SendEntry {
  final String absPath;
  final String relativeName;
  final bool isDir; // 是否由目录展开而来（离线排队拒收目录时提示用）
  const _SendEntry(
      {required this.absPath, required this.relativeName, this.isDir = false});
}
