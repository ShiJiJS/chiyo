#include "owner_file_opener.h"
#include <windows.h>
#include <aclapi.h>
#include <bcrypt.h>
#include <array>
#include <regex>
#include <tuple>
#include <vector>

namespace {
struct Handle {
  HANDLE value = INVALID_HANDLE_VALUE;
  explicit Handle(HANDLE handle) : value(handle) {}
  ~Handle() { if (value != INVALID_HANDLE_VALUE && value != nullptr) CloseHandle(value); }
  bool valid() const { return value != INVALID_HANDLE_VALUE && value != nullptr; }
};
bool Hash(const std::string& text) { return std::regex_match(text, std::regex("[0-9a-f]{64}")); }
bool Id(const std::string& text) { return std::regex_match(text, std::regex("[A-Za-z0-9_-]{1,128}")); }
std::wstring Wide(const std::string& text) {
  if (text.empty() || text.size() > 32768 || text.find('\0') != std::string::npos) return {};
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0);
  if (size <= 0) return {};
  std::wstring result(static_cast<size_t>(size), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), result.data(), size) != size) return {};
  for (auto& c : result) if (c == L'/') c = L'\\';
  return result;
}
std::wstring Canonical(HANDLE handle) {
  std::array<wchar_t, 32768> value{};
  const auto size = GetFinalPathNameByHandleW(handle, value.data(), static_cast<DWORD>(value.size()), 0);
  if (size == 0 || size >= value.size()) return {};
  std::wstring path(value.data(), size);
  if (path.rfind(L"\\\\?\\", 0) != 0) return {};
  return path.substr(4);
}
bool SamePath(const std::wstring& first, const std::wstring& second) {
  return !first.empty() && !second.empty() && _wcsicmp(first.c_str(), second.c_str()) == 0;
}
bool Private(HANDLE file) {
  HANDLE raw_token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &raw_token)) return false;
  Handle token(raw_token);
  DWORD required = 0;
  GetTokenInformation(token.value, TokenUser, nullptr, 0, &required);
  if (required == 0 || required > 65536) return false;
  std::vector<uint8_t> user(required);
  if (!GetTokenInformation(token.value, TokenUser, user.data(), required, &required)) return false;
  const auto sid = reinterpret_cast<TOKEN_USER*>(user.data())->User.Sid;
  std::array<uint8_t, SECURITY_MAX_SID_SIZE> system_sid{};
  DWORD sid_size = static_cast<DWORD>(system_sid.size());
  if (!CreateWellKnownSid(WinLocalSystemSid, nullptr, system_sid.data(), &sid_size)) return false;
  PSID owner = nullptr;
  PACL acl = nullptr;
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (GetSecurityInfo(file, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
      &owner, nullptr, &acl, nullptr, &descriptor) != ERROR_SUCCESS) return false;
  struct Descriptor { PSECURITY_DESCRIPTOR value; ~Descriptor() { LocalFree(value); } } guard{descriptor};
  SECURITY_DESCRIPTOR_CONTROL control = 0;
  DWORD revision = 0;
  if (!owner || !EqualSid(owner, sid) || !acl || acl->AceCount != 2 ||
      !GetSecurityDescriptorControl(descriptor, &control, &revision) || !(control & SE_DACL_PROTECTED)) return false;
  bool current_user = false, system = false;
  for (DWORD index = 0; index < 2; index++) {
    void* raw = nullptr;
    if (!GetAce(acl, index, &raw)) return false;
    const auto* ace = static_cast<ACCESS_ALLOWED_ACE*>(raw);
    if (ace->Header.AceType != ACCESS_ALLOWED_ACE_TYPE || (ace->Header.AceFlags & INHERITED_ACE) ||
        ace->Mask != FILE_ALL_ACCESS) return false;
    const auto trustee = const_cast<DWORD*>(&ace->SidStart);
    if (EqualSid(trustee, sid)) current_user = true;
    else if (EqualSid(trustee, system_sid.data())) system = true;
    else return false;
  }
  return current_user && system;
}
std::string Identity(HANDLE handle, bool directory) {
  BY_HANDLE_FILE_INFORMATION info{};
  if (!GetFileInformationByHandle(handle, &info) || (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
      ((info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) != directory ||
      (!directory && info.nNumberOfLinks != 1) || !Private(handle)) return {};
  return std::to_string(info.dwVolumeSerialNumber) + ":" + std::to_string(info.nFileIndexHigh) + ":" + std::to_string(info.nFileIndexLow);
}
bool Content(HANDLE file, int64_t expected_length, const std::string& expected_digest) {
  LARGE_INTEGER size{};
  if (!GetFileSizeEx(file, &size) || size.QuadPart != expected_length) return false;
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0) return false;
  bool valid = BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0) >= 0;
  std::array<uint8_t, 65536> buffer{};
  int64_t total = 0;
  while (valid) {
    DWORD count = 0;
    valid = ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()), &count, nullptr) != FALSE;
    if (!valid || count == 0) break;
    total += count;
    if (total > expected_length) { valid = false; break; }
    valid = BCryptHashData(hash, buffer.data(), count, 0) >= 0;
  }
  SecureZeroMemory(buffer.data(), buffer.size());
  std::array<uint8_t, 32> digest{};
  valid = valid && total == expected_length && BCryptFinishHash(hash, digest.data(), static_cast<ULONG>(digest.size()), 0) >= 0;
  if (hash) BCryptDestroyHash(hash);
  BCryptCloseAlgorithmProvider(algorithm, 0);
  static const char hex[] = "0123456789abcdef";
  std::string actual;
  for (auto byte : digest) { actual += hex[byte >> 4]; actual += hex[byte & 15]; }
  return valid && actual == expected_digest;
}
bool Valid(const OwnerFileIntent& intent) {
  return Id(intent.operation_id) && Hash(intent.command_digest) && Hash(intent.content_digest) &&
      intent.byte_length >= 0 && intent.byte_length <= 10 * 1024 * 1024 &&
      intent.directory_identity.size() <= 200 && intent.file_identity.size() <= 200 &&
      std::regex_match(intent.directory_identity, std::regex("[0-9]+:[0-9]+:[0-9]+")) &&
      std::regex_match(intent.file_identity, std::regex("[0-9]+:[0-9]+:[0-9]+")) &&
      std::regex_match(intent.name, std::regex("attachment\\.(pdf|txt|png|jpg|webp|doc|docx)"));
}
bool Verify(const OwnerFileIntent& intent, std::wstring& file_path) {
  const auto directory = Wide(intent.directory);
  if (directory.size() < 4 || directory[1] != L':' || directory[2] != L'\\') return false;
  const auto split = directory.find_last_of(L'\\');
  if (split == std::wstring::npos ||
      !std::regex_match(directory.substr(split + 1), std::wregex(L"info-managed-[A-Za-z0-9_-]{32}"))) return false;
  std::array<wchar_t, 32768> temporary{};
  const auto length = GetTempPathW(static_cast<DWORD>(temporary.size()), temporary.data());
  if (length == 0 || length >= temporary.size()) return false;
  Handle parent(CreateFileW(temporary.data(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr));
  if (!parent.valid() || !SamePath(Canonical(parent.value), directory.substr(0, split))) return false;
  const auto extended = L"\\\\?\\" + directory;
  Handle root(CreateFileW(extended.c_str(), READ_CONTROL | FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (!root.valid() || !SamePath(Canonical(root.value), directory) || Identity(root.value, true) != intent.directory_identity) return false;
  file_path = directory + L"\\" + Wide(intent.name);
  const auto extended_file = L"\\\\?\\" + file_path;
  Handle file(CreateFileW(extended_file.c_str(), GENERIC_READ | READ_CONTROL,
      FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  return file.valid() && SamePath(Canonical(file.value), file_path) &&
      Identity(file.value, false) == intent.file_identity && Content(file.value, intent.byte_length, intent.content_digest) &&
      Identity(file.value, false) == intent.file_identity && Identity(root.value, true) == intent.directory_identity;
}
}

bool OwnerFileIntent::operator==(const OwnerFileIntent& other) const {
  return std::tie(operation_id, command_digest, directory, directory_identity, name, file_identity, content_digest, byte_length) ==
      std::tie(other.operation_id, other.command_digest, other.directory, other.directory_identity, other.name, other.file_identity, other.content_digest, other.byte_length);
}
OwnerOpenResult OwnerFileOpener::Open(const OwnerFileIntent& intent) {
  if (!Valid(intent)) return OwnerOpenResult::not_opened;
  const auto old = entries_.find(intent.operation_id);
  if (old != entries_.end()) return old->second.intent == intent ? old->second.result : OwnerOpenResult::conflict;
  if (entries_.size() >= 256) return OwnerOpenResult::not_opened;
  std::wstring file;
  if (!Verify(intent, file)) return OwnerOpenResult::not_opened;
  entries_.emplace(intent.operation_id, Entry{intent, OwnerOpenResult::pending});
  try {
    entries_.at(intent.operation_id).result = launch_(file) ? OwnerOpenResult::opened : OwnerOpenResult::not_opened;
  } catch (...) { /* Retain pending; never launch this id again. */ }
  return entries_.at(intent.operation_id).result;
}
OwnerOpenResult OwnerFileOpener::Status(const std::string& id, const std::string& digest) const {
  if (!Id(id) || !Hash(digest)) return OwnerOpenResult::conflict;
  const auto old = entries_.find(id);
  if (old == entries_.end()) return OwnerOpenResult::missing;
  return old->second.intent.command_digest == digest ? old->second.result : OwnerOpenResult::conflict;
}
