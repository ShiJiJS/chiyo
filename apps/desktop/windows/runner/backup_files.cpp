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
        const bool credential = call.method_name() == "credentialInput";
        const bool known_hosts = call.method_name() == "knownHostsInput";
        const bool information_input = call.method_name() == "informationFileInput";
        const bool information_output = call.method_name() == "informationFileOutput";
        const bool information = information_input || information_output;
        const bool input = call.method_name() == "backupInput" || call.method_name() == "recoveryKeyInput" || credential || known_hosts || information_input;
        const bool recovery = call.method_name() == "recoveryKeyOutput" || call.method_name() == "recoveryKeyInput";
        if (!input && !recovery && !information_output && call.method_name() != "backupOutput") {
          result->NotImplemented();
          return;
        }
        std::array<wchar_t, 32768> path{};
        if (!input) {
          std::wstring suggested = information_output ? L"attachment"
              : recovery ? L"agent-info-recovery-key.txt"
                         : L"information-backup.aimbackup";
          if (information_output && call.arguments()) {
            const auto* name = std::get_if<std::string>(call.arguments());
            if (!name || name->empty() || name->size() > 4096) {
              result->Error("file_dialog_failed", "Invalid file name");
              return;
            }
            const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                name->data(), static_cast<int>(name->size()), nullptr, 0);
            if (count <= 0 || count > 1024) {
              result->Error("file_dialog_failed", "Invalid file name");
              return;
            }
            suggested.resize(static_cast<size_t>(count));
            if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                name->data(), static_cast<int>(name->size()), suggested.data(), count)) {
              result->Error("file_dialog_failed", "Invalid file name");
              return;
            }
            // A cross-device backup may contain a valid display name that
            // Windows cannot use verbatim. This is only a suggested basename.
            for (auto& character : suggested) {
              if (character < 32 ||
                  std::wstring(L"/\\:*?\"<>|").find(character) != std::wstring::npos) {
                character = L'_';
              }
            }
            if (suggested == L"." || suggested == L"..") suggested = L"attachment";
            if (suggested.back() == L'.' || suggested.back() == L' ') suggested.back() = L'_';
          }
          suggested.copy(path.data(), suggested.size());
        }
        OPENFILENAMEW dialog{};
        dialog.lStructSize = sizeof(dialog);
        dialog.hwndOwner = owner;
        dialog.lpstrFile = path.data();
        dialog.nMaxFile = static_cast<DWORD>(path.size());
        dialog.lpstrFilter = information ? L"All files\0*.*\0\0" : known_hosts ? L"SSH known_hosts file\0*.*\0\0" : credential ? L"Credential file\0*.*\0\0" : recovery ? L"Recovery key (*.txt)\0*.txt\0All files\0*.*\0\0"
                                     : L"Encrypted backup (*.aimbackup)\0*.aimbackup\0All files\0*.*\0\0";
        dialog.lpstrTitle = information_input ? L"Choose information file (up to 10 MiB)"
            : information_output ? L"Save original information file to a new file"
            : known_hosts ? L"Choose trusted SSH known_hosts file (confirm before enabling)" : credential ? L"Choose credential file (1 byte to 1 MiB)" : input ? (recovery ? L"Choose recovery key file" : L"Choose encrypted backup")
                                 : (recovery ? L"Save recovery key separately"
                                             : L"Export encrypted backup to a new file");
        dialog.lpstrDefExt = information || credential || known_hosts ? nullptr : recovery ? L"txt" : L"aimbackup";
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
