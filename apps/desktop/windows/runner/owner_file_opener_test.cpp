#include "owner_file_opener.h"
#include <iostream>

// Eight bounded stdin lines from the Dart test's freshly reserved protected
// lease. No path, identity, file body or control proof is printed or executed.
int main() {
  std::string values[8];
  for (auto& value : values) {
    if (!std::getline(std::cin, value) || value.size() > 32768) return 64;
  }
  OwnerFileIntent intent{values[0], values[1], values[2], values[3], values[4], values[5], values[7], -1};
  try { intent.byte_length = std::stoll(values[6]); } catch (...) { return 64; }
  int launched = 0;
  OwnerFileOpener opener([&](const std::wstring&) { launched++; return true; });
  if (opener.Open(intent) != OwnerOpenResult::opened || opener.Open(intent) != OwnerOpenResult::opened ||
      opener.Status(intent.operation_id, intent.command_digest) != OwnerOpenResult::opened || launched != 1) {
    std::cerr << "Protected lease dispatch/status failed\n"; return 1;
  }
  auto changed = intent;
  changed.byte_length++;
  if (opener.Open(changed) != OwnerOpenResult::conflict) return 2;
  for (int variant = 0; variant < 5; variant++) {
    auto bad = intent;
    bad.operation_id += "-invalid";
    if (variant == 0) bad.file_identity += "0";
    if (variant == 1) bad.directory_identity += "0";
    if (variant == 2) bad.content_digest = std::string(64, '0');
    if (variant == 3) bad.name = "attachment.exe";
    if (variant == 4) bad.directory += "\\..";
    if (opener.Open(bad) != OwnerOpenResult::not_opened || launched != 1) return 3;
  }
  int uncertain_attempts = 0;
  OwnerFileOpener uncertain([&](const std::wstring&) -> bool { uncertain_attempts++; throw 1; });
  if (uncertain.Open(intent) != OwnerOpenResult::pending || uncertain.Open(intent) != OwnerOpenResult::pending ||
      uncertain.Status(intent.operation_id, intent.command_digest) != OwnerOpenResult::pending || uncertain_attempts != 1) return 4;
  OwnerFileOpener reopened([](const std::wstring&) { return true; });
  if (reopened.Status(intent.operation_id, intent.command_digest) != OwnerOpenResult::missing) return 5;
  for (int index = 1; index < 256; index++) {
    auto next = intent;
    next.operation_id = "bounded-" + std::to_string(index);
    if (opener.Open(next) != OwnerOpenResult::opened) return 6;
  }
  auto overflow = intent;
  overflow.operation_id = "bounded-overflow";
  if (opener.Open(overflow) != OwnerOpenResult::not_opened ||
      opener.Open(intent) != OwnerOpenResult::opened || launched != 256) return 7;
  std::cout << "{\"validatedLease\":true,\"firstIntentLaunchCount\":1,\"mismatchesRefused\":true,\"unknownNotReplayed\":true,\"reopenMissing\":true,\"capacity\":256,\"overflowRefused\":true}" << std::endl;
}
