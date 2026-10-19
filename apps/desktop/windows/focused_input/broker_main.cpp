#include "fill_guard.h"
#include <objbase.h>
#include <array>
#include <cstdint>
#include <thread>

namespace {
using focused_input::Handle;
struct Frame {
  std::vector<BYTE> bytes;
  ~Frame() { if (!bytes.empty()) SecureZeroMemory(bytes.data(), bytes.size()); }
};
bool ReadExact(HANDLE pipe, BYTE* target, DWORD size) {
  while (size != 0) {
    DWORD received = 0;
    if (!ReadFile(pipe, target, size, &received, nullptr) || received == 0) return false;
    target += received; size -= received;
  }
  return true;
}
bool ReadFrame(HANDLE pipe, Frame* frame) {
  std::array<BYTE, 4> header{};
  if (!ReadExact(pipe, header.data(), 4)) return false;
  const DWORD size = header[0] | (static_cast<DWORD>(header[1]) << 8) |
      (static_cast<DWORD>(header[2]) << 16) | (static_cast<DWORD>(header[3]) << 24);
  if (size < 2 || size > 16384) return false;
  frame->bytes.resize(size);
  return ReadExact(pipe, frame->bytes.data(), size) && frame->bytes[0] == 1;
}
bool Reply(HANDLE pipe, const std::string& state, const std::string& error = "",
    const std::string& application = "") {
  const std::string text = "{\"format\":1,\"state\":\"" + state + "\"" +
      (error.empty() ? "" : ",\"errorCode\":\"" + error + "\"") +
      (application.empty() ? "" : ",\"application\":" + application) + "}\n";
  DWORD written = 0;
  return WriteFile(pipe, text.data(), static_cast<DWORD>(text.size()), &written, nullptr) && written == text.size();
}
std::string Hex(const std::vector<BYTE>& data, size_t start) {
  std::string result; const char* digits = "0123456789abcdef";
  for (size_t i = start; i < start + 32; ++i) {
    result += digits[data[i] >> 4]; result += digits[data[i] & 15];
  }
  return result;
}
DWORD ParentId(const std::vector<BYTE>& data) {
  return data[2] | (static_cast<DWORD>(data[3]) << 8) |
      (static_cast<DWORD>(data[4]) << 16) | (static_cast<DWORD>(data[5]) << 24);
}
int Run() {
  const HANDLE input = GetStdHandle(STD_INPUT_HANDLE), output = GetStdHandle(STD_OUTPUT_HANDLE);
  if (GetFileType(input) != FILE_TYPE_PIPE || GetFileType(output) != FILE_TYPE_PIPE) return 64;
  // Also bounds an orphan that stalls before sending its initial frame.
  std::thread([] { Sleep(30000); ExitProcess(70); }).detach();
  Frame init;
  if (!ReadFrame(input, &init) || init.bytes.size() < 38 || init.bytes[1] > 1) return 64;
  const bool probe = init.bytes[1] == 0;
  if ((probe && init.bytes.size() != 38) || (!probe && init.bytes.size() < 72)) return 64;
  const auto parent = focused_input::PinParent(ParentId(init.bytes));
  if (!parent) return 64;
  HANDLE parent_watch = nullptr;
  if (!DuplicateHandle(GetCurrentProcess(), parent->get(), GetCurrentProcess(),
      &parent_watch, SYNCHRONIZE, FALSE, 0)) return 70;
  std::thread([parent_watch] {
    WaitForSingleObject(parent_watch, INFINITE); CloseHandle(parent_watch); ExitProcess(70);
  }).detach();
  std::wstring own_path(32768, L'\0');
  const DWORD own_length = GetModuleFileNameW(nullptr, own_path.data(), static_cast<DWORD>(own_path.size()));
  if (own_length == 0 || own_length >= own_path.size()) return 70;
  own_path.resize(own_length);
  const auto self = focused_input::SealFile(own_path);
  if (!self || self->sha256 != Hex(init.bytes, 6)) {
    Reply(output, "refused", "application_changed"); return 0;
  }
  std::wstring approved_path; std::string approved_sha;
  if (!probe) {
    const size_t count = init.bytes[70] | (static_cast<size_t>(init.bytes[71]) << 8);
    if (count == 0 || count > 4096 || init.bytes.size() != 72 + count * 2) return 64;
    approved_sha = Hex(init.bytes, 38);
    for (size_t i = 0; i < count; ++i) {
      const wchar_t c = static_cast<wchar_t>(init.bytes[72 + i * 2] |
          (static_cast<unsigned int>(init.bytes[73 + i * 2]) << 8));
      if (c < 32 || c == 127) return 64;
      approved_path += c;
    }
  }
  std::string error;
  const auto reservation = focused_input::ReserveDesktop(&error);
  if (!reservation) { Reply(output, "refused", error); return 0; }
  const auto target = focused_input::TargetGuard::Prepare(approved_path, approved_sha, &error);
  if (!target) { Reply(output, "refused", error.empty() ? "unsupported_target" : error); return 0; }
  if (!Reply(output, probe ? "ready" : "prepared", "", target->PublicApplication()) || probe) return 0;
  size_t total_units = 0;
  for (unsigned batches = 0; batches < 4096; ++batches) {
    Frame frame;
    if (!ReadFrame(input, &frame)) return 0;
    if (frame.bytes[1] == 3 && frame.bytes.size() == 2) return 0;
    if (frame.bytes[1] != 2 || frame.bytes.size() < 4) return 64;
    const size_t count = frame.bytes[2] | (static_cast<size_t>(frame.bytes[3]) << 8);
    if (count == 0 || count > 16 || total_units + count > 4096 ||
        frame.bytes.size() != 4 + count * 2) return 64;
    total_units += count;
    std::vector<wchar_t> units;
    for (size_t i = 0; i < count; ++i) {
      units.push_back(static_cast<wchar_t>(frame.bytes[4 + i * 2] |
          (static_cast<unsigned int>(frame.bytes[5 + i * 2]) << 8)));
    }
    const bool valid = focused_input::ValidUnits(units);
    std::array<INPUT, 32> events{};
    if (valid) {
      for (size_t i = 0; i < count; ++i) {
        events[i * 2].type = events[i * 2 + 1].type = INPUT_KEYBOARD;
        events[i * 2].ki.wScan = events[i * 2 + 1].ki.wScan = static_cast<WORD>(units[i]);
        events[i * 2].ki.dwFlags = KEYEVENTF_UNICODE;
        events[i * 2 + 1].ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
      }
    }
    SecureZeroMemory(units.data(), units.size() * sizeof(wchar_t));
    if (!valid) { Reply(output, "refused", "unsupported_secret"); return 0; }
    error = target->Recheck();
    if (WaitForSingleObject(parent->get(), 0) != WAIT_TIMEOUT) error = "service_unavailable";
    if (!error.empty()) {
      SecureZeroMemory(events.data(), sizeof(events)); Reply(output, "refused", error); return 0;
    }
    SetLastError(ERROR_SUCCESS);
    const UINT inserted = SendInput(static_cast<UINT>(count * 2), events.data(), sizeof(INPUT));
    SecureZeroMemory(events.data(), sizeof(events));
    if (inserted != count * 2) {
      Reply(output, inserted == 0 ? "refused" : "partial",
          inserted == 0 ? "input_rejected" : "input_partial"); return 0;
    }
    error = target->Recheck();
    if (!error.empty()) { Reply(output, "unknown", error); return 0; }
    if (!Reply(output, "sent")) return 0;
  }
  return 0;
}
}

int APIENTRY wWinMain(HINSTANCE, HINSTANCE, wchar_t* arguments, int) {
  if (std::wstring(arguments) != L"--broker-v1") return 64;
  const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(initialized)) return 70;
  int result = 70;
  try { result = Run(); } catch (...) { /* Never output request or exception text. */ }
  CoUninitialize();
  return result;
}
