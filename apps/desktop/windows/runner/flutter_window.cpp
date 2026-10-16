#include "flutter_window.h"

#include <optional>
#include <windowsx.h>
#include <flutter/standard_method_codec.h>
#include "resource.h"

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

namespace {
constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kTerminateMessage = WM_APP + 2;
constexpr UINT kTrayId = 1;
constexpr UINT kOpenApprovals = 1;
constexpr UINT kQuit = 2;
}

bool FlutterWindow::AddTrayIcon() {
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = GetHandle();
  data.uID = kTrayId;
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  data.uCallbackMessage = kTrayMessage;
  data.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(data.szTip, L"信息访问授权");
  tray_available_ = Shell_NotifyIconW(NIM_ADD, &data) != FALSE;
  if (tray_available_) {
    data.uVersion = NOTIFYICON_VERSION_4;
    if (!Shell_NotifyIconW(NIM_SETVERSION, &data)) {
      RemoveTrayIcon();
    }
  }
  return tray_available_;
}

void FlutterWindow::RemoveTrayIcon() {
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = GetHandle();
  data.uID = kTrayId;
  Shell_NotifyIconW(NIM_DELETE, &data);
  tray_available_ = false;
}

flutter::EncodableValue FlutterWindow::DesktopAvailability() {
  using flutter::EncodableValue;
  return EncodableValue(flutter::EncodableMap{
      {EncodableValue("tray"), EncodableValue(tray_available_)},
      {EncodableValue("notifications"), EncodableValue(
          !tray_available_ ? "unavailable" : notifications_enabled_ ? "enabled" : "not_enabled")}});
}

void FlutterWindow::SendDesktopEvent(const char* event) {
  if (desktop_ready_ && desktop_channel_) {
    desktop_channel_->InvokeMethod(event, nullptr);
  }
}

