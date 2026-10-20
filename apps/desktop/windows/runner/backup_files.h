#ifndef RUNNER_BACKUP_FILES_H_
#define RUNNER_BACKUP_FILES_H_

#include <windows.h>
#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

// Owner-process-only file dialogs. No paths or secrets are logged.
class BackupFileDialogs {
 public:
  BackupFileDialogs(flutter::BinaryMessenger* messenger, HWND owner);

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_BACKUP_FILES_H_
