#ifndef RUNNER_OWNER_PDF_PREVIEWS_H_
#define RUNNER_OWNER_PDF_PREVIEWS_H_
#include <windows.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <memory>
#include <thread>

class OwnerPdfPreviews {
 public:
  OwnerPdfPreviews(flutter::BinaryMessenger* messenger, HWND owner);
  ~OwnerPdfPreviews();
  bool HandleMessage(UINT message);
 private:
  struct State;
  std::shared_ptr<State> state_;
  std::thread worker_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};
#endif
