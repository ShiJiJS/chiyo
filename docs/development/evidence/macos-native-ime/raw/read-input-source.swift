import Foundation
import Carbon
if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
   let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
  print(Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String)
} else { exit(1) }
