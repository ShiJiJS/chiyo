// Test-only fault receiver. Never installed or selected by production bootstrap.
#include "focus_snapshot.h"
#include <array>
#ifndef FILL_FAULT_MODE
#error Test-only behavior must be fixed at build time.
#endif
namespace {
bool Read(HANDLE pipe, BYTE* data, DWORD size) {
  while (size != 0) { DWORD count = 0;
    if (!ReadFile(pipe, data, size, &count, nullptr) || count == 0) return false;
    data += count; size -= count;
  }
  return true;
}
std::vector<BYTE> Frame(HANDLE pipe) {
  BYTE header[4]{}; if (!Read(pipe, header, 4)) return {};
  const DWORD size = header[0] | (static_cast<DWORD>(header[1]) << 8) |
      (static_cast<DWORD>(header[2]) << 16) | (static_cast<DWORD>(header[3]) << 24);
  if (size < 2 || size > 16384) return {};
  std::vector<BYTE> data(size); if (!Read(pipe, data.data(), size)) return {}; return data;
}
void Reply(const std::string& json) {
  DWORD written = 0; WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), json.data(),
      static_cast<DWORD>(json.size()), &written, nullptr);
}
}
int APIENTRY wWinMain(HINSTANCE, HINSTANCE, wchar_t*, int) {
  const HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
  auto init = Frame(input); if (init.size() < 38) return 64;
  if constexpr (FILL_FAULT_MODE == 0) { Sleep(INFINITE); return 70; }
  if constexpr (FILL_FAULT_MODE == 2) {
    Reply("{\"format\":1,\"state\":\"refused\",\"errorCode\":\"desktop_locked\"}\n"); return 0;
  }
  if (init.size() < 72) return 64;
  const size_t count = init[70] | (static_cast<size_t>(init[71]) << 8);
  if (init.size() != 72 + count * 2) return 64;
  std::wstring path;
  for (size_t i = 0; i < count; ++i) path += static_cast<wchar_t>(init[72 + i * 2] | (init[73 + i * 2] << 8));
  std::string hash; const char* digits = "0123456789abcdef";
  for (size_t i = 38; i < 70; ++i) { hash += digits[init[i] >> 4]; hash += digits[init[i] & 15]; }
  const std::string reply = "{\"format\":1,\"state\":\"prepared\",\"application\":{\"executable\":" +
      focused_input::JsonString(path) + ",\"sha256\":\"" + hash + "\"}}\n";
  if constexpr (FILL_FAULT_MODE == 3) { Reply(reply + "SYNTHETIC_TRAILING"); return 0; }
  Reply(reply);
  auto batch = Frame(input);
  if (!batch.empty()) SecureZeroMemory(batch.data(), batch.size());
  // Simulate losing an input acknowledgement. No raw value or diagnostics.
  return 71;
}
