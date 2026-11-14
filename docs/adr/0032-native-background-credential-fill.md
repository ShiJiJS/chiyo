# 原生后台填写固定 helper 持有的控件引用

支持资格已由 [ADR0033](0033-native-fill-by-control-capability.md) 修订：按实际控件能力开放，应用与版本不需要预先登记。以下首轮范围保留为历史；固定原对象与批准的决策继续有效。

2026-11-14，[#144](https://github.com/ShiJiJS/chiyo/issues/144)：用户要求在不抢前台、不改变焦点的情况下向经验证的原生密码控件填写凭据。新增独立的原生后台填写方式，由原设备可信 helper 持有进程代际、窗口及具体控件引用，直接调用原生 setter；不从名称、位置、公开句柄或旧焦点许可恢复目标。这样可以准确限定选中的存活对象，但不能承诺原生检查与外部 App 业务身份之间的通用原子保证。

本决定扩展 [ADR0012](0012-local-focused-credential-fill.md) 和 [ADR0031](0031-device-credential-delivery-and-reveal.md)，保留已有焦点填写的历史范围。首轮仅包括 Mac 标准 AppKit 密码控件及 Windows Win32/WinForms/WPF 密码控件；浏览器继续使用专用表单适配，内嵌网页、WK 和 Electron 不支持。沿用多凭据批准、持久操作、防重放与原设备材料交付，不建立另一套授权系统；失效或结果未知时拒绝后续写入，不回退到键盘、剪贴板、焦点方式或原文读取。实施合同见 [原生后台填写合同](../design/native-background-fill-contract.md)。
