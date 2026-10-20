#include "focus_snapshot.h"
#include <objbase.h>

int APIENTRY wWinMain(HINSTANCE, HINSTANCE, wchar_t* arguments, int) {
  if (std::wstring(arguments) != L"--inspect") return 64;
  const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(initialized)) return 70;
  const auto result = focused_input::CaptureFocus().ToPrivateJson();
  CoUninitialize();
  const HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
  DWORD written = 0;
  const bool ok = output != nullptr && output != INVALID_HANDLE_VALUE &&
      WriteFile(output, result.data(), static_cast<DWORD>(result.size()), &written, nullptr) &&
      written == result.size();
  return ok ? 0 : 74;
}
