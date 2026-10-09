import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // 剪贴板文件通道：把文件真复制进系统剪贴板（资源管理器/Finder 可粘贴）
    let channel = FlutterMethodChannel(
      name: "com.weimi95.weimi/clipboard_files",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { (call, result) in
      if call.method == "copyFiles",
         let args = call.arguments as? [String: Any],
         let paths = args["paths"] as? [String] {
        let urls: [NSURL] = paths.map { NSURL(fileURLWithPath: $0) }
        let pb = NSPasteboard.general
        pb.clearContents()
        let ok = pb.writeObjects(urls as [NSPasteboardWriting])
        result(ok)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
