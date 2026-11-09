import 'dart:io';
import 'package:info_workspace/owner_workspace_template_packages.dart';
import '../information_files.dart';
import 'owner_plugin_picker.dart';
import 'template_package_decoder.dart';
import 'workspace_source.dart';

/// Local selection belongs to the desktop. Validation, preview and mutation
/// use the same pure Dart adapter as the online server.
class OwnerWorkspacePlugins extends OwnerWorkspaceTemplatePackages {
  OwnerWorkspacePlugins({
    required super.owner,
    required super.changed,
    this.picker = const NativeTemplatePackagePicker(),
  });
  final InformationFilePicker picker;

  Future<WorkspacePluginCandidate?> pick() async {
    await load();
    final input = await readTemplatePackage(picker);
    if (input == null) return null;
    return stageBytes(input.filename, input.bytes);
  }
}

/// Used by both desktop composition roots. Paths never enter workspace DTOs
/// or server state; only the selected declarative JSON is transmitted.
Future<({String filename, List<int> bytes})?> readTemplatePackage(
  InformationFilePicker picker,
) async {
  final path = await picker.choose();
  if (path == null) return null;
  if (await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const WorkspaceFailure('invalid_package', '请选择实际的 JSON 插件文件。');
  }
  final bytes = await File(path)
      .openRead(0, TemplatePackageDecoder.maxBytes + 1)
      .fold<List<int>>([], (a, b) => a..addAll(b));
  if (bytes.length > TemplatePackageDecoder.maxBytes) {
    throw const WorkspaceFailure('invalid_package', '插件包不能超过1 MiB。');
  }
  return (filename: File(path).uri.pathSegments.last, bytes: bytes);
}
