#include "focus_snapshot.h"
#include <UIAutomation.h>
#include <iostream>

namespace {
int tests = 0;
void Check(bool value, const char* name) {
  if (!value) { std::cerr << "FAIL " << name << '\n'; ExitProcess(1); }
  ++tests;
}
focused_input::FocusSnapshot ValidTarget() {
  focused_input::FocusSnapshot value;
  value.password = true; value.enabled = true; value.keyboard_focus = true;
  value.keyboard_focusable = true; value.writable = true; value.offscreen = false;
  value.control_type = UIA_EditControlTypeId; value.native_focus_in_foreground = true;
  value.automation_in_foreground = true; value.stable = true;
  value.modifiers_released = true; value.runtime_id = {42, 1, 2};
  value.foreground = reinterpret_cast<HWND>(1); value.native_focus = reinterpret_cast<HWND>(2);
  value.application = {101, 1001, L"C:\\Apps\\Fixture.exe"}; value.provider = value.application;
  return value;
}
}

int main() {
  using focused_input::JsonString;
  Check(ValidTarget().RecognizesPassword(), "recognized synthetic password control");
  const auto refuse = [](auto change, const char* name) {
    auto target = ValidTarget(); change(target); Check(!target.RecognizesPassword(), name);
  };
  refuse([](auto& x) { x.error = "desktop_locked"; }, "locked desktop rejected");
  refuse([](auto& x) { x.password = false; }, "plain input rejected");
  refuse([](auto& x) { x.enabled = false; }, "disabled input rejected");
  refuse([](auto& x) { x.keyboard_focus = false; }, "unfocused input rejected");
  refuse([](auto& x) { x.keyboard_focusable = false; }, "unfocusable input rejected");
  refuse([](auto& x) { x.writable = false; }, "readonly or unsupported value metadata rejected");
  refuse([](auto& x) { x.control_type = UIA_DocumentControlTypeId; }, "unrecognized control type rejected");
  refuse([](auto& x) { x.offscreen = true; }, "offscreen input rejected");
  refuse([](auto& x) { x.native_focus_in_foreground = false; }, "foreign native window rejected");
  refuse([](auto& x) { x.automation_in_foreground = false; }, "foreign automation ancestry rejected");
  refuse([](auto& x) { x.stable = false; }, "changing focus rejected");
  refuse([](auto& x) { x.modifiers_released = false; }, "held modifier rejected");
  refuse([](auto& x) { x.runtime_id.clear(); }, "missing control identity rejected");
  refuse([](auto& x) { x.foreground = nullptr; }, "missing foreground rejected");
  refuse([](auto& x) { x.native_focus = nullptr; }, "missing native focus rejected");
  refuse([](auto& x) { x.application.pid = 0; }, "missing application PID rejected");
  refuse([](auto& x) { x.application.created_at = 0; }, "missing application birth rejected");
  refuse([](auto& x) { x.provider.pid = 0; }, "missing provider PID rejected");
  refuse([](auto& x) { x.provider.executable.clear(); }, "missing provider executable rejected");
  Check(JsonString(L"quote\" slash\\ newline\n") == "\"quote\\\" slash\\\\ newline\\u000a\"", "JSON escapes metadata");
  Check(JsonString(L"中文") == "\"中文\"", "JSON preserves unicode metadata");
  Check(JsonString(std::wstring(1, static_cast<wchar_t>(0xd800))) == "null", "invalid UTF-16 is not silently changed");
  const auto json = ValidTarget().ToPrivateJson();
  Check(json.find("\"valueWasRead\":false") != std::string::npos &&
      json.find("\"inputWasSent\":false") != std::string::npos, "inspection does not claim reading or filling");
  std::cout << tests << " native snapshot checks passed; no actual input sent\n";
}
