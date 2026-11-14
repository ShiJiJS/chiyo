import Foundation

/// Protocol capability, not an application/OS/language compatibility registry.
/// Tested applications belong in evidence records and never enable this path.
enum MacNativeBackgroundCapability {
  static let controlKind = "macos_ax_password"

  static func label(_ description: String, identifier: String = "") throws -> String {
    let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !(text + identifier).unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
          identifier.utf16.count <= 128 else { throw MacNativeBackgroundFailure.unsupportedTarget }
    let suffix = identifier.isEmpty ? "" : " [" + identifier + "]"
    let result = limit(text, units: 256 - suffix.utf16.count) + suffix
    guard !result.isEmpty else { throw MacNativeBackgroundFailure.unsupportedTarget }
    return result
  }
  static func limit(_ text: String, units: Int) -> String {
    var result = "", count = 0
    for character in text {
      let size = String(character).utf16.count
      if count + size > units { break }
      result.append(character); count += size
    }
    return result
  }
}
