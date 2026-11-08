import 'package:info_core/info_core.dart' as core;
import 'workspace_records.dart';

WorkspaceType ownerCredentialType(core.ManagedCredential credential) {
  final snapshot = credential.template?.snapshot;
  final type = snapshot?['type'] as Map?;
  final config = (snapshot?['definition'] as Map?)?['credential'] as Map?;
  final name = switch (config?['secretKind']) {
    'accountPassword' => '账号密码',
    'token' => 'API Key / Token',
    'file' => '凭据文件',
    _ => '凭据',
  };
  return WorkspaceType(
    credential.template?.typeId ?? 'credential',
    type?['name'] as String? ?? name,
    'key',
  );
}
