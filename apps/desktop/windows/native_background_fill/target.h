#ifndef CHIYO_NATIVE_BACKGROUND_TARGET_H_
#define CHIYO_NATIVE_BACKGROUND_TARGET_H_

#include <windows.h>
#include <memory>
#include <string>
#include <vector>

namespace native_background_fill {

// Private host-to-helper selection. These hints are never authorization:
// Capture must also pin the approved executable bytes and security context.
struct SelectorStep {
  std::wstring automation_id;
  int control_type = 0;
};
struct Selection {
  std::wstring approved_executable;
  std::string approved_sha256;
  DWORD process_id = 0;
  unsigned long long process_created_at = 0;
  HWND window = nullptr;
  std::vector<int> observed_window_runtime_id;
  std::vector<int> observed_element_runtime_id;
  std::vector<SelectorStep> path;
  DWORD lease_milliseconds = 300000;
};

enum class Outcome { kRefused, kSent, kUnknown };
struct Result {
  Outcome outcome = Outcome::kRefused;
  std::string error;
};

class Prepared;
// Worker-local retained target. Construct and use on the same windowless MTA.
// No field value is ever read. No focus, activation, keyboard or clipboard API
// participates in Capture/Recheck/Replace. Recheck failure permanently retires
// the lease; obtaining another instance requires an explicit new Capture.
class Target final : public std::enable_shared_from_this<Target> {
 public:
  static std::shared_ptr<Target> Capture(const Selection& selection,
                                       std::string* error);
  ~Target();
  Target(const Target&) = delete;
  Target& operator=(const Target&) = delete;
  std::string Recheck();
  std::unique_ptr<Prepared> Prepare(std::string* error);
  // Only the authenticated App may retain a discovered target for a submitted
  // request; the higher-level grant is still checked before every dispatch.
  bool Retain(std::string* error);
  void Invalidate();
  bool SameInstance(const Target& other) const;
  const std::string& family() const;
  const std::wstring& window_description() const;
  const std::wstring& field_description() const;

 private:
  struct Impl;
  friend class Prepared;
  explicit Target(std::unique_ptr<Impl> impl);
  std::unique_ptr<Impl> impl_;
};

// One execution ticket. Repeated Replace returns the first result; Close is
// idempotent and releases this preparation without discarding its target.
class Prepared final {
 public:
  ~Prepared();
  Result Replace(const wchar_t* units, size_t count);
  const Result* LastResult() const;
  void Close();
 private:
  friend class Target;
  explicit Prepared(std::shared_ptr<Target> target);
  std::shared_ptr<Target> target_;
  bool consumed_ = false, closed_ = false;
  Result result_;
};

// Private bootstrap utilities. Executable paths/digests and process identities
// are for the authenticated App boundary, not ordinary CLI output.
bool InspectExecutable(const std::wstring& path, std::wstring* canonical_path,
                       std::string* sha256);
unsigned long long ProcessCreatedAt(HANDLE process);
bool ValidSecret(const wchar_t* units, size_t count);
const char* OutcomeName(Outcome outcome);

}  // namespace native_background_fill
#endif
