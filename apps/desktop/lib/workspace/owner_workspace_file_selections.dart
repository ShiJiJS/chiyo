import 'package:info_core/info_core.dart';
import 'package:info_workspace/owner_file_stages.dart';
import '../information_files.dart';
import 'workspace_source.dart';
export 'package:info_workspace/owner_file_stages.dart';

/// The native picker stays on this device; lifecycle and staging are shared.
class OwnerWorkspaceFileSelections extends OwnerWorkspaceFileStages {
  OwnerWorkspaceFileSelections(
    super.owner, {
    this.picker = const NativeInformationFilePicker(),
  });
  final InformationFilePicker picker;
  bool _picking = false;
  Future<WorkspaceFileCandidate?> pick() async {
    checkAvailable();
    if (_picking) {
      throw const WorkspaceFailure('busy', '请先完成当前文件选择。');
    }
    _picking = true;
    try {
      final path = await picker.choose();
      checkAvailable();
      if (path == null) return null;
      return await stage(
        (draft) => owner.stageInformationFile(
          draft,
          path,
          mediaType: informationFileMediaType(path),
        ),
      );
    } finally {
      _picking = false;
    }
  }
}
