#include "owner_pdf_renderer.h"
#include <iostream>
#include <sstream>
#include <iomanip>
#include <array>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include "owner_pdf_locked_fixture.h"

std::array<uint8_t, 4> Center(const OwnerPdfPage& page) {
  using namespace winrt::Windows::Storage::Streams;
  using namespace winrt::Windows::Graphics::Imaging;
  InMemoryRandomAccessStream stream;
  DataWriter writer(stream.GetOutputStreamAt(0));
  writer.WriteBytes(page.png);
  writer.StoreAsync().get();
  writer.DetachStream();
  stream.Seek(0);
  const auto decoder = BitmapDecoder::CreateAsync(stream).get();
  if (decoder.PixelWidth() != page.width || decoder.PixelHeight() != page.height) {
    std::cerr << "PDF PNG dimensions differ: " << decoder.PixelWidth() << "x" << decoder.PixelHeight()
              << " vs " << page.width << "x" << page.height << "\n";
    return {0,0,0,0};
  }
  const auto pixels = decoder.GetPixelDataAsync(BitmapPixelFormat::Rgba8,
      BitmapAlphaMode::Straight, BitmapTransform(), ExifOrientationMode::IgnoreExifOrientation,
      ColorManagementMode::DoNotColorManage).get().DetachPixelData();
  const uint32_t offset = (page.height / 2 * page.width + page.width / 2) * 4;
  return {pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3]};
}

std::vector<uint8_t> Document() {
  std::string pdf = "%PDF-1.4\n";
  std::vector<size_t> offsets;
  const auto stream = [](const std::string& content) {
    return "<< /Length " + std::to_string(content.size()) + " >>\nstream\n" + content + "endstream";
  };
  const std::vector<std::string> objects{
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Count 2 /Kids [3 0 R 5 0 R] >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 200] /Contents 4 0 R >>",
    stream("1 0 0 rg 0 0 100 200 re f\n"),
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 2000 1000] /Contents 6 0 R >>",
    stream("0 0 1 rg 0 0 2000 1000 re f\n")
  };
  for (size_t i = 0; i < objects.size(); i++) {
    offsets.push_back(pdf.size());
    pdf += std::to_string(i + 1) + " 0 obj\n" + objects[i] + "\nendobj\n";
  }
  const auto xref = pdf.size();
  pdf += "xref\n0 7\n0000000000 65535 f \n";
  for (auto offset : offsets) {
    std::ostringstream row;
    row << std::setfill('0') << std::setw(10) << offset << " 00000 n \n";
    pdf += row.str();
  }
  pdf += "trailer\n<< /Size 7 /Root 1 0 R >>\nstartxref\n" + std::to_string(xref) + "\n%%EOF\n";
  return {pdf.begin(), pdf.end()};
}
int main() {
  winrt::init_apartment(winrt::apartment_type::multi_threaded);
  const auto bytes = Document();
  const auto first = RenderOwnerPdf(bytes, 0);
  const auto second = RenderOwnerPdf(bytes, 1);
  // Windows PDF Size is expressed in 96-DPI DIPs, rather than 72-DPI PDF points.
  if (!first.error.empty() || !second.error.empty() || first.width < 260 || first.width > 267 ||
      first.height < 527 || first.height > 534 ||
      second.width < 1590 || second.width > 1600 || second.height < 790 || second.height > 800 ||
      first.page_count != 2 || second.page != 1 ||
      first.png.size() < 33 || first.png[0] != 137 || first.png[1] != 80 || first.png == second.png) {
    std::cerr << "PDF rendering/dimensions failed: " << first.error << " " << second.error
              << " " << first.width << "x" << first.height << " " << second.width << "x" << second.height << "\n";
    return 1;
  }
  if (Center(first) != std::array<uint8_t,4>{255,0,0,255} ||
      Center(second) != std::array<uint8_t,4>{0,0,255,255}) {
    std::cerr << "PDF page original colors failed\n";
    return 1;
  }
  const std::string truncated = "%PDF-1.4\nbroken";
  const std::vector<uint8_t> locked(std::begin(kLockedPdf), std::end(kLockedPdf));
  const auto locked_result = RenderOwnerPdf(locked, 0);
  if (locked_result.error != "pdf_locked") {
    std::cerr << "Protected PDF error failed: " << locked_result.error << " "
              << std::hex << locked_result.native_error << "\n";
    return 1;
  }
  if (RenderOwnerPdf(bytes, 2).error != "invalid_request" ||
      RenderOwnerPdf(bytes, -1).error != "invalid_request" ||
      RenderOwnerPdf({}, 0).error != "invalid_request" ||
      RenderOwnerPdf({1,2,3}, 0).error != "invalid_pdf" ||
      RenderOwnerPdf({truncated.begin(), truncated.end()}, 0).error != "invalid_pdf") {
    const auto corrupt = RenderOwnerPdf({truncated.begin(), truncated.end()}, 0);
    std::cerr << "PDF bounds/corrupt input failed: " << corrupt.error << " " << std::hex << corrupt.native_error << "\n";
    return 1;
  }
  std::cout << "Windows in-memory PDF pages and bounds passed" << std::endl;
  winrt::uninit_apartment();
  return 0;
}
