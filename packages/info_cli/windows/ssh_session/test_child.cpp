// Synthetic process-identity fixture. It is built only with the test option and
// never shipped. Authentication output is compared in memory, never logged.
#include <windows.h>
#include <shellapi.h>
#include <string>

std::wstring Env(const wchar_t* key) {
  DWORD n = GetEnvironmentVariableW(key, nullptr, 0);
  if (!n) return {};
  std::wstring value(n, L'\0');
  GetEnvironmentVariableW(key, value.data(), n); value.resize(n - 1); return value;
}
void Output(const char* text) {
  DWORD count = 0;
  WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), text, static_cast<DWORD>(strlen(text)), &count, nullptr);
}
int Child(const std::wstring& program, const std::wstring& argument, bool receiver) {
  SECURITY_ATTRIBUTES attributes{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
  HANDLE read = nullptr, write = nullptr;
  if (!CreatePipe(&read, &write, &attributes, 0)) return 2;
  SetHandleInformation(read, HANDLE_FLAG_INHERIT, 0);
  std::wstring command = L"\"" + program + L"\" \"" + argument + L"\"";
  STARTUPINFOW startup{}; startup.cb = sizeof(startup); startup.dwFlags = STARTF_USESTDHANDLES;
  startup.hStdOutput = write; startup.hStdError = GetStdHandle(STD_ERROR_HANDLE); startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
  PROCESS_INFORMATION process{};
  bool created = CreateProcessW(program.c_str(), command.data(), nullptr, nullptr, TRUE, CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process) != FALSE;
  CloseHandle(write);
  if (!created) { CloseHandle(read); return 2; }
  char bytes[256]{}; DWORD count = 0;
  while (count < sizeof(bytes) - 1) {
    DWORD received = 0;
    if (!ReadFile(read, bytes + count, static_cast<DWORD>(sizeof(bytes) - 1 - count), &received, nullptr) || !received) break;
    count += received;
  }
  CloseHandle(read);
  WaitForSingleObject(process.hProcess, INFINITE);
  DWORD code = 1; GetExitCodeProcess(process.hProcess, &code);
  CloseHandle(process.hProcess); CloseHandle(process.hThread);
  if (receiver && code == 0 && std::string(bytes, count) == "synthetic-login-password\n") Output("accepted\n");
  else if (code != 0 && count == 0) Output("denied\n");
  SecureZeroMemory(bytes, sizeof(bytes));
  return static_cast<int>(code);
}
int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
  int argc = 0; LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  std::wstring mode = argc > 1 ? argv[1] : L""; LocalFree(argv);
  if (mode == L"mark") {
    auto path = Env(L"CHIYO_QA_STARTED_RECEIPT");
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return 2;
    DWORD count = 0; const char* value = "started\n";
    bool ok = WriteFile(file, value, 8, &count, nullptr) && count == 8;
    CloseHandle(file); Output("started\n"); return ok ? 0 : 2;
  }
  if (mode == L"headless") { Output(GetConsoleWindow() ? "console-present\n" : "headless\n"); return 0; }
  auto helper = Env(L"SSH_ASKPASS");
  if (mode == L"relay") {
    std::wstring self(32768, L'\0');
    self.resize(GetModuleFileNameW(nullptr, self.data(), static_cast<DWORD>(self.size())));
    return Child(self, L"ask", false);
  }
  if (mode == L"copy") helper = Env(L"CHIYO_QA_HELPER_COPY");
  if (mode == L"unsupported") return Child(helper, L"Password:", true);
  int code = Child(helper, L"fixture@127.0.0.1's password: ", true);
  if (mode == L"repeat" && !code) code = Child(helper, L"fixture@127.0.0.1's password: ", true);
  return code;
}
