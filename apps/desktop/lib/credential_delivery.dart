import 'package:info_core/info_core.dart';

String credentialInjectionTarget(CredentialUseRequest r) =>
    switch (r.plan.receiver) {
      'ssh_identity' => '-i {file:${r.alias}}',
      'aws_shared_credentials' => 'AWS_SHARED_CREDENTIALS_FILE',
      _ => 'GH_TOKEN',
    };
String credentialInjectionValue(CredentialUseRequest r) =>
    r.plan.receiver == 'gh_token' ? '真实 Token（不展示原文）' : 'CLI 生成的临时文件路径';
String credentialInjectionFact(CredentialUseRequest r) =>
    '${credentialInjectionTarget(r)} ← ${r.plan.receiver == 'gh_token' ? '{secret:${r.alias}}' : '受限临时文件'}';
String credentialInjectionTip(
  CredentialUseRequest r,
) => switch (r.plan.receiver) {
  'ssh_identity' =>
    'CLI 将私钥写入受限临时文件，-i 接收完整路径。主机记录来自本次批准的确认快照，使用独立空配置；拒绝未知或变化的主机，不读取原有 SSH 配置或 agent。进程组结束后核对身份并尝试清理，清理失败可单独重试。',
  'aws_shared_credentials' =>
    '环境变量装的是文件路径。CLI 创建受限凭据副本和独立空配置，程序从 AWS_SHARED_CREDENTIALS_FILE 读取静态 default 凭据；不使用当前账号配置或实例 metadata。进程组结束后核对身份并尝试清理，清理失败可单独重试。',
  _ => '环境变量装的是秘密值。CLI 创建目标进程时设置变量，程序自己读取；不修改全局环境变量，也不生成凭据文件。',
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
  CredentialUseRequest r,
) => switch (r.plan.receiver) {
  'ssh_identity' =>
    '严格校验主机 · 仅所选私钥 · 禁用 agent、密码和交互回退\n主机快照 ${r.plan.sshTrustSnapshotId}\n${r.plan.internalMaterialHashes['ssh_known_hosts']}',
  'aws_shared_credentials' =>
    '静态 default 凭据 · 独立空 AWS_CONFIG_FILE · 禁用 metadata、pager 和自动提示',
  _ => '仅本次子进程环境 · 独立 GitHub 配置 · 禁止交互登录',
};
