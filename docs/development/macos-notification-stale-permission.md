# 系统关闭通知后的旧允许缓存修正（#47）

2026-10-22，原生修正 `438df68c5151b8b431240d5b342e5cd3d9a38c8b`，
最终产品含重试修正 `7b19d34b61cf07d5a77db05adb8f0c9cdbf85805`，只在 Mac 分支。
系统设置关闭本应用通知后，旧实现仍依据启动时的允许缓存调用 UN add；本机实测
系统仍返回 accepted=true，没有 UN 错误，因此不能用返回值推断通知允许或实际显示。
新实现投递前重新查询系统许可，拒绝时不提交；Dart 在返回不可投递后重新读取状态，
显示具体的系统拒绝／未开启，而不是统一改成一般不可用。

## 基线与修正后的实机对照

沿用已允许的“Mac 通知合成验收”身份，仅合成 SQLCipher 库和内存密钥。
两轮都由 CUA 把这一个应用的系统通知 on→off→on，没有更改其他应用、专注模式
或全局共享屏幕偏好，没有密码或新通知许可提示。请求 gate 只协调新增合成请求，
不注入原生回调、状态或投递结果。

- 基线 QA `ecbf757`、PID78162：系统开关实际 off、应用仍缓存 enabled 时，
  新增请求触发一次 UN add。原生 submit/accepted 的 UUID、请求 ID 相同，accepted=true、
  errorCode=0、errorDomain为空。新请求可见、26条待处理；这不是投递错误。
  原假设断言失败，驱动 complete=false/退出1保留；恢复系统设置后实际 ⌘Q，
  应用正常退出0、库关闭一次、Flutter异常0、端口关闭，无强杀。
- 修正 `438df68`、PID79527：相同真实设置动作和旧缓存前提下，生产 native notify
  调用一次，内部新查询 authorization=1，UN add调用0，桥接返回false。
  生产 runtime再读真实状态，自动显示拒绝通知的提示；在点任何检查按钮前，设置页
  也已显示“系统已拒绝通知权限”。原请求仍 pending。
- 随后实际检查拒绝状态、再新增一条拒绝期间请求，待处理27／已处理0，无额外调用。
  系统允许恢复后，实际检查按钮显示 enabled，没有补发、没有批准请求。
  实际 ⌘Q退出0、库关闭一次、Flutter异常0、端口关闭；驱动 complete=true。

计数分清：最终 `submissions=1` 是 QA 记录的 DesktopPlatform.notifyNewRequest 调用，
不是 UN add。原生被动日志只有 settings，authorization序列2,2,1,1,1,2；没有
submit/accepted/willPresent/didReceive/open。两次显式检查调用权限API，新增系统决定0。
两轮各9项准备／严格分析／Release／签名检查退出0；构建输入及QA差异逐项核对。

## 实现与自动回归

原生普通／测试通知共同复查系统许可，查询返回时也要求desktopReady，避免终止后
迟到回调继续提交。许可为enabled仍只表示可以提交，不承诺横幅显示或点击。
Dart拒绝结果复查只读availability，不调用权限申请；许可仍enabled但投递失败时继续
显示unavailable，状态读取也失败时同样保持错误。退出中的迟到结果不再更新状态。

新增两条状态变化回归在旧逻辑上失败：denied/notEnabled都被误显示unavailable。
修正后相关runtime共13项通过，另覆盖测试通知的拒绝状态刷新；严格分析通过。
这些fixture测试与原生实机分开，不冒充真实UN错误。整包首次源码检查又发现测试通知
失败后重试按钮被禁用，package22在检查阶段失败，258通过／2跳过／1失败，没有ZIP。
最终 `7b19d34` 区分自动请求失败和手动测试：系统仍允许时，测试按钮可直接重试；
真正拒绝则显示拒绝。既有导航回归与runtime共15项通过，不放宽原重试断言。
该变化没有改原生预检查或已实测的普通新请求拒绝路径。

## 最终候选 package23

准确干净源码 `7b19d34b61cf07d5a77db05adb8f0c9cdbf85805`，版本
`0.4.1+13-mac-dev.7b19d34b61cf`。stock `--check` 全部四包严格分析及测试通过：
Core290/6、CLI75/40、Storage160/18、Desktop259/2（通过／条件跳过），合计784/66；
21个构建／提取阶段退出0。跳过不算通过，package22的失败不混入成功计数。

ZIP在 `build/macos-adaptation/issue50-package-23/`，130967495字节，SHA256
`35618d464b4be2f369efb7bde3be910dd40cbd2328e67efcb44841f29147fbdf`。
两份完整解包的7971项文件／权限／链接与清单一致，75项Mach-O；准确包内桌面摘要
`b778a781b736eb52bcb286fe1614cfbe129e6b004b2b8266a44d6a0da432678c`。
ARM64／最低二进制系统14.0／本机ad-hoc未公证，实测宿主27.0.1；不称14.0、Intel、
干净用户或其他机器Gatekeeper已验。原生预检查下允许侧的额外实际投递、最终普通
Keychain换包及同包闭环继续待验，固定4690e79普通预览没有替换。

[原始分轮结果、源码、日志与摘要](evidence/macos-notification-stale-permission/verification.json)。
CUA界面事实为会话原始AX／截图及明确转录，未另存图片。临时App/dSYM/缓存、
合成库和源码副本均清理。基线那个准确UUID／请求由同身份无授权请求helper查询，
before0/after0，不声称实际删除过一条；helper未提交通知或注入点击，结束后也已删除。
两份整包解包、诊断程序和根构建缓存另清理约1908.8MiB，ZIP保留；固定预览7971项、
strict签名和原PID53592、资料与恢复备份均保持，build/local只留一份固定App、生成dSYM为0。

#47仍OPEN、1/5，原条件保持。这个修正补系统设置变化后的真实状态，不能当作真实
UN投递错误、完整前台／后台点击或全部通知类型通过；Windows/main/CI未操作。

拒绝侧复跑（全新输出目录）：

```sh
python3 scripts/qa/macos-notifications-ui.py build/macos-adaptation/NEW-stale-permission \
  --reuse-permission --permission-settings --stale-permission
```
