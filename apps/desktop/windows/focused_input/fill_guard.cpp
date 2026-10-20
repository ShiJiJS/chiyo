#include "fill_guard.h"
#include <bcrypt.h>
#include <sddl.h>
#include <tlhelp32.h>
#include <algorithm>
#include <array>
#include <map>
#include <set>

namespace focused_input {
Handle::~Handle() {
  if (value_ != nullptr && value_ != INVALID_HANDLE_VALUE) CloseHandle(value_);
}
bool SamePath(const std::wstring& a, const std::wstring& b) {
  return !a.empty() && !b.empty() && CompareStringOrdinal(a.c_str(), -1,
      b.c_str(), -1, TRUE) == CSTR_EQUAL;
}
namespace {
unsigned long long Birth(HANDLE process) {
  FILETIME created{}, exited{}, kernel{}, user{};
  if (!GetProcessTimes(process, &created, &exited, &kernel, &user)) return 0;
  return (static_cast<unsigned long long>(created.dwHighDateTime) << 32) |
      created.dwLowDateTime;
}
bool Alive(HANDLE process) { return WaitForSingleObject(process, 0) == WAIT_TIMEOUT; }
std::wstring ProcessPath(HANDLE process) {
  std::wstring path(32768, L'\0'); DWORD size = static_cast<DWORD>(path.size());
  if (!QueryFullProcessImageNameW(process, 0, path.data(), &size)) return {};
  path.resize(size); return path;
}
bool Security(HANDLE process, std::wstring* sid, DWORD* integrity) {
  HANDLE raw = nullptr;
  if (!OpenProcessToken(process, TOKEN_QUERY, &raw)) return false;
  Handle token(raw); DWORD required = 0;
  GetTokenInformation(raw, TokenUser, nullptr, 0, &required);
  if (required == 0 || required > 65536) return false;
  std::vector<BYTE> user(required);
  if (!GetTokenInformation(raw, TokenUser, user.data(), required, &required)) return false;
  LPWSTR text = nullptr;
  if (!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(user.data())->User.Sid, &text)) return false;
  *sid = text; LocalFree(text);
  required = 0;
  GetTokenInformation(raw, TokenIntegrityLevel, nullptr, 0, &required);
  if (required == 0 || required > 65536) return false;
  std::vector<BYTE> label(required);
  if (!GetTokenInformation(raw, TokenIntegrityLevel, label.data(), required, &required)) return false;
  const auto value = reinterpret_cast<TOKEN_MANDATORY_LABEL*>(label.data())->Label.Sid;
  if (!IsValidSid(value) || *GetSidSubAuthorityCount(value) == 0) return false;
  *integrity = *GetSidSubAuthority(value, *GetSidSubAuthorityCount(value) - 1);
  return true;
}
std::map<DWORD, DWORD> Parents() {
  Handle snapshot(CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0));
  std::map<DWORD, DWORD> result;
  PROCESSENTRY32W entry{}; entry.dwSize = sizeof(entry);
  if (snapshot.get() == INVALID_HANDLE_VALUE || !Process32FirstW(snapshot.get(), &entry)) return result;
  do { result[entry.th32ProcessID] = entry.th32ParentProcessID; }
  while (Process32NextW(snapshot.get(), &entry));
  return result;
}
}

std::unique_ptr<FileSeal> SealFile(const std::wstring& path) {
  const HANDLE raw = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
      nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
  if (raw == INVALID_HANDLE_VALUE) return nullptr;
  auto result = std::make_unique<FileSeal>(raw);
  std::wstring actual(32768, L'\0');
  const DWORD size = GetFinalPathNameByHandleW(raw, actual.data(),
      static_cast<DWORD>(actual.size()), FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (size == 0 || size >= actual.size()) return nullptr;
  actual.resize(size);
  if (actual.rfind(L"\\\\?\\", 0) == 0) actual.erase(0, 4);
  result->path = actual;
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0) return nullptr;
  bool ok = BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0) >= 0;
  std::array<BYTE, 65536> buffer{};
  DWORD count = 0;
  while (ok) {
    if (!ReadFile(raw, buffer.data(), static_cast<DWORD>(buffer.size()), &count, nullptr)) { ok = false; break; }
    if (count == 0) break;
    ok = BCryptHashData(hash, buffer.data(), count, 0) >= 0;
  }
  std::array<BYTE, 32> digest{};
  if (ok) ok = BCryptFinishHash(hash, digest.data(), static_cast<ULONG>(digest.size()), 0) >= 0;
  if (hash != nullptr) BCryptDestroyHash(hash);
  BCryptCloseAlgorithmProvider(algorithm, 0);
  if (!ok) return nullptr;
  const char* digits = "0123456789abcdef";
  for (const auto byte : digest) {
    result->sha256 += digits[byte >> 4]; result->sha256 += digits[byte & 15];
  }
  return result;
}

