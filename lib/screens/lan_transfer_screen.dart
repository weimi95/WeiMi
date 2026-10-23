import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:qr_flutter/qr_flutter.dart';
import '../services/firewall_service.dart';
import '../services/device_alias_service.dart';
import '../services/landrop_service.dart';
import '../services/lan_transfer_service.dart';
import '../services/localsend_service.dart';
import '../services/pending_send_service.dart';
import '../services/transfer_history_service.dart';
import '../services/trusted_devices_service.dart';
import '../services/daemon_service.dart';
import '../widgets/progress_dialog.dart';
import 'lan_chat_screen.dart';
import 'settings_screen.dart';

/// 微密飞传页（单进程方案）：直接调用本进程 LanTransferService 单例，
/// 不再经 IPC 转发。接收确认通过 service 的 confirmHandler 回调弹窗。
/// 会话列表项：合并历史记录与当前在线设备（顶层类，供 _LanTransferScreenState 使用）。
class _ConvItem {
  final String key;
  final String name;
  final String? preview;
  final DateTime? lastTime;
  final bool online;
  final LanPeer? peer;
  final int count;
  final bool unread;
  const _ConvItem(this.key, this.name, this.preview, this.lastTime,
      this.online, this.peer, this.count, {this.unread = false});
}

class LanTransferScreen extends StatefulWidget {
  final String? initialText;
  final List<String> initialFiles;
  final bool standalone;

  /// 双击 Tab 回顶部的全局信号（main.dart 的 TabBar onDoubleTap 触发）。
  static final ValueNotifier<int> scrollToTopSignal = ValueNotifier(0);

  const LanTransferScreen(
      {super.key,
      this.initialText,
      this.initialFiles = const [],
      this.standalone = true});

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
  bool _fwLdMissing = false; // LANDrop 兼容层规则缺失（UDP/TCP 52637）
  bool _fwBusy = false;
  Timer? _pollTimer;
  String? _pendingText;
  List<String> _pendingFiles = [];
  final ScrollController _listCtl = ScrollController();
  int _lastTopSignal = 0;
  Set<String> _prevOnlineIds = {}; // 上轮在线设备集合（待发送队列的上线沿触发）
  Map<String, String> _aliases = {}; // 设备别名（重命名，id -> alias）

  /// 设备显示名：用户起的别名优先，否则设备广播名（v1.2.13 设备菜单「重命名」）
  String _displayName(LanPeer p) => _aliases[p.id] ?? p.name;

