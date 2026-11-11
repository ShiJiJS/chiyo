#include "owner_file_association.h"
#include <windows.h>
#include <iostream>
#include <string>

namespace {
// Reserve fresh per-user fixture classes only. Never change a real default or
// open an application. Cleanup owns only the keys created by this instance.
class FixtureClass {
 public:
  explicit FixtureClass(const std::wstring& name)
      : path_(L"Software\\Classes\\" + name) {
    DWORD disposition = 0;
    HKEY key = nullptr;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, path_.c_str(), 0, nullptr, 0,
                       KEY_READ | KEY_WRITE, nullptr, &key, &disposition) == ERROR_SUCCESS) {
      owned_ = disposition == REG_CREATED_NEW_KEY;
      RegCloseKey(key);
    }
  }
  ~FixtureClass() { if (owned_) RegDeleteTreeW(HKEY_CURRENT_USER, path_.c_str()); }
  bool Set(const std::wstring& subkey, const std::wstring& value) {
    if (!owned_) return false;
    return RegSetKeyValueW(HKEY_CURRENT_USER, (path_ + subkey).c_str(), nullptr,
                          REG_SZ, value.c_str(),
                          static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t))) == ERROR_SUCCESS;
  }
 private:
  std::wstring path_;
  bool owned_ = false;
};
}

int main() {
  const auto nonce = std::to_wstring(GetCurrentProcessId()) + L"_" +
                     std::to_wstring(GetTickCount64());
  const auto extension = L".chiyo_association_" + nonce;
  const auto program = L"Chiyo.AssociationFixture." + nonce;
  if (HasDefaultOwnerFileHandler(L"C:\\fixture\\attachment")) return 10;
  if (HasDefaultOwnerFileHandler(L"C:\\fixture\\attachment.")) return 11;
  if (HasDefaultOwnerFileHandler(L"C:\\fixture\\attachment" + extension)) return 12;
  FixtureClass registered_program(program);
  FixtureClass registered_extension(extension);
  wchar_t system[MAX_PATH]{};
  if (!GetSystemDirectoryW(system, MAX_PATH) ||
      !registered_program.Set(L"", L"Chiyo synthetic association") ||
      !registered_program.Set(L"\\shell\\open\\command",
          L"\"" + std::wstring(system) + L"\\notepad.exe\" \"%1\"") ||
      !registered_extension.Set(L"", program)) return 2;
  if (!HasDefaultOwnerFileHandler(L"C:\\中文 目录\\attachment" + extension)) return 3;
  std::cout << "PASS: registered handler, unknown extension, extensionless and trailing-dot paths; no application launched\n";
  return 0;
}
