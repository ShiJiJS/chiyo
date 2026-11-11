#include "flutter_window.h"

#include <flutter/method_result_functions.h>

#include <optional>
#include <windowsx.h>
#include <flutter/standard_method_codec.h>
#include "resource.h"
#include "utils.h"
#include "desktop_instance.h"
#include "focused_fill_identity.h"

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

namespace {
constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kTerminateMessage = WM_APP + 2;
constexpr UINT kOpenApprovals = 1;
constexpr UINT kQuit = 2;

std::optional<flutter::EncodableValue> FocusedFillHelperIdentity() {
  wchar_t path[32768]{};
  const DWORD length = GetModuleFileNameW(nullptr, path, 32768);
  if (length == 0 || length >= 32768) return std::nullopt;
  std::wstring executable(path, length);
  const auto separator = executable.find_last_of(L"\\/");
  if (separator == std::wstring::npos) return std::nullopt;
  executable.resize(separator + 1);
  executable += L"info-focus-broker.exe";
  const auto utf8 = Utf8FromUtf16(executable.c_str());
  if (utf8.empty()) return std::nullopt;
  return flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("executable"), flutter::EncodableValue(utf8)},
      {flutter::EncodableValue("sha256"),
       flutter::EncodableValue(kFocusedFillHelperSha256)},
  });
}
}

bool FlutterWindow::AddTrayIcon() {
  tray_id_ = (tray_id_ + 1) & 0x0fff;
  if (tray_id_ == 0) ++tray_id_;
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = GetHandle();
  data.uID = tray_id_;
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  data.uCallbackMessage = kTrayMessage;
  data.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(data.szTip, L"\u77e5\u4e88");
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
  data.uID = tray_id_;
  Shell_NotifyIconW(NIM_DELETE, &data);
  tray_available_ = false;
}

void FlutterWindow::RemoveNotificationIcon() {
  const UINT id = notification_icon_id_;
  // Retire before the Shell call: deletion can itself produce a late callback.
  notification_icon_id_ = 0;
  if (id == 0) return;
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = GetHandle();
  data.uID = id;
  Shell_NotifyIconW(NIM_DELETE, &data);
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

void FlutterWindow::RequestQuit() {
  if (!desktop_ready_ || !desktop_channel_ || control_state_ == 2) return;
  control_state_ = 2;
  desktop_channel_->InvokeMethod("quit", nullptr,
      std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
          [](const flutter::EncodableValue*) {
            // Success means the normal terminate message was queued. Only the
            // caller's process handle can confirm that the process really ends.
          },
          [this](const std::string&, const std::string&,
                 const flutter::EncodableValue*) { control_state_ = 3; },
          [this]() { control_state_ = 5; }));
}

void FlutterWindow::OpenApprovals(const std::string& request_id) {
  ShowWindow(GetHandle(), SW_RESTORE);
  SetForegroundWindow(GetHandle());
  if (desktop_ready_ && desktop_channel_) {
    desktop_channel_->InvokeMethod("open", !request_id.empty()
        ? std::make_unique<flutter::EncodableValue>(request_id) : nullptr);
  }
}

