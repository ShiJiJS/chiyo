// Disposable test receiver. It only accepts synthetic values supplied by QA.
// This executable is EXCLUDE_FROM_ALL and is never installed with the App.
#include <windows.h>
#include <string>
#include <vector>

namespace {
std::wstring Environment(const wchar_t* name) {
  const DWORD size = GetEnvironmentVariableW(name, nullptr, 0);
  if (size == 0 || size > 65536) return {};
  std::wstring value(size, L'\0');
  const DWORD written = GetEnvironmentVariableW(name, value.data(), size);
  if (written == 0 || written >= size) return {};
  value.resize(written); return value;
}
std::string Utf8(const std::wstring& value) {
  const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
      value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (size <= 0) return {};
  std::string result(size, '\0');
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), result.data(), size, nullptr, nullptr) != size) return {};
  return result;
}
bool Write(const std::string& value) {
  DWORD written = 0;
  return WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), value.data(),
      static_cast<DWORD>(value.size()), &written, nullptr) && written == value.size();
}
bool Read(HANDLE input, std::string* value) {
  char buffer[1024]; DWORD count = 0;
  while (ReadFile(input, buffer, sizeof(buffer), &count, nullptr)) {
    if (count == 0) return true;
    value->append(buffer, count);
    if (value->size() > 65536) return false;
  }
  return GetLastError() == ERROR_BROKEN_PIPE;
}
}
int wmain(int argc, wchar_t** argv) {
  const auto expected = Utf8(Environment(L"CHIYO_QA_EXPECTED"));
  if (expected.empty()) return 64;
  // OpenSSH passes its own prompt argument. This flag is scoped to the test
  // child, so no shell wrapper or password in argv is needed.
  if (Environment(L"CHIYO_QA_MODE") == L"askpass") {
    return Write(expected + "\n") ? 0 : 74;
  }
  if (argc < 2) return 64;
  const std::wstring mode = argv[1];
  std::string received;
  if (mode == L"stdin") {
    if (!Read(GetStdHandle(STD_INPUT_HANDLE), &received)) return 74;
  } else if (mode == L"env") {
    received = Utf8(Environment(L"CHIYO_QA_DELIVERY"));
  } else if (mode == L"file" && argc == 3) {
    const HANDLE file = CreateFileW(argv[2], GENERIC_READ, FILE_SHARE_READ,
        nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return 74;
    const bool ok = Read(file, &received); CloseHandle(file);
    if (!ok) return 74;
  } else return 64;
  const bool matches = received == expected;
  if (!received.empty()) SecureZeroMemory(received.data(), received.size());
  Write(matches ? "{\"matches\":true}\n" : "{\"matches\":false}\n");
  return matches ? 0 : 1;
}
