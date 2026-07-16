# WeiMi（微密）

开源跨平台文件加密工具。支持任意类型文件加密保护，内置视频/图片/音频/文本/PDF 查看器，加密文件可在输入密码后直接查看，也可解密还原。

### [网盘下载](https://pan.quark.cn/s/355fd17a414b?pwd=GpYp)

已支持：Windows · macOS(arm64) · Linux · Android

## 核心功能

- **加密**：选择任意类型文件，AES-256-GCM 加密，可添加密码提示词
- **解密**：批量解密 .kyl 文件，一次输入密码，自动跳过失败项
- **查看**：加密文件输入密码后直接预览，支持视频/图片/音频/文本/PDF
- **多语言**：中英文自动检测 + 手动切换，记住用户偏好
- **文件关联**：Windows 注册 .kyl 默认打开；Android 通过分享菜单打开

## 技术亮点

- **Rust 加密引擎**：AES-256-GCM 认证加密 + SHA-256 密钥派生，AES-NI 硬件加速
- **零拷贝架构**：文件 I/O 全程在 Rust 侧，消除 FFI 数据拷贝，1GB 文件加密仅 1.5 秒
- **并行处理**：Rayon 多线程 + 流水线并行，动态适配 CPU 核心数
- **流式大文件**：三级分块策略（128MB~256MB/chunk），支持 GB 级文件，无 OOM 风险
- **安全清理**：临时文件自动删除，file_picker 缓存管理，防止数据残留

## 构建

### Windows
```bash
flutter pub get
cd rust_crypto && cargo build --release && cd ..
cp rust_crypto/target/release/rust_crypto.dll .
flutter build windows --release
```

### Android
```bash
# Rust 库有修改时先运行
./build_android_rust.ps1
flutter build apk --release
```

### Linux
```bash
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev fonts-noto-cjk zenity
flutter pub get
cd rust_crypto && cargo build --release && cd ..
cp rust_crypto/target/release/librust_crypto.so .
flutter build linux --release
```

### macOS
```bash
brew install cocoapods && pod setup
rustup target add aarch64-apple-darwin
cd rust_crypto && cargo build --release --target aarch64-apple-darwin && cd ..
flutter pub get && flutter build macos --release
cp rust_crypto/target/aarch64-apple-darwin/release/librust_crypto.dylib build/macos/Build/Products/Release/weimi.app/Contents/Resources/
```

---

## 致谢

本项目基于 [KyrieLock](https://github.com/walkingon/KyrieLock) 修改而来，感谢原作者的优秀工作。
