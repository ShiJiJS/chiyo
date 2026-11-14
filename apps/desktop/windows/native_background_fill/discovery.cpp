#include "discovery.h"
#include <UIAutomation.h>
#include <wrl/client.h>
#include <set>

namespace native_background_fill {
namespace {
using Microsoft::WRL::ComPtr;
std::string UiaError(HRESULT hr) {
  return hr == E_ACCESSDENIED ? "access_denied" : "element_unavailable";
}
bool EqualPath(const std::wstring& a, const std::wstring& b) {
  return !a.empty() && !b.empty() && CompareStringOrdinal(a.c_str(), -1, b.c_str(), -1, TRUE) == CSTR_EQUAL;
}
std::wstring Path(HANDLE process) {
  std::wstring path(32768, L'\0'); DWORD length = static_cast<DWORD>(path.size());
  if (!QueryFullProcessImageNameW(process, 0, path.data(), &length)) return {};
  path.resize(length); return path;
}
HRESULT RuntimeId(IUIAutomationElement* element, std::vector<int>* result) {
  SAFEARRAY* array = nullptr;
  const auto hr = element->GetRuntimeId(&array);
  if (FAILED(hr)) return hr;
  if (!array) return E_FAIL;
  LONG first = 0, last = -1;
  bool valid = SafeArrayGetDim(array) == 1 && SUCCEEDED(SafeArrayGetLBound(array, 1, &first)) &&
      SUCCEEDED(SafeArrayGetUBound(array, 1, &last)) && last >= first && last - first < 128;
  for (LONG i = first; valid && i <= last; ++i) {
    int value = 0;
    valid = SUCCEEDED(SafeArrayGetElement(array, &i, &value));
    if (valid) result->push_back(value);
  }
  SafeArrayDestroy(array);
  if (!valid) result->clear();
  return valid ? S_OK : E_FAIL;
}
struct WindowSearch {
  std::wstring executable;
  HWND selected_window;
  std::vector<Selection> windows;
  std::string error;
  bool hidden = false;
};
BOOL CALLBACK Window(HWND window, LPARAM parameter) {
  auto* search = reinterpret_cast<WindowSearch*>(parameter);
  if (GetAncestor(window, GA_ROOT) != window ||
      (search->selected_window && search->selected_window != window)) return TRUE;
  DWORD pid = 0;
  if (!GetWindowThreadProcessId(window, &pid)) {
    if (search->selected_window) search->error = "window_changed";
    return TRUE;
  }
  HANDLE process = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!process) {
    // Unrelated protected processes are not candidates. A retained explicit
    // window's query failure, however, must not become an empty result.
    if (search->selected_window) search->error = "access_denied";
    return TRUE;
  }
  Selection selection;
  selection.process_created_at = ProcessCreatedAt(process);
  const auto executable = Path(process);
  CloseHandle(process);
  if (!EqualPath(executable, search->executable)) return TRUE;
  if (!selection.process_created_at) { search->error = "application_unavailable"; return FALSE; }
  if (!IsWindowVisible(window)) { search->hidden = true; return TRUE; }
  if (search->windows.size() >= 64) { search->error = "busy"; return FALSE; }
  selection.process_id = pid; selection.window = window;
  search->windows.push_back(std::move(selection));
  return TRUE;
}
}
std::vector<DiscoveredTarget> DiscoverNativeFields(const std::wstring& executable,
    HWND selected_window, size_t limit, std::string* error) {
  std::vector<DiscoveredTarget> result;
  *error = "unsupported_target";
  if (limit == 0 || limit > 64) return result;
  std::wstring canonical;
  std::string digest;
  SetLastError(ERROR_SUCCESS);
  if (!InspectExecutable(executable, &canonical, &digest)) {
    *error = GetLastError() == ERROR_ACCESS_DENIED ? "access_denied" : "application_unavailable";
    return result;
  }
  ComPtr<IUIAutomation2> automation;
  auto hr = CoCreateInstance(__uuidof(CUIAutomation8), nullptr, CLSCTX_INPROC_SERVER,
      IID_PPV_ARGS(&automation));
  if (FAILED(hr) || FAILED(hr = automation->put_AutoSetFocus(FALSE)) ||
      FAILED(hr = automation->put_ConnectionTimeout(500)) ||
      FAILED(hr = automation->put_TransactionTimeout(500))) {
    *error = hr == E_ACCESSDENIED ? "access_denied" : "automation_unavailable"; return result;
  }
  WindowSearch search{canonical, selected_window, {}, "", false};
  const auto enumerated = EnumWindows(Window, reinterpret_cast<LPARAM>(&search));
  if (!search.error.empty() || !enumerated) {
    *error = search.error.empty() ? "automation_unavailable" : search.error; return {};
  }
  if (search.windows.empty()) {
    *error = search.hidden ? "target_not_visible" : "application_unavailable"; return {};
  }
  VARIANT password{}; password.vt = VT_BOOL; password.boolVal = VARIANT_TRUE;
  ComPtr<IUIAutomationCondition> condition;
  hr = automation->CreatePropertyCondition(UIA_IsPasswordPropertyId, password, &condition);
  if (FAILED(hr)) { *error = UiaError(hr); return {}; }
  error->clear();
  std::string unsupported;
  for (auto& selection : search.windows) {
    *error = CheckProcessAccess(selection.process_id, selection.process_created_at);
    if (!error->empty()) return {};
    ComPtr<IUIAutomationElement> root;
    ComPtr<IUIAutomationElementArray> fields;
    hr = automation->ElementFromHandle(selection.window, &root);
    if (FAILED(hr) || !root) { *error = UiaError(hr); return {}; }
    hr = root->FindAll(TreeScope_Subtree, condition.Get(), &fields);
    if (FAILED(hr) || !fields) { *error = UiaError(hr); return {}; }
    int count = 0;
    hr = fields->get_Length(&count);
    if (FAILED(hr)) { *error = UiaError(hr); return {}; }
    // UIA may normalize a disappearing provider to an empty collection.
    // A process/window lost during enumeration is still an explicit failure.
    *error = CheckProcessAccess(selection.process_id, selection.process_created_at);
    DWORD current_pid = 0;
    if (!error->empty()) return {};
    if (!IsWindow(selection.window) || !GetWindowThreadProcessId(selection.window, &current_pid) ||
        current_pid != selection.process_id) { *error = "window_changed"; return {}; }
    if (count < 0 || count > 256) { *error = "busy"; return {}; }
    selection.approved_executable = canonical; selection.approved_sha256 = digest;
    hr = RuntimeId(root.Get(), &selection.observed_window_runtime_id);
    if (FAILED(hr)) { *error = UiaError(hr); return {}; }
    for (int i = 0; i < count; ++i) {
      ComPtr<IUIAutomationElement> field;
      hr = fields->GetElement(i, &field);
      if (FAILED(hr) || !field) { *error = UiaError(hr); return {}; }
      selection.observed_element_runtime_id.clear();
      hr = RuntimeId(field.Get(), &selection.observed_element_runtime_id);
      if (FAILED(hr)) { *error = UiaError(hr); return {}; }
      std::string refused;
      // Hold the discovered object, including providers without HWND or ID.
      // Descriptive developer IDs never rebuild an expired field reference.
      auto target = Target::Capture(selection, &refused, field.Get());
      if (!target) {
        if (refused == "unsupported_target" || refused == "target_disabled" || refused == "target_readonly") {
          unsupported = "unsupported_target"; continue;
        }
        *error = refused.empty() ? "unsupported_target" : refused; return {};
      }
      if (target->field_description().size() > 256) { unsupported = "unsupported_target"; continue; }
      const auto stable = target->Recheck();
      if (!stable.empty()) { *error = stable; return {}; }
      if (result.size() >= limit) { *error = "busy"; return {}; }
      result.push_back({std::move(target), selection.window, canonical, digest});
    }
  }
  std::set<std::pair<std::wstring, std::wstring>> descriptions;
  for (const auto& candidate : result) {
    if (!descriptions.insert({candidate.target->window_description(), candidate.target->field_description()}).second) {
      *error = "unsupported_target"; return {};
    }
  }
  if (result.empty()) *error = unsupported;
  return result;
}
}  // namespace native_background_fill
