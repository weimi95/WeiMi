import Cocoa
import FlutterMacOS
import LocalAuthentication
import Security

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    registerBiometricChannel()
  }

  // ==================== 保险箱生物识别（Touch ID + Keychain）====================
  // 主密码存 Keychain（this-device-only），条目带 biometryCurrentSet 门禁：
  // 读取时系统自动弹 Touch ID，验证通过才解得开。

  private func registerBiometricChannel() {
    guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController else { return }
    let channel = FlutterMethodChannel(
      name: "com.weimi95.weimi/biometric",
      binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "canAuth":
        let ctx = LAContext()
        var err: NSError?
        let ok = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
        result(ok)
      case "hasSavedMaster":
        result(self.keychainHasMaster())
      case "saveMaster":
        let master = (call.arguments as? [String: Any])?["master"] as? String ?? ""
        if master.isEmpty {
          result(["ok": false, "error": "主密码为空"])
        } else {
          DispatchQueue.global(qos: .userInitiated).async {
            if let err = self.saveMasterToKeychain(master) {
              result(["ok": false, "error": err])
            } else {
              result(["ok": true])
            }
          }
        }
      case "loadMaster":
        // 读取会触发系统 Touch ID 授权，放后台线程避免阻塞主线程
        DispatchQueue.global(qos: .userInitiated).async {
          let (master, err) = self.loadMasterFromKeychain()
          if let master = master {
            result(["ok": true, "master": master])
          } else {
            result(["ok": false, "error": err ?? "Touch ID 验证未通过"])
          }
        }
      case "removeMaster":
        result(self.removeMasterFromKeychain())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private var keychainQuery: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: "com.weimi95.weimi.vault",
     kSecAttrAccount as String: "master"]
  }

  private func keychainHasMaster() -> Bool {
    var q = keychainQuery
    q[kSecReturnData as String] = false
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
  }

  /// 保存主密码到钥匙串；返回 nil 成功，否则为可读错误原因
  private func saveMasterToKeychain(_ master: String) -> String? {
    SecItemDelete(keychainQuery as CFDictionary)
    var add = keychainQuery
    add[kSecValueData as String] = master.data(using: .utf8)
    add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    // Touch ID 门禁（macOS 12.3+）；创建失败则降级为普通 Keychain 条目
    var cfError: Unmanaged<CFError>?
    if let ac = SecAccessControlCreateWithFlags(
        kCFAllocatorDefault,
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        .biometryCurrentSet,
        &cfError) {
      add[kSecAttrAccessControl as String] = ac
    }
    let status = SecItemAdd(add as CFDictionary, nil)
    return status == errSecSuccess ? nil : "保存到钥匙串失败（OSStatus \(status)）"
  }

  /// 读取主密码；返回 (明文, nil) 或 (nil, 可读错误原因)
  private func loadMasterFromKeychain() -> (String?, String?) {
    var q = keychainQuery
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var data: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &data)
    if status == errSecSuccess, let d = data as? Data,
       let s = String(data: d, encoding: .utf8) {
      return (s, nil)
    }
    let reason: String
    switch status {
    case errSecItemNotFound: reason = "尚未录入生物识别"
    case errSecAuthFailed, errSecUserCanceled: reason = "验证已取消"
    case errSecInteractionNotAllowed: reason = "Touch ID 不可用"
    default: reason = "读取失败（OSStatus \(status)）"
    }
    return (nil, reason)
  }

  private func removeMasterFromKeychain() -> Bool {
    SecItemDelete(keychainQuery as CFDictionary)
    return true
  }
}
