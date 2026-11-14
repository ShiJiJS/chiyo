#include "target.h"

#include <UIAutomation.h>
#include <bcrypt.h>
#include <sddl.h>
#include <wrl/client.h>
#include <wtsapi32.h>
#include <array>
#include <atomic>
#include <map>
#include <mutex>
#include <thread>
#include <utility>

namespace native_background_fill {
namespace {
using Microsoft::WRL::ComPtr;

class Handle final {
 public:
  explicit Handle(HANDLE value = nullptr) : value_(value) {}
  ~Handle() { if (value_ && value_ != INVALID_HANDLE_VALUE) CloseHandle(value_); }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  HANDLE get() const { return value_; }
 private:
  HANDLE value_;
};

bool Same(const std::wstring& a, const std::wstring& b) {
  return !a.empty() && !b.empty() &&
      CompareStringOrdinal(a.c_str(), -1, b.c_str(), -1, TRUE) == CSTR_EQUAL;
}
std::wstring ProcessPath(HANDLE process) {
  std::wstring path(32768, L'\0');
  DWORD length = static_cast<DWORD>(path.size());
  if (!QueryFullProcessImageNameW(process, 0, path.data(), &length)) return {};
  path.resize(length);
  return path;
}
struct Security {
  std::wstring sid;
  DWORD integrity = 0;
  DWORD session = 0;
};
bool ReadSecurity(HANDLE process, DWORD pid, Security* result) {
  HANDLE raw = nullptr;
  if (!OpenProcessToken(process, TOKEN_QUERY, &raw)) return false;
  Handle token(raw);
  DWORD size = 0;
  GetTokenInformation(raw, TokenUser, nullptr, 0, &size);
  if (size == 0 || size > 65536) return false;
  std::vector<BYTE> buffer(size);
  if (!GetTokenInformation(raw, TokenUser, buffer.data(), size, &size)) return false;
  LPWSTR sid = nullptr;
  if (!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(buffer.data())->User.Sid,
                             &sid)) return false;
  result->sid = sid;
  LocalFree(sid);
  size = 0;
  GetTokenInformation(raw, TokenIntegrityLevel, nullptr, 0, &size);
  if (size == 0 || size > 65536) return false;
  buffer.resize(size);
  if (!GetTokenInformation(raw, TokenIntegrityLevel, buffer.data(), size, &size)) return false;
  const auto label = reinterpret_cast<TOKEN_MANDATORY_LABEL*>(buffer.data())->Label.Sid;
  if (!IsValidSid(label) || *GetSidSubAuthorityCount(label) == 0) return false;
  result->integrity = *GetSidSubAuthority(label, *GetSidSubAuthorityCount(label) - 1);
  return result->integrity != 0 && ProcessIdToSessionId(pid, &result->session);
}
bool EqualSecurity(const Security& a, const Security& b) {
  return a.sid == b.sid && a.integrity == b.integrity && a.session == b.session;
}
std::string DesktopStatus() {
  DWORD session = 0;
  LPWSTR data = nullptr;
  DWORD size = 0;
  if (!ProcessIdToSessionId(GetCurrentProcessId(), &session) ||
      !WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE, session,
                                   WTSSessionInfoEx, &data, &size)) {
    return "session_unavailable";
  }
  const auto* info = reinterpret_cast<WTSINFOEXW*>(data);
  const bool valid = size >= sizeof(WTSINFOEXW) && info->Level == 1;
  const bool unlocked = valid && info->Data.WTSInfoExLevel1.SessionState == WTSActive &&
      info->Data.WTSInfoExLevel1.SessionFlags == WTS_SESSIONSTATE_UNLOCK;
  WTSFreeMemory(data);
  if (!unlocked) return "desktop_locked_or_unavailable";
  const auto desktop = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
  if (!desktop) return "desktop_unavailable";
  wchar_t name[256]{};
  DWORD needed = 0;
  const bool ordinary = GetUserObjectInformationW(desktop, UOI_NAME, name,
      sizeof(name), &needed) && std::wstring(name) == L"Default";
  CloseDesktop(desktop);
  return ordinary ? "" : "unsupported_desktop";
}
struct FilePin {
  Handle handle;
  std::wstring path;
  std::string digest;
  explicit FilePin(HANDLE raw) : handle(raw) {}
};
std::unique_ptr<FilePin> PinFile(const std::wstring& path) {
  const auto raw = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
      nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN,
      nullptr);
  if (raw == INVALID_HANDLE_VALUE) return nullptr;
  auto pin = std::make_unique<FilePin>(raw);
  std::wstring actual(32768, L'\0');
  const auto length = GetFinalPathNameByHandleW(raw, actual.data(),
      static_cast<DWORD>(actual.size()), FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (!length || length >= actual.size()) return nullptr;
  actual.resize(length);
  if (actual.rfind(L"\\\\?\\", 0) == 0) actual.erase(0, 4);
  pin->path = actual;
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0) {
    return nullptr;
  }
  bool ok = BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0) >= 0;
  std::array<BYTE, 65536> bytes{};
  DWORD count = 0;
  while (ok) {
    if (!ReadFile(raw, bytes.data(), static_cast<DWORD>(bytes.size()), &count, nullptr)) {
      ok = false; break;
    }
    if (count == 0) break;
    ok = BCryptHashData(hash, bytes.data(), count, 0) >= 0;
  }
  std::array<BYTE, 32> digest{};
  if (ok) ok = BCryptFinishHash(hash, digest.data(), static_cast<ULONG>(digest.size()), 0) >= 0;
  if (hash) BCryptDestroyHash(hash);
  BCryptCloseAlgorithmProvider(algorithm, 0);
  if (!ok) return nullptr;
  constexpr char digits[] = "0123456789abcdef";
  for (const auto byte : digest) {
    pin->digest += digits[byte >> 4]; pin->digest += digits[byte & 15];
  }
  return pin;
}
std::vector<int> RuntimeId(IUIAutomationElement* element) {
  SAFEARRAY* raw = nullptr;
  std::vector<int> result;
  if (!element || FAILED(element->GetRuntimeId(&raw)) || !raw) return result;
  LONG first = 0, last = -1;
  if (SafeArrayGetDim(raw) == 1 &&
      SUCCEEDED(SafeArrayGetLBound(raw, 1, &first)) &&
      SUCCEEDED(SafeArrayGetUBound(raw, 1, &last)) && last >= first && last - first < 128) {
    for (LONG i = first; i <= last; ++i) {
      int value = 0;
      if (FAILED(SafeArrayGetElement(raw, &i, &value))) { result.clear(); break; }
      result.push_back(value);
    }
  }
  SafeArrayDestroy(raw);
  return result;
}
bool StringProperty(IUIAutomationElement* element, PROPERTYID id,
                    std::wstring* result) {
  VARIANT value{};
  const auto hr = element->GetCurrentPropertyValue(id, &value);
  const bool ok = SUCCEEDED(hr) && value.vt == VT_BSTR;
  if (ok) result->assign(value.bstrVal, SysStringLen(value.bstrVal));
  VariantClear(&value);
  return ok;
}
std::wstring WindowClass(HWND window) {
  wchar_t name[256]{};
  return GetClassNameW(window, name, 256) ? std::wstring(name) : std::wstring();
}
bool BrowserClass(const std::wstring& name) {
  // Positive native-field checks below are primary; these additionally reject
  // known embedded-browser roots/hosts even when a native child is exposed.
  for (const wchar_t* marker : {L"Chrome_", L"Chrome_Widget", L"Chrome_Render",
       L"Cef", L"WebView", L"Internet Explorer_Server", L"Mozilla"}) {
    if (name.find(marker) != std::wstring::npos) return true;
  }
  return false;
}
ComPtr<IUIAutomationElement> Resolve(IUIAutomation2* automation,
    IUIAutomationElement* root, const std::vector<SelectorStep>& path,
    std::string* error) {
  ComPtr<IUIAutomationElement> current = root;
  for (const auto& step : path) {
    VARIANT id{}; id.vt = VT_BSTR;
    id.bstrVal = SysAllocStringLen(step.automation_id.data(),
                                 static_cast<UINT>(step.automation_id.size()));
    ComPtr<IUIAutomationCondition> condition;
    const auto made = automation->CreatePropertyCondition(UIA_AutomationIdPropertyId,
                                                          id, &condition);
    VariantClear(&id);
    ComPtr<IUIAutomationElementArray> matches;
    int count = 0;
    if (FAILED(made) || FAILED(current->FindAll(TreeScope_Descendants,
        condition.Get(), &matches)) || !matches || FAILED(matches->get_Length(&count))) {
      *error = "element_unavailable"; return nullptr;
    }
    if (count != 1) { *error = "ambiguous_or_removed"; return nullptr; }
    ComPtr<IUIAutomationElement> next;
    int type = 0;
    if (FAILED(matches->GetElement(0, &next)) || !next ||
        FAILED(next->get_CurrentControlType(&type)) || type != step.control_type) {
      *error = "target_changed"; return nullptr;
    }
    current = next;
  }
  return current;
}
struct LeaseState { std::atomic<bool> invalidated{false}; };
class StructureHandler final : public IUIAutomationStructureChangedEventHandler {
 public:
  explicit StructureHandler(std::shared_ptr<LeaseState> state) : state_(std::move(state)) {}
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override {
    if (!object) return E_POINTER;
    if (iid == __uuidof(IUnknown) || iid == __uuidof(IUIAutomationStructureChangedEventHandler)) {
      *object = static_cast<IUIAutomationStructureChangedEventHandler*>(this);
      AddRef(); return S_OK;
    }
    *object = nullptr; return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
  ULONG STDMETHODCALLTYPE Release() override {
    const auto count = --references_; if (count == 0) delete this; return count;
  }
  HRESULT STDMETHODCALLTYPE HandleStructureChangedEvent(IUIAutomationElement*,
      StructureChangeType, SAFEARRAY*) override {
    state_->invalidated = true;
    return S_OK;
  }
 private:
  std::atomic<ULONG> references_{1};
  std::shared_ptr<LeaseState> state_;
};
class LifetimeHub;
thread_local LifetimeHub* current_hub = nullptr;
class LifetimeHub final {
 public:
  LifetimeHub() : thread_([this] {
    current_hub = this;
    const auto hook = SetWinEventHook(EVENT_OBJECT_DESTROY, EVENT_OBJECT_DESTROY,
        nullptr, Event, 0, 0, WINEVENT_OUTOFCONTEXT);
    installed_ = hook != nullptr;
    ready_ = true;
    MSG message{};
    while (!stop_) {
      while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
        TranslateMessage(&message); DispatchMessageW(&message);
      }
      Sleep(1);
    }
    if (hook) UnhookWinEvent(hook);
    current_hub = nullptr;
  }) { while (!ready_) Sleep(1); }
  ~LifetimeHub() { stop_ = true; thread_.join(); }
  unsigned long long Add(std::vector<HWND> ancestors, std::shared_ptr<LeaseState> state) {
    if (!installed_) return 0;
    std::lock_guard<std::mutex> lock(mutex_);
    const auto id = ++next_id_;
    entries_.emplace(id, Entry{std::move(ancestors), std::move(state)});
    return id;
  }
  void Remove(unsigned long long id) {
    std::lock_guard<std::mutex> lock(mutex_); entries_.erase(id);
  }
  static LifetimeHub& Shared() { static LifetimeHub hub; return hub; }
 private:
  struct Entry { std::vector<HWND> ancestors; std::weak_ptr<LeaseState> state; };
  static void CALLBACK Event(HWINEVENTHOOK, DWORD, HWND window, LONG object,
                              LONG child, DWORD, DWORD) {
    if (!current_hub || object != OBJID_WINDOW || child != CHILDID_SELF) return;
    std::lock_guard<std::mutex> lock(current_hub->mutex_);
    for (auto& pair : current_hub->entries_) {
      const auto state = pair.second.state.lock();
      if (!state) continue;
      for (auto ancestor : pair.second.ancestors) {
        if (window == ancestor) { state->invalidated = true; break; }
      }
    }
  }
  std::mutex mutex_;
  std::map<unsigned long long, Entry> entries_;
  unsigned long long next_id_ = 0;
  std::atomic<bool> stop_{false}, ready_{false};
  bool installed_ = false;
  std::thread thread_;
};
class LifetimeWatch final {
 public:
  LifetimeWatch(std::vector<HWND> ancestors, std::shared_ptr<LeaseState> state)
      : id_(LifetimeHub::Shared().Add(std::move(ancestors), std::move(state))) {}
  ~LifetimeWatch() { LifetimeHub::Shared().Remove(id_); }
  bool installed() const { return id_ != 0; }
 private:
  unsigned long long id_;
};
}  // namespace