  @override
  void initState() {
    super.initState();
    _lastTopSignal = LanTransferScreen.scrollToTopSignal.value;
    LanTransferScreen.scrollToTopSignal.addListener(_onScrollToTop);
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
  /// 微密飞传规则 / LocalSend / LANDrop 兼容层规则分开查：老用户只装了
  /// 前者，不应被后两者缺失误报（反之同理）。
  Future<void> _checkFirewall() async {
    if (!Platform.isWindows) return;
    final results = await Future.wait([
      FirewallService.rulesPresent(),
      FirewallService.lsRulesPresent(),
      FirewallService.landropRulesPresent(),
    ]);
    if (!mounted) return;
    setState(() {
      _fwMissing = !results[0];
      _fwLsMissing = !results[1];
      _fwLdMissing = !results[2];
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
      _fwLdMissing = !ok;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? '已放行，飞传/LocalSend/LANDrop 可正常收发' : '放行未成功，请点「手动命令」以管理员身份执行'),
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

  /// 网页版二维码（Windows daemon 模式下端口以 daemon 实报为准）。
  Future<void> _showQrDialog() async {
    var port = _selfHttpPort;
    if (Platform.isWindows) {
      try {
        final info = await DaemonService.listPeersInfo();
        final dp = (info?['port'] as int?) ?? 0;
        if (dp >= 1024) port = dp;
      } catch (_) {}
    }
    final ips = _selfIps.isNotEmpty ? _selfIps.take(3) : <String>[_selfIp];
    final urls = ips.where((e) => e.isNotEmpty).map((ip) => 'http://$ip:$port').toList();
    final url = urls.isEmpty ? 'http://$_selfIp:$port' : urls.first;
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('飞传网页版二维码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: () => _showQrFullscreen(url),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: QrImageView(
                  data: url,
                  size: 190,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 12),
            SelectableText(url,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              '手机扫码或浏览器打开，即可发文件/文本给本机\n点二维码可放大，方便手机扫描',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12, color: Colors.grey.shade600),
            ),
            if (urls.length > 1) ...[
              const SizedBox(height: 8),
              Text('其他网卡地址：\n${urls.skip(1).join('\n')}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 11, color: Colors.grey.shade500)),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: url));
              Navigator.pop(ctx);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('网址已复制')));
              }
            },
            child: const Text('复制网址'),
          ),
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }

  /// 全屏大二维码（手机扫电脑屏幕更稳）。
  void _showQrFullscreen(String url) {
    Navigator.of(context, rootNavigator: true).pop();
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        insetPadding: const EdgeInsets.all(36),
        child: GestureDetector(
          onTap: () => Navigator.pop(ctx),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 28),
              QrImageView(data: url, size: 330, backgroundColor: Colors.white),
              const SizedBox(height: 20),
              Text(url,
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.black87)),
              const SizedBox(height: 6),
              const Text('点击任意处返回',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 28),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFirewallCard() {
    final missing = <String>[
      if (_fwMissing) '微密飞传（52345-52365/52346）',
      if (_fwLsMissing) 'LocalSend（53317）',
      if (_fwLdMissing) 'LANDrop（52637）',
    ];
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
                child: Text('Windows 防火墙未放行：${missing.join('、')}',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '当前网络若为「公用」（如手机热点），系统默认拦截所有入站连接，'
                '对端将搜不到本机或发送超时。放行后即可正常互传。',
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
    // 会话列表依赖历史记录（conversations() 同步读内存不触发加载），
    // 轮询首拍先确保磁盘历史已载入，否则启动初期列表只有在线设备，
    // 历史会话要等第一条新消息 add() 才冒出来（2026-10-23 实机故障）
    await TransferHistoryService.instance.ensureLoaded();
    if (!mounted) return;
    final ips = await _svc.localIPv4s();
    if (!mounted) return;
    // LANDrop 兼容层设备按 IP 合并（共享 LandropService.mergeInto，
    // 与聊天窗「活 peer」查找同口径——曾出现列表在线/聊天窗离线的割裂）
    final peers = LandropService.mergeInto(_svc.peers);
    setState(() {
      // 排序兜底：微密设备永远排在 LocalSend / LANDrop 设备前面
      int rank(LanPeer p) =>
          p.protocol == 'weimi' ? 0 : (p.isLocalSend ? 1 : 2);
      peers.sort((a, b) => rank(a).compareTo(rank(b)));
      _peers = peers;
      _webPeers = _svc.webPeers;
      _selfName = _svc.selfName.isEmpty ? '本机' : _svc.selfName;
      _selfIps = ips;
      _selfIp = ips.isEmpty ? '' : ips.first;
      _selfHttpPort = _svc.httpPortActual;
      _selfWebShare = _svc.webShareEnabled;
    });
    unawaited(() async {
      final m = await DeviceAliasService.instance.load();
      if (mounted) setState(() => _aliases = m);
    }());
    // 待发送队列：设备新上线（含启动时已在线的）→ 尝试自动发出排队的文件/文本
    final onlineIds = peers.map((e) => e.id).toSet();
    final newly = onlineIds.difference(_prevOnlineIds);
    _prevOnlineIds = onlineIds;
    if (newly.isNotEmpty && PendingSendService.instance.count > 0) {
      for (final p in peers) {
        if (newly.contains(p.id)) {
          unawaited(PendingSendService.instance.flushFor(p));
        }
      }
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    LanTransferScreen.scrollToTopSignal.removeListener(_onScrollToTop);
    _listCtl.dispose();
    super.dispose();
  }

  /// 双击 Tab → 会话列表滚回顶部。
  void _onScrollToTop() {
    final v = LanTransferScreen.scrollToTopSignal.value;
    if (v == _lastTopSignal) return;
    _lastTopSignal = v;
    if (!_listCtl.hasClients) return;
    _listCtl.animateTo(0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic);
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
                      : (d.isLandrop
                          ? Icons.public
                          : (d.trusted ? Icons.verified_user : Icons.devices)),
                  color: d.isLocalSend
                      ? Colors.blue
                      : (d.isLandrop
                          ? Colors.indigo
                          : (d.trusted ? Colors.green : null)),
                ),
                title: Text(d.name),
                subtitle: Text('${d.ip}:${d.httpPort} · ${_peerProtocolLabel(d)}'),
              ),
            ),
        ],
      ),
    );
  }

  /// 设备协议标注：纯 LocalSend 设备 / 纯 LANDrop 设备 / 微密设备 /
  /// 合并条目（微密+LocalSend / 微密+LANDrop 双链路）。
  String _peerProtocolLabel(LanPeer d) {
    if (d.isLocalSend) return 'LocalSend';
    if (d.isLandrop) return 'LANDrop';
    final links = <String>[];
    if (d.hasLocalSendLink) links.add('LocalSend');
    if (d.hasLandropLink) links.add('LANDrop');
    if (links.isEmpty) return '微密';
    return '微密+${links.join('+')}';
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
    if (peer.isLandrop) {
      // LANDrop v2：filename 支持 '/' 相对路径，文件夹传输保留层级
      await _sendFilesToLandrop(peer, entries);
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

  /// 由 LanPeer（合并条目或纯 LANDrop 条目）构造发送目标
  LandropDevice _landropDeviceOf(LanPeer peer) => LandropDevice(
        publicKey: peer.ldPkB64 ?? peer.id,
        name: peer.name,
        type: '',
        address: peer.ip,
        port: peer.ldPort ?? peer.httpPort,
        lastSeen: peer.lastSeen,
      );

  /// 发送到 LANDrop 设备（v2 协议：握手 → file_send_request → 流式记录）。
  /// 未信任设备：握手成功后立即在进度框显示 6 位 verifCode 供与对方核对。
  Future<void> _sendFilesToLandrop(LanPeer peer, List<_SendEntry> entries) async {
    final device = _landropDeviceOf(peer);
    final files = entries
        .map((e) => LandropSendFile(path: e.absPath, filename: e.relativeName))
        .toList();
    if (mounted) {
      ProgressDialog.show(
        context,
        title: '正在发送（LANDrop）',
        currentProgress: 0,
        totalProgress: entries.length,
        currentFileName: entries.first.relativeName,
      );
    }
    // onProgress 节流：对话框 pop+show 重建代价高，≥400ms 或 ≥8MB 才刷一次
    var lastUi = DateTime.fromMillisecondsSinceEpoch(0);
    var lastSent = -1;
    var verifCode = '';
    final result = await LandropService.instance.sendFilesToDevice(
      device,
      files,
      onVerifCode: (code) {
        verifCode = code;
        if (!mounted) return;
        ProgressDialog.update(
          context,
          title: '正在发送（LANDrop）· 验证码 $code',
          currentProgress: 0,
          totalProgress: entries.length,
          currentFileName: entries.first.relativeName,
        );
      },
      onProgress: (fileName, sent, total) {
        if (!mounted) return;
        final now = DateTime.now();
        if (now.difference(lastUi).inMilliseconds < 400 &&
            sent - lastSent < 8 * 1024 * 1024) {
          return;
        }
        lastUi = now;
        lastSent = sent;
        final codePart = verifCode.isEmpty ? '' : ' · 验证码 $verifCode';
        ProgressDialog.update(
          context,
          title: '正在发送 $fileName'
              '（${(sent / 1048576).toStringAsFixed(1)}/${(total / 1048576).toStringAsFixed(1)} MB）$codePart',
          currentProgress: 0,
          totalProgress: entries.length,
          currentFileName: fileName,
        );
      },
    );
    if (mounted) {
      ProgressDialog.hide(context);
      final msg = result.ok
          ? '发送完成：${entries.length} 个文件（发给 ${peer.name}）'
          : result.rejected
              ? '对方拒收了本次发送（${peer.name}）'
              : '发送失败：${result.error}';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor:
            result.ok ? Colors.green : (result.rejected ? Colors.orange : Colors.red),
        duration: const Duration(seconds: 6),
      ));
    }
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
    if (peer.isLandrop) {
      if (mounted) {
        ProgressDialog.show(
          context,
          title: '正在发送文本（LANDrop）',
          currentProgress: 1,
          totalProgress: 1,
        );
      }
      final result = await LandropService.instance
          .sendTextToDevice(_landropDeviceOf(peer), text);
      if (mounted) {
        ProgressDialog.hide(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(result.ok
              ? '文本已发送给 ${peer.name}'
              : '发送失败：${result.error}'),
          backgroundColor: result.ok ? Colors.green : Colors.red,
        ));
      }
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

  // ============ 其他 UI 动作 ============

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
    if (widget.standalone) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('微密飞传'),
          actions: [
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: '设置',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                );
              },
            ),
          ],
        ),
        body: _buildBody(),
      );
    }
    return _buildBody();
  }

  /// 聊天式会话列表（Flix 风格）：本机卡 + 网页快传固定项 + 按设备聚合的历史会话
  /// （在线设备排在上方并标注在线/离线）+ 网页客户端。点开任意项进入与设备的聊天窗口。
  Widget _buildBody() {
    final convs = TransferHistoryService.instance.conversations();
    // 网页会话统一 key 'web'（_keyOf 已把 'ws_'/网页访客 旧记录归并进来），
    // 单独取出，与在线网页客户端合并成一张卡（v1.2.17 修「多个网页客户端」）
    Conversation? webConv;
    for (final c in convs) {
      if (c.key == 'web') {
        webConv = c;
        break;
      }
    }
    final peerConvs = convs.where((c) => c.key != 'web').toList();
    final convByKey = <String, Conversation>{for (final c in peerConvs) c.key: c};
    final items = <_ConvItem>[];
    LanPeer? webPeer; // 任一在线网页客户端（'ws_'=本机 daemon / 'rweb_'=远端主机）
    for (final p in _peers) {
      if (p.id.startsWith('ws_') || p.id.startsWith('rweb_')) {
        webPeer ??= p;
        continue;
      }
      final c = convByKey.remove(p.id);
      items.add(_ConvItem(p.id, _aliases[p.id] ?? (c?.name ?? p.name),
          c?.preview, c?.lastTime, true, p, c?.count ?? 0,
          unread: c != null &&
              TransferHistoryService.instance.isUnread(p.id, c.lastTime)));
    }
    for (final c in convByKey.values) {
      items.add(_ConvItem(
          c.key, c.name, c.preview, c.lastTime, false, null, c.count,
          unread:
              TransferHistoryService.instance.isUnread(c.key, c.lastTime)));
    }
    // 信任但从未传过文件的设备：离线也保留在列表（已在线的已在 _peers 覆盖；
    // 有历史的已在 convByKey 覆盖），仅补「信任且无记录」的离线设备。
    final covered = <String>{
      for (final p in _peers) p.id,
      ...convByKey.keys,
    };
    for (final t in TrustedDevices.instance.all) {
      if (covered.contains(t.key)) continue;
      items.add(_ConvItem(t.key, t.value, '已信任', null, false, null, 0));
    }
    // 网页传输统一一张会话卡（v1.2.18 起全平台：手机也能直连远端网页客户端；
    // 在线=任一网页客户端连着；点击进 'web' 会话聊天窗）。
    if (webPeer != null || webConv != null) {
      items.add(_ConvItem(
        'web',
        _aliases['web'] ?? webPeer?.name ?? webConv?.name ?? '网页客户端',
        webConv?.preview,
        webConv?.lastTime,
        webPeer != null,
        webPeer,
        webConv?.count ?? 0,
        unread: webConv != null &&
            TransferHistoryService.instance.isUnread('web', webConv.lastTime),
      ));
    }
    // 在线排上方（按协议 rank）；离线按最后活动时间降序
    items.sort((a, b) {
      if (a.online != b.online) return a.online ? -1 : 1;
      if (a.online) {
        int rank(LanPeer? p) =>
            p == null ? 3 : (p.protocol == 'weimi' ? 0 : (p.isLocalSend ? 1 : 2));
        return rank(a.peer).compareTo(rank(b.peer));
      }
      final ta = a.lastTime, tb = b.lastTime;
      if (ta == null && tb == null) return 0;
      if (ta == null) return 1;
      if (tb == null) return -1;
      return tb.compareTo(ta);
    });

    return Stack(
      children: [
        ListView(
          controller: _listCtl,
          padding: const EdgeInsets.all(12),
          children: [
            _buildSelfCard(),
            if (_fwMissing || _fwLsMissing || _fwLdMissing) _buildFirewallCard(),
            const SizedBox(height: 12),
            if (_pendingText != null || _pendingFiles.isNotEmpty) _buildPendingCard(),
            const SizedBox(height: 12),
            _sectionHeader('设备会话（在线 · 历史记录 · 已信任）',
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 20),
                    tooltip: '刷新设备列表',
                    onPressed: _poll,
                  ),
                  IconButton(
                    icon: const Icon(Icons.person_add_alt_1, size: 20),
                    tooltip: '手动添加对端 IP / 网段（跨网段）',
                    onPressed: _showManualPeerDialog,
                  ),
                ])),
            if (items.isEmpty) _emptyHint() else ...items.map(_buildConvTile),
            if (_webPeers.isNotEmpty) ...[
              _sectionHeader('网页客户端（${_webPeers.length}）'),
              ..._webPeers.map(_buildWebPeerTile),
            ],
            const SizedBox(height: 8),
            _buildNote(),
            const SizedBox(height: 80),
          ],
        ),
      ],
    );
  }

  /// 本机卡（v1.2.11 合并原「本机」+「网页快传」两张卡）：
  /// 名称/改名 + 本机 IP + 网页快传网址/复制 + 接收状态一句说明。
  Widget _buildSelfCard() {
    final urls = _webUrls;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
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
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.qr_code_2, size: 20),
                tooltip: '网页版二维码',
                onPressed: _showQrDialog,
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 18),
                tooltip: '复制快传地址',
                onPressed: () {
                  Clipboard.setData(ClipboardData(
                      text: urls.isEmpty
                          ? 'http://$_selfIp:$_selfHttpPort'
                          : urls.join('\n')));
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已复制网页快传地址')));
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '飞传网页版',
            style: TextStyle(
                fontSize: 11,
                color: Colors.grey.shade500,
                fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 2),
          Text(
            urls.isEmpty ? '获取中…' : urls.join('\n'),
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w600, color: Colors.teal),
          ),
          const SizedBox(height: 4),
          Text(
            _selfWebShare
                ? '允许接收文件（托盘常驻）· 同一 WiFi 下用浏览器打开此地址，即可发送文件/文本给本机'
                : '允许接收文件（托盘常驻）· 飞传网页版已在设置中关闭',
            style: TextStyle(
                fontSize: 12,
                color: _selfWebShare ? Colors.grey.shade600 : Colors.orange),
          ),
        ],
      ),
    );
  }

  Widget _buildPendingCard() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.amber.withAlpha(30),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.amber.withAlpha(90)),
      ),
      child: Row(
        children: [
          const Icon(Icons.share_outlined, size: 20, color: Colors.amber),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _pendingText != null
                  ? '待发送文本：${_pendingText!.length > 30 ? '${_pendingText!.substring(0, 30)}…' : _pendingText!}'
                  : '待发送 ${_pendingFiles.length} 个文件，点击下方设备即发送',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
          TextButton(
            onPressed: () => setState(() {
              _pendingText = null;
              _pendingFiles = [];
            }),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String text, {Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade600),
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  Widget _buildConvTile(_ConvItem item) {
    final online = item.online;
    final peer = item.peer;
    final isLs = peer?.isLocalSend ?? false;
    final isLd = peer?.isLandrop ?? false;
    final isWebConv = item.key == 'web';
    // 手机长按 / 桌面右击 → 设备菜单（信任/重命名/删除）；网页会话走专用菜单
    // （重命名存 alias 'web' / 删除记录；信任 ws 会话 id 无意义）
    return GestureDetector(
      onLongPress:
          isWebConv ? _showWebConvMenu : () => _showPeerMenu(item),
      onSecondaryTap:
          isWebConv ? _showWebConvMenu : () => _showPeerMenu(item),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: ListTile(
          leading: Stack(
            children: [
              Icon(
                isLs
                    ? Icons.swap_horiz
                    : (isLd ? Icons.public : Icons.devices),
                color: isLs
                    ? Colors.blue
                    : (isLd ? Colors.indigo : Colors.teal),
              ),
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: 11,
                  height: 11,
                  decoration: BoxDecoration(
                    color: online ? Colors.green : Colors.grey,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                ),
              ),
            ],
          ),
          title: Text(item.name,
              style: const TextStyle(fontWeight: FontWeight.w500)),
          subtitle: Text(
            item.preview ?? (online ? '在线' : '离线'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(online ? '在线' : '离线',
                  style: TextStyle(
                      fontSize: 11,
                      color: online ? Colors.green : Colors.grey)),
              if (item.lastTime != null)
                Text(_fmtTime(item.lastTime!),
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
              if (item.unread)
                Container(
                  margin: const EdgeInsets.only(top: 3),
                  width: 9,
                  height: 9,
                  decoration: const BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                  ),
                ),
            ],
          ),
          onTap: () => _openChat(item),
        ),
      ),
    );
  }

  Widget _buildWebPeerTile(WebPeer w) {
    // 网页客户端同样支持长按（手机）/右击（电脑）菜单：重命名/断开
    return GestureDetector(
      onLongPress: () => _showWebPeerMenu(w),
      onSecondaryTap: () => _showWebPeerMenu(w),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.teal.shade300),
        ),
        child: ListTile(
          leading: const Icon(Icons.language, color: Colors.teal),
          title: Text(_aliases[w.id] ?? w.name,
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
      ),
    );
  }

  Widget _emptyHint() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(Icons.chat_bubble_outline, size: 40, color: Colors.grey.shade400),
          const SizedBox(height: 10),
          Text(
            '还没有聊天记录。\n附近有设备上线时会出现在这里，点开即可收发文件/文本',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }

  Widget _buildNote() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        '说明：发送与接收双方须连接同一 WiFi；接收的文件默认存入「加密文件存放目录」（未设置时存入应用目录）；信任过的设备免确认直接接收。',
        style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
      ),
    );
  }

  /// 手动添加对端 IP / 网段（跨网段方案 A，v1.2.13）。
  /// 交互对齐飞鸽传书「设置 → 系统设置 → 添加网段」：支持整个网段
  /// （IP 前三位）或单个 IP；强调双方都加、网络互通前提。
  Future<void> _showManualPeerDialog() async {
    final controller = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          Future<void> add() async {
            final text = controller.text.trim();
            if (text.isEmpty) return;
            final msg = await _svc.addManualIp(text);
            controller.clear();
            setLocal(() {});
            if (ctx.mounted) {
              ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(msg)));
            }
          }

          return AlertDialog(
            title: const Text('手动添加对端 IP / 网段'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '跨网段（不同路由器 / 网段）时广播发现不可用，添加对方 IP 或网段后改为单播发现：',
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '· 对方网段（推荐）：192.168.2 或 192.168.2.0/24\n'
                    '· 单个 IP：192.168.2.50，可加端口 192.168.2.50:52346',
                    style: const TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '注意：建议双方都添加对方网段，只加一边可能看不到；前提是两个网段网络互通（能 ping 通）。',
                    style: TextStyle(
                        fontSize: 12, color: Colors.orange.shade800),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: controller,
                          autofocus: true,
                          decoration: const InputDecoration(
                            labelText: 'IP 或网段',
                            hintText: '192.168.2 或 192.168.2.50',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          onSubmitted: (_) => add(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(onPressed: add, child: const Text('添加')),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_svc.manualIps.isEmpty)
                    Text('还没有手动添加的条目',
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade500))
                  else ...[
                    Text('已添加（${_svc.manualIps.length}）',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Colors.grey.shade600)),
                    const SizedBox(height: 4),
                    Flexible(
                      child: SizedBox(
                        height: 132,
                        child: ListView(
                          shrinkWrap: true,
                          children: [
                            for (final raw in _svc.manualIps)
                              ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(
                                  LanTransferService.parseManualEntry(raw)
                                              ?.isSubnet ==
                                          true
                                      ? Icons.lan_outlined
                                      : Icons.dns_outlined,
                                  size: 20,
                                ),
                                title: Text(raw, style: const TextStyle(fontSize: 13)),
                                subtitle: Text(
                                  LanTransferService.parseManualEntry(raw)
                                              ?.isSubnet ==
                                          true
                                      ? '网段 · 定向广播发现'
                                      : '单 IP · 单播连接',
                                  style: const TextStyle(fontSize: 11),
                                ),
                                trailing: IconButton(
                                  icon: const Icon(Icons.close, size: 18),
                                  tooltip: '移除',
                                  onPressed: () async {
                                    await _svc.removeManualIp(raw);
                                    setLocal(() {});
                                  },
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  final ctrl = ScaffoldMessenger.of(ctx);
                  final found = <String>[];
                  for (final raw in _svc.manualIps) {
                    final e = LanTransferService.parseManualEntry(raw);
                    if (e == null) continue;
                    found.addAll(await _svc.probeManualEntry(e));
                  }
                  ctrl.showSnackBar(SnackBar(
                    content: Text(found.isEmpty
                        ? '未发现新设备'
                        : '发现：${found.join('、')}'),
                  ));
                },
                child: const Text('立即刷新'),
              ),
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('完成')),
            ],
          );
        },
      ),
    );
    controller.dispose();
  }

  void _openChat(_ConvItem item) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LanChatScreen(
          peer: item.peer,
          peerKey: item.key,
          displayName: item.name,
        ),
      ),
    );
  }

  // ============ 设备菜单（v1.2.13：手机长按 / 电脑右击） ============

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 设备列表项菜单：信任/取消信任、重命名、删除。
  /// 手机长按 / 桌面右击触发（_buildConvTile 的 GestureDetector）。
  Future<void> _showPeerMenu(_ConvItem item) async {
    final peer = item.peer;
    if (peer == null) {
      // 纯历史会话（设备离线且未信任）：仅提供删除记录
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('删除与「${item.name}」的会话'),
          content: const Text('将删除该设备的全部传输记录（不删除已接收的文件）。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('删除', style: TextStyle(color: Colors.red))),
          ],
        ),
      );
      if (ok == true && mounted) {
        final recs =
            await TransferHistoryService.instance.recordsFor(item.key);
        await TransferHistoryService.instance
            .deleteRecords(recs.map((r) => r.id).toList());
        _toast('已删除会话记录');
        _poll();
      }
      return;
    }
    final trusted = TrustedDevices.instance.isTrustedSync(peer.id);
    await showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(_displayName(peer),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(
                  '${peer.ip}:${peer.httpPort} · ${_peerProtocolLabel(peer)}'
                  '${trusted ? ' · 已信任' : ''}'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(trusted
                  ? Icons.shield_outlined
                  : Icons.verified_user_outlined),
              title: Text(trusted ? '取消信任' : '信任此设备'),
              subtitle: Text(trusted ? '取消后对方发送需重新确认' : '信任后免确认直接接收文件/文本'),
              onTap: () {
                Navigator.pop(ctx);
                _toggleTrust(peer, trusted);
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('重命名'),
              subtitle: const Text('别名只影响本机显示，对方无感'),
              onTap: () {
                Navigator.pop(ctx);
                _renamePeer(peer);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: Text('删除设备',
                  style: TextStyle(color: Colors.red.shade700)),
              subtitle: const Text('取消信任、清除别名并删除会话记录'),
              onTap: () {
                Navigator.pop(ctx);
                _deletePeer(peer);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 网页会话菜单（长按/右击「网页客户端」卡）：重命名（alias 存 'web'）/ 删除记录
  Future<void> _showWebConvMenu() async {
    await showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(_aliases['web'] ?? '网页客户端',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text('网页传输会话'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('重命名'),
              onTap: () {
                Navigator.pop(ctx);
                _renameWebConv();
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: Text('删除会话记录',
                  style: TextStyle(color: Colors.red.shade700)),
              subtitle: const Text('删除与网页端的全部传输记录（不删除已接收的文件）'),
              onTap: () async {
                Navigator.pop(ctx);
                final recs =
                    await TransferHistoryService.instance.recordsFor('web');
                await TransferHistoryService.instance
                    .deleteRecords(recs.map((r) => r.id).toList());
                if (!mounted) return;
                _toast('已删除网页会话记录');
                _poll();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _renameWebConv() async {
    final controller = TextEditingController(text: _aliases['web'] ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名网页客户端'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 30,
          decoration: const InputDecoration(
            hintText: '留空恢复默认名称',
            helperText: '别名只影响本机显示，对方无感',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('保存')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || !mounted) return;
    await DeviceAliasService.instance.setAlias('web', name);
    final m = await DeviceAliasService.instance.load();
    if (!mounted) return;
    setState(() => _aliases = m);
    _toast(name.trim().isEmpty ? '已恢复默认名称' : '已重命名为「${name.trim()}」');
  }

  Future<void> _toggleTrust(LanPeer peer, bool trusted) async {
    if (trusted) {
      await TrustedDevices.instance.remove(peer.id);
      _toast('已取消信任「${_displayName(peer)}」');
    } else {
      await TrustedDevices.instance.add(peer.id, peer.name);
      _toast('已信任「${_displayName(peer)}」，之后免确认直接接收');
    }
    _poll();
  }

  Future<void> _renamePeer(LanPeer peer) async {
    final controller = TextEditingController(text: _aliases[peer.id] ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名设备'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 30,
          decoration: const InputDecoration(
            hintText: '留空恢复设备广播的名字',
            helperText: '别名只影响本机显示，对方无感',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('保存')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || !mounted) return;
    await DeviceAliasService.instance.setAlias(peer.id, name);
    final m = await DeviceAliasService.instance.load();
    if (!mounted) return;
    setState(() => _aliases = m);
    _toast(name.trim().isEmpty ? '已恢复默认名称' : '已重命名为「${name.trim()}」');
  }

  Future<void> _deletePeer(LanPeer peer) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除设备'),
        content: Text(
            '将取消信任、清除别名，并删除与「${_displayName(peer)}」的全部会话记录。'
            '设备仍在局域网时下次出现需重新确认。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await TrustedDevices.instance.remove(peer.id);
    await DeviceAliasService.instance.remove(peer.id);
    final recs = await TransferHistoryService.instance.recordsFor(peer.id);
    if (recs.isNotEmpty) {
      await TransferHistoryService.instance
          .deleteRecords(recs.map((r) => r.id).toList());
    }
    _toast('已删除「${_displayName(peer)}」');
    _poll();
  }

  /// 网页客户端菜单（v1.2.13）：重命名 / 断开连接
  Future<void> _showWebPeerMenu(WebPeer w) async {
    await showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(w.name,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('网页客户端 · ${w.ip}'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('重命名'),
              onTap: () {
                Navigator.pop(ctx);
                _renameWebPeer(w);
              },
            ),
            ListTile(
              leading: const Icon(Icons.link_off, color: Colors.red),
              title:
                  Text('断开连接', style: TextStyle(color: Colors.red.shade700)),
              onTap: () {
                Navigator.pop(ctx);
                _svc.removeWebPeer(w);
                _toast('已断开 ${w.name}');
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _renameWebPeer(WebPeer w) async {
    final controller = TextEditingController(text: _aliases[w.id] ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名网页客户端'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 30,
          decoration: const InputDecoration(
            hintText: '留空恢复默认名称',
            helperText: '别名只影响本机显示，对方无感',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('保存')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || !mounted) return;
    await DeviceAliasService.instance.setAlias(w.id, name);
    final m = await DeviceAliasService.instance.load();
    if (!mounted) return;
    setState(() => _aliases = m);
    _toast(name.trim().isEmpty ? '已恢复默认名称' : '已重命名为「${name.trim()}」');
  }

  String _fmtTime(DateTime t) {
    final now = DateTime.now();
    final sameDay =
        t.year == now.year && t.month == now.month && t.day == now.day;
    final hm =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    if (sameDay) return hm;
    return '${t.month}/${t.day} $hm';
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
