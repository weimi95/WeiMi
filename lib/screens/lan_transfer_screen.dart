import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import '../services/firewall_service.dart';
import '../services/lan_transfer_service.dart';
import '../services/localsend_service.dart';
import '../services/transfer_history_service.dart';
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
  List<String> _selfIps = const [];
  int _selfHttpPort = 0;
  bool _selfWebShare = true;
  bool _fwMissing = false; // Windows 防火墙入站规则缺失（微密飞传）
  bool _fwLsMissing = false; // LocalSend 兼容层规则缺失（UDP/TCP 53317）
  bool _fwBusy = false;
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
    // LocalSend 兼容层：打开页面强制扫一轮网段 53317（8s 节流可被 force 绕过）
    LocalSendService.instance.scanOnce(force: true);
    _checkFirewall();
    _startPolling();
  }

  /// Windows：检查防火墙入站规则是否放行（热点/公用网络下默认拦入站，
  /// 会导致对端搜不到本机或发送超时）。只查一次，放行成功后不再提示。
  /// 微密飞传规则与 LocalSend 兼容层规则分开查：老用户只装了前者，
  /// 不应被 LocalSend 缺失误报（反之同理）。
  Future<void> _checkFirewall() async {
    if (!Platform.isWindows) return;
    final results = await Future.wait([
      FirewallService.rulesPresent(),
      FirewallService.lsRulesPresent(),
    ]);
    if (!mounted) return;
    setState(() {
      _fwMissing = !results[0];
      _fwLsMissing = !results[1];
    });
  }

  Future<void> _fixFirewall() async {
    setState(() => _fwBusy = true);
    final ok = await FirewallService.addRules();
    if (!mounted) return;
    setState(() {
      _fwBusy = false;
      _fwMissing = !ok;
      _fwLsMissing = !ok;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? '已放行，飞传/LocalSend 可正常收发' : '放行未成功，请点「手动命令」以管理员身份执行'),
    ));
  }

  void _showFirewallManual() {
    final cmds = FirewallService.manualCommands();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('手动放行命令'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('以管理员身份运行 CMD 后执行以下命令：',
                style: TextStyle(fontSize: 13)),
            const SizedBox(height: 8),
            SelectableText(cmds,
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: cmds));
              Navigator.pop(ctx);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('命令已复制')));
              }
            },
            child: const Text('复制'),
          ),
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }

  /// 网页快传地址列表：多网卡时每个 IP 一条（双网卡场景只有一个可达，
  /// 只显示排序第一的会误导用户）。
  List<String> get _webUrls {
    if (_selfIps.isEmpty) return const [];
    return _selfIps.take(3).map((ip) => 'http://$ip:$_selfHttpPort').toList();
  }

  Widget _buildFirewallCard() {
    final both = _fwMissing && _fwLsMissing;
    final title = both
        ? 'Windows 防火墙未放行飞传/LocalSend'
        : _fwMissing
            ? 'Windows 防火墙未放行飞传'
            : 'Windows 防火墙未放行 LocalSend';
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.orange.withAlpha(25),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.shade700.withAlpha(90)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.shield_outlined, size: 20, color: Colors.orange),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title,
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            both
                ? '当前网络若为「公用」（如手机热点），系统默认拦截所有入站连接，'
                    '对端将搜不到本机或发送超时。放行后即可正常互传。'
                    '（微密飞传 52345-52365/52346 + LocalSend 53317）'
                : _fwMissing
                    ? '当前网络若为「公用」（如手机热点），系统默认拦截所有入站连接，'
                        '对端将搜不到本机或发送超时。放行后即可正常互传。'
                    : '与 LocalSend App 互传需要放行 53317 端口（组播发现 + HTTP 传输），'
                        '否则对端搜不到本机或发送失败。',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _fwBusy ? null : _fixFirewall,
                icon: const Icon(Icons.lock_open, size: 18),
                label: Text(_fwBusy ? '等待授权…' : '一键放行'),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: _showFirewallManual,
                child: const Text('手动命令'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _poll();
    _pollTimer =
        Timer.periodic(const Duration(milliseconds: 1500), (_) => _poll());
  }

  Future<void> _poll() async {
    if (!mounted) return;
    final ips = await _svc.localIPv4s();
    if (!mounted) return;
    setState(() {
      _peers = _svc.peers;
      _webPeers = _svc.webPeers;
      _selfName = _svc.selfName.isEmpty ? '本机' : _svc.selfName;
      _selfIps = ips;
      _selfIp = ips.isEmpty ? '' : ips.first;
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
                  d.isLocalSend
                      ? Icons.swap_horiz
                      : (d.trusted ? Icons.verified_user : Icons.devices),
                  color: d.isLocalSend
                          ? Colors.blue
                          : (d.trusted ? Colors.green : null),
                ),
                title: Text(d.name),
                subtitle: Text('${d.ip} · ${_peerProtocolLabel(d)}'),
              ),
            ),
        ],
      ),
    );
  }

  /// 设备协议标注：纯 LocalSend 设备 / 微密设备 / 合并条目（微密+LocalSend 双链路）。
  String _peerProtocolLabel(LanPeer d) {
    if (d.isLocalSend) return ' · LocalSend';
    if (d.hasLocalSendLink) return ' · 微密+LocalSend';
    return '';
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

  /// 发送文件夹（仅微密设备：自研协议按相对路径落盘，保留目录结构）。
  Future<void> _startSendFolderTo(LanPeer peer) async {
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择要发送的文件夹',
    );
    if (dir == null || dir.isEmpty || !mounted) return;
    await _sendFilesTo(peer, [dir]);
  }

  Future<void> _sendFilesTo(LanPeer peer, List<String> files) async {
    // 展开：目录递归成「相对路径」条目（v1.0.68 文件夹传输，仅自研协议支持），
    // 单文件保持 basename。folderTop 非空 = 该条目属于某个顶层目录。
    final entries = <_SendEntry>[];
    for (final f in files) {
      if (FileSystemEntity.isDirectorySync(f)) {
        final top = p.basename(f);
        await for (final e in Directory(f).list(recursive: true, followLinks: false)) {
          if (e is! File) continue;
          final rel = p.relative(e.path, from: f).replaceAll('\\', '/');
          entries.add(_SendEntry(e.path, '$top/$rel', top));
        }
      } else {
        entries.add(_SendEntry(f, p.basename(f), null));
      }
    }
    if (entries.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('没有可发送的文件'),
        ));
      }
      return;
    }
    if (peer.isLocalSend) {
      // LocalSend v2 协议只有文件没有目录概念：含目录时拒绝并说明
      if (entries.any((e) => e.folderTop != null)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('LocalSend 设备不支持文件夹发送（协议无目录概念），'
                '请仅选择文件，或改用微密设备'),
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 5),
          ));
        }
        return;
      }
      await _sendFilesToLocalSend(peer, files);
      return;
    }
    int okCount = 0;
    int failCount = 0;
    final folderBytes = <String, int>{};
    final folderFails = <String, int>{};
    for (int i = 0; i < entries.length; i++) {
      final e = entries[i];
      if (mounted) {
        if (i == 0) {
          ProgressDialog.show(
            context,
            title: '正在发送',
            currentProgress: i,
            totalProgress: entries.length,
            currentFileName: e.relativeName,
          );
        } else {
          ProgressDialog.update(
            context,
            title: '正在发送',
            currentProgress: i,
            totalProgress: entries.length,
            currentFileName: e.relativeName,
          );
        }
      }

      final ok = await _svc.sendFile(
        peer: peer,
        filePath: e.absPath,
        relativeName: e.relativeName,
        // 目录内文件由调用方按目录汇总记账，避免记录被文件数量刷爆
        recordHistory: e.folderTop == null,
      );
      if (ok) {
        okCount++;
      } else {
        failCount++;
      }
      if (e.folderTop != null) {
        final top = e.folderTop!;
        if (ok) {
          try {
            folderBytes[top] = (folderBytes[top] ?? 0) + await File(e.absPath).length();
          } catch (_) {}
        } else {
          folderFails[top] = (folderFails[top] ?? 0) + 1;
        }
      }
    }

    // 每个顶层目录记一条 folder 记录（传输页/历史按 kind 渲染，不参与文件操作）
    for (final top in folderBytes.keys) {
      await TransferHistoryService.instance.add(TransferRecord(
        id: '${DateTime.now().microsecondsSinceEpoch}_out',
        kind: 'folder',
        direction: 'out',
        name: top,
        size: folderBytes[top]!,
        peerName: peer.name,
        time: DateTime.now(),
        ok: (folderFails[top] ?? 0) == 0,
        note: (folderFails[top] ?? 0) > 0 ? '${folderFails[top]} 个文件失败' : null,
      ));
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

  /// 发送到 LocalSend 设备（v2 协议：send-request → 逐个 upload）
  Future<void> _sendFilesToLocalSend(LanPeer peer, List<String> files) async {
    if (mounted) {
      ProgressDialog.show(
        context,
        title: '正在发送（LocalSend）',
        currentProgress: 0,
        totalProgress: files.length,
        currentFileName: p.basename(files.first),
      );
    }
    // onProgress 节流：对话框 pop+show 重建代价高，≥400ms 或 ≥32MB 才刷一次
    var lastUi = DateTime.fromMillisecondsSinceEpoch(0);
    var lastSent = 0;
    final ok = await LocalSendService.instance.sendFiles(
      peer: peer,
      filePaths: files,
      onProgress: (fileName, sent, total) {
        if (!mounted) return;
        final now = DateTime.now();
        if (now.difference(lastUi).inMilliseconds < 400 &&
            sent - lastSent < 32 * 1024 * 1024) {
          return;
        }
        lastUi = now;
        lastSent = sent;
        ProgressDialog.update(
          context,
          title: '正在发送 $fileName'
              '（${(sent / 1048576).toStringAsFixed(1)}/${(total / 1048576).toStringAsFixed(1)} MB）',
          currentProgress: 0,
          totalProgress: files.length,
          currentFileName: fileName,
        );
      },
    );
    if (mounted) {
      ProgressDialog.hide(context);
      final detail = ok < files.length && LocalSendService.instance.lastError.isNotEmpty
          ? '\n失败原因：${LocalSendService.instance.lastError}'
          : '';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('发送完成：成功 $ok / ${files.length}（发给 ${peer.name}）$detail'),
        backgroundColor: ok == files.length ? Colors.green : Colors.orange,
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
    if (peer.isLocalSend) {
      // LocalSend v2 协议无文本消息类型，只有文件传输
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('LocalSend 设备只支持文件发送，不支持文本'),
        backgroundColor: Colors.orange,
      ));
      return;
    }
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
                Text(
                  _selfIps.isEmpty ? '本机 IP：获取中…' : '本机 IP：${_selfIps.join('、')}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
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
          // Windows 防火墙未放行警示（热点/公用网络下默认拦所有入站，
          // 对端会搜不到本机或发送超时）
          if (_fwMissing || _fwLsMissing) _buildFirewallCard(),
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
                      child: Text('微密飞传-网页版',
                          style: TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 15)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 18),
                      tooltip: '复制地址',
                      onPressed: () {
                        final urls = _webUrls;
                        Clipboard.setData(ClipboardData(
                            text: urls.isEmpty
                                ? 'http://$_selfIp:$_selfHttpPort'
                                : urls.join('\n')));
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已复制网页快传地址')));
                      },
                    ),
                  ],
                ),
                Text(
                  _webUrls.isEmpty ? 'http://…' : _webUrls.join('\n'),
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.teal),
                ),
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
              final isLs = d.isLocalSend;
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: trusted
                          ? Colors.green.shade300
                          : (isLs ? Colors.blue.shade200 : Colors.grey.shade300)),
                ),
                child: ListTile(
                  leading: Icon(
                    isLs
                        ? Icons.swap_horiz
                        : (trusted ? Icons.verified_user : Icons.devices),
                    color: isLs
                        ? Colors.blue
                        : (trusted ? Colors.green : Colors.teal),
                  ),
                  title: Text(d.name,
                      style: const TextStyle(fontWeight: FontWeight.w500)),
                  subtitle: Text(
                      '${d.ip}:${d.httpPort}'
                      '${_peerProtocolLabel(d)}'
                      '${trusted ? ' · 已信任' : ''}',
                      style: const TextStyle(fontSize: 12)),
                  trailing: PopupMenuButton<String>(
                    icon: const Icon(Icons.more_horiz, size: 20),
                    onSelected: (v) {
                      if (v == 'send_file') {
                        _startSendFilesTo(d);
                      } else if (v == 'send_folder') {
                        _startSendFolderTo(d);
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
                      // 文件夹发送：仅微密设备（自研协议支持目录层级，
                      // LocalSend v2 协议无目录概念）
                      if (!isLs)
                        const PopupMenuItem(
                            value: 'send_folder',
                            child: Row(children: [
                              Icon(Icons.folder_outlined, size: 18),
                              SizedBox(width: 8),
                              Text('发送文件夹'),
                            ])),
                      // LocalSend 设备不支持文本/信任体系（协议无文本消息，
                      // 信任是微密设备 ID 概念）
                      if (!isLs)
                        const PopupMenuItem(
                            value: 'send_text',
                            child: Row(children: [
                              Icon(Icons.chat_bubble_outline, size: 18),
                              SizedBox(width: 8),
                              Text('发送文本'),
                            ])),
                      if (!isLs)
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

/// 发送条目：绝对路径 + 对端相对名（文件夹传输）+ 所属顶层目录（汇总记账用）。
class _SendEntry {
  final String absPath;
  final String relativeName;
  final String? folderTop;
  const _SendEntry(this.absPath, this.relativeName, this.folderTop);
}
