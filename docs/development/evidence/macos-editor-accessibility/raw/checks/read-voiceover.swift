import AppKit
import Foundation
let state: [String: Any] = ["voiceOverEnabled": NSWorkspace.shared.isVoiceOverEnabled]
let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
