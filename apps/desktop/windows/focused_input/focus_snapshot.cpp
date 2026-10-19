#include "focus_snapshot.h"
#include <UIAutomation.h>
#include <wrl/client.h>
#include <wtsapi32.h>
#include <sstream>

namespace focused_input {
namespace {
using Microsoft::WRL::ComPtr;

bool Identity(DWORD pid, ProcessIdentity* result) {
  const HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (process == nullptr) return false;
  FILETIME created{}, exited{}, kernel{}, user{};
  std::wstring path(32768, L'\0');
  DWORD length = static_cast<DWORD>(path.size());
  const bool ok = GetProcessTimes(process, &created, &exited, &kernel, &user) != 0 &&
      QueryFullProcessImageNameW(process, 0, path.data(), &length) != 0;
  CloseHandle(process);
  if (!ok) return false;
  path.resize(length);
  result->pid = pid;
  result->created_at = (static_cast<unsigned long long>(created.dwHighDateTime) << 32) |
      created.dwLowDateTime;
  result->executable = path;
  return true;
}

std::vector<LONG> RuntimeId(IUIAutomationElement* element) {
  SAFEARRAY* array = nullptr;
  std::vector<LONG> result;
  if (FAILED(element->GetRuntimeId(&array)) || array == nullptr) return result;
  LONG first = 0, last = -1;
  if (SafeArrayGetDim(array) == 1 &&
      SUCCEEDED(SafeArrayGetLBound(array, 1, &first)) &&
      SUCCEEDED(SafeArrayGetUBound(array, 1, &last)) &&
      last >= first && last - first < 128) {
    for (LONG index = first; index <= last; ++index) {
      LONG value = 0;
      if (FAILED(SafeArrayGetElement(array, &index, &value))) { result.clear(); break; }
      result.push_back(value);
    }
  }
  SafeArrayDestroy(array);
  return result;
}

std::string Bool(bool value) { return value ? "true" : "false"; }
std::string ProcessJson(const ProcessIdentity& value) {
  std::ostringstream out;
  out << "{\"pid\":" << value.pid << ",\"createdAt\":\"" << value.created_at
      << "\",\"executable\":" << JsonString(value.executable) << "}";
  return out.str();
}
}  // namespace

std::string JsonString(const std::wstring& value) {
  if (value.empty()) return "\"\"";
  const int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (length <= 0) return "null";
  std::string text(static_cast<size_t>(length), '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), text.data(), length, nullptr, nullptr);
  std::ostringstream out;
  out << '"';
  const char* digits = "0123456789abcdef";
  for (const unsigned char c : text) {
    if (c == '"' || c == '\\') out << '\\' << c;
    else if (c < 0x20) out << "\\u00" << digits[c >> 4] << digits[c & 15];
    else out << c;
  }
  out << '"';
  return out.str();
}

bool FocusSnapshot::RecognizesPassword() const {
  return error.empty() && foreground != nullptr && native_focus != nullptr &&
      application.pid != 0 && application.created_at != 0 && !application.executable.empty() &&
      provider.pid != 0 && provider.created_at != 0 && !provider.executable.empty() &&
      password && enabled && keyboard_focus &&
      keyboard_focusable && writable && control_type == UIA_EditControlTypeId &&
      !offscreen && native_focus_in_foreground &&
      automation_in_foreground && stable && modifiers_released && !runtime_id.empty();
}

FocusSnapshot CaptureFocus() {
  FocusSnapshot result;
  // An in-app browser may report DOM focus while Windows is locked. The input
  // desktop may still be named Default then, so check the session as well.
  DWORD session = 0;
  LPWSTR buffer = nullptr;
  DWORD bytes = 0;
  if (!ProcessIdToSessionId(GetCurrentProcessId(), &session) ||
      !WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE, session,
          WTSSessionInfoEx, &buffer, &bytes)) {
    result.error = "session_unavailable"; return result;
  }
  const auto* status = reinterpret_cast<const WTSINFOEXW*>(buffer);
  const bool valid = bytes >= sizeof(WTSINFOEXW) && status->Level == 1;
  const bool active = valid && status->Data.WTSInfoExLevel1.SessionState == WTSActive;
  const bool unlocked = valid && status->Data.WTSInfoExLevel1.SessionFlags == WTS_SESSIONSTATE_UNLOCK;
  const bool locked = valid && status->Data.WTSInfoExLevel1.SessionFlags == WTS_SESSIONSTATE_LOCK;
  WTSFreeMemory(buffer);
  if (!active || !unlocked) {
    result.error = locked ? "desktop_locked" : "session_unavailable";
    return result;
  }
  const HDESK desktop = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
  if (desktop == nullptr) { result.error = "desktop_unavailable"; return result; }
  wchar_t desktop_name[256]{};
  DWORD needed = 0;
  const bool ordinary = GetUserObjectInformationW(desktop, UOI_NAME, desktop_name,
      sizeof(desktop_name), &needed) != 0 && std::wstring(desktop_name) == L"Default";
  CloseDesktop(desktop);
  if (!ordinary) { result.error = "unsupported_desktop"; return result; }
  result.foreground = GetForegroundWindow();
  DWORD pid = 0;
  const DWORD thread = GetWindowThreadProcessId(result.foreground, &pid);
  if (thread == 0 || !Identity(pid, &result.application)) {
    result.error = "application_unavailable"; return result;
  }
  GUITHREADINFO info{}; info.cbSize = sizeof(info);
  if (!GetGUIThreadInfo(thread, &info)) { result.error = "focus_unavailable"; return result; }
  result.native_focus = info.hwndFocus;
  result.native_focus_in_foreground = info.hwndFocus != nullptr &&
      GetAncestor(info.hwndFocus, GA_ROOT) == result.foreground;
  result.modifiers_released = true;
  for (const int key : {VK_SHIFT, VK_CONTROL, VK_MENU, VK_LWIN, VK_RWIN}) {
    if ((GetAsyncKeyState(key) & 0x8000) != 0) result.modifiers_released = false;
  }
  ComPtr<IUIAutomation> automation;
  if (FAILED(CoCreateInstance(__uuidof(CUIAutomation), nullptr, CLSCTX_INPROC_SERVER,
      IID_PPV_ARGS(&automation)))) { result.error = "automation_unavailable"; return result; }
  ComPtr<IUIAutomationElement> element;
  if (FAILED(automation->GetFocusedElement(&element)) || element == nullptr) {
    result.error = "control_unavailable"; return result;
  }
  int provider = 0;
  BOOL password = FALSE, enabled = FALSE, focus = FALSE, focusable = FALSE, offscreen = TRUE;
  BSTR framework = nullptr;
  const bool properties = SUCCEEDED(element->get_CurrentProcessId(&provider)) &&
      SUCCEEDED(element->get_CurrentIsPassword(&password)) &&
      SUCCEEDED(element->get_CurrentIsEnabled(&enabled)) &&
      SUCCEEDED(element->get_CurrentHasKeyboardFocus(&focus)) &&
      SUCCEEDED(element->get_CurrentIsKeyboardFocusable(&focusable)) &&
      SUCCEEDED(element->get_CurrentIsOffscreen(&offscreen)) &&
      SUCCEEDED(element->get_CurrentControlType(&result.control_type)) &&
      SUCCEEDED(element->get_CurrentFrameworkId(&framework));
  if (framework != nullptr) { result.framework.assign(framework, SysStringLen(framework)); SysFreeString(framework); }
  if (!properties || provider <= 0 || !Identity(static_cast<DWORD>(provider), &result.provider)) {
    result.error = "control_properties_unavailable"; return result;
  }
  result.password = password != FALSE; result.enabled = enabled != FALSE;
  result.keyboard_focus = focus != FALSE; result.keyboard_focusable = focusable != FALSE;
  result.offscreen = offscreen != FALSE; result.runtime_id = RuntimeId(element.Get());
  VARIANT readonly{};
  if (SUCCEEDED(element->GetCurrentPropertyValue(UIA_ValueIsReadOnlyPropertyId, &readonly))) {
    result.writable = readonly.vt == VT_BOOL && readonly.boolVal == VARIANT_FALSE;
  }
  VariantClear(&readonly);
  ComPtr<IUIAutomationTreeWalker> walker;
  if (SUCCEEDED(automation->get_RawViewWalker(&walker))) {
    ComPtr<IUIAutomationElement> ancestor = element;
    for (int depth = 0; depth < 32 && ancestor != nullptr; ++depth) {
      UIA_HWND handle{};
      if (SUCCEEDED(ancestor->get_CurrentNativeWindowHandle(&handle)) && handle != nullptr &&
          GetAncestor(reinterpret_cast<HWND>(handle), GA_ROOT) == result.foreground) {
        result.automation_in_foreground = true; break;
      }
      ComPtr<IUIAutomationElement> parent;
      if (FAILED(walker->GetParentElement(ancestor.Get(), &parent))) break;
      ancestor = parent;
    }
  }
  ComPtr<IUIAutomationElement> current;
  GUITHREADINFO after{}; after.cbSize = sizeof(after);
  ProcessIdentity identity;
  ProcessIdentity provider_identity;
  result.stable = GetForegroundWindow() == result.foreground &&
      GetGUIThreadInfo(thread, &after) && after.hwndFocus == result.native_focus &&
      SUCCEEDED(automation->GetFocusedElement(&current)) && current != nullptr &&
      RuntimeId(current.Get()) == result.runtime_id && Identity(pid, &identity) &&
      identity.created_at == result.application.created_at &&
      Identity(result.provider.pid, &provider_identity) &&
      provider_identity.created_at == result.provider.created_at;
  return result;
}

std::string FocusSnapshot::ToPrivateJson() const {
  std::ostringstream out;
  out << "{\"format\":1,\"inspectionOnly\":true,\"valueWasRead\":false,\"inputWasSent\":false,"
      << "\"errorCode\":\"" << error << "\",\"application\":" << ProcessJson(application)
      << ",\"provider\":" << ProcessJson(provider) << ",\"foreground\":\""
      << reinterpret_cast<uintptr_t>(foreground) << "\",\"nativeFocus\":\""
      << reinterpret_cast<uintptr_t>(native_focus) << "\",\"framework\":" << JsonString(framework)
      << ",\"controlType\":" << control_type << ",\"isPassword\":" << Bool(password)
      << ",\"enabled\":" << Bool(enabled) << ",\"hasKeyboardFocus\":" << Bool(keyboard_focus)
      << ",\"keyboardFocusable\":" << Bool(keyboard_focusable) << ",\"offscreen\":" << Bool(offscreen)
      << ",\"writable\":" << Bool(writable)
      << ",\"nativeFocusInForeground\":" << Bool(native_focus_in_foreground)
      << ",\"automationInForeground\":" << Bool(automation_in_foreground)
      << ",\"stable\":" << Bool(stable) << ",\"modifiersReleased\":" << Bool(modifiers_released)
      << ",\"recognizedPasswordTarget\":" << Bool(RecognizesPassword()) << ",\"runtimeId\":[";
  for (size_t i = 0; i < runtime_id.size(); ++i) { if (i != 0) out << ','; out << runtime_id[i]; }
  out << "]}\n";
  return out.str();
}
}  // namespace focused_input
