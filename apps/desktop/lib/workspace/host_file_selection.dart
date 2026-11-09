import 'dart:io';
import 'package:info_core/info_core.dart' as core;
import '../information_files.dart';
import 'workspace_source.dart';

class SelectedHostFile {
  SelectedHostFile(this.name, List<int> bytes)
    : bytes = List.unmodifiable(bytes);
  final String name;
  final List<int> bytes;
}

/// Read only the explicitly selected public known_hosts file. A stable bounded
/// read and original format validation precede either local or remote staging.
Future<SelectedHostFile?> selectHostFile(InformationFilePicker picker) async {
  final path = await picker.choose();
  if (path == null) return null;
  final file = File(path);
  final before = await file.stat();
  if (before.type != FileSystemEntityType.file ||
      before.size < 1 ||
      before.size > 1048576) {
    throw const WorkspaceFailure(
      'invalid_file',
      '请选择不超过1MB的 known_hosts 普通文件。',
    );
  }
  final bytes = <int>[];
  await for (final chunk in file.openRead()) {
    if (bytes.length + chunk.length > 1048576) {
      throw const WorkspaceFailure('invalid_file', '文件超过1MB。');
    }
    bytes.addAll(chunk);
  }
  final after = await file.stat();
  if (before.size != after.size ||
      before.modified != after.modified ||
      bytes.length != before.size) {
    throw const WorkspaceFailure('conflict', '读取期间文件已变化，请重新选择。');
  }
  final name = file.uri.pathSegments.last;
  try {
    core.validateSshKnownHosts(name, bytes);
  } on core.AccessFailure {
    throw const WorkspaceFailure('invalid_file', '文件不是有效的 known_hosts 主机记录。');
  }
  return SelectedHostFile(name, bytes);
}
