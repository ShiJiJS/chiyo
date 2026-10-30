import 'dart:io';
import 'dart:math';
import 'package:info_core/info_core.dart'
    show OwnerAccess, OwnerLibraryScope, OwnerInbox;
import '../backups.dart';
import 'workspace_source.dart';

/// Owner-only file selection registry for one library binding. Paths never
/// enter page resources, commands, receipts or Agent responses. Selection is
/// not authentication of a backup and does not write or restore anything.
class OwnerWorkspaceBackupFiles {
  OwnerWorkspaceBackupFiles({
    required OwnerAccess owner,
    BackupFilePicker picker = const NativeBackupFilePicker(),
  }) : _owner = owner,
       _scope = owner.captureLibraryScope(),
       _picker = picker;

  final OwnerAccess _owner;
  final OwnerLibraryScope _scope;
  final BackupFilePicker _picker;
  final _random = Random.secure();
  final _selected =
      <
        WorkspaceBackupPick,
        ({WorkspaceBackupResource resource, String path})
      >{};
  bool _closed = false, _choosing = false;

  void _checkCurrent() {
    if (_closed) {
      throw const WorkspaceFailure('unavailable', '此备份窗口已关闭，请重新打开。');
    }
    if (!_scope.isCurrent) {
      _selected.clear();
      throw const WorkspaceFailure('library_changed', '资料库已更换，请重新选择备份文件。');
    }
    if (!_owner.serviceAvailable) {
      throw const WorkspaceFailure('unavailable', '信息库暂时不可用，请稍后重试。');
    }
  }

  Future<WorkspaceBackupResource?> pick(WorkspaceBackupPick kind) async {
    _checkCurrent();
    if (_choosing) {
      throw const WorkspaceFailure('busy', '请先完成当前文件选择。');
    }
    _choosing = true;
    try {
      String? selected;
      try {
        selected = await switch (kind) {
          WorkspaceBackupPick.keyOutput => _picker.recoveryKeyOutput(),
          WorkspaceBackupPick.archiveOutput => _picker.backupOutput(),
          WorkspaceBackupPick.archiveInput => _picker.backupInput(),
          WorkspaceBackupPick.keyInput => _picker.recoveryKeyInput(),
        };
      } on Object {
        // Native failures may contain private paths. Keep them out of UI errors.
        _checkCurrent();
        throw const WorkspaceFailure('selection_failed', '文件选择未完成，请重新选择。');
      }
      _checkCurrent(); // A restore/close may have completed while the panel was open.
      if (selected == null) return null;
      if (selected.isEmpty ||
          selected.contains('\u0000') ||
          !File(selected).isAbsolute) {
        throw const WorkspaceFailure('invalid_selection', '文件选择无法确认，请重新选择。');
      }
      final name = File(selected).uri.pathSegments.lastOrNull;
      if (name == null ||
          name.isEmpty ||
          name.length > 4000 ||
          name == '.' ||
          name == '..') {
        throw const WorkspaceFailure('invalid_selection', '文件名称无法确认，请重新选择。');
      }
      final resource = WorkspaceBackupResource(
        id: List.generate(
          32,
          (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join(),
        name: name,
        kind: kind,
      );
      // At most one current selection of each kind; cancel/failure keeps the
      // previous selection. Reselecting invalidates old previews by identity.
      _selected[kind] = (resource: resource, path: selected);
      return resource;
    } finally {
      _choosing = false;
    }
  }

  /// Only the backup source may resolve a handle. It must still authenticate
  /// input contents and use the production no-overwrite publisher for outputs.
  String pathFor(
    WorkspaceBackupResource resource, {
    required WorkspaceBackupPick kind,
  }) {
    _checkCurrent();
    final selected = _selected[kind];
    if (resource.kind != kind ||
        selected == null ||
        !selected.resource.same(resource)) {
      throw const WorkspaceFailure('invalid_selection', '文件选择已变化，请重新选择并检查。');
    }
    return selected.path;
  }

  void dispose() {
    _closed = true;
    _selected.clear();
  }
}
