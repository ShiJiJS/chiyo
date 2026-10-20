#ifndef AGENT_INFO_FOCUS_SNAPSHOT_H_
#define AGENT_INFO_FOCUS_SNAPSHOT_H_

#include <windows.h>
#include <string>
#include <vector>

namespace focused_input {

struct ProcessIdentity {
  DWORD pid = 0;
  unsigned long long created_at = 0;
  std::wstring executable;
};

// Private native identities are for the broker's checks. A future public CLI
// projection must omit handles/runtime IDs; no field value or title is read.
struct FocusSnapshot {
  std::string error;
  HWND foreground = nullptr;
  HWND native_focus = nullptr;
  ProcessIdentity application;
  ProcessIdentity provider;
  std::vector<LONG> runtime_id;
  std::wstring framework;
  int control_type = 0;
  bool password = false;
  bool enabled = false;
  bool keyboard_focus = false;
  bool keyboard_focusable = false;
  bool writable = false;
  bool offscreen = true;
  bool native_focus_in_foreground = false;
  bool automation_in_foreground = false;
  bool stable = false;
  bool modifiers_released = false;
  bool RecognizesPassword() const;
  std::string ToPrivateJson() const;
};

FocusSnapshot CaptureFocus();
std::string JsonString(const std::wstring& value);

}  // namespace focused_input
#endif
