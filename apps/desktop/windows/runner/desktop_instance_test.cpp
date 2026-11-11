#include "desktop_instance.h"
#include <iostream>
#include <stdexcept>
#include <array>

namespace {
void Check(bool value) { if (!value) throw std::runtime_error("desktop instance contract failed"); }
int activations = 0;
LRESULT CALLBACK Window(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  // Test transport without displaying a test window on the user's desktop.
  // Actual Flutter restoration and modal retention are checked in the App.
  if (message == DesktopInstance::ActivationMessage() && wparam == GetCurrentProcessId() && lparam == 0) {
    ++activations;
    return 1;
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}
PROCESS_INFORMATION Launch(const std::wstring& scope) {
  std::array<wchar_t, 32768> image{};
  Check(GetModuleFileNameW(nullptr, image.data(), static_cast<DWORD>(image.size())) > 0);
  std::wstring command = L"\"" + std::wstring(image.data()) + L"\" --acquire \"" + scope + L"\"";
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  Check(CreateProcessW(image.data(), command.data(), nullptr, nullptr, FALSE,
      CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process) != FALSE);
  CloseHandle(process.hThread);
  return process;
}
DWORD Finish(PROCESS_INFORMATION process) {
  const ULONGLONG start = GetTickCount64();
  while (WaitForSingleObject(process.hProcess, 0) == WAIT_TIMEOUT) {
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
    Check(GetTickCount64() - start < 5000);
    Sleep(5);
  }
  DWORD result = 99;
  Check(GetExitCodeProcess(process.hProcess, &result) != FALSE);
  CloseHandle(process.hProcess);
  return result;
}
}
int wmain(int argc, wchar_t** argv) {
  if (argc == 3 && std::wstring(argv[1]) == L"--acquire") {
    DesktopInstance instance(argv[2], 250);
    switch (instance.result()) {
      case DesktopInstance::Result::primary: return 10;
      case DesktopInstance::Result::activated: return 0;
      case DesktopInstance::Result::unavailable: return 20;
    }
  }
  try {
    const auto scope = DesktopInstance::Scope(L"C:/Program Files/知予/app.exe", L"C:/Users/Test/AppData/Roaming", {});
    Check(scope.has_value());
    Check(scope == DesktopInstance::Scope(L"c:\\program files\\知予\\app.exe", L"c:\\users\\test\\appdata\\roaming\\", {}));
    Check(scope != DesktopInstance::Scope(L"C:/Program Files/知予/app.exe", L"C:/QA", {}));
    Check(scope != DesktopInstance::Scope(L"C:/Program Files/知予/app.exe", L"C:/Users/Test/AppData/Roaming", {"--connection-profile", "QA_1"}));
    Check(!DesktopInstance::Scope(L"C:/app.exe", L"C:/QA", {"--connection-profile", "../escape"}));
    Check(!DesktopInstance::Scope(L"C:/app.exe", L"C:/QA", {"--connection-profile", ""}));
    Check(!DesktopInstance::Scope(L"C:/app.exe", L"C:/QA", {"unexpected"}));
    const std::wstring key = L"ChiyoSyntheticInstance-" + std::to_wstring(GetCurrentProcessId());
    WNDCLASSW klass{};
    klass.lpfnWndProc = Window;
    klass.hInstance = GetModuleHandleW(nullptr);
    klass.lpszClassName = L"ChiyoSyntheticInstanceWindow";
    Check(RegisterClassW(&klass) != 0);
    {
      DesktopInstance primary(key);
      Check(primary.result() == DesktopInstance::Result::primary);
      HWND window = CreateWindowW(klass.lpszClassName, L"Synthetic instance transport", 0,
          0, 0, 1, 1, nullptr, nullptr, klass.hInstance, nullptr);
      Check(primary.Attach(window));
      const auto first = Launch(key), second = Launch(key), third = Launch(key);
      Check(Finish(first) == 0 && Finish(second) == 0 && Finish(third) == 0);
      Check(activations == 3);
      Check(Finish(Launch(key + L"-another-profile")) == 10);
      Check(activations == 3);
      DestroyWindow(window);
      // Owner still holds its mutex; missing/hung startup cannot create a writer.
      Check(Finish(Launch(key)) == 20);
    }
    Check(Finish(Launch(key)) == 10);
    std::cout << "Profile separation, repeated launches, activation and lifetime checks passed.\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
  return 1;
}