bool SameTarget(const FocusSnapshot& a, const FocusSnapshot& b) {
  return b.RecognizesPassword() && a.foreground == b.foreground &&
      a.native_focus == b.native_focus && a.runtime_id == b.runtime_id &&
      a.application.pid == b.application.pid &&
      a.application.created_at == b.application.created_at &&
      a.provider.pid == b.provider.pid && a.provider.created_at == b.provider.created_at &&
      SamePath(a.application.executable, b.application.executable) &&
      SamePath(a.provider.executable, b.provider.executable);
}
bool ValidUnits(const std::vector<wchar_t>& units) {
  if (units.empty() || units.size() > 16) return false;
  for (size_t i = 0; i < units.size(); ++i) {
    const auto c = static_cast<unsigned int>(units[i]);
    if (c < 32 || c == 127 || (c >= 0xdc00 && c <= 0xdfff)) return false;
    if (c >= 0xd800 && c <= 0xdbff) {
      if (++i >= units.size() || units[i] < 0xdc00 || units[i] > 0xdfff) return false;
    }
  }
  return true;
}
std::string Refusal(const FocusSnapshot& s) {
  if (s.error == "desktop_locked" || s.error == "session_unavailable" ||
      s.error == "unsupported_desktop") return s.error;
  if (!s.modifiers_released && s.error.empty()) return "modifier_active";
  if (!s.stable && s.error.empty()) return "focus_changed";
  return "unsupported_target";
}
std::unique_ptr<Handle> PinParent(DWORD expected) {
  const auto parents = Parents();
  const auto entry = parents.find(GetCurrentProcessId());
  if (expected == 0 || entry == parents.end() || entry->second != expected) return nullptr;
  auto result = std::make_unique<Handle>(OpenProcess(
      SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, expected));
  if (result->get() == nullptr || !Alive(result->get()) || Birth(result->get()) == 0 ||
      Birth(result->get()) > Birth(GetCurrentProcess())) return nullptr;
  return result;
}

std::unique_ptr<TargetGuard> TargetGuard::Prepare(
    const std::wstring& approved_path, const std::string& approved_sha, std::string* error) {
  auto result = std::unique_ptr<TargetGuard>(new TargetGuard());
  result->target_ = CaptureFocus();
  if (!result->target_.RecognizesPassword()) { *error = Refusal(result->target_); return nullptr; }
  result->application_ = SealFile(result->target_.application.executable);
  result->provider_ = SealFile(result->target_.provider.executable);
  if (!result->application_ || !result->provider_) { *error = "access_denied"; return nullptr; }
  if (!approved_path.empty() && (!SamePath(approved_path, result->application_->path) ||
      approved_sha != result->application_->sha256)) { *error = "application_changed"; return nullptr; }
  std::wstring own_sid; DWORD own_integrity = 0;
  if (!Security(GetCurrentProcess(), &own_sid, &own_integrity)) { *error = "access_denied"; return nullptr; }
  const auto parents = Parents(); std::set<DWORD> seen;
  DWORD id = result->target_.provider.pid, own_session = 0;
  if (!ProcessIdToSessionId(GetCurrentProcessId(), &own_session)) {
    *error = "session_unavailable"; return nullptr;
  }
  unsigned long long child_birth = ~0ull;
  bool reached = false;
  for (int depth = 0; depth < 32 && seen.insert(id).second; ++depth) {
    auto process = std::make_unique<Handle>(OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, id));
    DWORD session = 0, integrity = 0; std::wstring sid;
    const auto birth = process->get() == nullptr ? 0 : Birth(process->get());
    if (process->get() == nullptr || !Alive(process->get()) || birth == 0 || birth > child_birth ||
        !ProcessIdToSessionId(id, &session) || session != own_session ||
        !Security(process->get(), &sid, &integrity) || sid != own_sid || integrity > own_integrity) {
      *error = "access_denied"; return nullptr;
    }
    if (id == result->target_.provider.pid && (birth != result->target_.provider.created_at ||
        !SamePath(ProcessPath(process->get()), result->target_.provider.executable))) {
      *error = "application_changed"; return nullptr;
    }
    if (id == result->target_.application.pid) {
      reached = birth == result->target_.application.created_at &&
          SamePath(ProcessPath(process->get()), result->target_.application.executable);
      result->processes_.push_back(std::move(process)); break;
    }
    result->processes_.push_back(std::move(process)); child_birth = birth;
    const auto parent = parents.find(id);
    if (parent == parents.end() || parent->second == 0) break;
    id = parent->second;
  }
  if (!reached) { *error = "unsupported_target"; return nullptr; }
  *error = result->Recheck();
  return error->empty() ? std::move(result) : nullptr;
}
std::string TargetGuard::Recheck() const {
  for (const auto& process : processes_) if (!Alive(process->get())) return "application_changed";
  const auto current = CaptureFocus();
  if (!current.RecognizesPassword()) return Refusal(current);
  return SameTarget(target_, current) ? "" : "focus_changed";
}
std::string TargetGuard::PublicApplication() const {
  return "{\"executable\":" + JsonString(application_->path) +
      ",\"sha256\":\"" + application_->sha256 + "\"}";
}
std::unique_ptr<Handle> ReserveDesktop(std::string* error) {
  std::wstring sid; DWORD integrity = 0;
  if (!Security(GetCurrentProcess(), &sid, &integrity)) { *error = "access_denied"; return nullptr; }
  const auto name = L"Local\\AgentInfoFocusedFill-" + sid;
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  const auto sddl = L"D:P(A;;GA;;;SY)(A;;GA;;;" + sid + L")";
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(), SDDL_REVISION_1, &descriptor, nullptr)) {
    *error = "access_denied"; return nullptr;
  }
  SECURITY_ATTRIBUTES attributes{sizeof(SECURITY_ATTRIBUTES), descriptor, FALSE};
  auto mutex = std::make_unique<Handle>(CreateMutexW(&attributes, FALSE, name.c_str()));
  LocalFree(descriptor);
  if (mutex->get() == nullptr) { *error = "access_denied"; return nullptr; }
  const auto wait = WaitForSingleObject(mutex->get(), 0);
  if (wait != WAIT_OBJECT_0 && wait != WAIT_ABANDONED) { *error = "busy"; return nullptr; }
  // The helper's main thread holds this mutex until process exit. Handle close
  // alone does not release ownership; WinMain always exits after the session.
  return mutex;
}
}  // namespace focused_input
