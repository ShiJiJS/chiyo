#ifndef CHIYO_NATIVE_BACKGROUND_DISCOVERY_H_
#define CHIYO_NATIVE_BACKGROUND_DISCOVERY_H_
#include "target.h"

namespace native_background_fill {
// Entirely private helper data. Raw process/window information never leaves
// this boundary; the App receives opaque registry IDs and descriptive metadata.
struct DiscoveredTarget {
  std::shared_ptr<Target> target;
  HWND window = nullptr;
  std::wstring executable;
  std::string sha256;
};
std::vector<DiscoveredTarget> DiscoverNativeFields(
    const std::wstring& executable, HWND selected_window, size_t limit,
    std::string* error);
}  // namespace native_background_fill
#endif
