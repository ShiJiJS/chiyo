# macOS 凭据执行使用独立 POSIX 会话及内核身份核查

2026-10-20：Mac 适配沿用 ADR0009/0010 的持续宿主、先登记后启动和逐操作防重放；worker 在放行前建立独立 POSIX 会话/进程组，以 PID 和内核启动时间核对身份，目标暂停装载、登记后恢复，并通过 kqueue 保留退出结果。Darwin 没有 Windows Job 的同等边界，采用这一机制以支持本机已验证接收程序，而不引入常驻特权服务；主动脱离进程组的程序不在其跟踪保证内，任意同用户程序的强隔离仍不属于 ADR0002/0008 的承诺。

文件材料与受管附件副本采用本用户独占的目录/文件、描述符相对操作及原路径身份核查；Mac 的释放表示登记路径已移除，已打开的文件描述符仍可能继续读取原内容。它不能被解释为已读取内容被收回，也不能沿用 Windows 文件占用时必然保留路径的判断；平台验证与交付状态记录在 [Mac 适配记录](https://github.com/ShiJiJS/chiyo/blob/46ff2a9ba5bda130c88f9aac9beef72eb586e781/docs/development/macos-runtime-adaptation.md)。
