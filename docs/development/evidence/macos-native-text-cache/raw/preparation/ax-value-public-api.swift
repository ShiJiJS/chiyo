import Cocoa
_ = NSApplication.shared
let field = NSTextField(frame: NSRect(x: 0,y:0,width:200,height:30))
field.stringValue = "SyntheticNative"
let before = field.stringValue
let overrideAccepted = field.accessibilitySetOverrideValue("SyntheticAX", forAttribute: .value)
let result: [String: Any] = ["overrideAccepted":overrideAccepted,"nativeBefore":before,"nativeAfter":field.stringValue,"axAfter":field.accessibilityValue() ?? NSNull()]
let bytes = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(data:bytes, encoding:.utf8)!)
