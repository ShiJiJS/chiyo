// Synthetic receiver for #35 only. This file may inspect its own password
// controls to independently verify fake bytes. Production broker never does.
#include <windows.h>
#include <string>
#include <vector>
#include <thread>

namespace {
HWND window = nullptr, password = nullptr, other = nullptr;
WNDPROC original = nullptr;
std::wstring expected;
DWORD clipboard = 0;
unsigned pastes = 0, changes = 0;
bool change_focus = false, focus_changed = false;
void Write(const std::string& text) {
  DWORD count = 0; const auto line = text + "\n";
  WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), line.data(), static_cast<DWORD>(line.size()), &count, nullptr);
}
LRESULT CALLBACK Edit(HWND h, UINT message, WPARAM w, LPARAM l) {
  if (message == WM_PASTE) ++pastes;
  return CallWindowProcW(original, h, message, w, l);
}
LRESULT CALLBACK Window(HWND h, UINT message, WPARAM w, LPARAM l) {
  if (message == WM_APP + 1) {
    const auto data = reinterpret_cast<std::vector<BYTE>*>(l);
    const auto command = data->front();
    if (command == 1) {
      if (!expected.empty()) SecureZeroMemory(expected.data(), expected.size() * sizeof(wchar_t));
      expected.clear();
      for (size_t i = 1; i + 1 < data->size(); i += 2) expected += static_cast<wchar_t>((*data)[i] | ((*data)[i + 1] << 8));
      clipboard = GetClipboardSequenceNumber();
      Write("{\"event\":\"expected_ready\"}");
    } else if (command == 2) {
      std::wstring received(8193, L'\0');
      const int size = GetWindowTextW(password, received.data(), static_cast<int>(received.size()));
      received.resize(size > 0 ? size : 0);
      const bool matches = received == expected;
      SecureZeroMemory(received.data(), received.size() * sizeof(wchar_t));
      Write(std::string("{\"event\":\"verified\",\"matches\":") + (matches ? "true" : "false") +
          ",\"empty\":" + (size == 0 ? "true" : "false") +
          ",\"noPaste\":" + (pastes == 0 ? "true" : "false") +
          ",\"clipboardUnchanged\":" + (clipboard == GetClipboardSequenceNumber() ? "true" : "false") +
          ",\"focusChanged\":" + (focus_changed ? "true" : "false") + "}");
    } else if (command == 3) {
      SetWindowTextW(password, L""); SetWindowTextW(other, L"");
      changes = 0; focus_changed = false; change_focus = false;
      Write("{\"event\":\"cleared\"}");
    } else if (command == 4) {
      change_focus = true; Write("{\"event\":\"focus_change_armed\"}");
    }
    SecureZeroMemory(data->data(), data->size()); delete data; return 0;
  }
  if (message == WM_COMMAND && HIWORD(w) == EN_CHANGE && reinterpret_cast<HWND>(l) == password) {
    ++changes;
    if (change_focus && changes >= 16) { change_focus = false; focus_changed = true; SetFocus(other); }
  }
  if (message == WM_DESTROY) {
    if (!expected.empty()) SecureZeroMemory(expected.data(), expected.size() * sizeof(wchar_t));
    PostQuitMessage(0); return 0;
  }
  return DefWindowProcW(h, message, w, l);
}
bool Read(HANDLE handle, BYTE* data, DWORD size) {
  while (size != 0) { DWORD count = 0;
    if (!ReadFile(handle, data, size, &count, nullptr) || count == 0) return false;
    data += count; size -= count;
  }
  return true;
}
}
int APIENTRY wWinMain(HINSTANCE instance, HINSTANCE, wchar_t*, int) {
  WNDCLASSW type{}; type.hInstance = instance; type.lpfnWndProc = Window;
  type.lpszClassName = L"AgentInfoSyntheticFill"; type.hCursor = LoadCursor(nullptr, IDC_ARROW);
  type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
  if (!RegisterClassW(&type)) return 70;
  window = CreateWindowW(type.lpszClassName, L"AgentInfo synthetic focused-fill test", WS_OVERLAPPEDWINDOW,
      CW_USEDEFAULT, CW_USEDEFAULT, 640, 330, nullptr, nullptr, instance, nullptr);
  CreateWindowW(L"STATIC", L"Local synthetic receiver. No login or network access.", WS_CHILD | WS_VISIBLE,
      24, 24, 560, 28, window, nullptr, instance, nullptr);
  CreateWindowW(L"STATIC", L"Password input (masked)", WS_CHILD | WS_VISIBLE,
      24, 70, 550, 24, window, nullptr, instance, nullptr);
  password = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"", WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_PASSWORD | ES_AUTOHSCROLL,
      24, 100, 560, 40, window, reinterpret_cast<HMENU>(101), instance, nullptr);
  original = reinterpret_cast<WNDPROC>(SetWindowLongPtrW(password, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(Edit)));
  CreateWindowW(L"STATIC", L"Other input (focus-change test)", WS_CHILD | WS_VISIBLE,
      24, 166, 560, 24, window, nullptr, instance, nullptr);
  other = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"", WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_PASSWORD | ES_AUTOHSCROLL,
      24, 196, 560, 40, window, reinterpret_cast<HMENU>(102), instance, nullptr);
  ShowWindow(window, SW_SHOWNOACTIVATE); UpdateWindow(window);
  Write("{\"event\":\"window_ready\"}");
  std::thread([] {
    const HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
    while (true) {
      BYTE header[4]{};
      if (!Read(input, header, 4)) break;
      const DWORD size = header[0] | (static_cast<DWORD>(header[1]) << 8) |
          (static_cast<DWORD>(header[2]) << 16) | (static_cast<DWORD>(header[3]) << 24);
      if (size == 0 || size > 16384) break;
      auto data = new std::vector<BYTE>(size);
      if (!Read(input, data->data(), size) || !PostMessageW(window, WM_APP + 1, 0, reinterpret_cast<LPARAM>(data))) {
        SecureZeroMemory(data->data(), data->size()); delete data; break;
      }
    }
    PostMessageW(window, WM_CLOSE, 0, 0);
  }).detach();
  std::thread([] { Sleep(300000); PostMessageW(window, WM_CLOSE, 0, 0); }).detach();
  MSG message{};
  while (GetMessageW(&message, nullptr, 0, 0) > 0) { TranslateMessage(&message); DispatchMessageW(&message); }
  return 0;
}
