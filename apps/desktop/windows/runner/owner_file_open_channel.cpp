#include "owner_file_open_channel.h"
#include <shellapi.h>
#include <flutter/standard_method_codec.h>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
std::string Text(const Map& values, const char* key) {
  const auto entry = values.find(Value(key));
  if (entry == values.end()) return {};
  const auto* value = std::get_if<std::string>(&entry->second);
  return value ? *value : std::string();
}
int64_t Length(const Map& values) {
  const auto entry = values.find(Value("byteLength"));
  if (entry == values.end()) return -1;
  if (const auto* value = std::get_if<int32_t>(&entry->second)) return *value;
  if (const auto* value = std::get_if<int64_t>(&entry->second)) return *value;
  return -1;
}
}
OwnerFileOpenChannel::OwnerFileOpenChannel(flutter::BinaryMessenger* messenger, HWND owner)
    : opener_([owner](const std::wstring& path) {
      // Shell acceptance can also mean the user is choosing an application.
      // This is a dispatch receipt, not proof that a reader displayed the file.
      // Retain the copy until explicit finish/exit and never replay the intent.
      SHELLEXECUTEINFOW launch{};
      launch.cbSize = sizeof(launch);
      launch.fMask = SEE_MASK_FLAG_NO_UI | SEE_MASK_NOCLOSEPROCESS | SEE_MASK_ASYNCOK;
      launch.hwnd = owner;
      launch.lpVerb = L"open";
      launch.lpFile = path.c_str();
      launch.nShow = SW_SHOWNORMAL;
      const bool accepted = ShellExecuteExW(&launch) != FALSE;
      if (launch.hProcess) CloseHandle(launch.hProcess);
      return accepted;
    }) {
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(messenger,
      "agent_info_manage/owner_file_open", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const flutter::MethodCall<Value>& call, auto result) {
    const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
    OwnerOpenResult outcome = OwnerOpenResult::conflict;
    if (call.method_name() == "status" && args && args->size() == 2) {
      outcome = opener_.Status(Text(*args, "operationId"), Text(*args, "commandDigest"));
    } else if (call.method_name() == "open" && args && args->size() == 8) {
      outcome = opener_.Open({Text(*args, "operationId"), Text(*args, "commandDigest"),
        Text(*args, "path"), Text(*args, "directoryIdentity"), Text(*args, "name"),
        Text(*args, "fileIdentity"), Text(*args, "sha256"), Length(*args)});
    } else if (call.method_name() != "open" && call.method_name() != "status") {
      result->NotImplemented(); return;
    }
    switch (outcome) {
      case OwnerOpenResult::missing: result->Success(); break;
      case OwnerOpenResult::pending: result->Success(Value("pending")); break;
      case OwnerOpenResult::opened: result->Success(Value("opened")); break;
      case OwnerOpenResult::not_opened: result->Success(Value("notOpened")); break;
      case OwnerOpenResult::conflict: result->Error("file_open_unavailable", "File open outcome unavailable"); break;
    }
  });
}

OwnerFileOpenChannel::~OwnerFileOpenChannel() {
  channel_->SetMethodCallHandler(nullptr);
}
