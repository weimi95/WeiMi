#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "file_association_plugin.h"
#include "clipboard_plugin.h"
#include "resource.h"

namespace {

// 任务栏图标兜底：显式响应 WM_GETICON。
// 类图标（WNDCLASS.hIcon）本身已设置，但插件（window_manager 等）子类化
// 窗口过程后可能干扰 Explorer 的图标查询，导致任务栏显示默认图标。
// 在消息转发给 Flutter/插件之前先行返回应用图标，确保任务栏/标题栏正确。
LRESULT HandleGetIcon(WPARAM wparam) {
  HMODULE module = GetModuleHandle(nullptr);
  if (wparam == ICON_SMALL) {
    HICON small = static_cast<HICON>(LoadImage(
        module, MAKEINTRESOURCE(IDI_APP_ICON), IMAGE_ICON,
        GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON),
        LR_SHARED));
    if (small) {
      return reinterpret_cast<LRESULT>(small);
    }
  }
  HICON icon = LoadIcon(module, MAKEINTRESOURCE(IDI_APP_ICON));
  return icon ? reinterpret_cast<LRESULT>(icon) : 0;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  // 创建即挂窗口图标：任务栏按钮在窗口显示后立即创建，
  // WM_SETICON 保证按钮/缩略图/跳转列表从一开始就拿到应用图标，
  // 不依赖 Explorer 对类图标的回退查询。
  {
    HMODULE module = GetModuleHandle(nullptr);
    HICON icon = LoadIcon(module, MAKEINTRESOURCE(IDI_APP_ICON));
    if (icon) {
      SendMessage(GetHandle(), WM_SETICON, ICON_BIG,
                  reinterpret_cast<LPARAM>(icon));
    }
    HICON small = static_cast<HICON>(LoadImage(
        module, MAKEINTRESOURCE(IDI_APP_ICON), IMAGE_ICON,
        GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON),
        LR_SHARED));
    if (small) {
      SendMessage(GetHandle(), WM_SETICON, ICON_SMALL,
                  reinterpret_cast<LPARAM>(small));
    }
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  
  auto registrar = flutter_controller_->engine()->GetRegistrarForPlugin("FileAssociationPlugin");
  auto plugin_registrar = flutter::PluginRegistrarManager::GetInstance()
      ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  FileAssociationPlugin::RegisterWithRegistrar(plugin_registrar);

  ClipboardPluginRegisterWithRegistrar(
      flutter_controller_->engine()->GetRegistrarForPlugin("ClipboardPlugin"));
  
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // WM_GETICON 先于插件转发处理：确保 Explorer 的任务栏图标查询
  // 永远拿到应用图标（不受任何插件窗口过程子类化影响）。
  if (message == WM_GETICON) {
    return HandleGetIcon(wparam);
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}