bool FlutterWindow::ShowNotification(const NotificationMessage& message) {
#ifndef NDEBUG
  ++notification_send_attempts_;
  notification_last_accepted_ = false;
#endif
  if (!tray_available_ || !notifications_enabled_ ||
      notification_icon_id_ != 0 || message.native_id < 0x1000 ||
      message.native_id > 0xffff) return false;
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = GetHandle();
  data.uID = message.native_id;
  // Keep the persistent tray entry unchanged. This hidden, one-notification
  // entry gives every callback an immutable ID, including duplicate timeouts.
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_STATE;
  data.uCallbackMessage = kTrayMessage;
  data.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  data.dwStateMask = NIS_HIDDEN;
  data.dwState = NIS_HIDDEN;
  wcscpy_s(data.szTip, L"\u77e5\u4e88");
  if (!Shell_NotifyIconW(NIM_ADD, &data)) return false;
  notification_icon_id_ = message.native_id;
  data.uVersion = NOTIFYICON_VERSION_4;
  if (!Shell_NotifyIconW(NIM_SETVERSION, &data)) {
    RemoveNotificationIcon();
    return false;
  }
  data.uFlags = NIF_INFO;
  data.dwInfoFlags = NIIF_INFO | NIIF_RESPECT_QUIET_TIME;
  wcscpy_s(data.szInfoTitle, L"\u77e5\u4e88");
  wcscpy_s(data.szInfo, message.test ? L"这是一条测试通知。访问申请提醒已连接到系统。" : L"有新的访问请求。打开应用查看并审批。");
  const bool accepted = Shell_NotifyIconW(NIM_MODIFY, &data) != FALSE;
  if (!accepted) RemoveNotificationIcon();
#ifndef NDEBUG
  notification_last_accepted_ = accepted;
#endif
  return accepted;
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
  pdf_previews_ = std::make_unique<OwnerPdfPreviews>(
      flutter_controller_->engine()->messenger(), GetHandle());
  owner_file_open_ = std::make_unique<OwnerFileOpenChannel>(
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
  control_message_ = RegisterWindowMessageW(L"AgentInfoManage.LocalControl.v1");
  desktop_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "agent_info_manage/desktop",
      &flutter::StandardMethodCodec::GetInstance());
  desktop_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto& method = call.method_name();
    if (method == "focusedFillHelper") {
      if (call.arguments() &&
          !std::holds_alternative<std::monostate>(*call.arguments())) {
        result->Error("invalid_arguments", "No arguments are accepted.");
      } else if (const auto identity = FocusedFillHelperIdentity()) {
        result->Success(*identity);
      } else {
        result->Error("bundle_unavailable", "Application identity unavailable.");
      }
#ifndef NDEBUG
    } else if (method == "notificationDebugState") {
      // Read-only diagnostics for the opt-in live test. There is no event
      // injection or permission change, and no release-channel API.
      using flutter::EncodableValue;
      QUERY_USER_NOTIFICATION_STATE state{};
      const HRESULT query = SHQueryUserNotificationState(&state);
      result->Success(EncodableValue(flutter::EncodableMap{
          {EncodableValue("queryHresult"), EncodableValue(static_cast<int>(query))},
          {EncodableValue("userState"), EncodableValue(static_cast<int>(state))},
          {EncodableValue("trayId"), EncodableValue(static_cast<int>(tray_id_))},
          {EncodableValue("activeNotificationId"), EncodableValue(static_cast<int>(notification_icon_id_))},
          {EncodableValue("sendAttempts"), EncodableValue(notification_send_attempts_)},
          {EncodableValue("lastAccepted"), EncodableValue(notification_last_accepted_)},
          {EncodableValue("shown"), EncodableValue(notification_shown_)},
          {EncodableValue("hidden"), EncodableValue(notification_hidden_)},
          {EncodableValue("timedOut"), EncodableValue(notification_timed_out_)},
          {EncodableValue("clicked"), EncodableValue(notification_clicked_)},
          {EncodableValue("idMismatch"), EncodableValue(notification_id_mismatch_)},
      }));
#endif
    } else if (method == "initialize") {
      if (!desktop_ready_) AddTrayIcon();
      desktop_ready_ = true;
      if (control_state_ == 4) control_state_ = 1;
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
      const auto* request_id = call.arguments() ? std::get_if<std::string>(call.arguments()) : nullptr;
      auto response = std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(std::move(result));
      if (!tray_available_ || !notifications_enabled_) {
        response->Success(flutter::EncodableValue(false));
      } else {
        notifications_.Enqueue({method == "notify" && request_id ? *request_id : "", method == "testNotify"},
            [response](bool accepted) { response->Success(flutter::EncodableValue(accepted)); });
      }
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
  RemoveNotificationIcon();
  notifications_.Reset();
  pdf_previews_.reset();
  owner_file_open_.reset();
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
  if (DesktopInstance::HandleActivation(hwnd, message, wparam, lparam)) {
    SendDesktopEvent("shown");
    return 1;
  }
  if (pdf_previews_ && pdf_previews_->HandleMessage(message)) return 0;
  if (control_message_ != 0 && message == control_message_) {
    if (wparam != GetCurrentProcessId() || (lparam != 0 && lparam != 1)) return 0;
    if (lparam == 1) RequestQuit();
    return control_state_;
  }
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
  if (message == WM_POWERBROADCAST &&
      wparam == PBT_APMRESUMEAUTOMATIC && desktop_ready_) {
    // The automatic event is delivered for unattended wake as well. The later
    // user-activity RESUMESUSPEND event must not trigger a second reconnect.
    // Dart owns connection/identity checks and local registered-copy recovery.
    SendDesktopEvent("resume");
    return TRUE;
  }
  if (taskbar_created_ != 0 && message == taskbar_created_ && desktop_ready_) {
    // Explorer restarts lose the old icon. Restore a visible entry or window.
    tray_available_ = false;
    RemoveNotificationIcon();
    notifications_.Reset();
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
    const UINT callback_id = HIWORD(lparam);
    const bool balloon = event == NIN_BALLOONSHOW || event == NIN_BALLOONHIDE ||
        event == NIN_BALLOONTIMEOUT || event == NIN_BALLOONUSERCLICK;
    if ((balloon && (callback_id == 0 || callback_id != notification_icon_id_)) ||
        (!balloon && callback_id != tray_id_)) {
#ifndef NDEBUG
      if (event == NIN_BALLOONSHOW || event == NIN_BALLOONHIDE ||
          event == NIN_BALLOONTIMEOUT || event == NIN_BALLOONUSERCLICK) {
        ++notification_id_mismatch_;
      }
#endif
      return 0;
    }
    if (event == NIN_BALLOONSHOW) {
#ifndef NDEBUG
      ++notification_shown_;
#endif
      notifications_.OnBalloonEvent(BalloonEvent::shown, callback_id);
    } else if (event == NIN_BALLOONHIDE || event == NIN_BALLOONTIMEOUT) {
#ifndef NDEBUG
      if (event == NIN_BALLOONHIDE) ++notification_hidden_;
      else ++notification_timed_out_;
#endif
      RemoveNotificationIcon();
      notifications_.OnBalloonEvent(event == NIN_BALLOONHIDE ? BalloonEvent::hidden : BalloonEvent::timedOut, callback_id);
    } else if (event == NIN_BALLOONUSERCLICK) {
#ifndef NDEBUG
      ++notification_clicked_;
#endif
      RemoveNotificationIcon();
      const auto clicked = notifications_.OnBalloonEvent(BalloonEvent::clicked, callback_id);
      if (clicked) OpenApprovals(clicked->request_id);
    } else if (event == NIN_SELECT || event == NIN_KEYSELECT) {
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
      if (selected == kQuit) RequestQuit();
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
