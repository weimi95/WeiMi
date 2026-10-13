#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "file_association_plugin.h"
#include "clipboard_plugin.h"
#include "resource.h"

namespace {

// Taskbar icon fallback: answer WM_GETICON explicitly.
// The class icon (WNDCLASS.hIcon) is already set, but plugin WndProc
// subclassing (window_manager, system_tray, etc.) can interfere with
// Explorer's icon query, leaving the taskbar showing the default icon.
// Answering before the message is forwarded to Flutter/plugins guarantees
// the taskbar/title bar always receive the application icon.
// IMPORTANT: do not name any local identifier "small" -- <windows.h> (via
// rpcndr.h) performs "#define small char", which corrupts "HICON small = ...".
LRESULT HandleGetIcon(WPARAM wparam) {
  HMODULE module = GetModuleHandle(nullptr);
  if (wparam == ICON_SMALL) {
    HICON small_icon = static_cast<HICON>(LoadImage(
        module, MAKEINTRESOURCE(IDI_APP_ICON), IMAGE_ICON,
        GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON),
        LR_SHARED));
    if (small_icon) {
      return reinterpret_cast<LRESULT>(small_icon);
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

  // Attach the window icon at creation time so the taskbar button / thumbnail
  // / jump list pick up the app icon immediately, without relying on Explorer
  // falling back to the class icon.
  {
    HMODULE module = GetModuleHandle(nullptr);
    HICON icon = LoadIcon(module, MAKEINTRESOURCE(IDI_APP_ICON));
    if (icon) {
      SendMessage(GetHandle(), WM_SETICON, ICON_BIG,
                  reinterpret_cast<LPARAM>(icon));
    }
    HICON small_icon = static_cast<HICON>(LoadImage(
        module, MAKEINTRESOURCE(IDI_APP_ICON), IMAGE_ICON,
        GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON),
        LR_SHARED));
    if (small_icon) {
      SendMessage(GetHandle(), WM_SETICON, ICON_SMALL,
                  reinterpret_cast<LPARAM>(small_icon));
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
  // Handle WM_GETICON before any plugin/Flutter forwarding so Explorer's
  // taskbar icon query always gets the app icon, regardless of WndProc
  // subclassing.
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
