import 'dart:convert';
import 'package:info_core/info_core.dart' as core;
import '../information_files.dart';
import 'owner_workspace_information.dart';
import 'owner_workspace_file_selections.dart';
import 'builtin_workspace_definitions.dart';
import 'workspace_source.dart';

class OwnerWorkspaceFileChanges {
  OwnerWorkspaceFileChanges(
    this.owner,
    this.information,
    this.selections,
    this.onChanged,
  );
  final core.OwnerAccess owner;
  final OwnerWorkspaceInformation information;
  final OwnerWorkspaceFileSelections selections;
  final void Function(WorkspaceRecordRef) onChanged;
  WorkspaceFileOperationReceipt _receipt(core.InformationRecordReceipt r) {
    final file = r.file;
    if (file == null) {
      throw const WorkspaceFailure('operation_conflict', '此编号不属于文件写入操作。');
    }
    return WorkspaceFileOperationReceipt(
      WorkspaceRecordRef(WorkspaceRecordKind.information, r.itemId),
      WorkspaceFileRef(
        file.reference.attachmentId,
        file.reference.attachmentVersion,
      ),
      commandDigest: file.command.digest,
    );
  }

  Future<WorkspaceFileOperationReceipt?> receipt(String id) async {
    try {
      final r = await owner.informationRecordReceipt(id);
      final lifecycle = await owner.informationLifecycleReceipt(id);
      if (r != null && lifecycle != null) {
        throw const WorkspaceFailure(
          'unknown_outcome',
          '原操作编号对应多种记录，无法确认文件结果。',
        );
      }
      if (lifecycle != null) {
        throw const WorkspaceFailure('operation_conflict', '此编号已用于其他资料操作。');
      }
      return r == null ? null : _receipt(r);
    } catch (e) {
      throw _failure(e, unknown: true);
    }
  }

  Future<WorkspaceFileOperationReceipt?> _previous(
    String id,
    String digest,
  ) async {
    final result = await receipt(id);
    if (result != null && result.commandDigest != digest) {
      throw const WorkspaceFailure('operation_conflict', '同一次操作不能用于不同文件或内容。');
    }
    return result;
  }

  WorkspaceFailure _failure(Object e, {bool unknown = false}) {
    if (e is WorkspaceFailure) return e;
    final code = e is core.AccessFailure ? e.status : '';
    return switch (code) {
      'version_conflict' => const WorkspaceFailure(
        'conflict',
        '资料或文件版本已变化，请重新核对。',
      ),
      'operation_conflict' => const WorkspaceFailure(
        'operation_conflict',
        '同一次操作不能用于不同内容。',
      ),
      'library_changed' => const WorkspaceFailure(
        'library_changed',
        '资料库已更换，请重新打开文件。',
      ),
      'invalid_information' ||
      'invalid_organization' ||
      'tag_not_found' ||
      'directory_not_found' => const WorkspaceFailure(
        'validation',
        '请检查名称、目录和标签。',
      ),
      'attachment_missing' ||
      'stage_unavailable' => WorkspaceFailure(code, informationFileError(e)),
      'attachment_too_large' || 'attachment_capacity_exceeded' =>
        WorkspaceFailure(code, informationFileError(e)),
      _ => WorkspaceFailure(
        unknown ? 'unknown_outcome' : 'unavailable',
        unknown ? '文件操作结果尚未确认，请核对原操作。' : '文件操作尚未完成，请核对文件和资料状态。',
      ),
    };
  }

  Future<WorkspaceRecordRef> importFile(WorkspaceFileImport c) async {
    try {
      final previous = await _previous(c.operationId, c.digest);
      if (previous != null) return previous.record;
      final selected = selections.selection(c.selectionId);
      final definition = builtinWorkspaceDefinitions['file']!;
      final input = core.InformationDraftInput(
        name: c.name,
        description: c.description,
        directoryId: c.directoryId,
        tagIds: c.tagIds,
        fields: [
          core.InformationDraftField.stagedFile('文件', '', selected.stage.id),
        ],
        fileCommand: core.InformationFileCommand(
          action: 'import',
          digest: c.digest,
        ),
        layout: core.InformationDraftLayout(
          core.InformationLayout(
            typeId: 'file',
            fieldIds: {},
            snapshot: {
              'codec': 'workspace-information-v1',
              'type': {'name': definition['name'], 'icon': definition['icon']},
              'definition': definition,
              'fieldOverrides': <String, Object?>{},
              'retainedFields': [],
              'retainedRelations': [],
              'entries': <String, Object?>{},
            },
          ),
          [
            jsonEncode(['field', 'file']),
          ],
        ),
      );
      final r = await owner.saveInformationFileRecord(
        selected.draft,
        c.operationId,
        input,
      );
      await selections.committed(c.selectionId);
      final result = _receipt(r);
      onChanged(result.record);
      return result.record;
    } catch (e) {
      try {
        final result = await _previous(c.operationId, c.digest);
        if (result != null) {
          await selections.committed(c.selectionId);
          onChanged(result.record);
          return result.record;
        }
      } catch (check) {
        throw _failure(check, unknown: true);
      }
      throw _failure(e);
    }
  }

