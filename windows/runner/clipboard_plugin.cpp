#include "clipboard_plugin.h"

#include <windows.h>
#include <shlobj.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>
#include <vector>

// 把一组文件路径复制进系统剪贴板（CF_HDROP），资源管理器可直接粘贴。
static bool CopyFilesToClipboard(const std::vector<std::wstring>& paths) {
  if (paths.empty()) return false;
  // 计算宽字符总长（每个路径 + 结尾 \0，再补一个额外 \0）
  size_t totalChars = 0;
  for (const auto& p : paths) totalChars += p.size() + 1;
  totalChars += 1;
  const size_t bytes = sizeof(DROPFILES) + totalChars * sizeof(wchar_t);

  HGLOBAL hMem = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, bytes);
  if (!hMem) return false;
  LPDROPFILES df = static_cast<LPDROPFILES>(GlobalLock(hMem));
  if (!df) {
    GlobalFree(hMem);
    return false;
  }
  df->pFiles = sizeof(DROPFILES);
  df->pt.x = 0;
  df->pt.y = 0;
  df->fNC = FALSE;
  df->fWide = TRUE;
  wchar_t* dst = reinterpret_cast<wchar_t*>(reinterpret_cast<BYTE*>(df) + sizeof(DROPFILES));
  for (const auto& p : paths) {
    wcscpy_s(dst, p.size() + 1, p.c_str());
    dst += p.size() + 1;
  }
  *dst = L'\0';
  GlobalUnlock(hMem);

  if (!OpenClipboard(NULL)) {
    GlobalFree(hMem);
    return false;
  }
  EmptyClipboard();
  HANDLE placed = SetClipboardData(CF_HDROP, hMem);
  CloseClipboard();
  // SetClipboardData 成功后 hMem 归系统所有，不要 GlobalFree
  if (!placed) {
    GlobalFree(hMem);
    return false;
  }
  return true;
}

static std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return std::wstring();
  int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
  std::wstring out(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &out[0], n);
  out.resize(n - 1); // 去掉结尾 \0
  return out;
}

void ClipboardPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar_ref) {
  auto registrar = flutter::PluginRegistrarManager::GetInstance()
                       ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar_ref);

  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "com.weimi95.weimi/clipboard_files",
          &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         auto result) {
        if (call.method_name() != "copyFiles") {
          result->NotImplemented();
          return;
        }
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (!args) {
          result->Error("bad_args", "expected map");
          return;
        }
        auto it = args->find(flutter::EncodableValue("paths"));
        if (it == args->end()) {
          result->Error("bad_args", "missing paths");
          return;
        }
        const auto* list = std::get_if<flutter::EncodableList>(&it->second);
        if (!list) {
          result->Error("bad_args", "paths must be list");
          return;
        }
        std::vector<std::wstring> paths;
        for (const auto& v : *list) {
          const auto* s = std::get_if<std::string>(&v);
          if (s) paths.push_back(Utf8ToWide(*s));
        }
        bool ok = CopyFilesToClipboard(paths);
        result->Success(flutter::EncodableValue(ok));
      });
}
