import 'dart:io';

/// Windows 防火墙入站放行助手（仅 Windows 有效，其他平台一律返回 true）。
///
/// 背景：飞传的 UDP 发现（52346）与 HTTP 传输（52345-52365）都要求对端能
/// 入站连本机。电脑连手机热点等场景下 Windows 把网络识别为「公用」，
/// Defender 防火墙默认拦截所有入站连接——表现为对端发送超时、互相发现
/// 不了（Landrop 等能通是因为其规则覆盖所有网络配置文件）。
///
/// 规则按端口创建（不按程序路径），同时覆盖 weimi.exe 与托盘态
/// weimi_daemon.exe；profile=any 保证公用/专用网络下都放行。
///
/// 注意（实测）：netsh 经 argv 调用时引号会被 CreateProcess 转码弄丢，
/// `name="带空格的名字"` 会直接报「指定的值无效」——规则名必须用不带
/// 空格的单词，查询时也不加引号。
class FirewallService {
  FirewallService._();

  static const String _tcpRule = 'WeiMiFileLANTCP';
  static const String _udpRule = 'WeiMiFileLANUDP';
  /// LocalSend v2 兼容层（组播发现 UDP + HTTP 53317）的入站规则
  static const String _lsRule = 'WeiMiFileLSLAN';
  static const String _lsTcpRule = 'WeiMiFileLSTCP';
  /// LANDrop v2 兼容层（UDP 52637 发现 + TCP 52637 加密传输）的入站规则
  static const String _ldRule = 'WeiMiFileLANDROP';
  static const String _ldUdpRule = 'WeiMiFileLANDROPUDP';

  /// 会话内缓存：已放行就不再查（netsh 查询虽快，也不必每分钟跑）。
  static bool? _cachedOk;
  static bool? _cachedLsOk;
  static bool? _cachedLdOk;

  static bool get supported => Platform.isWindows;

  /// 主飞传入站规则是否都在（只读查询，不需要管理员权限）。
  /// 只含 UDP 52346 + TCP 52345-52365；LocalSend 规则单独查（见
  /// lsRulesPresent）——避免没装过 LocalSend 兼容版的用户被误报缺失。
  static Future<bool> rulesPresent() async {
    if (!supported) return true;
    if (_cachedOk == true) return true;
    final tcp = await _ruleExists(_tcpRule);
    final udp = await _ruleExists(_udpRule);
    final ok = tcp && udp;
    if (ok) _cachedOk = true;
    return ok;
  }

  /// LocalSend 兼容层规则是否都在（UDP 53317 组播 + TCP 53317）。
  static Future<bool> lsRulesPresent() async {
    if (!supported) return true;
    if (_cachedLsOk == true) return true;
    final udp = await _ruleExists(_lsRule);
    final tcp = await _ruleExists(_lsTcpRule);
    final ok = udp && tcp;
    if (ok) _cachedLsOk = true;
    return ok;
  }

  /// LANDrop 兼容层规则是否都在（UDP 52637 发现 + TCP 52637 传输）。
  static Future<bool> landropRulesPresent() async {
    if (!supported) return true;
    if (_cachedLdOk == true) return true;
    final udp = await _ruleExists(_ldUdpRule);
    final tcp = await _ruleExists(_ldRule);
    final ok = udp && tcp;
    if (ok) _cachedLdOk = true;
    return ok;
  }

  static Future<bool> _ruleExists(String name) async {
    try {
      final r = await Process.run(
        'netsh',
        ['advfirewall', 'firewall', 'show', 'rule', 'name=$name'],
        stdoutEncoding: null,
        stderrEncoding: null,
      );
      if (r.exitCode != 0) return false;
      // 输出按系统 ANSI 代码页（中文 Windows 为 GBK），按 latin1 解码后
      // 搜 ASCII 规则名即可，与界面语言无关。
      final out = String.fromCharCodes(r.stdout as List<int>);
      return out.contains(name);
    } catch (_) {
      return false;
    }
  }

  /// 触发一次 UAC 授权，添加入站规则。返回是否复查确认成功
  /// （UAC 是用户交互，无法直接拿退出码，只能加完再查；用户点授权可能
  /// 要几十秒，轮询等待）。
  static Future<bool> addRules() async {
    if (!supported) return true;
    final inner =
        'netsh advfirewall firewall add rule name=$_tcpRule dir=in action=allow '
        'protocol=TCP localport=52345-52365 profile=any; '
        'netsh advfirewall firewall add rule name=$_udpRule dir=in action=allow '
        'protocol=UDP localport=52346 profile=any; '
        'netsh advfirewall firewall add rule name=$_lsRule dir=in action=allow '
        'protocol=UDP localport=53317 profile=any; '
        'netsh advfirewall firewall add rule name=$_lsTcpRule dir=in action=allow '
        'protocol=TCP localport=53317 profile=any; '
        'netsh advfirewall firewall add rule name=$_ldUdpRule dir=in action=allow '
        'protocol=UDP localport=52637 profile=any; '
        'netsh advfirewall firewall add rule name=$_ldRule dir=in action=allow '
        'protocol=TCP localport=52637 profile=any';
    try {
      await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-Command',
          'Start-Process powershell -Verb runas -WindowStyle Hidden '
              '-ArgumentList \'-NoProfile\',\'-Command\',\'$inner\'',
        ],
        stdoutEncoding: null,
        stderrEncoding: null,
      );
    } catch (_) {}
    // Start-Process 不等子进程，UAC 框由用户掌控；轮询复查最多约 30 秒
    for (var i = 0; i < 20; i++) {
      await Future.delayed(const Duration(milliseconds: 1500));
      final ok = await rulesPresent();
      final lsOk = await lsRulesPresent();
      final ldOk = await landropRulesPresent();
      if (ok && lsOk && ldOk) {
        _cachedOk = true;
        _cachedLsOk = true;
        _cachedLdOk = true;
        return true;
      }
    }
    return false;
  }

  /// 手动放行命令文本（给「一键放行」失败或不愿点 UAC 的用户）。
  static String manualCommands() =>
      'netsh advfirewall firewall add rule name=$_tcpRule dir=in action=allow '
      'protocol=TCP localport=52345-52365 profile=any\n'
      'netsh advfirewall firewall add rule name=$_udpRule dir=in action=allow '
      'protocol=UDP localport=52346 profile=any\n'
      'netsh advfirewall firewall add rule name=$_lsRule dir=in action=allow '
      'protocol=UDP localport=53317 profile=any\n'
      'netsh advfirewall firewall add rule name=$_lsTcpRule dir=in action=allow '
      'protocol=TCP localport=53317 profile=any\n'
      'netsh advfirewall firewall add rule name=$_ldUdpRule dir=in action=allow '
      'protocol=UDP localport=52637 profile=any\n'
      'netsh advfirewall firewall add rule name=$_ldRule dir=in action=allow '
      'protocol=TCP localport=52637 profile=any';
}