  Future<WorkspaceFileRef> change(WorkspaceFileChange c) async {
    core.InformationFileDraft? restoring;
    try {
      final previous = await _previous(c.operationId, c.digest);
      if (previous != null) return previous.file!;
      final detail = await information.readDetail(c.record);
      final item = owner.information
          .where((i) => i.id == c.record.id)
          .firstOrNull;
      final field = item?.fields
          .where((f) => f.id == detail.fieldIds[c.fieldKey])
          .firstOrNull;
      if (item == null || field == null || field.kind != core.FieldKind.file) {
        throw const WorkspaceFailure('not_found', '文件字段已不可用。');
      }
      if (item.version != c.expectedRecordVersion ||
          field.attachment!.attachmentVersion != c.expectedFileVersion) {
        throw const WorkspaceFailure('conflict', '资料或文件版本已变化，请重新核对。');
      }
      late core.InformationFileDraft draft;
      late core.InformationFileStage stage;
      if (c.kind == WorkspaceFileChangeKind.replace) {
        if (c.selectionId == null || c.restoreVersion != null) {
          throw const WorkspaceFailure('validation', '请选择替换文件。');
        }
        final selected = selections.selection(c.selectionId!);
        draft = selected.draft;
        stage = selected.stage;
      } else {
        if (c.selectionId != null ||
            c.restoreVersion == null ||
            c.restoreVersion! < 1 ||
            c.restoreVersion == field.attachment!.attachmentVersion) {
          throw const WorkspaceFailure('validation', '请选择保留版本。');
        }
        draft = restoring = await owner.beginInformationFileDraft();
        stage = await owner.stageRetainedInformationFile(
          draft,
          core.InformationAttachmentRef(
            field.attachment!.attachmentId,
            c.restoreVersion!,
          ),
        );
      }
      final input = core.InformationDraftInput(
        itemId: item.id,
        baseVersion: c.expectedRecordVersion,
        name: item.name,
        description: item.description,
        directoryId: item.directoryId,
        tagIds: item.tagIds,
        fileCommand: core.InformationFileCommand(
          action: c.kind.name,
          digest: c.digest,
          fieldId: field.id,
          expected: field.attachment,
        ),
        fields: [
          for (final f in item.fields)
            if (f.id == field.id)
              core.InformationDraftField.stagedFile(
                f.name,
                f.description,
                stage.id,
                fieldId: f.id,
              )
            else if (f.kind == core.FieldKind.file)
              core.InformationDraftField.retainedFile(
                f.name,
                f.description,
                f.attachment,
                fieldId: f.id,
              )
            else
              core.InformationDraftField.text(
                f.name,
                f.description,
                f.value,
                fieldId: f.id,
                kind: f.kind,
              ),
        ],
      );
      final r = await owner.saveInformationFileRecord(
        draft,
        c.operationId,
        input,
      );
      if (c.selectionId != null) await selections.committed(c.selectionId!);
      final result = _receipt(r);
      onChanged(result.record);
      return result.file!;
    } catch (e) {
      try {
        final result = await _previous(c.operationId, c.digest);
        if (result != null) {
          if (c.selectionId != null) await selections.committed(c.selectionId!);
          onChanged(result.record);
          return result.file!;
        }
      } catch (check) {
        throw _failure(check, unknown: true);
      }
      throw _failure(e);
    } finally {
      if (restoring != null) {
        try {
          await owner.releaseInformationFileDraft(restoring);
        } catch (_) {
          /* Owner retains cleanup. */
        }
      }
    }
  }
}
