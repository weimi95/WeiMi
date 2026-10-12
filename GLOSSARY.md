# GLOSSARY - 微密文件（WeiMi File）

> 只放「词 → 紧定义」两栏，不放实现细节。

| 术语 | 定义 |
|------|------|
| 方案A | Windows 缩略图实现路线一：FFI 调 `SHGetFileInfo` 拿「文件关联图标」（PSD 显示 PS logo），拿不到内容画面。已落地于 `lib/services/windows_system_icon.dart`。 |
| 方案B | Windows 缩略图实现路线二：FFI 调 COM `IThumbnailProvider` 拿「真内容缩略图」（PSD 画面、视频首帧）。依赖系统装了对应缩略图提供程序（如 PSD 需装 Photoshop 或解码包），失败需回退。 |
| 三级回退链 | 方案B 失败 → 方案A 系统图标 → Flutter 通用类型图标的兜底顺序。 |
