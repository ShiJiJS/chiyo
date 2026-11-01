import 'dart:math';
import 'package:info_core/info_core.dart' as core;
import '../information_files.dart';
import 'workspace_source.dart';

class OwnerFileSelection {
  const OwnerFileSelection(this.resource, this.draft, this.stage);
  final WorkspaceFileCandidate resource;
  final core.InformationFileDraft draft;
  final core.InformationFileStage stage;
}

/// File bytes enter encrypted staging immediately; no source path is retained
/// in the page, selection handle, command or receipt after the panel returns.
class OwnerWorkspaceFileSelections {
  OwnerWorkspaceFileSelections(
    this.owner, {
    this.picker = const NativeInformationFilePicker(),
  }) : _scope = owner.captureLibraryScope();
  final core.OwnerAccess owner;
  final InformationFilePicker picker;
  final core.OwnerLibraryScope _scope;
  final _random = Random.secure();
  OwnerFileSelection? _current;
  final _cleanup = <core.InformationFileDraft>[];
  bool _closed = false, _choosing = false;
  void _check() {
    if (_closed) throw const WorkspaceFailure('unavailable', '文件选择已关闭。');
    if (!_scope.isCurrent) {
      throw const WorkspaceFailure('library_changed', '资料库已更换，请重新选择文件。');
    }
    if (!owner.serviceAvailable) {
      throw const WorkspaceFailure('unavailable', '资料服务暂不可用。');
    }
  }

  OwnerFileSelection selection(String id) {
    _check();
    final selected = _current;
    if (selected == null || selected.resource.selectionId != id) {
      throw const WorkspaceFailure('selection_expired', '文件选择已失效，请重新选择。');
    }
    return selected;
  }

  Future<WorkspaceFileCandidate?> pick() async {
    _check();
    if (_choosing) throw const WorkspaceFailure('busy', '请先完成当前文件选择。');
    _choosing = true;
    core.InformationFileDraft? draft;
    try {
      final path = await picker.choose();
      _check();
      if (path == null) return null;
      draft = await owner.beginInformationFileDraft();
      final stage = await owner.stageInformationFile(
        draft,
        path,
        mediaType: informationFileMediaType(path),
      );
      _check();
      if (_current != null) {
        await owner.releaseInformationFileDraft(_current!.draft);
      }
      _check();
      final resource = WorkspaceFileCandidate(
        List.generate(
          32,
          (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join(),
        stage.originalName,
        stage.mediaType,
        stage.byteLength,
      );
      _current = OwnerFileSelection(resource, draft, stage);
      draft = null;
      return resource;
    } catch (e) {
      if (e is WorkspaceFailure) rethrow;
      _check();
      throw WorkspaceFailure(
        e is core.AccessFailure ? e.status : 'selection_failed',
        informationFileError(e),
      );
    } finally {
      _choosing = false;
      if (draft != null) {
        try {
          await owner.releaseInformationFileDraft(draft);
        } catch (_) {
          _cleanup.add(draft);
        }
      }
    }
  }

  Future<void> release(String id) async {
    if (_current?.resource.selectionId != id) return;
    final draft = _current!.draft;
    _current = null;
    try {
      await owner.releaseInformationFileDraft(draft);
    } catch (_) {
      _cleanup.add(draft);
      throw const WorkspaceFailure(
        'cleanup_pending',
        '文件未入库，临时资源仍待清理；关闭资料库时会继续清理。',
      );
    }
  }

  Future<void> committed(String id) async {
    if (_current?.resource.selectionId != id) return;
    final draft = _current!.draft;
    _current = null;
    try {
      await owner.releaseInformationFileDraft(draft);
    } catch (_) {
      _cleanup.add(draft);
    }
  }

  Future<void> dispose() async {
    _closed = true;
    final drafts = [if (_current != null) _current!.draft, ..._cleanup];
    _current = null;
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
