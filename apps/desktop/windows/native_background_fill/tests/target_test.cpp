#include "target.h"
#include "discovery.h"
#include <UIAutomation.h>
#include <bcrypt.h>
#include <wrl/client.h>
#include <sddl.h>
#include <atomic>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <thread>

namespace nb = native_background_fill;
namespace {
unsigned failures = 0, checks = 0;
const char* Bool(bool value) { return value ? "true" : "false"; }
void Check(const std::string& framework, const std::string& name, bool pass,
           const std::string& error = "") {
  ++checks; if (!pass) ++failures;
  std::cout << "{\"framework\":\"" << framework << "\",\"case\":\"" << name
      << "\",\"pass\":" << Bool(pass) << ",\"errorCode\":\"" << error << "\"}" << std::endl;
}
bool ReadByte(HANDLE pipe, char* byte) {
  DWORD count = 0; return ReadFile(pipe, byte, 1, &count, nullptr) && count == 1;
}
std::string Line(HANDLE pipe) {
  std::string line; char c;
  while (ReadByte(pipe, &c)) {
    if (c == '\n') break;
    if (c != '\r') line += c;
    if (line.size() > 32768) throw std::runtime_error("fixture_protocol");
  }
  return line;
}
void Write(HANDLE pipe, const std::string& text) {
  const auto line = text + "\n"; DWORD written = 0;
  if (!WriteFile(pipe, line.data(), static_cast<DWORD>(line.size()), &written, nullptr) ||
      written != line.size()) throw std::runtime_error("fixture_pipe");
}
struct Child {
  PROCESS_INFORMATION process{};
  HANDLE input = nullptr, output = nullptr;
  HWND window = nullptr;
  std::wstring executable;
  Child(const std::wstring& path, const std::wstring& argument) : executable(path) {
    SECURITY_ATTRIBUTES security{sizeof(security), nullptr, TRUE};
    HANDLE child_in = nullptr, child_out = nullptr;
    if (!CreatePipe(&child_in, &input, &security, 0) || !CreatePipe(&output, &child_out, &security, 0)) {
      throw std::runtime_error("fixture_pipe");
    }
    SetHandleInformation(input, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(output, HANDLE_FLAG_INHERIT, 0);
    STARTUPINFOW startup{}; startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdInput = child_in; startup.hStdOutput = child_out; startup.hStdError = child_out;
    auto command = L"\"" + path + L"\" " + argument;
    const bool started = CreateProcessW(path.c_str(), command.data(), nullptr, nullptr, TRUE,
        CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process) != FALSE;
    CloseHandle(child_in); CloseHandle(child_out);
    if (!started) throw std::runtime_error("fixture_start");
    AllowSetForegroundWindow(process.dwProcessId);
    const auto ready = Line(output);
    if (ready.rfind("ready ", 0) != 0) throw std::runtime_error("fixture_ready");
    window = reinterpret_cast<HWND>(static_cast<uintptr_t>(std::stoull(ready.substr(6))));
  }
  std::string Command(const std::string& message) { Write(input, message); return Line(output); }
  void Stop() {
    if (process.hProcess && WaitForSingleObject(process.hProcess, 0) == WAIT_TIMEOUT) {
      Write(input, "close");
      if (WaitForSingleObject(process.hProcess, 4000) != WAIT_OBJECT_0) {
        throw std::runtime_error("fixture_did_not_exit");
      }
    }
  }
  ~Child() {
    try { Stop(); } catch (...) {}
    if (input) CloseHandle(input); if (output) CloseHandle(output);
    if (process.hProcess) CloseHandle(process.hProcess); if (process.hThread) CloseHandle(process.hThread);
  }
  nb::Selection Select() const {
    nb::Selection result;
    if (!nb::InspectExecutable(executable, &result.approved_executable, &result.approved_sha256)) {
      throw std::runtime_error("fixture_identity");
    }
    result.process_id = process.dwProcessId;
    result.process_created_at = nb::ProcessCreatedAt(process.hProcess);
    result.window = window; result.path = {{L"101", UIA_EditControlTypeId}};
    return result;
  }
};
struct State { HWND foreground = nullptr, focus = nullptr; POINT cursor{}; DWORD clipboard = 0; bool valid = false; };
State Snapshot() {
  State result;
  result.foreground = GetForegroundWindow();
  GUITHREADINFO gui{}; gui.cbSize = sizeof(gui);
  result.valid = result.foreground && GetGUIThreadInfo(GetWindowThreadProcessId(result.foreground, nullptr), &gui) &&
      gui.hwndFocus && GetAncestor(gui.hwndFocus, GA_ROOT) == result.foreground && GetCursorPos(&result.cursor);
  result.focus = gui.hwndFocus; result.clipboard = GetClipboardSequenceNumber(); return result;
}
class Observer;
thread_local Observer* local_observer = nullptr;
class Observer {
 public:
  explicit Observer(HWND expected, HWND target) : expected_(expected), target_(target), thread_([this] {
    local_observer = this;
    const auto foreground = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND,
        nullptr, Event, 0, 0, WINEVENT_OUTOFCONTEXT);
    const auto focus = SetWinEventHook(EVENT_OBJECT_FOCUS, EVENT_OBJECT_FOCUS,
        nullptr, Event, 0, 0, WINEVENT_OUTOFCONTEXT);
    installed_ = foreground && focus; ready_ = true;
    MSG message{};
    while (!stop_) {
      while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) DispatchMessageW(&message);
      if (recording_) {
        const auto now = Snapshot();
        if (!now.valid || now.foreground != expected_ || now.focus != baseline_.focus ||
            now.cursor.x != baseline_.cursor.x || now.cursor.y != baseline_.cursor.y ||
            now.clipboard != baseline_.clipboard) changed_ = true;
      }
      Sleep(1);
    }
    if (foreground) UnhookWinEvent(foreground); if (focus) UnhookWinEvent(focus);
    local_observer = nullptr;
  }) { while (!ready_) Sleep(1); }
  ~Observer() { stop_ = true; thread_.join(); }
  void Begin() { Sleep(40); baseline_ = Snapshot(); changed_ = false; foreground_events_ = 0; target_focus_ = 0; recording_ = true; }
  bool End() {
    Sleep(40); recording_ = false;
    const auto now = Snapshot();
    return installed_ && baseline_.valid && now.valid && !changed_ &&
        baseline_.foreground == expected_ && now.foreground == expected_ &&
        baseline_.focus == now.focus && baseline_.cursor.x == now.cursor.x &&
        baseline_.cursor.y == now.cursor.y && baseline_.clipboard == now.clipboard &&
        foreground_events_ == 0 && target_focus_ == 0;
  }
  unsigned foreground_events() const { return foreground_events_; }
 private:
  static void CALLBACK Event(HWINEVENTHOOK, DWORD event, HWND window, LONG, LONG, DWORD, DWORD) {
    if (!local_observer || !local_observer->recording_) return;
    if (event == EVENT_SYSTEM_FOREGROUND && window != local_observer->expected_) ++local_observer->foreground_events_;
    if (event == EVENT_OBJECT_FOCUS && GetAncestor(window, GA_ROOT) == local_observer->target_) ++local_observer->target_focus_;
  }
  HWND expected_, target_;
  State baseline_;
  std::atomic<bool> stop_{false}, ready_{false}, recording_{false}, changed_{false};
  std::atomic<unsigned> foreground_events_{0}, target_focus_{0};
  bool installed_ = false;
  std::thread thread_;
};
bool Front(Child& typing) {
  SetWindowPos(typing.window, HWND_TOP, 40, 40, 760, 500, SWP_NOACTIVATE);
  if (GetForegroundWindow() != typing.window) {
    for (int attempt = 0; attempt < 3 && GetForegroundWindow() != typing.window; ++attempt) {
      AllowSetForegroundWindow(typing.process.dwProcessId); typing.Command("activate");
      SetForegroundWindow(typing.window); Sleep(80);
    }
  }
  Sleep(60);
  const auto state = Snapshot(); return state.valid && state.foreground == typing.window;
}
std::wstring Secret() {
  BYTE random[16]{};
  if (BCryptGenRandom(nullptr, random, sizeof(random), BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0) {
    throw std::runtime_error("random_unavailable");
  }
  std::wstring secret = L" "; constexpr wchar_t hex[] = L"0123456789abcdef";
  for (auto c : random) { secret += hex[c >> 4]; secret += hex[c & 15]; }
  secret += L"中\U0001F642e\u0301%\"\\ "; SecureZeroMemory(random, sizeof(random)); return secret;
}
std::string Hex(const std::wstring& text) {
  std::ostringstream out;
  for (auto c : text) out << std::hex << std::setfill('0') << std::setw(4) << static_cast<unsigned>(c);
  return out.str();
}
bool Has(const std::string& result, const std::string& fact) { return result.find(fact) != std::string::npos; }

void Case(const std::string& family, const std::string& name, const std::wstring& executable,
          const std::wstring& argument, Child& typing, const std::string& mutation,
          nb::Outcome expected_outcome, bool expect_match, bool close_before = false) {
  Child receiver(executable, argument), decoy(executable, argument);
  std::string error;
  receiver.Command("reset"); decoy.Command("reset"); typing.Command("reset");
  auto secret = Secret(); auto encoded = Hex(secret);
  receiver.Command("expect " + encoded); SecureZeroMemory(encoded.data(), encoded.size());
  if (expect_match) receiver.Command("seed");
  const auto target = nb::Target::Capture(receiver.Select(), &error);
  if (!target) { Check(family, name, false, error); SecureZeroMemory(secret.data(), secret.size() * sizeof(wchar_t)); return; }
  auto ticket = target->Prepare(&error);
  if (!ticket) { Check(family, name, false, error); SecureZeroMemory(secret.data(), secret.size() * sizeof(wchar_t)); return; }
  if (!mutation.empty()) receiver.Command(mutation);
  if (close_before) { ticket->Close(); ticket->Close(); }
  if (!Front(typing)) { Check(family, name, false, "test_foreground_unavailable"); return; }
  Observer observer(typing.window, receiver.window);
  observer.Begin();
  std::thread user_surrogate([&typing] { typing.Command("type"); });
  auto result = ticket->Replace(secret.data(), secret.size());
  user_surrogate.join();
  const bool unchanged = observer.End();
  const auto actual = receiver.Command("verify"), other = decoy.Command("verify"), user = typing.Command("verify");
  const bool exact = expect_match ? Has(actual, "match=1") : Has(actual, "empty=1");
  const bool isolated = Has(actual, "others=1") && Has(other, "empty=1") && Has(other, "others=1");
  const bool input = Has(user, "typing=1");
  const bool pass = result.outcome == expected_outcome && exact && isolated && unchanged && input;
  Check(family, name, pass, result.error);
  std::cout << "{\"framework\":\"" << family << "\",\"case\":\"" << name
      << "_facts\",\"result\":\"" << nb::OutcomeName(result.outcome) << "\",\"fieldMatches\":"
      << Bool(Has(actual, "match=1")) << ",\"otherFieldsEmpty\":" << Bool(isolated)
      << ",\"noInterference\":" << Bool(unchanged) << ",\"foregroundControlInputPreserved\":"
      << Bool(input) << ",\"inputSurrogateIsControlDirected\":true}" << std::endl;
  if (expect_match) {
    const auto first_oracle = actual;
    const auto duplicate = ticket->Replace(L"different synthetic value", 25);
    const auto again = receiver.Command("verify");
    Check(family, name + "_single_ticket_no_replay", duplicate.outcome == result.outcome && again == first_oracle);
  }
  ticket->Close(); ticket->Close();
  if (result.outcome == nb::Outcome::kSent) {
    auto next = target->Prepare(&error);
    Check(family, name + "_close_retains_target", next != nullptr, error);
    if (next) {
      receiver.Command("seed");
      const auto reused = next->Replace(secret.data(), secret.size());
      Check(family, name + "_new_ticket_can_replace_same_target", reused.outcome == nb::Outcome::kSent &&
            Has(receiver.Command("verify"), "match=1"), reused.error);
    }
  }
  SecureZeroMemory(secret.data(), secret.size() * sizeof(wchar_t));
}

void Suite(const std::string& family, const std::wstring& executable,
           const std::wstring& argument, Child& typing) {
  Case(family, "covered_unicode_whole_value", executable, argument, typing, "", nb::Outcome::kSent, true);
  Case(family, "captured_A_internal_focus_B", executable, argument, typing, "focusB", nb::Outcome::kSent, true);
  Case(family, "minimized", executable, argument, typing, "minimize", nb::Outcome::kSent, true);
  Case(family, "hidden_is_refused", executable, argument, typing, "hide", nb::Outcome::kRefused, false);
  Case(family, "disabled_before_dispatch", executable, argument, typing, "disable", nb::Outcome::kRefused, false);
  if (family != "WPF") Case(family, "readonly_before_dispatch", executable, argument, typing, "readonly", nb::Outcome::kRefused, false);
  Case(family, "recreated_before_dispatch", executable, argument, typing, "recreate", nb::Outcome::kRefused, false);
  Case(family, "duplicate_id_before_dispatch", executable, argument, typing, "duplicate", nb::Outcome::kRefused, false);
  Case(family, "container_changed_before_dispatch", executable, argument, typing, "retitle", nb::Outcome::kRefused, false);
  Case(family, "close_only_preparation", executable, argument, typing, "", nb::Outcome::kRefused, false, true);
  Case(family, "changed_after_set_is_unknown", executable, argument, typing, "disable-after-set", nb::Outcome::kUnknown, true);
  Child original(executable, argument);
  std::string error;
  const auto selection = original.Select();
  const auto discovered = nb::DiscoverNativeFields(selection.approved_executable, original.window, 64, &error);
  Check(family, "discovery_retains_two_distinct_password_fields", discovered.size() == 2, error);
  auto short_selection = selection; short_selection.lease_milliseconds = 50;
  auto expiring = nb::Target::Capture(short_selection, &error);
  if (expiring) {
    Sleep(70); Check(family, "unused_discovery_expires", expiring->Recheck() == "target_expired");
  } else Check(family, "unused_discovery_expires", false, error);
  auto bound = nb::Target::Capture(short_selection, &error);
  if (bound && bound->Retain(&error)) {
    Sleep(70); Check(family, "request_retention_outlives_discovery_ttl", bound->Recheck().empty());
  } else Check(family, "request_retention_outlives_discovery_ttl", false, error);
  auto retained = nb::Target::Capture(selection, &error);
  if (!retained) { Check(family, "process_restart", false, error); return; }
  auto ticket = retained->Prepare(&error);
  original.Stop(); Child replacement(executable, argument);
  const auto result = ticket->Replace(L"synthetic", 9);
  Check(family, "process_restart", result.outcome == nb::Outcome::kRefused &&
        Has(replacement.Command("verify"), "empty=1"), result.error);
}

unsigned long long Fact(const std::string& facts, const std::string& key) {
  const auto offset = facts.find(key + "=");
  if (offset == std::string::npos) return 0;
  return std::stoull(facts.substr(offset + key.size() + 1));
}
void CapabilityCase(const std::wstring& executable, const std::wstring& mode,
                    Child& typing, const std::string& mutation = "") {
  std::string name;
  for (auto c : mode) name += static_cast<char>(c);
  Child receiver(executable, mode);
  auto secret = Secret();
  receiver.Command("expect " + Hex(secret));
  Check("custom-native-uia", name + "_business_locked_before_fill", receiver.Command("submit") == "accepted=0");
  const auto selection = receiver.Select();
  if (mode == L"enum-error") receiver.Command("arm-enumeration-exit");
  std::string error;
  auto found = nb::DiscoverNativeFields(selection.approved_executable, receiver.window, 64, &error);
  if (mode == L"plain-text") {
    Check("custom-native-uia", "ordinary_text_is_not_a_password_candidate", found.empty() && error.empty(), error);
    Check("custom-native-uia", "ordinary_text_never_written_or_read", Has(receiver.Command("verify"), "valueReads=0") &&
        receiver.Command("submit") == "accepted=0");
    SecureZeroMemory(secret.data(), secret.size() * sizeof(wchar_t)); return;
  }
  const bool unsupported = mode == L"readonly" || mode == L"disabled" || mode == L"no-value" ||
      mode == L"web-target" || mode == L"unknown-web-target" || mode == L"ambiguous";
  if (unsupported || mode == L"deny-pattern" || mode == L"enum-error") {
    Check("custom-native-uia", name, found.empty() && !error.empty() &&
        (mode != L"deny-pattern" || error == "unsupported_target"), error);
    SecureZeroMemory(secret.data(), secret.size() * sizeof(wchar_t)); return;
  }
  if (found.size() != 2 || !error.empty()) {
    Check("custom-native-uia", name + "_discovery", false, error);
    SecureZeroMemory(secret.data(), secret.size() * sizeof(wchar_t)); return;
  }
  auto target = found.front().target;
  Check("custom-native-uia", name + "_not_legacy_framework", target->family() == "uia-password-edit");
  if (mode == L"missing-id") Check("custom-native-uia", "no_developer_id_still_descriptive",
      target->field_description() == L"Archive password");
  auto ticket = target->Prepare(&error);
  if (!ticket) { Check("custom-native-uia", name, false, error); return; }
  if (!mutation.empty()) receiver.Command(mutation);
  if (mode == L"minimized") receiver.Command("minimize");
  if (!Front(typing)) { Check("custom-native-uia", name, false, "test_foreground_unavailable"); return; }
  Observer observer(typing.window, receiver.window);
  observer.Begin();
  LARGE_INTEGER before{}, after{}; QueryPerformanceCounter(&before);
  const auto result = ticket->Replace(secret.data(), secret.size());
  QueryPerformanceCounter(&after);
  const bool unchanged = observer.End();
  const auto facts = receiver.Command("verify");
  const bool sent = mutation.empty();
  const bool covered = !sent || (Fact(facts, "setterStarted") >= static_cast<unsigned long long>(before.QuadPart) &&
      Fact(facts, "setterEnded") <= static_cast<unsigned long long>(after.QuadPart));
  const bool pass = result.outcome == (sent ? nb::Outcome::kSent : nb::Outcome::kRefused) &&
      Has(facts, sent ? "match=1" : "empty=1") && Has(facts, "others=1") &&
      Has(facts, "valueReads=0") && Has(facts, "focusCalls=0") && Has(facts, "limitMessages=0") &&
      unchanged && covered;
  Check("custom-native-uia", name + (mutation.empty() ? "" : "_" + mutation), pass, result.error);
  const auto business = receiver.Command("submit");
  Check("custom-native-uia", name + "_separate_receiver_business",
      sent ? business == "accepted=1 payloadSha256=4d4ced12374f78cc0929d87f36d62246eb168b935267e31696feb99d2c528a8b" : business == "accepted=0");
  std::cout << "{\"framework\":\"custom-native-uia\",\"case\":\"" << name << "_setter_facts\","
      << "\"sent\":" << Bool(result.outcome == nb::Outcome::kSent)
      << ",\"noInterference\":" << Bool(unchanged) << ",\"setterCompletelyCovered\":" << Bool(covered)
      << ",\"noPasswordRead\":" << Bool(Has(facts, "valueReads=0"))
      << ",\"noEditMessage\":" << Bool(Has(facts, "limitMessages=0")) << "}" << std::endl;
  const auto original = facts;
  ticket->Replace(L"different synthetic", 19);
  Check("custom-native-uia", name + "_ticket_never_replays", receiver.Command("verify") == original);
  SecureZeroMemory(secret.data(), secret.size() * sizeof(wchar_t));
}
void Capabilities(const std::wstring& executable, Child& typing) {
  for (const auto* mode : {L"normal", L"missing-id", L"native-hwnd", L"web-sibling", L"minimized"}) {
    CapabilityCase(executable, mode, typing);
  }
  for (const auto& mutation : {"recreate", "readonly", "disable", "deny", "retitle", "hide"}) {
    CapabilityCase(executable, L"normal", typing, mutation);
  }
  for (const auto* mode : {L"readonly", L"disabled", L"no-value", L"deny-pattern", L"web-target", L"unknown-web-target", L"plain-text", L"ambiguous", L"enum-error"}) {
    CapabilityCase(executable, mode, typing);
  }
  Child secured(executable, L"normal");
  wchar_t self[32768]{}; GetModuleFileNameW(nullptr, self, 32768);
  Child restricted(self, L"--low-access-check " + std::to_wstring(secured.process.dwProcessId) +
      L" " + std::to_wstring(nb::ProcessCreatedAt(secured.process.hProcess)));
  const auto denied = Line(restricted.output);
  Check("security", "lower_integrity_probe_cannot_access_normal_target", denied == "access_denied", denied);
}
int LowAccessCheck(DWORD process_id, unsigned long long created_at) {
  std::cout << "ready 0" << std::endl;
  HANDLE token = nullptr; PSID sid = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_DEFAULT | TOKEN_QUERY, &token) ||
      !ConvertStringSidToSidW(L"S-1-16-4096", &sid)) {
    if (token) CloseHandle(token);
    std::cout << "probe_setup_failed" << std::endl; return 1;
  }
  TOKEN_MANDATORY_LABEL label{};
  label.Label.Attributes = SE_GROUP_INTEGRITY; label.Label.Sid = sid;
  const auto lowered = SetTokenInformation(token, TokenIntegrityLevel, &label,
      static_cast<DWORD>(sizeof(label) + GetLengthSid(sid)));
  LocalFree(sid); CloseHandle(token);
  if (!lowered) { std::cout << "probe_setup_failed" << std::endl; return 1; }
  // Only this disposable child's own token is lowered. No UAC, policy, user
  // permission or target token is changed, and the probe exits immediately.
  const auto result = nb::CheckProcessAccess(process_id, created_at);
  std::cout << result << std::endl;
  return result == "access_denied" ? 0 : 1;
}
}
int wmain(int argc, wchar_t** argv) {
  if (argc == 4 && std::wstring(argv[1]) == L"--low-access-check") {
    return LowAccessCheck(static_cast<DWORD>(std::stoul(argv[2])), std::stoull(argv[3]));
  }
  const bool capabilities = argc == 5 && std::wstring(argv[4]) == L"capabilities";
  if (argc != 3 && argc != 4 && !capabilities) return 64;
  const bool limits_only = argc == 4 && std::wstring(argv[3]) == L"limits";
  if (argc == 4 && !limits_only) return 64;
  if (FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) return 70;
  std::thread([] { Sleep(170000); ExitProcess(90); }).detach();
  try {
    Child typing(argv[1], L"--typing");
    if (!Front(typing)) {
      std::cout << "{\"case\":\"waiting_for_test_foreground\"}" << std::endl;
      for (int i = 0; i < 900 && GetForegroundWindow() != typing.window; ++i) Sleep(100);
    }
    if (!Front(typing)) { Check("observer", "precondition", false, "test_foreground_unavailable"); }
    else {
      Child calibration(argv[1], L"");
      Observer observer(typing.window, calibration.window);
      observer.Begin(); calibration.Command("activate"); SetForegroundWindow(calibration.window); Sleep(80);
      const bool detected = !observer.End() && observer.foreground_events() > 0;
      Check("observer", "actual_foreground_change_detected", detected);
      Front(typing); observer.Begin(); Sleep(20); Check("observer", "stable_control", observer.End());
      if (capabilities) {
        Capabilities(argv[3], typing);
      } else if (limits_only) {
        Case("Win32", "declared_limit_refused", argv[1], L"", typing, "limit", nb::Outcome::kRefused, false);
        Case("WinForms", "declared_limit_refused", argv[2], L"forms", typing, "limit", nb::Outcome::kRefused, false);
        Case("WPF", "programmatic_password_ignores_typing_limit", argv[2], L"wpf", typing, "limit", nb::Outcome::kSent, true);
      } else {
        Suite("Win32", argv[1], L"", typing);
        Suite("WinForms", argv[2], L"forms", typing);
        Suite("WPF", argv[2], L"wpf", typing);
      }
      Child browser(argv[1], L"--browser-root"); std::string error;
      Check("Win32", "browser_host_class_excluded", !nb::Target::Capture(browser.Select(), &error) && error == "unsupported_target", error);
      auto bad = calibration.Select(); bad.approved_sha256.assign(64, '0');
      Check("identity", "unapproved_bytes_refused", !nb::Target::Capture(bad, &error) && error == "application_changed", error);
      bad = calibration.Select(); ++bad.process_created_at;
      Check("identity", "wrong_process_generation_refused", !nb::Target::Capture(bad, &error) && error == "application_changed", error);
    }
  } catch (...) { Check("harness", "fatal", false, "sanitized_test_failure"); }
  CoUninitialize();
  std::cout << "{\"case\":\"summary\",\"checks\":" << checks << ",\"failures\":" << failures << "}" << std::endl;
  return failures ? 1 : 0;
}
