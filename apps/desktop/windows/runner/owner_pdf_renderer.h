#ifndef RUNNER_OWNER_PDF_RENDERER_H_
#define RUNNER_OWNER_PDF_RENDERER_H_
#include <cstdint>
#include <string>
#include <vector>

struct OwnerPdfPage {
  std::vector<uint8_t> png;
  uint32_t width = 0, height = 0, page = 0, page_count = 0;
  std::string error;
  int32_t native_error = 0;  // Internal diagnostic; never returned to Flutter.
};

// Call on a worker thread. Bytes stay in memory; one bounded PNG page out.
OwnerPdfPage RenderOwnerPdf(const std::vector<uint8_t>& bytes, int64_t page);
#endif
