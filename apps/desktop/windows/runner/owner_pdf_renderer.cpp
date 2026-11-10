#include "owner_pdf_renderer.h"
#include <windows.h>
#include <roapi.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Data.Pdf.h>
#include <algorithm>
#include <chrono>
#include <cmath>

namespace {
using Clock = std::chrono::steady_clock;
template <class Async>
auto Await(Async const& operation, Clock::time_point deadline) {
  const auto remaining = deadline - Clock::now();
  if (remaining <= Clock::duration::zero()) {
    operation.Cancel();
    throw winrt::hresult_error(E_ABORT);
  }
  if (operation.wait_for(std::chrono::duration_cast<std::chrono::microseconds>(remaining)) ==
      winrt::Windows::Foundation::AsyncStatus::Started) {
    operation.Cancel();
    throw winrt::hresult_error(E_ABORT);
  }
  return operation.get();
}
OwnerPdfPage Failure(const char* code, int32_t native_error = 0) {
  OwnerPdfPage value;
  value.error = code;
  value.native_error = native_error;
  return value;
}
uint32_t BigEndian(const std::vector<uint8_t>& bytes, size_t offset) {
  return (static_cast<uint32_t>(bytes[offset]) << 24) |
      (static_cast<uint32_t>(bytes[offset + 1]) << 16) |
      (static_cast<uint32_t>(bytes[offset + 2]) << 8) | bytes[offset + 3];
}
}

OwnerPdfPage RenderOwnerPdf(const std::vector<uint8_t>& bytes, int64_t page) {
  if (page < 0 || bytes.empty() || bytes.size() > 10 * 1024 * 1024) {
    return Failure("invalid_request");
  }
  const auto initialized = RoInitialize(RO_INIT_MULTITHREADED);
  if (FAILED(initialized)) return Failure("preview_unavailable");
  struct Apartment { ~Apartment() { RoUninitialize(); } } apartment;
  try {
    using namespace winrt::Windows::Storage::Streams;
    using namespace winrt::Windows::Data::Pdf;
    const auto deadline = Clock::now() + std::chrono::seconds(15);
    InMemoryRandomAccessStream source;
    DataWriter writer(source.GetOutputStreamAt(0));
    writer.WriteBytes(bytes);
    Await(writer.StoreAsync(), deadline);
    Await(writer.FlushAsync(), deadline);
    writer.DetachStream();
    source.Seek(0);
    PdfDocument document{nullptr};
    try {
      document = Await(PdfDocument::LoadFromStreamAsync(source), deadline);
    } catch (winrt::hresult_error const& error) {
      // Microsoft PDF sample: HRESULT_FROM_WIN32(ERROR_WRONG_PASSWORD).
      if (error.code() == HRESULT_FROM_WIN32(ERROR_WRONG_PASSWORD)) {
        return Failure("pdf_locked");
      }
      // This Windows parser reports these codes for non-PDF/truncated bytes.
      const bool invalid = error.code() == E_FAIL ||
          error.code() == static_cast<HRESULT>(0x80048014) ||
          error.code() == static_cast<HRESULT>(0x80048018);
      return Failure(invalid ? "invalid_pdf" : "preview_unavailable", error.code());
    }
    const auto count = document.PageCount();
    if (count == 0 || count > 4096) return Failure("pdf_unsupported");
    if (static_cast<uint64_t>(page) >= count) return Failure("invalid_request");
    auto pdf_page = document.GetPage(static_cast<uint32_t>(page));
    const auto size = pdf_page.Size();
    if (!std::isfinite(size.Width) || !std::isfinite(size.Height) ||
        size.Width <= 0 || size.Height <= 0 ||
        size.Width > 100000 || size.Height > 100000) {
      return Failure("pdf_unsupported");
    }
    const double scale = std::min(2.0, 1600.0 / std::max(size.Width, size.Height));
    const auto width = static_cast<uint32_t>(std::clamp(std::ceil(size.Width * scale), 1.0, 1600.0));
    const auto height = static_cast<uint32_t>(std::clamp(std::ceil(size.Height * scale), 1.0, 1600.0));
    PdfPageRenderOptions options;
    options.BitmapEncoderId(winrt::Windows::Graphics::Imaging::BitmapEncoder::PngEncoderId());
    options.BackgroundColor({255, 255, 255, 255});
    auto render = [&](uint32_t dip_width, uint32_t dip_height) {
      options.DestinationWidth(dip_width);
      options.DestinationHeight(dip_height);
      InMemoryRandomAccessStream output;
      Await(pdf_page.RenderToStreamAsync(output, options), deadline);
      const auto length = output.Size();
      if (length < 33 || length > 12 * 1024 * 1024) throw winrt::hresult_error(E_FAIL);
      DataReader reader(output.GetInputStreamAt(0));
      if (Await(reader.LoadAsync(static_cast<uint32_t>(length)), deadline) != length) {
        throw winrt::hresult_error(E_FAIL);
      }
      std::vector<uint8_t> png(static_cast<size_t>(length));
      reader.ReadBytes(png);
      const std::vector<uint8_t> header{137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82};
      if (!std::equal(header.begin(), header.end(), png.begin())) throw winrt::hresult_error(E_FAIL);
      return png;
    };
    // WinRT destination sizes are DIPs, not PNG pixels. Calibrate its actual
    // raster scale with a tiny bounded page, independent of window/monitor DPI
    // APIs. This avoids allocating a full-size page at an unknown display scale.
    const auto probe = render(100, 100);
    const auto probe_edge = std::max(BigEndian(probe, 16), BigEndian(probe, 20));
    if (probe_edge < 100 || probe_edge > 1000) return Failure("pdf_unsupported");
    const double raster_scale = probe_edge / 100.0;
    auto png = render(std::max(1U, static_cast<uint32_t>(std::floor(width / raster_scale))),
        std::max(1U, static_cast<uint32_t>(std::floor(height / raster_scale))));
    pdf_page.Close();
    OwnerPdfPage result;
    result.width = BigEndian(png, 16);
    result.height = BigEndian(png, 20);
    if (result.width == 0 || result.height == 0 || result.width > 1600 || result.height > 1600) {
      return Failure("pdf_unsupported");
    }
    result.png = std::move(png);
    result.page = static_cast<uint32_t>(page);
    result.page_count = count;
    return result;
  } catch (...) {
    return Failure("preview_unavailable");
  }
}
