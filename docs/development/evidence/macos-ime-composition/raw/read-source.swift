import Foundation
import Carbon
func metadata(_ source: TISInputSource?) -> [String:String] {
  guard let source else { return [:] }
  var result: [String:String] = [:]
  for (name,key) in [("id",kTISPropertyInputSourceID),("name",kTISPropertyLocalizedName),("mode",kTISPropertyInputModeID)] {
    if let pointer=TISGetInputSourceProperty(source,key) {
      result[name]=Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
  }
  return result
}
let result=["selected":metadata(TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()),"layout":metadata(TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue())]
let data=try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys])
print(String(data:data,encoding:.utf8)!)