unsigned long long ProcessCreatedAt(HANDLE process) {
  FILETIME created{}, exited{}, kernel{}, user{};
  if (!GetProcessTimes(process, &created, &exited, &kernel, &user)) return 0;
  return (static_cast<unsigned long long>(created.dwHighDateTime) << 32) |
      created.dwLowDateTime;
}
bool InspectExecutable(const std::wstring& path, std::wstring* canonical,
                       std::string* sha256) {
  const auto pin = PinFile(path);
  if (!pin) return false;
  *canonical = pin->path; *sha256 = pin->digest;
  return true;
}
bool ValidSecret(const wchar_t* units, size_t count) {
  if (!units || count == 0 || count > 4096) return false;
  for (size_t i = 0; i < count; ++i) {
    const auto c = static_cast<unsigned>(units[i]);
    if (c < 32 || c == 127 || (c >= 0xdc00 && c <= 0xdfff)) return false;
    if (c >= 0xd800 && c <= 0xdbff) {
      if (++i >= count || units[i] < 0xdc00 || units[i] > 0xdfff) return false;
    }
  }
  return true;
}
const char* OutcomeName(Outcome outcome) {
  switch (outcome) {
    case Outcome::kRefused: return "refused";
    case Outcome::kSent: return "sent";
    case Outcome::kUnknown: return "unknown";
  }
  return "unknown";
}

