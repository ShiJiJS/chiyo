// Synthetic receiver only. Only this process reads its own fake password.
#include <windows.h>
#include <atomic>
#include <string>
#include <thread>

namespace {
HWND window = nullptr, first = nullptr, second = nullptr, plain = nullptr, extra = nullptr;
std::wstring expected;
WNDPROC edit_proc = nullptr;
unsigned changes = 0, pastes = 0;
bool disable_after_set = false, delay_next_set = false;
struct Snapshot { HWND foreground = nullptr, focus = nullptr; POINT cursor{}; DWORD clipboard = 0; bool valid = false; };
Snapshot watched;
std::atomic<bool> watching{false}, observation_changed{false};
std::thread sampling;
HWINEVENTHOOK foreground_hook = nullptr, focus_hook = nullptr;
unsigned foreground_events = 0, focus_events = 0;
Snapshot Capture() {
  Snapshot result; result.foreground = GetForegroundWindow();
  GUITHREADINFO gui{}; gui.cbSize = sizeof(gui);
  result.valid = result.foreground && GetGUIThreadInfo(GetWindowThreadProcessId(result.foreground, nullptr), &gui) &&
      gui.hwndFocus && GetAncestor(gui.hwndFocus, GA_ROOT) == result.foreground && GetCursorPos(&result.cursor);
  result.focus = gui.hwndFocus; result.clipboard = GetClipboardSequenceNumber(); return result;
}
bool Equal(const Snapshot& now) {
  return watched.valid && now.valid && now.foreground == watched.foreground && now.focus == watched.focus &&
      now.cursor.x == watched.cursor.x && now.cursor.y == watched.cursor.y && now.clipboard == watched.clipboard;
}
void CALLBACK Observe(HWINEVENTHOOK, DWORD event, HWND owner, LONG, LONG, DWORD, DWORD) {
  if (!watching) return;
  if (event == EVENT_SYSTEM_FOREGROUND && owner != watched.foreground) { ++foreground_events; observation_changed = true; }
  if (event == EVENT_OBJECT_FOCUS && owner != watched.focus) { ++focus_events; observation_changed = true; }
}
void StopWatching() {
  watching = false;
  if (sampling.joinable()) sampling.join();
  if (foreground_hook) UnhookWinEvent(foreground_hook);
  if (focus_hook) UnhookWinEvent(focus_hook);
  foreground_hook = nullptr; focus_hook = nullptr;
}
void StartWatching() {
  StopWatching(); watched = Capture(); observation_changed = false; foreground_events = 0; focus_events = 0;
  foreground_hook = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, nullptr, Observe, 0, 0, WINEVENT_OUTOFCONTEXT);
  focus_hook = SetWinEventHook(EVENT_OBJECT_FOCUS, EVENT_OBJECT_FOCUS, nullptr, Observe, 0, 0, WINEVENT_OUTOFCONTEXT);
  watching = true;
  sampling = std::thread([] { while (watching) { if (!Equal(Capture())) observation_changed = true; Sleep(1); } });
}
void Reply(const std::string& message) {
  const auto line = message + "\n"; DWORD count = 0;
  WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), line.data(), static_cast<DWORD>(line.size()), &count, nullptr);
}
bool ReadByte(char* byte) {
  DWORD count = 0;
  return ReadFile(GetStdHandle(STD_INPUT_HANDLE), byte, 1, &count, nullptr) && count == 1;
}
std::string ReadLine() {
  std::string line; char c;
  while (ReadByte(&c)) {
    if (c == '\n') break;
    if (c != '\r') line += c;
    if (line.size() > 32768) return "";
  }
  return line;
}
std::wstring Text(HWND control) {
  const int length = GetWindowTextLengthW(control);
  std::wstring text(static_cast<size_t>(length) + 1, L'\0');
  GetWindowTextW(control, text.data(), length + 1); text.resize(length); return text;
}
LRESULT CALLBACK Edit(HWND control, UINT message, WPARAM w, LPARAM l) {
  if (message == WM_PASTE) ++pastes;
  if (control == first && message == WM_SETTEXT && delay_next_set) {
    delay_next_set = false; Reply("setter_entered"); Sleep(1200);
  }
  const auto result = CallWindowProcW(edit_proc, control, message, w, l);
  if (control == first && message == WM_SETTEXT && disable_after_set) {
    disable_after_set = false; EnableWindow(first, FALSE);
  }
  return result;
}
HWND Password(int id, int top) {
  CreateWindowW(L"STATIC", L"Password", WS_VISIBLE | WS_CHILD, 20, top - 22, 400, 20,
      window, nullptr, GetModuleHandle(nullptr), nullptr);
  auto field = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"",
      WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_PASSWORD | ES_AUTOHSCROLL,
      20, top, 470, 30, window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)),
      GetModuleHandle(nullptr), nullptr);
  edit_proc = reinterpret_cast<WNDPROC>(SetWindowLongPtrW(field, GWLP_WNDPROC,
      reinterpret_cast<LONG_PTR>(Edit)));
  return field;
}
struct Request { std::string command, response; };
std::string Command(const std::string& command) {
  if (command.rfind("expect ", 0) == 0) {
    if (!expected.empty()) SecureZeroMemory(expected.data(), expected.size() * sizeof(wchar_t));
    expected.clear();
    for (size_t i = 7; i + 3 < command.size(); i += 4) {
      expected += static_cast<wchar_t>(std::stoul(command.substr(i, 4), nullptr, 16));
    }
  } else if (command.rfind("title ", 0) == 0) {
    const auto title = command.substr(6);
    SetWindowTextW(window, std::wstring(title.begin(), title.end()).c_str());
  } else if (command == "reset") {
    EnableWindow(first, TRUE); SendMessageW(first, EM_SETREADONLY, FALSE, 0);
    SetWindowTextW(first, L""); SetWindowTextW(second, L""); SetWindowTextW(plain, L"");
    changes = 0; pastes = 0;
  } else if (command == "seed") {
    SetWindowTextW(first, L"old synthetic value"); changes = 0;
  } else if (command == "verify") {
    auto value = Text(first);
    const bool match = value == expected, empty = value.empty();
    SecureZeroMemory(value.data(), value.size() * sizeof(wchar_t));
    return "match=" + std::string(match ? "1" : "0") + " empty=" + (empty ? "1" : "0") +
        " others=" + (Text(second).empty() && (!extra || Text(extra).empty()) ? "1" : "0") +
        " plainEmpty=" + (Text(plain).empty() ? "1" : "0") +
        " typing=" + (Text(plain) == L"synthetic user input" ? "1" : "0") +
        " typingTwice=" + (Text(plain) == L"synthetic user inputsynthetic user input" ? "1" : "0") +
        " changes=" + std::to_string(changes) + " noPaste=" + (pastes == 0 ? "1" : "0");
  } else if (command == "limit") SendMessageW(first, EM_SETLIMITTEXT, 1, 0);
  else if (command == "readonly") SendMessageW(first, EM_SETREADONLY, TRUE, 0);
  else if (command == "disable") EnableWindow(first, FALSE);
  else if (command == "enable") EnableWindow(first, TRUE);
  else if (command == "focusA") SetFocus(first);
  else if (command == "focusB") SetFocus(second);
  else if (command == "plain") SendMessageW(first, EM_SETPASSWORDCHAR, 0, 0);
  else if (command == "recreate") { DestroyWindow(first); first = Password(101, 60); }
  else if (command == "duplicate") extra = Password(101, 230);
  else if (command == "retitle") SetWindowTextW(window, L"Changed synthetic container");
  else if (command == "minimize") ShowWindow(window, SW_SHOWMINNOACTIVE);
  else if (command == "hide") ShowWindow(window, SW_HIDE);
  else if (command == "show") ShowWindow(window, SW_SHOWNOACTIVATE);
  else if (command == "disable-after-set") disable_after_set = true;
  else if (command == "delay-next-set") delay_next_set = true;
  else if (command == "watch-start") { StartWatching(); return watched.valid && watched.foreground == window && foreground_hook && focus_hook ? "valid=1" : "valid=0"; }
  else if (command == "watch-stop") {
    const auto now = Capture(); const bool stable = Equal(now) && !observation_changed;
    StopWatching();
    return "stable=" + std::string(stable ? "1" : "0") + " valid=" + (watched.valid && now.valid ? "1" : "0") +
        " foregroundEvents=" + std::to_string(foreground_events) + " focusEvents=" + std::to_string(focus_events);
  }
  else if (command == "activate") {
    ShowWindow(window, SW_SHOWNORMAL); SetForegroundWindow(window); SetFocus(plain);
  } else if (command == "type") {
    // A control-directed foreground-app input surrogate, never global input.
    for (wchar_t c : std::wstring(L"synthetic user input")) SendMessageW(plain, WM_CHAR, c, 0);
  } else return "unsupported";
  return "ok";
}
LRESULT CALLBACK Window(HWND owner, UINT message, WPARAM w, LPARAM l) {
  if (message == WM_APP + 1) {
    auto request = reinterpret_cast<Request*>(l); request->response = Command(request->command); return 0;
  }
  if (message == WM_COMMAND && HIWORD(w) == EN_CHANGE && reinterpret_cast<HWND>(l) == first) ++changes;
  if (message == WM_DESTROY) {
    StopWatching();
    if (!expected.empty()) SecureZeroMemory(expected.data(), expected.size() * sizeof(wchar_t));
    PostQuitMessage(0); return 0;
  }
  return DefWindowProcW(owner, message, w, l);
}
}
int APIENTRY wWinMain(HINSTANCE instance, HINSTANCE, wchar_t* args, int) {
  const std::wstring mode(args);
  const bool typing = mode == L"--typing";
  WNDCLASSW type{}; type.hInstance = instance; type.lpfnWndProc = Window;
  type.lpszClassName = mode == L"--browser-root" ? L"Chrome_WidgetWin_0" : L"ChiyoNativeBackgroundTest";
  type.hCursor = LoadCursor(nullptr, IDC_ARROW); type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
  if (!RegisterClassW(&type)) return 70;
  window = CreateWindowW(type.lpszClassName,
      typing ? L"Chiyo native background test typing" : L"Chiyo native background test receiver",
      WS_OVERLAPPEDWINDOW, 120, 120, 540, 330, nullptr, nullptr, instance, nullptr);
  first = Password(101, 60); second = Password(102, 130);
  plain = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"", WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL,
      20, 180, 470, 30, window, reinterpret_cast<HMENU>(103), instance, nullptr);
  ShowWindow(window, SW_SHOWNOACTIVATE); UpdateWindow(window);
  Reply("ready " + std::to_string(reinterpret_cast<uintptr_t>(window)));
  std::thread([] {
    for (;;) {
      auto command = ReadLine(); if (command.empty() || command == "close") break;
      Request request{std::move(command), ""};
      SendMessageW(window, WM_APP + 1, 0, reinterpret_cast<LPARAM>(&request));
      Reply(request.response);
      SecureZeroMemory(request.command.data(), request.command.size());
    }
    PostMessageW(window, WM_CLOSE, 0, 0);
  }).detach();
  MSG message{};
  while (GetMessageW(&message, nullptr, 0, 0) > 0) { TranslateMessage(&message); DispatchMessageW(&message); }
  return 0;
}
