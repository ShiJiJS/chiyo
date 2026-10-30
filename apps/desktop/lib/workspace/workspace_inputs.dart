import 'workspace_source.dart';

/// Optional host input adapters. Unconnected inputs never offer fixed examples.
class WorkspaceInputs {
  const WorkspaceInputs({
    this.file,
    this.credential,
    this.plugin,
    this.hostFile,
    this.backup,
  });
  final WorkspaceFilePicker? file;
  final WorkspaceCredentialPicker? credential;
  final WorkspacePluginPicker? plugin;
  final WorkspaceHostFilePicker? hostFile;
  final WorkspaceBackupPicker? backup;
}

Future<WorkspaceBackupResource?> unavailableBackupInput(
  WorkspaceBackupPick _,
) async =>
    throw const WorkspaceFailure('unsupported', '本机备份文件服务尚未接入，没有读取或写入文件。');

Future<WorkspaceHostFile?> unavailableHostFileInput() async =>
    throw const WorkspaceFailure('unsupported', '本机主机记录文件选择尚未接入，没有导入文件。');

Future<WorkspacePluginCandidate?> unavailablePluginInput() async =>
    throw const WorkspaceFailure('unsupported', '本机插件文件选择尚未接入。');