struct Target::Impl {
  Selection selection;
  Handle process;
  std::unique_ptr<FilePin> executable;
  Security security;
  ComPtr<IUIAutomation2> automation;
  ComPtr<IUIAutomationElement> window, element;
  ComPtr<IUIAutomationValuePattern> value;
  ComPtr<StructureHandler> structure;
  std::shared_ptr<LeaseState> lease = std::make_shared<LeaseState>();
  std::unique_ptr<LifetimeWatch> lifetime;
  std::vector<int> root_id, element_id;
  std::vector<std::vector<int>> ancestry;
  std::wstring root_class, root_name, field_name, field_label, framework, control_class;
  HWND native_control = nullptr;
  std::string family_name, retired;
  ULONGLONG expires = 0;
  DWORD owner_thread = GetCurrentThreadId();
  bool subscribed = false, busy = false;
  explicit Impl(HANDLE raw) : process(raw) {}
  ~Impl() {
    lease->invalidated = true;
    if (subscribed) automation->RemoveStructureChangedEventHandler(window.Get(), structure.Get());
  }

  std::string InspectAncestry(bool capture) {
    ComPtr<IUIAutomationTreeWalker> walker;
    if (FAILED(automation->get_RawViewWalker(&walker))) return "automation_unavailable";
    std::vector<std::vector<int>> current;
    ComPtr<IUIAutomationElement> node = element;
    for (int depth = 0; depth < 64 && node; ++depth) {
      int pid = 0, type = 0;
      BOOL enabled = FALSE;
      std::wstring framework_id, class_name;
      if (FAILED(node->get_CurrentProcessId(&pid)) ||
          FAILED(node->get_CurrentControlType(&type)) ||
          FAILED(node->get_CurrentIsEnabled(&enabled)) ||
          !StringProperty(node.Get(), UIA_FrameworkIdPropertyId, &framework_id) ||
          !StringProperty(node.Get(), UIA_ClassNamePropertyId, &class_name)) {
        return "element_unavailable";
      }
      if (pid != static_cast<int>(selection.process_id) || !enabled) return "target_changed";
      if (type == UIA_DocumentControlTypeId || BrowserClass(class_name) ||
          (framework_id != L"Win32" && framework_id != L"WinForm" && framework_id != L"WPF")) {
        return "unsupported_target";
      }
      auto id = RuntimeId(node.Get());
      if (id.empty()) return "element_unavailable";
      current.push_back(std::move(id));
      BOOL root = FALSE;
      if (FAILED(automation->CompareElements(node.Get(), window.Get(), &root))) return "element_unavailable";
      if (root) {
        if (capture) ancestry = current;
        return current == ancestry ? "" : "target_changed";
      }
      ComPtr<IUIAutomationElement> parent;
      if (FAILED(walker->GetParentElement(node.Get(), &parent))) return "element_unavailable";
      node = parent;
    }
    return "target_changed";
  }

