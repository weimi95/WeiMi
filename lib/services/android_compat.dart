import 'dart:io';

/// Android 版本兼容工具（零插件依赖，getprop 直查）。
class AndroidCompat {
  AndroidCompat._();

  static int? _sdk;

  /// Android API level。非 Android 平台或取不到返回 null。
  /// 结果缓存，进程内只查一次。
  static Future<int?> sdkInt() async {
    if (!Platform.isAndroid) return null;
    if (_sdk != null) return _sdk;
    try {
      final r = await Process.run('getprop', ['ro.build.version.sdk']);
      _sdk = int.tryParse(r.stdout.toString().trim());
    } catch (_) {
      // 部分 ROM 禁 shell，兜底 null
    }
    return _sdk;
  }

  /// Android 11（API 30）+ 才有「所有文件访问」(MANAGE_EXTERNAL_STORAGE)。
  /// 低版本走传统 READ/WRITE_EXTERNAL_STORAGE 运行时授权。
  static Future<bool> useManageStorage() async {
    final sdk = await sdkInt();
    return sdk == null || sdk >= 30;
  }
}
