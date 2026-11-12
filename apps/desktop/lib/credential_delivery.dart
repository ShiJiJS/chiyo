import 'package:info_core/info_core.dart';

String credentialInjectionTarget(CredentialUseRequest r) => r.isReveal
    ? '当前 AI 聊天'
    : r.isFocusedFill
    ? '本机前台密码框'
    : switch (r.plan.receiver) {
        'ssh_identity' => '-i {file:${r.alias}}',
        'aws_shared_credentials' => 'AWS_SHARED_CREDENTIALS_FILE',
        'program_stdin' => '程序标准输入',
        'program_env' =>
          r.plan.env.entries
              .where((entry) => entry.value.kind == LaunchValueKind.secret)
              .map((entry) => entry.key)
              .join('、'),
        'program_file' => '程序参数或环境变量中的文件路径',
        _ => 'GH_TOKEN',
      };
String credentialInjectionValue(CredentialUseRequest r) => r.isReveal
    ? '凭据原文会进入聊天'
    : r.isFocusedFill
    ? '本机宿主直接输入（不展示原文）'
    : !r.plan.requiresMaterialFiles
    ? '凭据原文（不在普通输出中展示）'
    : 'CLI 生成的临时文件路径';
String credentialCommandTarget(CredentialUseRequest r) {
  if (r.isReveal) return r.revealReason ?? '';
  if (r.isFocusedFill) return r.focusedFill!.targetHint;
  final args = (r.requestedPlan ?? r.plan).argv
      .where((a) => a.kind == LaunchValueKind.literal)
      .map((a) => a.value)
      .toList();
  if (r.plan.isProgramReceiver) {
    return '${r.plan.path} · ${args.join(' ')}';
  }
  if (r.plan.receiver == 'ssh_identity') {
    final target = args
        .where((a) => RegExp(r'^[^\s@]+@[^\s@]+$').hasMatch(a))
        .firstOrNull;
    final p = args.indexOf('-p');
    return target == null
        ? '见下方固定命令'
        : '$target${p >= 0 && p + 1 < args.length ? ' · ${args[p + 1]}' : ''}';
  }
  return '${r.plan.receiver == 'gh_token' ? 'GitHub' : 'AWS'} · ${args.take(r.plan.receiver == 'gh_token' ? 3 : 2).join(' ')}';
}

String credentialInjectionFact(CredentialUseRequest r) => r.isReveal
    ? '单独批准后向本次 AI 聊天提供原文'
    : r.isFocusedFill
    ? '本机宿主 → 获批应用的前台密码框'
    : '${credentialInjectionTarget(r)} ← ${r.plan.requiresMaterialFiles ? '受限临时文件' : '所选凭据'}';
String credentialInjectionTip(CredentialUseRequest r) => r.isReveal
    ? '这是读取原文申请，批准后密码会进入 AI 聊天。'
    : r.isFocusedFill
    ? '批准后由 Agent 重新点击密码框，再后台调用 CLI；宿主核验应用和焦点后输入，不自动提交登录。'
    : switch (r.plan.receiver) {
        'program_stdin' => '凭据通过私有管道交给获批程序，不作为命令参数；发送后关闭输入，不自动添加换行。',
        'program_env' => '凭据只放进获批程序的指定环境变量，不修改系统环境变量。',
        'program_file' => '创建权限受限的临时凭据文件，将路径交给获批程序；任务结束后清理。',
        'ssh_identity' =>
          'CLI 将私钥写入受限临时文件，-i 接收完整路径。首版连接 Linux / Unix 主机，执行一次非交互命令。主机记录来自本次批准的确认快照，使用独立空配置；拒绝未知或变化的主机，不读取原有 SSH 配置或 agent。进程组结束后核对身份并尝试清理，清理失败可单独重试。',
        'aws_shared_credentials' =>
          '环境变量装的是文件路径。CLI 创建受限凭据副本和独立空配置，程序从 AWS_SHARED_CREDENTIALS_FILE 读取静态 default 凭据；不使用当前账号配置或实例 metadata。进程组结束后核对身份并尝试清理，清理失败可单独重试。',
        _ => '环境变量装的是凭据值。CLI 创建目标进程时设置变量，程序自己读取；不修改全局环境变量，也不生成凭据文件。',
      };
String launchValueLabel(LaunchValue value) => switch (value.kind) {
  LaunchValueKind.literal => value.value,
  LaunchValueKind.file => '{{file:${value.value}}}',
  LaunchValueKind.secret => '{secret:${value.value}}',
  LaunchValueKind.internalMaterial => switch (value.value) {
    'ssh_config' => '{临时空SSH配置}',
    'ssh_user_hosts_option' => 'UserKnownHostsFile={确认主机快照}',
    'ssh_global_hosts_option' => 'GlobalKnownHostsFile={临时空主机记录}',
    'aws_config' => '{临时空AWS配置}',
    _ => '{内部材料:${value.value}}',
  },
};
String credentialIsolationFacts(
  CredentialUseRequest r, {
  CredentialLaunchPlan? plan,
}) => r.isReveal
    ? '仅限本次聊天和获批的凭据版本；使用许可不包含原文读取许可。'
    : r.isFocusedFill
    ? '固定应用及凭据版本；每次核验当前前台密码框；申报网址未核验。'
    : switch ((plan ?? r.plan).receiver) {
        'program_stdin' ||
        'program_env' ||
        'program_file' => '固定获批程序及凭据接收位置；普通命令输出会遮住凭据。',
        'ssh_identity' =>
          '严格校验主机 · 仅所选私钥 · 禁用 agent、密码和交互回退\n主机快照 ${(plan ?? r.plan).sshTrustSnapshotId}\n${(plan ?? r.plan).internalMaterialHashes['ssh_known_hosts']}',
        'aws_shared_credentials' =>
          '静态 default 凭据 · 独立空 AWS_CONFIG_FILE · 禁用 metadata、pager 和自动提示',
        _ => '仅本次子进程环境 · 独立 GitHub 配置 · 禁止交互登录',
      };