  std::string Check() {
    if (GetCurrentThreadId() != owner_thread) return "wrong_worker_thread";
    if (!retired.empty()) return retired;
    if (GetTickCount64() >= expires) return "target_expired";
    if (WaitForSingleObject(process.get(), 0) != WAIT_TIMEOUT ||
        ProcessCreatedAt(process.get()) != selection.process_created_at) return "application_changed";
    Security current, own;
    if (!ReadSecurity(process.get(), selection.process_id, &current) ||
        !ReadSecurity(GetCurrentProcess(), GetCurrentProcessId(), &own)) return "access_denied";
    if (!EqualSecurity(security, current) || current.sid != own.sid ||
        current.session != own.session || current.integrity > own.integrity) return "security_context_changed";
    const auto desktop = DesktopStatus();
    if (!desktop.empty()) return desktop;
    if (!Same(ProcessPath(process.get()), executable->path)) return "application_changed";
    DWORD pid = 0;
    if (!IsWindow(selection.window) || GetWindowThreadProcessId(selection.window, &pid) == 0 ||
        pid != selection.process_id || GetAncestor(selection.window, GA_ROOT) != selection.window ||
        WindowClass(selection.window) != root_class) return "window_changed";
    // Hiding removes the subtree in the tested UIA providers. Minimized
    // windows retain WS_VISIBLE and remain supported; hidden roots fail closed.
    if (!IsWindowVisible(selection.window)) return "target_not_visible";
    if (native_control) {
      UIA_HWND current_native = nullptr;
      DWORD control_pid = 0;
      if (!IsWindow(native_control) ||
          !GetWindowThreadProcessId(native_control, &control_pid) ||
          control_pid != selection.process_id ||
          GetAncestor(native_control, GA_ROOT) != selection.window ||
          !IsWindowVisible(native_control) ||
          FAILED(element->get_CurrentNativeWindowHandle(&current_native)) ||
          reinterpret_cast<HWND>(current_native) != native_control) return "target_changed";
    }
    if (lease->invalidated) return "target_invalidated";
    if (RuntimeId(window.Get()) != root_id || RuntimeId(element.Get()) != element_id) return "target_changed";
    std::wstring title, field_name_now, current_framework, current_class;
    if (!StringProperty(window.Get(), UIA_NamePropertyId, &title) ||
        !StringProperty(element.Get(), UIA_NamePropertyId, &field_name_now) ||
        !StringProperty(element.Get(), UIA_FrameworkIdPropertyId, &current_framework) ||
        !StringProperty(element.Get(), UIA_ClassNamePropertyId, &current_class)) return "element_unavailable";
    if (title != root_name || field_name_now != field_name || current_framework != framework || current_class != control_class) return "target_changed";
    int provider = 0, type = 0;
    BOOL password = FALSE, enabled = FALSE, readonly = TRUE, auto_focus = TRUE;
    if (FAILED(element->get_CurrentProcessId(&provider)) ||
        FAILED(element->get_CurrentControlType(&type)) ||
        FAILED(element->get_CurrentIsPassword(&password)) ||
        FAILED(element->get_CurrentIsEnabled(&enabled)) ||
        FAILED(value->get_CurrentIsReadOnly(&readonly)) ||
        FAILED(automation->get_AutoSetFocus(&auto_focus))) return "element_unavailable";
    if (provider != static_cast<int>(selection.process_id) || type != UIA_EditControlTypeId || !password || auto_focus) return "unsupported_target";
    if (!enabled) return "target_disabled";
    if (readonly) return "target_readonly";
    std::string error;
    const auto resolved = Resolve(automation.Get(), window.Get(), selection.path, &error);
    if (!resolved) return error;
    BOOL same = FALSE;
    if (FAILED(automation->CompareElements(element.Get(), resolved.Get(), &same)) ||
        !same || RuntimeId(resolved.Get()) != element_id) return "target_changed";
    return InspectAncestry(false);
  }
};

