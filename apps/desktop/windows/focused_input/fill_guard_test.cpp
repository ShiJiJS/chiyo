#include "fill_guard.h"
#include <UIAutomation.h>
#include <iostream>

namespace {
int checks = 0;
void Check(bool ok, const char* label) {
  if (!ok) { std::cerr << "FAIL " << label << '\n'; ExitProcess(1); }
  ++checks;
}
focused_input::FocusSnapshot Target() {
  focused_input::FocusSnapshot s;
  s.foreground = reinterpret_cast<HWND>(1); s.native_focus = reinterpret_cast<HWND>(2);
  s.application = {10, 11, L"C:\\Fixture.exe"}; s.provider = {12, 13, L"C:\\Provider.exe"};
  s.password = s.enabled = s.keyboard_focus = s.keyboard_focusable = s.writable = true;
  s.offscreen = false; s.native_focus_in_foreground = s.automation_in_foreground = true;
  s.stable = s.modifiers_released = true; s.control_type = UIA_EditControlTypeId;
  s.runtime_id = {42, 3}; return s;
}
}
int main() {
  using namespace focused_input;
  const auto a = Target(); Check(SameTarget(a, Target()), "same pinned control");
  for (int change = 0; change < 6; ++change) {
    auto b = Target();
    if (change == 0) b.application.created_at++;
    if (change == 1) b.provider.created_at++;
    if (change == 2) b.native_focus = reinterpret_cast<HWND>(3);
    if (change == 3) b.foreground = reinterpret_cast<HWND>(4);
    if (change == 4) b.runtime_id.push_back(5);
    if (change == 5) b.application.executable = L"C:\\Other.exe";
    Check(!SameTarget(a, b), "reused PID or changed target rejected");
  }
  Check(SamePath(L"C:\\Apps\\Fixture.exe", L"c:\\apps\\fixture.EXE"), "Windows case-insensitive identity");
  Check(!SamePath(L"", L""), "empty identity is not a match");
  Check(ValidUnits({L' ', L'中', 0xd83e, 0xdded, L' '}), "Unicode and spaces preserved");
  Check(!ValidUnits({L'\n'}), "newline is not an Enter shortcut");
  Check(!ValidUnits({L'\t'}), "tab is not focus navigation");
  Check(!ValidUnits({L'\0'}), "NUL rejected");
  Check(!ValidUnits({0xd83e}), "split high surrogate rejected");
  Check(!ValidUnits({0xdded}), "orphan low surrogate rejected");
  Check(!ValidUnits(std::vector<wchar_t>(17, L'a')), "oversized batch rejected");
  Check(!PinParent(GetCurrentProcessId()), "self is not the launcher");
  wchar_t temp[MAX_PATH]{}, path[MAX_PATH]{};
  Check(GetTempPathW(MAX_PATH, temp) != 0 && GetTempFileNameW(temp, L"aif", 0, path) != 0, "create owned file");
  {
    Handle file(CreateFileW(path, GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
    DWORD count = 0; Check(file.get() != INVALID_HANDLE_VALUE && WriteFile(file.get(), "abc", 3, &count, nullptr) && count == 3, "write synthetic digest fixture");
  }
  auto seal = SealFile(path);
  Check(seal && seal->sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "actual SHA256 bytes");
  {
    Handle writer(CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr));
    Check(writer.get() == INVALID_HANDLE_VALUE && GetLastError() == ERROR_SHARING_VIOLATION, "sealed executable denies writes");
  }
  Check(!DeleteFileW(path) && GetLastError() == ERROR_SHARING_VIOLATION, "sealed executable denies replacement");
  seal.reset(); Check(DeleteFileW(path) != 0, "release only the generated fixture file");
  std::cout << checks << " guard checks passed; no input sent\n";
}
