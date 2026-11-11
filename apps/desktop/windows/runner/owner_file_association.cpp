#include "owner_file_association.h"
#include <windows.h>
#include <shlwapi.h>
#include <vector>

bool HasDefaultOwnerFileHandler(const std::wstring& path) {
  const auto* extension = PathFindExtensionW(path.c_str());
  if (!extension || *extension != L'.' || extension[1] == L'\0') return false;
  DWORD length = 0;
  // Otherwise Windows resolves an unregistered extension to its generic
  // "Unknown"/OpenWith handler, which is not a document application.
  const HRESULT measured = AssocQueryStringW(
      ASSOCF_INIT_IGNOREUNKNOWN, ASSOCSTR_PROGID, extension, nullptr, nullptr, &length);
  if ((FAILED(measured) && measured != E_POINTER) || length < 2) return false;
  std::vector<wchar_t> program(length);
  return SUCCEEDED(AssocQueryStringW(ASSOCF_INIT_IGNOREUNKNOWN, ASSOCSTR_PROGID, extension,
      nullptr, program.data(), &length)) && program[0] != L'\0';
}
