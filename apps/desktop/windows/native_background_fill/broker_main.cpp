#include "discovery.h"
#include <bcrypt.h>
#include <tlhelp32.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Data.Json.h>
#include <array>
#include <map>
#include <set>
#include <thread>

namespace nb = native_background_fill;
namespace {
using winrt::Windows::Data::Json::IJsonValue;
using winrt::Windows::Data::Json::JsonArray;
using winrt::Windows::Data::Json::JsonObject;
using winrt::Windows::Data::Json::JsonValue;
using winrt::Windows::Data::Json::JsonValueType;
constexpr DWORD kMaxFrame = 2 * 1024 * 1024;
constexpr size_t kGlobalTargetLimit = 512, kGlobalLeaseLimit = 512;

struct Bytes {
  std::vector<BYTE> data;
  ~Bytes() { if (!data.empty()) SecureZeroMemory(data.data(), data.size()); }
};
struct SensitiveText {
  std::wstring value;
  ~SensitiveText() { if (!value.empty()) SecureZeroMemory(value.data(), value.size() * sizeof(wchar_t)); }
};
bool ReadExact(HANDLE pipe, BYTE* buffer, DWORD size) {
  while (size) {
    DWORD count = 0;
    if (!ReadFile(pipe, buffer, size, &count, nullptr) || count == 0) return false;
    buffer += count; size -= count;
  }
  return true;
}
bool ReadFrame(HANDLE pipe, Bytes* bytes) {
  BYTE header[4]{};
  if (!ReadExact(pipe, header, 4)) return false;
  const DWORD size = header[0] | (DWORD(header[1]) << 8) | (DWORD(header[2]) << 16) | (DWORD(header[3]) << 24);
  if (size == 0 || size > kMaxFrame) return false;
  bytes->data.resize(size); return ReadExact(pipe, bytes->data.data(), size);
}
bool WriteExact(HANDLE pipe, const BYTE* bytes, DWORD size) {
  while (size) {
    DWORD count = 0;
    if (!WriteFile(pipe, bytes, size, &count, nullptr) || !count) return false;
    bytes += count; size -= count;
  }
  return true;
}
std::string Utf8(const std::wstring& text) {
  const int count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(),
      static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
  if (count <= 0) return {};
  std::string result(count, '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()),
      result.data(), count, nullptr, nullptr); return result;
}
std::wstring Wide(const BYTE* bytes, size_t size) {
  if (!size || size > kMaxFrame) return {};
  const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      reinterpret_cast<const char*>(bytes), static_cast<int>(size), nullptr, 0);
  if (count <= 0) return {};
  std::wstring result(count, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, reinterpret_cast<const char*>(bytes),
      static_cast<int>(size), result.data(), count); return result;
}
bool Reply(HANDLE pipe, const JsonObject& object) {
  const auto serialized = object.Stringify();
  const auto bytes = Utf8(std::wstring(serialized));
  if (bytes.empty() || bytes.size() > kMaxFrame) return false;
  const DWORD size = static_cast<DWORD>(bytes.size());
  const BYTE header[4]{BYTE(size), BYTE(size >> 8), BYTE(size >> 16), BYTE(size >> 24)};
  return WriteExact(pipe, header, 4) &&
      WriteExact(pipe, reinterpret_cast<const BYTE*>(bytes.data()), size);
}
std::wstring Text(const JsonObject& object, const wchar_t* key) {
  if (!object.HasKey(key) || object.Lookup(key).ValueType() != JsonValueType::String) return {};
  return std::wstring(object.GetNamedString(key));
}
bool Shape(const JsonObject& object, const std::set<std::wstring>& required,
           const std::set<std::wstring>& optional = {}) {
  for (const auto& key : required) if (!object.HasKey(key)) return false;
  for (const auto& entry : object) {
    const std::wstring key(entry.Key());
    if (!required.count(key) && !optional.count(key)) return false;
  }
  return true;
}
bool Reference(const std::wstring& text) {
  if (text.size() < 22 || text.size() > 128) return false;
  for (auto c : text) if (!((c >= L'A' && c <= L'Z') || (c >= L'a' && c <= L'z') ||
      (c >= L'0' && c <= L'9') || c == L'_' || c == L'-')) return false;
  return true;
}
bool Scope(const std::wstring& text) {
  if (text.size() != 64) return false;
  for (auto c : text) if (!((c >= L'a' && c <= L'f') || (c >= L'0' && c <= L'9'))) return false;
  return true;
}
std::wstring NewId() {
  BYTE bytes[32]{};
  if (BCryptGenRandom(nullptr, bytes, sizeof(bytes), BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0) {
    throw winrt::hresult_error(E_FAIL);
  }
  constexpr wchar_t alphabet[] = L"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-";
  std::wstring result;
  unsigned accumulator = 0, bits = 0;
  for (auto byte : bytes) {
    accumulator = (accumulator << 8) | byte; bits += 8;
    while (bits >= 6) { bits -= 6; result += alphabet[(accumulator >> bits) & 63]; }
  }
  if (bits) result += alphabet[(accumulator << (6 - bits)) & 63];
  SecureZeroMemory(bytes, sizeof(bytes)); return result;
}
JsonObject State(const wchar_t* state) {
  JsonObject object;
  object.Insert(L"format", JsonValue::CreateNumberValue(1));
  object.Insert(L"state", JsonValue::CreateStringValue(state)); return object;
}
const wchar_t* PublicError(const std::string& error) {
  if (error == "application_changed") return L"application_changed";
  if (error == "application_unavailable") return L"target_unavailable";
  if (error == "access_denied" || error == "security_context_changed") return L"access_denied";
  if (error == "busy") return L"busy";
  if (error == "unsupported_secret") return L"unsupported_secret";
  if (error == "unsupported_target") return L"unsupported_target";
  if (error == "material_unavailable") return L"service_unavailable";
  if (error == "target_not_visible" || error == "target_expired" || error == "target_invalidated" ||
      error == "element_unavailable" || error == "window_changed" || error == "preparation_closed") return L"target_unavailable";
  if (error == "target_changed" || error == "target_disabled" || error == "target_readonly" ||
      error == "ambiguous_or_removed") return L"destination_changed";
  return L"session_unavailable";
}
JsonObject Refused(const wchar_t* error) {
  auto object = State(L"refused"); object.Insert(L"errorCode", JsonValue::CreateStringValue(error)); return object;
}
std::wstring Label(std::wstring text) {
  if (text.size() > 256) text.resize(256);
  if (!text.empty() && text.back() >= 0xd800 && text.back() <= 0xdbff) text.pop_back();
  for (auto& c : text) if (c < 32 || c == 127) c = L' ';
  return text;
}
std::wstring AppName(const std::wstring& executable) {
  const auto slash = executable.find_last_of(L"\\/");
  return Label(executable.substr(slash == std::wstring::npos ? 0 : slash + 1));
}
bool SameSnapshot(const JsonObject& a, const JsonObject& b) {
  const std::set<std::wstring> keys{L"targetId", L"helperInstanceId", L"platform", L"application",
      L"appId", L"appName", L"windowId", L"windowTitle", L"fieldLabel", L"controlKind"};
  if (!Shape(a, keys) || !Shape(b, keys)) return false;
  for (const auto& key : keys) {
    if (key == L"application") continue;
    if (a.Lookup(key).ValueType() != JsonValueType::String ||
        Text(a, key.c_str()) != Text(b, key.c_str())) return false;
  }
  if (a.Lookup(L"application").ValueType() != JsonValueType::Object) return false;
  const auto left = a.GetNamedObject(L"application"), right = b.GetNamedObject(L"application");
  return Shape(left, {L"executable", L"sha256"}) &&
      Text(left, L"executable") == Text(right, L"executable") && Text(left, L"sha256") == Text(right, L"sha256");
}
struct Item {
  std::wstring scope;
  HWND window;
  std::shared_ptr<nb::Target> target;
  JsonObject snapshot;
  ULONGLONG expires;
  bool retained = false;
};
struct Lease {
  std::wstring scope, target_id;
  std::unique_ptr<nb::Prepared> prepared;
  bool attempted = false;
};
class Registry final {
 public:
  const std::wstring instance = NewId();
  JsonObject Command(const JsonObject& request) {
    Prune();
    if (!request.HasKey(L"format") || request.Lookup(L"format").ValueType() != JsonValueType::Number ||
        request.GetNamedNumber(L"format") != 1) return Refused(L"input_rejected");
    const auto scope = Text(request, L"scope"), command = Text(request, L"command");
    if (command == L"dispose") {
      if (!Shape(request, {L"format", L"command"})) return Refused(L"input_rejected");
      leases_.clear(); items_.clear(); return State(L"disposed");
    }
    if (!Scope(scope)) return Refused(L"scope_not_approved");
    if (command == L"discover") return Discover(request, scope);
    if (command == L"prepare") return Prepare(request, scope);
    if (command == L"setValue") return SetValue(request, scope);
    if (command == L"close") return Close(request, scope);
    if (command == L"release") return Release(request, scope);
    return Refused(L"input_rejected");
  }
 private:
  std::map<std::wstring, Item> items_;
  std::map<std::wstring, Lease> leases_;
  void Prune() {
    const auto now = GetTickCount64();
    for (auto i = items_.begin(); i != items_.end();) {
      if (!i->second.retained && i->second.expires <= now) i = items_.erase(i); else ++i;
    }
  }
  JsonObject Discover(const JsonObject& request, const std::wstring& scope) {
    if (!Shape(request, {L"format", L"command", L"scope", L"appId"}, {L"windowId"})) return Refused(L"input_rejected");
    const auto app = Text(request, L"appId"), window = Text(request, L"windowId");
    if (app.size() < 7 || app.size() > 4096 || app[1] != L':' ||
        (app[2] != L'\\' && app[2] != L'/')) return Refused(L"unsupported_target");
    HWND selected = nullptr;
    if (request.HasKey(L"windowId")) {
      if (!Reference(window)) return Refused(L"target_unavailable");
      for (const auto& pair : items_) {
        if (pair.second.scope == scope && Text(pair.second.snapshot, L"windowId") == window &&
            Text(pair.second.snapshot, L"appId") == app &&
            pair.second.target->Recheck().empty()) selected = pair.second.window;
      }
      if (!selected) return Refused(L"target_unavailable");
    }
    size_t unused = 0;
    for (const auto& pair : items_) if (pair.second.scope == scope && !pair.second.retained) ++unused;
    std::string error;
    auto found = nb::DiscoverNativeFields(app, selected, 64, &error);
    if (!error.empty()) return Refused(PublicError(error));
    // Distinct opaque IDs alone are not enough to let a user identify a field.
    // Reject discovery when two roots still have the same complete public
    // window/field description; never make the Agent guess between them.
    std::set<std::pair<std::wstring, std::wstring>> descriptions;
    for (const auto& candidate : found) {
      const auto key = std::make_pair(Label(candidate.target->window_description()), Label(candidate.target->field_description()));
      if (!descriptions.insert(key).second) return Refused(L"unsupported_target");
    }
    JsonArray targets;
    for (auto& candidate : found) {
      bool reused = false;
      for (const auto& pair : items_) {
        if (!pair.second.target->SameInstance(*candidate.target) ||
            !pair.second.target->Recheck().empty()) continue;
        if (pair.second.scope == scope) {
          targets.Append(pair.second.snapshot); reused = true; break;
        }
        // Share the live object across scopes so native busy is per concrete
        // control. Public IDs, snapshots, promotion counts and leases remain
        // scope-owned; sharing never grants another scope access to an ID.
        candidate.target = pair.second.target;
      }
      if (reused) continue;
      if (unused >= 64 || items_.size() >= kGlobalTargetLimit) return Refused(L"busy");
      const auto id = NewId(); std::wstring window_id;
      for (const auto& pair : items_) if (pair.second.scope == scope && pair.second.window == candidate.window &&
          Text(pair.second.snapshot, L"appId") == app && pair.second.target->Recheck().empty()) {
        window_id = Text(pair.second.snapshot, L"windowId"); break;
      }
      if (window_id.empty()) window_id = NewId();
      JsonObject target, application;
      application.Insert(L"executable", JsonValue::CreateStringValue(candidate.executable));
      application.Insert(L"sha256", JsonValue::CreateStringValue(winrt::to_hstring(candidate.sha256)));
      target.Insert(L"targetId", JsonValue::CreateStringValue(id));
      target.Insert(L"helperInstanceId", JsonValue::CreateStringValue(instance));
      target.Insert(L"platform", JsonValue::CreateStringValue(L"windows"));
      target.Insert(L"application", application);
      target.Insert(L"appId", JsonValue::CreateStringValue(app));
      target.Insert(L"appName", JsonValue::CreateStringValue(AppName(candidate.executable)));
      target.Insert(L"windowId", JsonValue::CreateStringValue(window_id));
      target.Insert(L"windowTitle", JsonValue::CreateStringValue(Label(candidate.target->window_description())));
      target.Insert(L"fieldLabel", JsonValue::CreateStringValue(Label(candidate.target->field_description())));
      target.Insert(L"controlKind", JsonValue::CreateStringValue(L"windows_uia_password"));
      targets.Append(target);
      items_.emplace(id, Item{scope, candidate.window, std::move(candidate.target), target,
          GetTickCount64() + 300000, false});
      ++unused;
    }
    auto response = State(L"ready"); response.Insert(L"targets", targets); return response;
  }
  JsonObject Prepare(const JsonObject& request, const std::wstring& scope) {
    if (!Shape(request, {L"format", L"command", L"scope", L"targetId"}, {L"expected"})) return Refused(L"input_rejected");
    const auto id = Text(request, L"targetId");
    if (!Reference(id)) return Refused(L"target_unavailable");
    const auto item = items_.find(id);
    if (item == items_.end()) return Refused(L"target_unavailable");
    if (item->second.scope != scope) return Refused(L"scope_not_approved");
    if (request.HasKey(L"expected") && (request.Lookup(L"expected").ValueType() != JsonValueType::Object ||
        !SameSnapshot(request.GetNamedObject(L"expected"), item->second.snapshot))) return Refused(L"destination_changed");
    size_t retained = 0;
    for (const auto& pair : items_) if (pair.second.scope == scope && pair.second.retained) ++retained;
    if ((!item->second.retained && retained >= 256) || leases_.size() >= kGlobalLeaseLimit) return Refused(L"busy");
    std::string error;
    auto ticket = item->second.target->Prepare(&error);
    if (!ticket) return Refused(PublicError(error));
    if (!item->second.target->Retain(&error)) return Refused(PublicError(error));
    item->second.retained = true;
    const auto lease = NewId();
    leases_.emplace(lease, Lease{scope, id, std::move(ticket), false});
    auto response = State(L"prepared"); response.Insert(L"target", item->second.snapshot);
    response.Insert(L"leaseId", JsonValue::CreateStringValue(lease)); return response;
  }
  JsonObject SetValue(const JsonObject& request, const std::wstring& scope) {
    if (!Shape(request, {L"format", L"command", L"scope", L"leaseId", L"bytes"})) return Refused(L"input_rejected");
    const auto id = Text(request, L"leaseId");
    const auto lease = leases_.find(id);
    if (!Reference(id) || lease == leases_.end()) return Refused(L"target_unavailable");
    if (lease->second.scope != scope) return Refused(L"scope_not_approved");
    if (lease->second.attempted) return Refused(L"input_rejected");
    lease->second.attempted = true;
    if (request.Lookup(L"bytes").ValueType() != JsonValueType::Array) return Refused(L"unsupported_secret");
    const auto array = request.GetNamedArray(L"bytes");
    if (array.Size() == 0 || array.Size() > 16384) return Refused(L"unsupported_secret");
    Bytes bytes; bytes.data.reserve(array.Size());
    for (const auto& value : array) {
      if (value.ValueType() != JsonValueType::Number) return Refused(L"unsupported_secret");
      const auto number = value.GetNumber();
      if (!(number >= 0 && number <= 255) || number != static_cast<int>(number)) return Refused(L"unsupported_secret");
      bytes.data.push_back(static_cast<BYTE>(number));
    }
    SensitiveText text{Wide(bytes.data.data(), bytes.data.size())};
    // The JSON numeric values are also temporary material; remove them before
    // dispatch. Frame and decoded text buffers are wiped on all normal paths.
    for (uint32_t i = 0; i < array.Size(); ++i) array.SetAt(i, JsonValue::CreateNumberValue(0));
    const auto result = lease->second.prepared->Replace(text.value.data(), text.value.size());
    if (result.outcome == nb::Outcome::kSent) return State(L"sent");
    if (result.outcome == nb::Outcome::kUnknown) {
      auto response = State(L"unknown"); response.Insert(L"errorCode", JsonValue::CreateStringValue(L"fill_unknown")); return response;
    }
    return Refused(PublicError(result.error));
  }
  JsonObject Close(const JsonObject& request, const std::wstring& scope) {
    if (!Shape(request, {L"format", L"command", L"scope", L"leaseId"})) return Refused(L"input_rejected");
    const auto id = Text(request, L"leaseId");
    if (!Reference(id)) return Refused(L"target_unavailable");
    const auto lease = leases_.find(id);
    if (lease != leases_.end()) {
      if (lease->second.scope != scope) return Refused(L"scope_not_approved");
      leases_.erase(lease);
    }
    return State(L"closed");
  }
  JsonObject Release(const JsonObject& request, const std::wstring& scope) {
    if (!Shape(request, {L"format", L"command", L"scope", L"targetId"})) return Refused(L"input_rejected");
    const auto id = Text(request, L"targetId");
    if (!Reference(id)) return Refused(L"target_unavailable");
    const auto item = items_.find(id);
    if (item != items_.end()) {
      if (item->second.scope != scope) return Refused(L"scope_not_approved");
      for (auto lease = leases_.begin(); lease != leases_.end();) {
        if (lease->second.target_id == id) lease = leases_.erase(lease); else ++lease;
      }
      items_.erase(item);
    }
    return State(L"released");
  }
};

HANDLE PinParent(DWORD expected) {
  const auto snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return nullptr;
  PROCESSENTRY32W entry{}; entry.dwSize = sizeof(entry); DWORD actual = 0;
  if (Process32FirstW(snapshot, &entry)) do {
    if (entry.th32ProcessID == GetCurrentProcessId()) { actual = entry.th32ParentProcessID; break; }
  } while (Process32NextW(snapshot, &entry));
  CloseHandle(snapshot);
  if (!expected || expected != actual) return nullptr;
  HANDLE parent = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, expected);
  const auto created = parent ? nb::ProcessCreatedAt(parent) : 0;
  if (!parent || !created || created > nb::ProcessCreatedAt(GetCurrentProcess()) ||
      WaitForSingleObject(parent, 0) != WAIT_TIMEOUT) { if (parent) CloseHandle(parent); return nullptr; }
  return parent;
}
int Run() {
  const auto input = GetStdHandle(STD_INPUT_HANDLE), output = GetStdHandle(STD_OUTPUT_HANDLE);
  if (GetFileType(input) != FILE_TYPE_PIPE || GetFileType(output) != FILE_TYPE_PIPE) return 64;
  Bytes init;
  if (!ReadFrame(input, &init) || init.data.size() != 38 || init.data[0] != 1 || init.data[1] != 0) return 64;
  const DWORD parent_pid = init.data[2] | (DWORD(init.data[3]) << 8) | (DWORD(init.data[4]) << 16) | (DWORD(init.data[5]) << 24);
  const auto parent = PinParent(parent_pid);
  if (!parent) return 64;
  std::thread([parent] { WaitForSingleObject(parent, INFINITE); CloseHandle(parent); ExitProcess(0); }).detach();
  wchar_t self[32768]{}; GetModuleFileNameW(nullptr, self, 32768);
  std::wstring path; std::string digest, expected;
  constexpr char digits[] = "0123456789abcdef";
  for (size_t i = 6; i < 38; ++i) { expected += digits[init.data[i] >> 4]; expected += digits[init.data[i] & 15]; }
  if (!nb::InspectExecutable(self, &path, &digest) || digest != expected) return 64;
  Registry registry;
  auto hello = State(L"ready"); hello.Insert(L"helperInstanceId", JsonValue::CreateStringValue(registry.instance));
  if (!Reply(output, hello)) return 0;
  for (;;) {
    Bytes frame;
    if (!ReadFrame(input, &frame)) return 0;
    SensitiveText text{Wide(frame.data.data(), frame.data.size())};
    JsonObject request;
    if (text.value.empty() || !JsonObject::TryParse(text.value, request)) return 64;
    JsonObject response;
    try { response = registry.Command(request); }
    catch (...) {
      // A setter may already have started. Never emit request/exception text.
      response = State(L"unknown"); response.Insert(L"errorCode", JsonValue::CreateStringValue(L"fill_unknown"));
    }
    if (!Reply(output, response)) return 0;
    if (Text(request, L"command") == L"dispose" && Text(response, L"state") == L"disposed") return 0;
  }
}
}
int APIENTRY wWinMain(HINSTANCE, HINSTANCE, wchar_t* arguments, int) {
  if (std::wstring(arguments) != L"--native-background-v2") return 64;
  try {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    const int result = Run(); winrt::uninit_apartment(); return result;
  } catch (...) { return 70; }
}
