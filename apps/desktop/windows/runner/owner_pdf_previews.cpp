#include "owner_pdf_previews.h"
#include "owner_pdf_renderer.h"
#include <flutter/standard_method_codec.h>
#include <mutex>
#include <optional>

namespace {
constexpr UINT kPdfReady = WM_APP + 71;
using Value = flutter::EncodableValue;
using Result = flutter::MethodResult<Value>;
std::optional<int64_t> Integer(const Value& value) {
  if (const auto* number = std::get_if<int32_t>(&value)) return *number;
  if (const auto* number = std::get_if<int64_t>(&value)) return *number;
  return std::nullopt;
}
}
struct OwnerPdfPreviews::State {
  std::mutex mutex;
  bool closed = false, ready = false;
  std::unique_ptr<Result> pending;
  OwnerPdfPage output;
};
OwnerPdfPreviews::OwnerPdfPreviews(flutter::BinaryMessenger* messenger, HWND owner)
    : state_(std::make_shared<State>()) {
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(messenger,
      "agent_info_manage/owner_pdf_preview", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this, owner](const flutter::MethodCall<Value>& call,
      std::unique_ptr<Result> result) {
    if (call.method_name() != "renderPage") { result->NotImplemented(); return; }
    const auto* args = call.arguments() ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
    if (!args || args->size() != 2 || args->count(Value("bytes")) != 1 || args->count(Value("page")) != 1) {
      result->Error("invalid_request", "Invalid PDF preview request"); return;
    }
    const auto* bytes = std::get_if<std::vector<uint8_t>>(&args->at(Value("bytes")));
    const auto page = Integer(args->at(Value("page")));
    if (!bytes || bytes->empty() || bytes->size() > 10 * 1024 * 1024 || !page || *page < 0) {
      result->Error("invalid_request", "Invalid PDF preview request"); return;
    }
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      if (state_->pending) { result->Error("preview_busy", "PDF preview busy"); return; }
      if (state_->closed) { result->Error("preview_unavailable", "PDF preview unavailable"); return; }
      state_->pending = std::move(result);
      state_->ready = false;
    }
    if (worker_.joinable()) worker_.join();
    worker_ = std::thread([state = state_, owner, bytes = *bytes, page = *page]() mutable {
      auto output = RenderOwnerPdf(bytes, page);
      SecureZeroMemory(bytes.data(), bytes.size());
      std::lock_guard<std::mutex> lock(state->mutex);
      if (!state->closed) {
        state->output = std::move(output);
        state->ready = true;
        // Only a wakeup crosses HWND messaging, never a pointer or file bytes.
        PostMessageW(owner, kPdfReady, 0, 0);
      }
    });
  });
}
OwnerPdfPreviews::~OwnerPdfPreviews() {
  channel_->SetMethodCallHandler(nullptr);
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->closed = true;
  }
  if (worker_.joinable()) worker_.join();
  if (state_->pending) state_->pending->Error("preview_unavailable", "PDF preview closed");
}
bool OwnerPdfPreviews::HandleMessage(UINT message) {
  if (message != kPdfReady) return false;
  std::unique_ptr<Result> result;
  OwnerPdfPage output;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (!state_->ready || !state_->pending || state_->closed) return true;
    result = std::move(state_->pending);
    output = std::move(state_->output);
    state_->ready = false;
  }
  if (worker_.joinable()) worker_.join();
  if (!output.error.empty()) result->Error(output.error, "PDF preview unavailable");
  else result->Success(Value(flutter::EncodableMap{
      {Value("png"), Value(std::move(output.png))},
      {Value("width"), Value(static_cast<int32_t>(output.width))},
      {Value("height"), Value(static_cast<int32_t>(output.height))},
      {Value("page"), Value(static_cast<int32_t>(output.page))},
      {Value("pageCount"), Value(static_cast<int32_t>(output.page_count))},
  }));
  return true;
}