Target::Target(std::unique_ptr<Impl> impl) : impl_(std::move(impl)) {}
Target::~Target() = default;
std::shared_ptr<Target> Target::Capture(const Selection& selection, std::string* error) {
  *error = "unsupported_target";
  APTTYPE apartment; APTTYPEQUALIFIER qualifier;
  if (FAILED(CoGetApartmentType(&apartment, &qualifier)) || apartment != APTTYPE_MTA) {
    *error = "wrong_worker_thread"; return nullptr;
  }
  if (selection.approved_executable.empty() || selection.approved_sha256.size() != 64 ||
      !selection.process_id || !selection.process_created_at || !selection.window ||
      selection.path.empty() || selection.path.size() > 16 ||
      !selection.lease_milliseconds || selection.lease_milliseconds > 300000) return nullptr;
  for (const auto& step : selection.path) {
    if (step.automation_id.empty() || step.automation_id.size() > 256 || step.control_type <= 0) return nullptr;
  }
  auto desktop = DesktopStatus();
  if (!desktop.empty()) { *error = desktop; return nullptr; }
  auto impl = std::make_unique<Impl>(OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION,
                                               FALSE, selection.process_id));
  impl->selection = selection;
  if (!impl->process.get() || ProcessCreatedAt(impl->process.get()) != selection.process_created_at ||
      WaitForSingleObject(impl->process.get(), 0) != WAIT_TIMEOUT) {
    *error = "application_changed"; return nullptr;
  }
  impl->executable = PinFile(selection.approved_executable);
  if (!impl->executable || !Same(impl->executable->path, selection.approved_executable) ||
      impl->executable->digest != selection.approved_sha256 ||
      !Same(ProcessPath(impl->process.get()), impl->executable->path)) {
    *error = "application_changed"; return nullptr;
  }
  Security own;
  if (!ReadSecurity(impl->process.get(), selection.process_id, &impl->security) ||
      !ReadSecurity(GetCurrentProcess(), GetCurrentProcessId(), &own) ||
      impl->security.sid != own.sid || impl->security.session != own.session ||
      impl->security.integrity > own.integrity) { *error = "access_denied"; return nullptr; }
  DWORD root_pid = 0;
  if (!IsWindow(selection.window) || GetWindowThreadProcessId(selection.window, &root_pid) == 0 ||
      root_pid != selection.process_id || GetAncestor(selection.window, GA_ROOT) != selection.window) return nullptr;
  impl->root_class = WindowClass(selection.window);
  if (!IsWindowVisible(selection.window)) { *error = "target_not_visible"; return nullptr; }
  if (impl->root_class.empty() || BrowserClass(impl->root_class)) return nullptr;
  if (FAILED(CoCreateInstance(__uuidof(CUIAutomation8), nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&impl->automation))) ||
      FAILED(impl->automation->put_AutoSetFocus(FALSE)) ||
      FAILED(impl->automation->put_ConnectionTimeout(500)) ||
      FAILED(impl->automation->put_TransactionTimeout(500)) ||
      FAILED(impl->automation->ElementFromHandle(selection.window, &impl->window))) {
    *error = "automation_unavailable"; return nullptr;
  }
  impl->element = Resolve(impl->automation.Get(), impl->window.Get(), selection.path, error);
  if (!impl->element) return nullptr;
  impl->root_id = RuntimeId(impl->window.Get()); impl->element_id = RuntimeId(impl->element.Get());
  if ((!selection.observed_window_runtime_id.empty() && selection.observed_window_runtime_id != impl->root_id) ||
      (!selection.observed_element_runtime_id.empty() && selection.observed_element_runtime_id != impl->element_id)) {
    *error = "target_changed"; return nullptr;
  }
  if (impl->root_id.empty() || impl->element_id.empty() ||
      !StringProperty(impl->window.Get(), UIA_NamePropertyId, &impl->root_name) ||
      !StringProperty(impl->element.Get(), UIA_NamePropertyId, &impl->field_name) ||
      !StringProperty(impl->element.Get(), UIA_FrameworkIdPropertyId, &impl->framework) ||
      !StringProperty(impl->element.Get(), UIA_ClassNamePropertyId, &impl->control_class)) {
    *error = "element_unavailable"; return nullptr;
  }
  impl->field_label = L"[";
  for (const auto& step : selection.path) {
    if (impl->field_label.size() > 1) impl->field_label += L"/";
    impl->field_label += step.automation_id;
  }
  impl->field_label += L"] " + (impl->field_name.empty() ? std::wstring(L"Password") : impl->field_name);
  UIA_HWND native = nullptr;
  if (FAILED(impl->element->get_CurrentNativeWindowHandle(&native))) return nullptr;
  const HWND control = reinterpret_cast<HWND>(native);
  impl->native_control = control;
  if (impl->framework == L"Win32" && Same(impl->control_class, L"Edit") &&
      control && Same(WindowClass(control), L"Edit")) {
    impl->family_name = "win32-password-edit";
  } else if (impl->framework == L"WinForm" && control &&
      WindowClass(control).rfind(L"WindowsForms10.EDIT.", 0) == 0) {
    impl->family_name = "winforms-password-textbox";
  } else if (impl->framework == L"WPF" && impl->control_class == L"PasswordBox" &&
      impl->root_class.rfind(L"HwndWrapper[", 0) == 0) {
    impl->family_name = "wpf-passwordbox";
  } else {
    *error = "unsupported_target"; return nullptr;
  }
  if (FAILED(impl->element->GetCurrentPatternAs(UIA_ValuePatternId,
                                               IID_PPV_ARGS(&impl->value))) || !impl->value) return nullptr;
  *error = impl->InspectAncestry(true);
  if (!error->empty()) return nullptr;
  *error = "unsupported_target";
  std::vector<HWND> handles{selection.window};
  if (control) {
    DWORD control_pid = 0;
    GetWindowThreadProcessId(control, &control_pid);
    if (control_pid != selection.process_id || GetAncestor(control, GA_ROOT) != selection.window) return nullptr;
    for (HWND parent = control; parent && parent != selection.window; parent = GetParent(parent)) {
      if (BrowserClass(WindowClass(parent))) { *error = "unsupported_target"; return nullptr; }
      handles.push_back(parent);
    }
  }
  impl->lifetime = std::make_unique<LifetimeWatch>(std::move(handles), impl->lease);
  if (!impl->lifetime->installed()) { *error = "automation_unavailable"; return nullptr; }
  impl->structure.Attach(new StructureHandler(impl->lease));
  if (FAILED(impl->automation->AddStructureChangedEventHandler(impl->window.Get(),
      TreeScope_Subtree, nullptr, impl->structure.Get()))) {
    *error = "automation_unavailable"; return nullptr;
  }
  impl->subscribed = true;
  impl->expires = GetTickCount64() + selection.lease_milliseconds;
  *error = impl->Check();
  if (!error->empty()) return nullptr;
  return std::shared_ptr<Target>(new Target(std::move(impl)));
}
std::string Target::Recheck() {
  const auto error = impl_->Check();
  if (!error.empty() && impl_->retired.empty()) impl_->retired = error;
  return error;
}
std::unique_ptr<Prepared> Target::Prepare(std::string* error) {
  *error = Recheck();
  if (!error->empty()) return nullptr;
  if (impl_->busy) { *error = "busy"; return nullptr; }
  impl_->busy = true;
  return std::unique_ptr<Prepared>(new Prepared(shared_from_this()));
}
bool Target::Retain(std::string* error) {
  *error = Recheck();
  if (!error->empty()) return false;
  impl_->expires = ~0ull;
  return true;
}
void Target::Invalidate() { impl_->retired = "target_invalidated"; }
bool Target::SameInstance(const Target& other) const {
  return impl_->selection.process_id == other.impl_->selection.process_id &&
      impl_->selection.process_created_at == other.impl_->selection.process_created_at &&
      impl_->root_id == other.impl_->root_id && impl_->element_id == other.impl_->element_id &&
      impl_->executable->digest == other.impl_->executable->digest &&
      Same(impl_->executable->path, other.impl_->executable->path);
}
Prepared::Prepared(std::shared_ptr<Target> target) : target_(std::move(target)) {}
Prepared::~Prepared() { Close(); }
Result Prepared::Replace(const wchar_t* units, size_t count) {
  if (consumed_) return result_;
  if (closed_) return {Outcome::kRefused, "preparation_closed"};
  consumed_ = true;
  if (!ValidSecret(units, count)) {
    result_ = {Outcome::kRefused, "unsupported_secret"}; return result_;
  }
  auto error = target_->Recheck();
  if (!error.empty()) { result_ = {Outcome::kRefused, error}; return result_; }
  if (target_->impl_->native_control) {
    // Read only the standard Edit's declared input limit. Never read its value
    // or use a window message as a writing fallback.
    DWORD_PTR limit = 0;
    if (!SendMessageTimeoutW(target_->impl_->native_control, EM_GETLIMITTEXT, 0,
        0, SMTO_ABORTIFHUNG | SMTO_BLOCK, 500, &limit)) {
      target_->Invalidate();
      result_ = {Outcome::kRefused, "element_unavailable"}; return result_;
    }
    if (count > limit) {
      result_ = {Outcome::kRefused, "unsupported_secret"}; return result_;
    }
    error = target_->Recheck();
    if (!error.empty()) { result_ = {Outcome::kRefused, error}; return result_; }
  }
  BSTR value = SysAllocStringLen(units, static_cast<UINT>(count));
  if (!value) { result_ = {Outcome::kRefused, "material_unavailable"}; return result_; }
  // Mark unknown before dispatch. A failed/timed-out provider may already have
  // changed the field; failures after this boundary are never retried.
  result_ = {Outcome::kUnknown, "input_unknown"};
  const auto applied = target_->impl_->value->SetValue(value);
  SecureZeroMemory(value, count * sizeof(wchar_t)); SysFreeString(value);
  error = target_->Recheck();
  if (FAILED(applied)) return result_;
  if (!error.empty()) { result_.error = error; return result_; }
  result_ = {Outcome::kSent, ""};
  return result_;
}
const Result* Prepared::LastResult() const { return consumed_ ? &result_ : nullptr; }
void Prepared::Close() {
  if (closed_) return;
  closed_ = true;
  target_->impl_->busy = false;
}
const std::string& Target::family() const { return impl_->family_name; }
const std::wstring& Target::window_description() const { return impl_->root_name; }
const std::wstring& Target::field_description() const { return impl_->field_label; }

}  // namespace native_background_fill
