import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'vault_service.dart';

/// 生物识别快捷解锁：
/// - Android：Keystore 门禁密钥（setUserAuthenticationRequired）+ BiometricPrompt
///   加解密主密码（密文存 SharedPreferences）；指纹/人脸通过才解得开。
/// - macOS：Keychain SecAccessControl(biometryCurrentSet) 存主密码，Touch ID 门禁。
/// - Windows / Linux：无（无干净的生物识别门禁 API），返回 false 不显示入口。
class VaultBiometricService {
  VaultBiometricService._();
  static const MethodChannel _channel =
      MethodChannel('com.weimi95.weimi/biometric');

  static bool get platformSupported =>
      Platform.isAndroid || Platform.isMacOS;

  /// 设备支持且已录入生物识别
  static Future<bool> canAuth() async {
    if (!platformSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('canAuth') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 用户开关（与「是否已保存密文」共同决定可用性）
  static Future<bool> isEnabled() async {
    if (!platformSupported) return false;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(VaultService.biometricPrefKey) ?? false;
  }

  static Future<void> setEnabled(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(VaultService.biometricPrefKey, v);
    if (!v) await removeMaster();
  }

  /// 是否已有已保存的主密码密文
  static Future<bool> hasSavedMaster() async {
    if (!platformSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('hasSavedMaster') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 触发生物识别验证，通过后保存主密码。返回是否成功。
  static Future<bool> saveMaster(String master) async {
    if (!platformSupported) return false;
    try {
      return await _channel
              .invokeMethod<bool>('saveMaster', {'master': master}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 触发生物识别验证，通过后返回主密码；失败/取消返回 null。
  static Future<String?> loadMaster() async {
    if (!platformSupported) return null;
    try {
      return await _channel.invokeMethod<String>('loadMaster');
    } catch (_) {
      return null;
    }
  }

  static Future<void> removeMaster() async {
    if (!platformSupported) return;
    try {
      await _channel.invokeMethod('removeMaster');
    } catch (_) {}
  }
}
