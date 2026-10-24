import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../framework/setting_store.dart';

/// 发送文件副本归档（v1.2.24）。
///
/// 背景：手机端选文件走系统选择器（SAF），Android 10+ scoped storage 下
/// file_picker 只能把内容拷到 app cache（/cache/file_picker/<ts>/<name>），
/// 临时路径会被 file_picker/系统清掉 → 聊天记录缩略图丢失、点开报错。
///
/// 方案：发送成功后把 cache 临时文件移进接收目录的「已发送」子目录，
/// 记录 path 指向归档路径——用户不主动删就永久有效。桌面端发送用的是
/// 真实路径（不含 /cache/file_picker/），本服务原样放行。
class SentFileArchiver {
  SentFileArchiver._();

  /// 接收目录 SharedPreferences key（与 LanTransferService._kReceiveDirKey
  /// 同值；独立读取避免服务间循环依赖）。
  static const String _receiveDirKey = 'lan_receive_dir';

  /// 归档子目录名（接收目录下）。
  static const String sentDirName = '已发送';

  /// 副本保留天数设置 key。0=永久保留；默认 30 天。
  static const String _keepDaysKey = 'sent_copy_keep_days';

  static int get keepDays {
    // choice 控件存字符串（'0'/'7'/'30'/'90'），兼容 int
    final v = SettingStore.get(_keepDaysKey, '30');
    return int.tryParse('$v') ?? 30;
  }

  static Future<void> setKeepDays(int days) async {
    await SettingStore.set(_keepDaysKey, '$days');
  }

  /// 是否为 file_picker 临时拷贝路径（仅这类路径需要归档）。
  static bool isTempPickPath(String path) {
    final norm = path.replaceAll('\\', '/');
    return norm.contains('/cache/file_picker/');
  }

  /// 发送成功后调用：把临时文件移进「<接收目录>/已发送」，返回归档路径。
  /// 任何一步失败都原样返回入参（记录退回旧行为：路径可能失效但不再坏）。
  static Future<String> archive(String path) async {
    try {
      if (!isTempPickPath(path)) return path;
      final prefs = await SharedPreferences.getInstance();
      final dir = (prefs.getString(_receiveDirKey) ?? '').trim();
      if (dir.isEmpty) return path;
      final sentDir = Directory(p.join(dir, sentDirName));
      await sentDir.create(recursive: true);
      final name = p.basename(path);
      var target = p.join(sentDir.path, name);
      if (await File(target).exists()) {
        final ts = DateTime.now().millisecondsSinceEpoch;
        final ext = p.extension(name);
        final base = p.basenameWithoutExtension(name);
        target = p.join(sentDir.path, '${base}_$ts$ext');
      }
      try {
        // cache（内部存储）与接收目录（外部存储）多跨分区，rename 会失败
        await File(path).rename(target);
      } catch (_) {
        await File(path).copy(target);
      }
      try {
        final src = File(path);
        if (await src.exists()) await src.delete();
      } catch (_) {}
      return target;
    } catch (_) {
      return path;
    }
  }

  /// 启动/改设置时后台清理过期副本（仅 Android；0=永久保留直接跳过）。
  /// 返回删除的文件数。
  static Future<int> cleanupExpired() async {
    if (!Platform.isAndroid) return 0;
    final days = keepDays;
    if (days <= 0) return 0;
    int removed = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      final dir = (prefs.getString(_receiveDirKey) ?? '').trim();
      if (dir.isEmpty) return;
      final sentDir = Directory(p.join(dir, sentDirName));
      if (!await sentDir.exists()) return;
      final deadline = DateTime.now().subtract(Duration(days: days));
      await for (final e in sentDir.list()) {
        if (e is! File) continue;
        try {
          final st = await e.stat();
          if (st.modified.isBefore(deadline)) {
            await e.delete();
            removed++;
          }
        } catch (_) {}
      }
    } catch (_) {
      // 清理失败静默（不影响主流程）
    }
    if (kDebugMode) {
      debugPrint('[SentFileArchiver] cleanup done (keep=$days days, removed=$removed)');
    }
    return removed;
  }
}
