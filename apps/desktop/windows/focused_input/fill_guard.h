#ifndef AGENT_INFO_FILL_GUARD_H_
#define AGENT_INFO_FILL_GUARD_H_
#include "focus_snapshot.h"
#include <memory>

namespace focused_input {
class Handle {
 public:
  explicit Handle(HANDLE value = nullptr) : value_(value) {}
  ~Handle();
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  HANDLE get() const { return value_; }
 private:
  HANDLE value_;
};
struct FileSeal {
  Handle handle;
  std::wstring path;
  std::string sha256;
  explicit FileSeal(HANDLE h) : handle(h) {}
};
std::unique_ptr<FileSeal> SealFile(const std::wstring& path);
bool SamePath(const std::wstring& a, const std::wstring& b);
bool SameTarget(const FocusSnapshot& pinned, const FocusSnapshot& current);
bool ValidUnits(const std::vector<wchar_t>& units);
std::string Refusal(const FocusSnapshot& snapshot);
std::unique_ptr<Handle> PinParent(DWORD expected);

// Keeps process and executable handles until the operation ends. No field
// value, window title, DOM or clipboard access is used by this boundary.
class TargetGuard {
 public:
  static std::unique_ptr<TargetGuard> Prepare(
      const std::wstring& approved_path, const std::string& approved_sha,
      std::string* error);
  std::string Recheck() const;
  std::string PublicApplication() const;
 private:
  FocusSnapshot target_;
  std::unique_ptr<FileSeal> application_, provider_;
  std::vector<std::unique_ptr<Handle>> processes_;
};
std::unique_ptr<Handle> ReserveDesktop(std::string* error);
}  // namespace focused_input
#endif
