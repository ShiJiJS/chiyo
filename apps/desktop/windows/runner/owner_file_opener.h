#ifndef RUNNER_OWNER_FILE_OPENER_H_
#define RUNNER_OWNER_FILE_OPENER_H_
#include <cstdint>
#include <functional>
#include <map>
#include <string>

struct OwnerFileIntent {
  std::string operation_id, command_digest, directory, directory_identity;
  std::string name, file_identity, content_digest;
  int64_t byte_length = -1;
  bool operator==(const OwnerFileIntent& other) const;
};
enum class OwnerOpenResult { missing, pending, opened, not_opened, conflict };

// Owner-only dispatch of a protected generated attachment, not arbitrary URLs.
// The durable Dart journal records opening before calling this process cache.
class OwnerFileOpener {
 public:
  using Launch = std::function<bool(const std::wstring&)>;
  explicit OwnerFileOpener(Launch launch) : launch_(std::move(launch)) {}
  OwnerOpenResult Open(const OwnerFileIntent& intent);
  OwnerOpenResult Status(const std::string& id, const std::string& digest) const;
 private:
  struct Entry { OwnerFileIntent intent; OwnerOpenResult result; };
  std::map<std::string, Entry> entries_;
  Launch launch_;
};
#endif
