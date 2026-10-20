// Synthetic Win32 transport peer only, never part of the desktop payload.
#include <windows.h>
#include <iostream>
#include <string>
#include <thread>

namespace {
UINT control = 0;
std::string mode;
LRESULT state = 1;
int attempts = 0;
LRESULT CALLBACK Handle(HWND window, UINT message, WPARAM pid, LPARAM op) {
  if (message == control) {
    if (pid != GetCurrentProcessId() || (op != 0 && op != 1) || mode == "old") return 0;
    if (op == 1 && state != 4) {
      ++attempts;
      state = mode == "failed" && attempts == 1 ? 3 : 2;
      if (state == 2 && mode != "timeout") SetTimer(window, 2, 40, nullptr);
    }
    return state;
  }
  if (message == WM_TIMER) {
    if (pid == 1) { state = 1; KillTimer(window, 1); }
    if (pid == 2) DestroyWindow(window);
    return 0;
  }
  if (message == WM_DESTROY) { PostQuitMessage(0); return 0; }
  return DefWindowProcW(window, message, pid, op);
}
}
int main(int argc, char** argv) {
  mode = argc == 2 ? argv[1] : "normal";
  control = RegisterWindowMessageW(L"AgentInfoManage.LocalControl.v1");
  WNDCLASSW type{};
  type.lpfnWndProc = Handle;
  type.hInstance = GetModuleHandleW(nullptr);
  type.lpszClassName = L"FLUTTER_RUNNER_WIN32_WINDOW";
  if (!RegisterClassW(&type)) return 1;
  const HWND window = CreateWindowW(type.lpszClassName, L"Synthetic control peer", 0,
      0, 0, 1, 1, nullptr, nullptr, type.hInstance, nullptr);
  if (!window || !control) return 2;
  // Test cleanup only closes this synthetic peer on its own stdin EOF.
  std::thread([window] { std::string line; std::getline(std::cin, line);
    PostMessageW(window, WM_CLOSE, 0, 0); }).detach();
  if (mode == "starting") { state = 4; SetTimer(window, 1, 100, nullptr); }
  std::cout << "ready" << std::endl;
  MSG message{};
  while (GetMessageW(&message, nullptr, 0, 0)) DispatchMessageW(&message);
  // Confirm the client waits for the process, not merely HWND disappearance.
  if (mode == "normal") Sleep(160);
  return 0;
}