void FlutterWindow::OpenApprovals() {
  ShowWindow(GetHandle(), SW_RESTORE);
  SetForegroundWindow(GetHandle());
  SendDesktopEvent("open");
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
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
  backup_files_ = std::make_unique<BackupFileDialogs>(
      flutter_controller_->engine()->messenger(), GetHandle());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  window_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "agent_info_manage/window",
      &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto& method = call.method_name();
    const HWND hwnd = GetHandle();
    if (method == "enableCustomFrame") {
      // Retain WS_OVERLAPPEDWINDOW: the OS still owns resizing and snapping.
      custom_frame_ = true;
      if (!SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
          SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED)) {
        custom_frame_ = false;
        result->Error("frame_unavailable", "Cannot install custom frame.");
        return;
      }
      result->Success(flutter::EncodableValue(IsZoomed(hwnd) != FALSE));
    } else if (method == "minimize") {
      ShowWindow(hwnd, SW_MINIMIZE);
      result->Success();
    } else if (method == "toggleMaximize") {
      ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
      result->Success();
    } else if (method == "drag") {
      result->Success();
      ReleaseCapture();
      POINT cursor{};
      GetCursorPos(&cursor);
      PostMessage(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, MAKELPARAM(cursor.x, cursor.y));
    } else if (method == "close") {
      result->Success();
      PostMessage(hwnd, WM_CLOSE, 0, 0);
    } else {
      result->NotImplemented();
    }
  });
  taskbar_created_ = RegisterWindowMessageW(L"TaskbarCreated");
  desktop_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "agent_info_manage/desktop",
      &flutter::StandardMethodCodec::GetInstance());
  desktop_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto& method = call.method_name();
    if (method == "initialize") {
      if (!desktop_ready_) AddTrayIcon();
      desktop_ready_ = true;
      result->Success(DesktopAvailability());
    } else if (method == "availability") {
      result->Success(DesktopAvailability());
    } else if (method == "enableNotifications") {
      // Classic notification-area balloons do not request OS permission.
      notifications_enabled_ = true;
      result->Success(DesktopAvailability());
    } else if (method == "hide") {
      if (tray_available_) ShowWindow(GetHandle(), SW_HIDE);
      result->Success(flutter::EncodableValue(tray_available_));
    } else if (method == "show") {
      ShowWindow(GetHandle(), SW_RESTORE);
      SetForegroundWindow(GetHandle());
      result->Success();
    } else if (method == "notify" || method == "testNotify") {
      NOTIFYICONDATAW data{};
      data.cbSize = sizeof(data);
      data.hWnd = GetHandle();
      data.uID = kTrayId;
      data.uFlags = NIF_INFO;
      data.dwInfoFlags = NIIF_INFO | NIIF_RESPECT_QUIET_TIME;
      wcscpy_s(data.szInfoTitle, L"信息访问授权");
      wcscpy_s(data.szInfo, method == "testNotify" ? L"这是一条测试通知。访问申请提醒已连接到系统。" : L"有新的访问请求。打开应用查看并审批。");
      const bool accepted = tray_available_ && notifications_enabled_ &&
          Shell_NotifyIconW(NIM_MODIFY, &data) != FALSE;
      result->Success(flutter::EncodableValue(accepted));
    } else if (method == "terminate") {
      result->Success();
      // Destroy only after the channel handler has unwound.
      PostMessage(GetHandle(), kTerminateMessage, 0, 0);
    } else {
      result->NotImplemented();
    }
  });

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
  backup_files_.reset();
  RemoveTrayIcon();
  desktop_ready_ = false;
  desktop_channel_ = nullptr;
  window_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (custom_frame_ && message == WM_NCCALCSIZE && wparam) {
    auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
    const LONG original_top = params->rgrc[0].top;
    // Keep the native sizing borders. Only reclaim the system caption strip.
    const LRESULT result = DefWindowProc(hwnd, message, wparam, lparam);
    const UINT dpi = GetDpiForWindow(hwnd);
    params->rgrc[0].top = original_top +
        GetSystemMetricsForDpi(SM_CYSIZEFRAME, dpi) +
        GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
    return result;
  }
  if (custom_frame_ && message == WM_NCHITTEST) {
    const LRESULT hit = DefWindowProc(hwnd, message, wparam, lparam);
    // Native edges remain resize handles; the Flutter caption owns its controls.
    if (hit == HTCAPTION || hit == HTMINBUTTON || hit == HTMAXBUTTON ||
        hit == HTCLOSE || hit == HTSYSMENU) return HTCLIENT;
    return hit;
  }
  if (custom_frame_ && message == WM_SIZE && window_channel_) {
    window_channel_->InvokeMethod("state",
        std::make_unique<flutter::EncodableValue>(IsZoomed(hwnd) != FALSE));
  }
  if (taskbar_created_ != 0 && message == taskbar_created_ && desktop_ready_) {
    // Explorer restarts lose the old icon. Restore a visible entry or window.
    tray_available_ = false;
    if (!AddTrayIcon()) {
      ShowWindow(hwnd, SW_RESTORE);
    }
    SendDesktopEvent("availability");
    return 0;
  }
  if (message == WM_CLOSE && desktop_ready_) {
    SendDesktopEvent("close");
    return 0;
  }
  if (message == kTerminateMessage) {
    DestroyWindow(hwnd);
    return 0;
  }
  if (message == kTrayMessage) {
    const UINT event = LOWORD(lparam);
    if (event == NIN_SELECT || event == NIN_KEYSELECT || event == NIN_BALLOONUSERCLICK) {
      OpenApprovals();
    } else if (event == WM_CONTEXTMENU) {
      POINT cursor{};
      GetCursorPos(&cursor);
      HMENU menu = CreatePopupMenu();
      AppendMenuW(menu, MF_STRING, kOpenApprovals, L"打开访问审批");
      AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
      AppendMenuW(menu, MF_STRING, kQuit, L"完全退出");
      SetForegroundWindow(hwnd);
      const UINT selected = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY,
          cursor.x, cursor.y, 0, hwnd, nullptr);
      DestroyMenu(menu);
      PostMessage(hwnd, WM_NULL, 0, 0);
      if (selected == kOpenApprovals) OpenApprovals();
      if (selected == kQuit) SendDesktopEvent("quit");
    }
    return 0;
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
