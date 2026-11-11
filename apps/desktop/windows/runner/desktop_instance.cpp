#include "desktop_instance.h"
#include <bcrypt.h>
#include <sddl.h>
#include <algorithm>
#include <array>
#include <cwctype>

namespace {
std::optional<std::wstring> Absolute(const std::wstring& value) {
  if (value.empty() || value.size() >= 32768 || value.find(L'\0') != std::wstring::npos)
    return std::nullopt;
  std::array<wchar_t, 32768> path{};
  const DWORD length = GetFullPathNameW(value.c_str(), static_cast<DWORD>(path.size()), path.data(), nullptr);
  if (length == 0 || length >= path.size()) return std::nullopt;
  std::wstring result(path.data(), length);
  std::replace(result.begin(), result.end(), L'/', L'\\');
  std::transform(result.begin(), result.end(), result.begin(), towlower);
  while (result.size() > 3 && result.back() == L'\\') result.pop_back();
  return result;
}
std::optional<std::wstring> UserSid() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return std::nullopt;
  DWORD length = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &length);
  std::vector<BYTE> bytes(length);
  const bool read = length > 0 && GetTokenInformation(token, TokenUser, bytes.data(), length, &length);
  CloseHandle(token);
  if (!read) return std::nullopt;
  LPWSTR sid = nullptr;
  if (!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(bytes.data())->User.Sid, &sid)) return std::nullopt;
  std::wstring result(sid);
  LocalFree(sid);
  return result;
}
std::optional<std::wstring> Digest(const std::wstring& value) {
  std::array<UCHAR, 32> hash{};
  if (BCryptHash(BCRYPT_SHA256_ALG_HANDLE, nullptr, 0,
      reinterpret_cast<PUCHAR>(const_cast<wchar_t*>(value.data())),
      static_cast<ULONG>(value.size() * sizeof(wchar_t)), hash.data(),
      static_cast<ULONG>(hash.size())) < 0) return std::nullopt;
  const wchar_t* digits = L"0123456789abcdef";
  std::wstring result;
  for (auto byte : hash) { result += digits[byte >> 4]; result += digits[byte & 15]; }
  return result;
}
struct Target { const std::wstring& property; HWND window = nullptr; };
BOOL CALLBACK Find(HWND window, LPARAM parameter) {
  auto& target = *reinterpret_cast<Target*>(parameter);
  if (GetPropW(window, target.property.c_str()) != reinterpret_cast<HANDLE>(1)) return TRUE;
  target.window = window;
  return FALSE;
}
}

std::optional<std::wstring> DesktopInstance::Scope(
    const std::wstring& executable, const std::wstring& app_data,
    const std::vector<std::string>& arguments) {
  const auto image = Absolute(executable), base = Absolute(app_data);
  if (!image || !base) return std::nullopt;
  std::wstring directory = *base + L"\\chiyo\\online";
  if (!arguments.empty()) {
    if (arguments.size() != 2 || arguments[0] != "--connection-profile") return std::nullopt;
    const auto& name = arguments[1];
    const auto alnum = [](char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'); };
    if (name.empty() || name.size() > 64 || !alnum(name[0]) ||
        !std::all_of(name.begin(), name.end(), [&](char c) { return alnum(c) || c == '_' || c == '-'; })) return std::nullopt;
    directory += L"\\profiles\\" + std::wstring(name.begin(), name.end());
    std::transform(directory.begin(), directory.end(), directory.begin(), towlower);
  }
  return *image + L"\n" + directory;
}
std::optional<std::wstring> DesktopInstance::CurrentScope(const std::vector<std::string>& arguments) {
  std::array<wchar_t, 32768> image{}, base{};
  const DWORD image_length = GetModuleFileNameW(nullptr, image.data(), static_cast<DWORD>(image.size()));
  const DWORD base_length = GetEnvironmentVariableW(L"APPDATA", base.data(), static_cast<DWORD>(base.size()));
  if (image_length == 0 || image_length >= image.size() || base_length == 0 || base_length >= base.size()) return std::nullopt;
  return Scope(image.data(), base.data(), arguments);
}
UINT DesktopInstance::ActivationMessage() {
  static const UINT message = RegisterWindowMessageW(L"Chiyo.ActivateExisting.v1");
  return message;
}
bool DesktopInstance::HandleActivation(HWND window, UINT message, WPARAM process, LPARAM reserved) {
  if (message != ActivationMessage() || message == 0 || process != GetCurrentProcessId() || reserved != 0) return false;
  ShowWindow(window, IsIconic(window) ? SW_RESTORE : SW_SHOW);
  const HWND popup = GetLastActivePopup(window);
  SetForegroundWindow(popup && IsWindowVisible(popup) ? popup : window);
  return true;
}
DesktopInstance::DesktopInstance(const std::wstring& scope, DWORD timeout_ms) {
  const auto sid = UserSid();
  const auto digest = sid ? Digest(*sid + L"\n" + scope) : std::nullopt;
  if (scope.empty() || !digest || ActivationMessage() == 0) return;
  property_ = L"Chiyo.Instance.v1." + *digest;
  mutex_ = CreateMutexW(nullptr, FALSE, (L"Local\\" + property_).c_str());
  if (!mutex_) return;
  const ULONGLONG started = GetTickCount64();
  do {
    const DWORD acquired = WaitForSingleObject(mutex_, 0);
    if (acquired == WAIT_OBJECT_0 || acquired == WAIT_ABANDONED) {
      owns_ = true;
      result_ = Result::primary;
      return;
    }
    if (acquired != WAIT_TIMEOUT) return;
    Target target{property_};
    EnumWindows(Find, reinterpret_cast<LPARAM>(&target));
    if (target.window) {
      DWORD process = 0;
      GetWindowThreadProcessId(target.window, &process);
      AllowSetForegroundWindow(process);
      DWORD_PTR response = 0;
      if (SendMessageTimeoutW(target.window, ActivationMessage(), process, 0,
          SMTO_ABORTIFHUNG | SMTO_BLOCK, 1000, &response) && response == 1) result_ = Result::activated;
      return; // A hung owner must never permit a second database writer.
    }
    Sleep(25); // First process may still be creating its native window.
  } while (GetTickCount64() - started < timeout_ms);
}
bool DesktopInstance::Attach(HWND window) {
  if (!owns_ || !IsWindow(window) || !SetPropW(window, property_.c_str(), reinterpret_cast<HANDLE>(1))) return false;
  window_ = window;
  return true;
}
DesktopInstance::~DesktopInstance() {
  if (window_ && IsWindow(window_)) RemovePropW(window_, property_.c_str());
  if (owns_) ReleaseMutex(mutex_);
  if (mutex_) CloseHandle(mutex_);
}
