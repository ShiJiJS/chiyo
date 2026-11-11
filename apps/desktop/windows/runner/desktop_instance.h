#ifndef RUNNER_DESKTOP_INSTANCE_H_
#define RUNNER_DESKTOP_INSTANCE_H_
#include <windows.h>
#include <optional>
#include <string>
#include <vector>

// One application lifetime per executable and private connection directory.
// A repeat launch only raises the original window, including its active modal.
class DesktopInstance {
 public:
  enum class Result { primary, activated, unavailable };
  explicit DesktopInstance(const std::wstring& scope, DWORD timeout_ms = 10000);
  ~DesktopInstance();
  DesktopInstance(const DesktopInstance&) = delete;
  DesktopInstance& operator=(const DesktopInstance&) = delete;
  Result result() const { return result_; }
  bool Attach(HWND window);
  static UINT ActivationMessage();
  static bool HandleActivation(HWND window, UINT message, WPARAM process,
                               LPARAM reserved);
  static std::optional<std::wstring> Scope(
      const std::wstring& executable, const std::wstring& app_data,
      const std::vector<std::string>& arguments);
  static std::optional<std::wstring> CurrentScope(
      const std::vector<std::string>& arguments);

 private:
  HANDLE mutex_ = nullptr;
  HWND window_ = nullptr;
  std::wstring property_;
  bool owns_ = false;
  Result result_ = Result::unavailable;
};
#endif
