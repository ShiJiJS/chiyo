#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <shellapi.h>

#include <memory>
#include <string>

#include "win32_window.h"
#include "backup_files.h"
#include "owner_pdf_previews.h"
#include "notification_queue.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  bool AddTrayIcon();
  void RemoveTrayIcon();
  void RemoveNotificationIcon();
  void OpenApprovals(const std::string& request_id = "");
  bool ShowNotification(const NotificationMessage& message);
  void SendDesktopEvent(const char* event);
  void RequestQuit();
  flutter::EncodableValue DesktopAvailability();
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> desktop_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> window_channel_;
  bool custom_frame_ = false;
  bool desktop_ready_ = false;
  UINT control_message_ = 0;
  // Local-control v1: 1 running, 2 quitting, 3 save/close failed, 4 starting,
  // 5 handler unavailable. No pointer or caller data crosses this protocol.
  LRESULT control_state_ = 4;
  bool tray_available_ = false;
  bool notifications_enabled_ = true;
  UINT tray_id_ = 0;
  UINT notification_icon_id_ = 0;
#ifndef NDEBUG
  int notification_send_attempts_ = 0;
  bool notification_last_accepted_ = false;
  int notification_shown_ = 0;
  int notification_hidden_ = 0;
  int notification_timed_out_ = 0;
  int notification_clicked_ = 0;
  int notification_id_mismatch_ = 0;
#endif
  NotificationQueue notifications_{[this](const NotificationMessage& message) {
    return ShowNotification(message);
  }};
  UINT taskbar_created_ = 0;
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<BackupFileDialogs> backup_files_;
  std::unique_ptr<OwnerPdfPreviews> pdf_previews_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
