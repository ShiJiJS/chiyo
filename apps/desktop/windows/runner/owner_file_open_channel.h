#ifndef RUNNER_OWNER_FILE_OPEN_CHANNEL_H_
#define RUNNER_OWNER_FILE_OPEN_CHANNEL_H_
#include <windows.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include "owner_file_opener.h"
#include <memory>
class OwnerFileOpenChannel {
 public:
  OwnerFileOpenChannel(flutter::BinaryMessenger* messenger, HWND owner);
  ~OwnerFileOpenChannel();
 private:
  OwnerFileOpener opener_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};
#endif
