import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'file_operations_service.dart';

/// 系统打开结果分类（替代裸 bool，让调用方能按原因走兜底）
class OpenResult {
  /// 已成功调起系统
  final bool ok;

  /// Android 8+ 装 apk 但用户未授权「安装未知应用」——需引导去设置
  final bool needUnknownSources;

  /// 没有任何 App 能处理该文件（ActivityNotFoundException）
  final bool noApp;

  const OpenResult({
    this.ok = false,
    this.needUnknownSources = false,
    this.noApp = false,
  });
}

/// 用系统默认方式打开文件（内置查看器不支持的格式兜底）。
///
/// - 桌面：Windows `start`、macOS `open`、Linux `xdg-open`
/// - Android：ACTION_VIEW + FileProvider（支持 apk 安装、HEIC 相册等）
class SystemOpenService {
  static const _channel = MethodChannel('com.weimi95.weimi/file_association');

  /// 用系统方式打开本地文件。
  static Future<OpenResult> open(String filePath) async {
    try {
      if (Platform.isAndroid) {
        final r = await _channel.invokeMethod<Map<Object?, Object?>>(
            'openWithSystem', {'path': filePath});
        if (r == null) return const OpenResult();
        return OpenResult(
          ok: r['ok'] == true,
          needUnknownSources: r['needUnknownSources'] == true,
          noApp: r['noApp'] == true,
        );
      }
      if (Platform.isWindows) {
        // start 的第一个引号参数是窗口标题，必须占位
        final r = await Process.run(
          'cmd',
          ['/c', 'start', '', filePath],
          runInShell: false,
        );
        return OpenResult(ok: r.exitCode == 0);
      }
      if (Platform.isMacOS) {
        final r = await Process.run('open', [filePath]);
        return OpenResult(ok: r.exitCode == 0);
      }
      if (Platform.isLinux) {
        final r = await Process.run('xdg-open', [filePath]);
        return OpenResult(ok: r.exitCode == 0);
      }
    } catch (_) {}
    return const OpenResult();
  }

  /// 跳系统「安装未知应用」授权页（Android 8+）
  static Future<bool> openInstallSettings() async {
    try {
      if (Platform.isAndroid) {
        final ok = await _channel.invokeMethod<bool>('openInstallSettings');
        return ok == true;
      }
    } catch (_) {}
    return false;
  }

  /// 「打开方式」系统选择器（打不开时的兜底）
  static Future<bool> openWithChooser(String filePath) async {
    try {
      if (Platform.isAndroid) {
        final ok = await _channel
            .invokeMethod<bool>('openWithChooser', {'path': filePath});
        return ok == true;
      }
      // 桌面等同系统打开
      final r = await open(filePath);
      return r.ok;
    } catch (_) {}
    return false;
  }

  /// 打开失败后的统一兜底（对齐手机/桌面文件管理器的「打开方式」习惯）：
  /// - needUnknownSources：弹引导对话框，一键跳系统「安装未知应用」设置
  /// - 其他失败/无应用：弹「打开方式」底部弹窗（用其他应用打开 / 分享到其他应用）
  static Future<void> handleFailure(
      BuildContext context, String filePath, OpenResult r) async {
    if (r.needUnknownSources) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('允许安装未知应用'),
          content: const Text(
              '首次安装应用需要授权：请在系统设置中为「微密文件」打开「允许安装未知应用」。\n\n'
              '安装包已通过完整性校验，可放心安装。授权后回来重新点击文件即可安装。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('去设置')),
          ],
        ),
      );
      if (go == true) await openInstallSettings();
      return;
    }
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('用其他应用打开'),
              onTap: () => Navigator.pop(ctx, 'chooser'),
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('分享到其他应用'),
              onTap: () => Navigator.pop(ctx, 'share'),
            ),
          ],
        ),
      ),
    );
    if (action == 'chooser') {
      await openWithChooser(filePath);
    } else if (action == 'share') {
      await FileOperationsService.shareFiles([filePath]);
    }
  }
}
