import 'dart:math';
import 'package:info_core/info_core.dart' as core;
import 'information_file_messages.dart';
import 'workspace_source.dart';

class OwnerFileSelection {
  const OwnerFileSelection(this.resource, this.draft, this.stage);
  final WorkspaceFileCandidate resource;
  final core.InformationFileDraft draft;
  final core.InformationFileStage stage;
}

abstract interface class OwnerFileSelectionSource {
  OwnerFileSelection selection(String id);
  Future<void> committed(String id);
}

abstract interface class OwnerFileInformation {
  Future<WorkspaceDetail> readDetail(WorkspaceRecordRef record);
}

/// File bytes enter encrypted staging immediately; no source path is retained
/// in the page, selection handle, command or receipt after the panel returns.
class OwnerWorkspaceFileStages implements OwnerFileSelectionSource {
  OwnerWorkspaceFileStages(this.owner) : _scope = owner.captureLibraryScope();
  final core.OwnerAccess owner;
  final core.OwnerLibraryScope _scope;
  final _random = Random.secure();
  final _selected = <String, OwnerFileSelection>{};
  final _releasing = <String>{};
  core.InformationFileDraft? _draft;
  final _cleanup = <core.InformationFileDraft>{};
  bool _closed = false, _choosing = false;
  void checkAvailable() {
    if (_closed) throw const WorkspaceFailure('unavailable', '文件选择已关闭。');
    if (!_scope.isCurrent) {
      throw const WorkspaceFailure('library_changed', '资料库已更换，请重新选择文件。');
    }
    if (!owner.serviceAvailable) {
      throw const WorkspaceFailure('unavailable', '资料服务暂不可用。');
    }
  }

  @override
  OwnerFileSelection selection(String id) {
    checkAvailable();
    final selected = _selected[id];
    if (selected == null ||
        selected.resource.selectionId != id ||
        _releasing.contains(id)) {
      throw const WorkspaceFailure('selection_expired', '文件选择已失效，请重新选择。');
    }
    return selected;
  }

  Future<WorkspaceFileCandidate> stage(
    Future<core.InformationFileStage> Function(core.InformationFileDraft) read,
  ) async {
    checkAvailable();
    if (_choosing) throw const WorkspaceFailure('busy', '请先完成当前文件选择。');
    _choosing = true;
    core.InformationFileDraft? draft;
    try {
      if (_selected.length >= 32) {
        throw const WorkspaceFailure('capacity', '请先完成或取消已有文件表单。');
      }
      draft = _draft ?? await owner.beginInformationFileDraft();
      _draft = draft;
      final stage = await read(draft);
      checkAvailable();
      final resource = WorkspaceFileCandidate(
        List.generate(
          32,
          (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join(),
        stage.originalName,
        stage.mediaType,
        stage.byteLength,
      );
      _selected[resource.selectionId] = OwnerFileSelection(
        resource,
        draft,
        stage,
      );
      draft = null;
      return resource;
    } catch (e) {
      if (e is WorkspaceFailure) rethrow;
      checkAvailable();
      throw WorkspaceFailure(
        e is core.AccessFailure ? e.status : 'selection_failed',
        informationFileError(e),
      );
    } finally {
      _choosing = false;
      if (draft != null && _selected.isEmpty) {
        _draft = null;
        try {
          await owner.releaseInformationFileDraft(draft);
        } catch (_) {
          _cleanup.add(draft);
        }
      }
    }
  }

  Future<void> release(String id) async {
    final selected = _selected[id];
    if (selected == null) return;
    _releasing.add(id);
    try {
      await owner.releaseInformationStage(selected.draft, selected.stage);
      if (_selected.length == 1) {
        await owner.releaseInformationFileDraft(selected.draft);
        _draft = null;
      }
      _selected.remove(id);
      _releasing.remove(id);
    } catch (_) {
      _cleanup.add(selected.draft);
      throw const WorkspaceFailure('cleanup_pending', '临时附件待清理；资料库关闭时会继续清理。');
    }
  }

  @override
  Future<void> committed(String id) async {
    final selected = _selected.remove(id);
    _releasing.remove(id);
    if (selected == null) return;
    if (_selected.isNotEmpty) return;
    _draft = null;
    try {
      await owner.releaseInformationFileDraft(selected.draft);
    } catch (_) {
      _cleanup.add(selected.draft);
    }
  }

  Future<void> dispose() async {
    _closed = true;
    final drafts = {
      ?_draft,
      for (final s in _selected.values) s.draft,
      ..._cleanup,
    };
    _selected.clear();
    _releasing.clear();
    _draft = null;
    _cleanup.clear();
    for (final draft in drafts) {
      try {
        await owner.releaseInformationFileDraft(draft);
      } catch (_) {
        /* Owner shutdown retains staging ownership. */
      }
    }
  }
}
