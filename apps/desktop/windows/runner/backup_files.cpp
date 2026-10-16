#include "backup_files.h"

#include <commdlg.h>
#include <flutter/standard_method_codec.h>

#include <array>
#include <string>

BackupFileDialogs::BackupFileDialogs(flutter::BinaryMessenger* messenger,
                                   HWND owner) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "agent_info_manage/backup_files",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [owner](const flutter::MethodCall<flutter::EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        const bool input = call.method_name() == "backupInput";
        const bool recovery = call.method_name() == "recoveryKeyOutput";
        if (!input && !recovery && call.method_name() != "backupOutput") {
          result->NotImplemented();
          return;
        }
        std::array<wchar_t, 32768> path{};
        if (!input) {
          const std::wstring suggested = recovery ? L"agent-info-recovery-key.txt"
                                                : L"information-backup.aimbackup";
          suggested.copy(path.data(), suggested.size());
        }
        OPENFILENAMEW dialog{};
        dialog.lStructSize = sizeof(dialog);
        dialog.hwndOwner = owner;
        dialog.lpstrFile = path.data();
        dialog.nMaxFile = static_cast<DWORD>(path.size());
        dialog.lpstrFilter = recovery ? L"Recovery key (*.txt)\0*.txt\0All files\0*.*\0\0"
                                     : L"Encrypted backup (*.aimbackup)\0*.aimbackup\0All files\0*.*\0\0";
        dialog.lpstrTitle = input ? L"Choose encrypted backup"
                                 : (recovery ? L"Save recovery key separately"
                                             : L"Export encrypted backup to a new file");
        dialog.lpstrDefExt = recovery ? L"txt" : L"aimbackup";
        dialog.Flags = OFN_EXPLORER | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR |
                       OFN_DONTADDTORECENT | (input ? OFN_FILEMUSTEXIST : OFN_OVERWRITEPROMPT);
        const BOOL chosen = input ? GetOpenFileNameW(&dialog) : GetSaveFileNameW(&dialog);
        if (!chosen) {
          if (CommDlgExtendedError() == 0) result->Success();
          else result->Error("file_dialog_failed", "File dialog unavailable");
          return;
        }
        const int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                              path.data(), -1, nullptr, 0,
                                              nullptr, nullptr);
        if (length <= 1) {
          result->Error("file_dialog_failed", "Invalid file selection");
          return;
        }
        std::string utf8(static_cast<size_t>(length), '\0');
        if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path.data(), -1,
                                utf8.data(), length, nullptr, nullptr) == 0) {
          result->Error("file_dialog_failed", "Invalid file selection");
          return;
        }
        utf8.resize(static_cast<size_t>(length - 1));
        result->Success(flutter::EncodableValue(utf8));
      });
}
