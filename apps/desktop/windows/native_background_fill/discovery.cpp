#include "discovery.h"
#include <UIAutomation.h>
#include <wrl/client.h>
#include <algorithm>

namespace native_background_fill {
namespace {
using Microsoft::WRL::ComPtr;
bool EqualPath(const std::wstring& a, const std::wstring& b) {
  return !a.empty() && !b.empty() && CompareStringOrdinal(a.c_str(), -1, b.c_str(), -1, TRUE) == CSTR_EQUAL;
}
std::wstring Path(HANDLE process) {
  std::wstring path(32768, L'\0'); DWORD length = static_cast<DWORD>(path.size());
  if (!QueryFullProcessImageNameW(process, 0, path.data(), &length)) return {};
  path.resize(length); return path;
}
std::wstring AutomationId(IUIAutomationElement* element) {
  BSTR value = nullptr;
  if (FAILED(element->get_CurrentAutomationId(&value)) || !value) return {};
  std::wstring text(value, SysStringLen(value)); SysFreeString(value); return text;
}
std::vector<int> RuntimeId(IUIAutomationElement* element) {
  SAFEARRAY* array = nullptr;
  if (FAILED(element->GetRuntimeId(&array)) || !array) return {};
  std::vector<int> result;
  LONG first = 0, last = -1;
  if (SafeArrayGetDim(array) == 1 && SUCCEEDED(SafeArrayGetLBound(array, 1, &first)) &&
      SUCCEEDED(SafeArrayGetUBound(array, 1, &last)) && last >= first && last - first < 128) {
    for (LONG i = first; i <= last; ++i) {
      int value = 0;
      if (FAILED(SafeArrayGetElement(array, &i, &value))) { result.clear(); break; }
      result.push_back(value);
    }
  }
  SafeArrayDestroy(array); return result;
}
struct WindowSearch {
  std::wstring executable;
  HWND selected_window;
  std::vector<Selection> windows;
};
BOOL CALLBACK Window(HWND window, LPARAM parameter) {
  auto* search = reinterpret_cast<WindowSearch*>(parameter);
  if (search->windows.size() >= 64) return FALSE;
  if (!IsWindowVisible(window) || GetAncestor(window, GA_ROOT) != window ||
      (search->selected_window && search->selected_window != window)) return TRUE;
  DWORD pid = 0;
  GetWindowThreadProcessId(window, &pid);
  HANDLE process = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!process) return TRUE;
  Selection selection;
  selection.process_created_at = ProcessCreatedAt(process);
  const auto executable = Path(process);
  CloseHandle(process);
  if (!selection.process_created_at || !EqualPath(executable, search->executable)) return TRUE;
  selection.process_id = pid; selection.window = window;
  search->windows.push_back(std::move(selection));
  return TRUE;
}
std::vector<SelectorStep> PathWithin(IUIAutomation2* automation,
    IUIAutomationElement* root, IUIAutomationElement* element) {
  ComPtr<IUIAutomationTreeWalker> walker;
  if (FAILED(automation->get_RawViewWalker(&walker))) return {};
  ComPtr<IUIAutomationElement> current = element;
  std::vector<SelectorStep> path;
  for (int depth = 0; depth < 64 && current; ++depth) {
    BOOL at_root = FALSE;
    if (FAILED(automation->CompareElements(root, current.Get(), &at_root))) return {};
    if (at_root) { std::reverse(path.begin(), path.end()); return path; }
    const auto id = AutomationId(current.Get());
    int type = 0;
    if (FAILED(current->get_CurrentControlType(&type))) return {};
    if (depth == 0 && id.empty()) return {};
    if (!id.empty()) path.push_back({id, type});
    ComPtr<IUIAutomationElement> parent;
    if (FAILED(walker->GetParentElement(current.Get(), &parent))) return {};
    current = parent;
  }
  return {};
}
}
std::vector<DiscoveredTarget> DiscoverNativeFields(const std::wstring& executable,
    HWND selected_window, size_t limit, std::string* error) {
  std::vector<DiscoveredTarget> result;
  *error = "unsupported_target";
  if (limit == 0 || limit > 64) return result;
  std::wstring canonical;
  std::string digest;
  if (!InspectExecutable(executable, &canonical, &digest)) {
    *error = "application_unavailable"; return result;
  }
  ComPtr<IUIAutomation2> automation;
  if (FAILED(CoCreateInstance(__uuidof(CUIAutomation8), nullptr, CLSCTX_INPROC_SERVER,
      IID_PPV_ARGS(&automation))) || FAILED(automation->put_AutoSetFocus(FALSE)) ||
      FAILED(automation->put_ConnectionTimeout(500)) ||
      FAILED(automation->put_TransactionTimeout(500))) {
    *error = "automation_unavailable"; return result;
  }
  WindowSearch search{canonical, selected_window, {}};
  EnumWindows(Window, reinterpret_cast<LPARAM>(&search));
  VARIANT password{}; password.vt = VT_BOOL; password.boolVal = VARIANT_TRUE;
  ComPtr<IUIAutomationCondition> condition;
  if (FAILED(automation->CreatePropertyCondition(UIA_IsPasswordPropertyId, password, &condition))) {
    *error = "automation_unavailable"; return result;
  }
  for (auto& selection : search.windows) {
    ComPtr<IUIAutomationElement> root;
    ComPtr<IUIAutomationElementArray> fields;
    if (FAILED(automation->ElementFromHandle(selection.window, &root)) || !root ||
        FAILED(root->FindAll(TreeScope_Descendants, condition.Get(), &fields)) || !fields) continue;
    int count = 0;
    if (FAILED(fields->get_Length(&count)) || count > 256) continue;
    selection.approved_executable = canonical; selection.approved_sha256 = digest;
    selection.observed_window_runtime_id = RuntimeId(root.Get());
    if (selection.observed_window_runtime_id.empty()) continue;
    for (int i = 0; i < count && result.size() < limit; ++i) {
      ComPtr<IUIAutomationElement> field;
      if (FAILED(fields->GetElement(i, &field)) || !field) continue;
      selection.path = PathWithin(automation.Get(), root.Get(), field.Get());
      selection.observed_element_runtime_id = RuntimeId(field.Get());
      if (selection.path.empty() || selection.observed_element_runtime_id.empty()) continue;
      std::string refused;
      auto target = Target::Capture(selection, &refused);
      if (!target) { *error = refused.empty() ? "unsupported_target" : refused; continue; }
      if (target->field_description().size() > 256) { *error = "unsupported_target"; continue; }
      // Capture compared the two observed runtime IDs before retaining the
      // unique candidate. These are private identities, never field values.
      const auto stable = target->Recheck();
      if (!stable.empty()) { *error = stable; continue; }
      result.push_back({std::move(target), selection.window, canonical, digest});
    }
    if (result.size() >= limit) break;
  }
  if (!result.empty()) error->clear();
  return result;
}
}  // namespace native_background_fill
