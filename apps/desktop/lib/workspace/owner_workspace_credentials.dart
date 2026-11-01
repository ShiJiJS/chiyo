import 'dart:async';
import 'package:info_storage/info_storage.dart';
import 'owner_credential_staging.dart';
import 'package:info_core/info_core.dart' as core;
import 'unavailable_workspace_sources.dart';
import 'workspace_source.dart';

String ownerCredentialRecycleId(String id, int revision) =>
    'credential_${id}_$revision';

WorkspaceRecycleEntry ownerCredentialRecycleEntry(
  core.OwnerAccess owner,
  core.ManagedCredential c,
) => WorkspaceRecycleEntry(
  id: ownerCredentialRecycleId(c.id, c.revision),
  record: WorkspaceRecordSummary(
    ref: WorkspaceRecordRef(WorkspaceRecordKind.credential, c.id),
    name: c.name,
    description: c.publicPurpose,
    type: const WorkspaceType('credential', '凭据', 'key'),
    updatedAt: c.modifiedAt,
    directoryId: c.directoryId,
    tags: [
      for (final id in c.tagIds)
        for (final t in owner.tags.where((t) => t.id == id))
          WorkspaceTag(id, t.name),
    ],
  ),
  version: c.revision,
  deletedAt: c.deletedAt!,
  expiresAt: c.deletedAt!.add(const Duration(days: 30)),
  directoryName: owner.directories
      .where((d) => d.id == c.directoryId)
      .firstOrNull
      ?.name,
);

/// Owner credential management. Secret staging is Host-owned; workspace DTOs
/// contain metadata/opaque identities only. AI use remains a separate adapter.
class OwnerWorkspaceCredentials extends UnavailableWorkspaceCredential {
  OwnerWorkspaceCredentials(this.owner, {this.onChanged})
    : _scope = owner.captureLibraryScope(),
      staging = OwnerCredentialStaging(owner);
  final OwnerCredentialStaging staging;
  final void Function(WorkspaceRecordRef)? onChanged;
  final _pending = <String, String>{};
  bool _closed = false;
  void _check() {
    if (_closed) throw const WorkspaceFailure('unavailable', '凭据资料窗口已关闭。');
    staging.check();
  }

  void dispose() {
    _closed = true;
    staging.dispose();
    _pending.clear();
  }

  final core.OwnerAccess owner;
  final core.OwnerLibraryScope _scope;

  Future<T> _read<T>(FutureOr<T> Function() action) async {
    try {
      return await owner.inLibraryScope(_scope, () async {
        _check();
        if (!owner.serviceAvailable) {
          throw const WorkspaceFailure('unavailable', '凭据资料服务尚未就绪。');
        }
        final result = await action();
        _check();
        return result;
      });
    } on core.AccessFailure catch (error) {
      if (error.status == 'library_changed') {
        staging.dispose();
        _pending.clear();
        throw const WorkspaceFailure('library_changed', '资料库已替换，请重新打开凭据。');
      }
      throw _failure(error);
    }
  }

  core.ManagedCredential _credential(WorkspaceRecordRef ref) {
    if (ref.kind != WorkspaceRecordKind.credential) {
      throw const WorkspaceFailure('invalid_reference', '此入口只读取托管凭据。');
    }
    final credential = owner.credentials
        .where((c) => c.id == ref.id)
        .firstOrNull;
    if (credential == null) {
      throw const WorkspaceFailure('not_found', '凭据已回收或不存在。');
    }
    return credential;
  }

  WorkspaceCredentialDetail _detail(core.ManagedCredential credential) {
    final file = credential.form == core.CredentialForm.file;
    final availability = owner.credentialAvailability(credential);
    return WorkspaceCredentialDetail(
      record: WorkspaceRecordSummary(
        ref: WorkspaceRecordRef(WorkspaceRecordKind.credential, credential.id),
        name: credential.name,
        description: credential.publicPurpose,
        type: const WorkspaceType('credential', '凭据', 'key'),
        updatedAt: credential.modifiedAt,
        directoryId: credential.directoryId,
        tags: [
          for (final id in credential.tagIds)
            for (final tag in owner.tags.where((t) => t.id == id))
              WorkspaceTag(id, tag.name),
        ],
      ),
      recordVersion: credential.revision,
      materialVersion: credential.version,
      useGeneration: credential.useGeneration,
      enabled: credential.enabled,
      discoverable: credential.discoverable,
      useSupported: false,
      useUnavailableReason: availability == core.CredentialAvailability.expired
          ? '凭据已到期，不能批准新的使用。'
          : '新版凭据使用审批尚未接入，可管理和更换凭据。',
      form: file
          ? WorkspaceCredentialForm.file
          : WorkspaceCredentialForm.string,
      format: file ? '凭据文件' : '凭据字符串',
      delivery: file
          ? WorkspaceCredentialDelivery.file
          : WorkspaceCredentialDelivery.environment,
      binding: credential.suggestedBinding,
      privateNote: credential.privateNote,
      filename: credential.fileName,
      linkedInformation: credential.linkedItemIds.map(
        (id) => WorkspaceRecordRef(WorkspaceRecordKind.information, id),
      ),
    );
  }

  @override
  Future<WorkspaceCredentialDetail> read(WorkspaceRecordRef ref) =>
      _read(() => _detail(_credential(ref)));

  @override
  Future<WorkspaceCredentialMaterialHistory> materials(
    WorkspaceRecordRef ref,
  ) => _read(() {
    final credential = _credential(ref);
    final file = credential.form == core.CredentialForm.file;
    final versions = owner.credentialVersions(credential.id)
      ..sort((a, b) => b.version.compareTo(a.version));
    return WorkspaceCredentialMaterialHistory(_detail(credential), [
      for (final version in versions)
        WorkspaceCredentialMaterial(
          version: version.version,
          form: file
              ? WorkspaceCredentialForm.file
              : WorkspaceCredentialForm.string,
          format: file ? '凭据文件' : '凭据字符串',
          filename: version.fileName,
          createdAt: version.createdAt,
          retiredAt: version.retiredAt,
        ),
    ]);
  });
  WorkspaceFailure _failure(core.AccessFailure error) => switch (error.status) {
    'library_changed' => const WorkspaceFailure(
      'library_changed',
      '资料库已替换，请重新打开凭据。',
    ),
    'credential_conflict' || 'operation_conflict' => const WorkspaceFailure(
      'conflict',
      '凭据或原操作已变化，请重新核对。',
    ),
    'credential_deleted' => const WorkspaceFailure('not_found', '凭据已回收或不存在。'),
    'credential_material_purged' => const WorkspaceFailure(
      'not_found',
      '保留材料已到期或清理，不能恢复。',
    ),
    'unsupported_capability' => const WorkspaceFailure(
      'unsupported',
      '当前资料库不支持凭据持久操作。',
    ),
    'invalid_credential_metadata' ||
    'invalid_credential_content' ||
    'invalid_credential_file' ||
    'invalid_credential_links' ||
    'invalid_credential_classification' ||
    'invalid_credential_operation' => const WorkspaceFailure(
      'validation',
      '请核对凭据名称、用途、备注、引用及所选材料。',
    ),
    _ => const WorkspaceFailure('unavailable', '凭据资料服务暂不可用。'),
  };
  WorkspaceCredentialReceipt _receipt(
    core.CredentialRecordReceipt receipt,
  ) => WorkspaceCredentialReceipt(
    WorkspaceRecordRef(WorkspaceRecordKind.credential, receipt.credentialId),
    receipt.revision,
    receipt.materialVersion,
    commandDigest: receipt.commandDigest,
    entryId: receipt.action == core.CredentialRecordAction.recycle
        ? ownerCredentialRecycleId(receipt.credentialId, receipt.revision)
        : receipt.action == core.CredentialRecordAction.restoreRecycled ||
              receipt.action == core.CredentialRecordAction.purge
        ? ownerCredentialRecycleId(receipt.credentialId, receipt.baseRevision!)
        : null,
  );
  Future<core.CredentialRecordReceipt?> _previous(
    String id,
    String digest,
  ) async {
    final pending = _pending[id];
    if (pending != null && pending != digest) {
      throw const WorkspaceFailure('conflict', '操作编号已绑定另一份凭据意图。');
    }
    try {
      final result = await owner.credentialRecordReceipt(id);
      _check();
      if (result != null && result.commandDigest != digest) {
        throw const WorkspaceFailure('conflict', '原操作与本次凭据意图不符。');
      }
      return result;
    } on StorageFailure {
      throw const WorkspaceFailure(
        'unknown_outcome',
        '原操作暂无法核对，请保留当前输入并查询原结果。',
      );
    }
  }

  Future<WorkspaceCredentialReceipt> _commit(
    String id,
    core.CredentialRecordInput input,
  ) async {
    _pending[id] = input.commandDigest;
    try {
      final result = await owner.saveCredentialRecord(id, input);
      if (result.commandDigest != input.commandDigest) {
        throw const WorkspaceFailure('unknown_outcome', '返回的凭据回执不匹配，请先核对原结果。');
      }
      staging.resolve(id, committed: true);
      _pending.remove(id);
      final receipt = _receipt(result);
      if (!_closed) onChanged?.call(receipt.ref);
      return receipt;
    } on core.AccessFailure catch (error) {
      if (error.status == 'library_changed') {
        staging.dispose();
        _pending.clear();
      }
      staging.resolve(id, committed: false);
      _pending.remove(id);
      throw _failure(error);
    } on Object {
      throw const WorkspaceFailure(
        'unknown_outcome',
        '凭据操作结果暂无法确认，请核对原操作，勿重复提交。',
      );
    }
  }

  @override
  Future<WorkspaceCredentialRecycled> readRecycled(String entryId) =>
      _read(() async {
        final c = owner.recycledCredentials
            .where((c) => ownerCredentialRecycleId(c.id, c.revision) == entryId)
            .firstOrNull;
        if (c == null) {
          throw const WorkspaceFailure('not_found', '凭据已恢复、到期或清理，请刷新回收站。');
        }
        final catalog = await owner.informationClassificationSnapshot();
        final dirs = catalog.directories.map((d) => d.id).toSet(),
            tags = catalog.tags.map((t) => t.id).toSet();
        final restored = c.copy(
          restore: true,
          enabled: false,
          version: c.version + 1,
          modifiedAt: c.modifiedAt,
          invalidateUse: true,
          clearDirectory: !dirs.contains(c.directoryId),
          tagIds: c.tagIds.where(tags.contains),
        );
        return WorkspaceCredentialRecycled(
          ownerCredentialRecycleEntry(owner, c),
          _detail(c),
          restored: _detail(restored),
          catalogVersion: catalog.version,
          notices: [
            if (c.directoryId != restored.directoryId ||
                c.tagIds.length != restored.tagIds.length)
              '已移除的目录或标签不会重建；凭据恢复后停用，旧授权不会恢复。',
          ],
        );
      });

  @override
  Future<WorkspaceCredentialReceipt> change(WorkspaceCredentialChange change) =>
      _read(() async {
        final prior = await _previous(change.operationId, change.commandDigest);
        if (prior != null) return _receipt(prior);
        if (change.ref.kind != WorkspaceRecordKind.credential) {
          throw const WorkspaceFailure('validation', '此入口只管理托管凭据。');
        }
        final recycled =
            change.action == WorkspaceCredentialAction.restoreRecycled ||
            change.action == WorkspaceCredentialAction.purge;
        if (recycled) {
          if (change.entryId !=
                  ownerCredentialRecycleId(
                    change.ref.id,
                    change.expectedRecordVersion,
                  ) ||
              change.expectedCatalogVersion == null) {
            throw const WorkspaceFailure('conflict', '回收对象或分类预览已变化，请重新核对。');
          }
        } else if (change.entryId != null ||
            change.expectedCatalogVersion != null) {
          throw const WorkspaceFailure('validation', '凭据操作范围不匹配。');
        }
        if ((change.action == WorkspaceCredentialAction.restoreMaterial) !=
            (change.materialVersion != null)) {
          throw const WorkspaceFailure('validation', '请重新选择保留的材料版本。');
        }
        return _commit(
          change.operationId,
          core.CredentialRecordInput(
            action: core.CredentialRecordAction.values.byName(
              change.action.name,
            ),
            commandDigest: change.commandDigest,
            credentialId: change.ref.id,
            expectedRevision: change.expectedRecordVersion,
            expectedMaterialVersion: change.expectedMaterialVersion,
            retainedMaterialVersion: change.materialVersion,
            expectedCatalogVersion: change.expectedCatalogVersion,
          ),
        );
      });

  @override
  Future<void> releaseCandidate(String candidateId) async =>
      staging.release(candidateId);

  @override
  Future<WorkspaceCredentialReceipt> save(WorkspaceCredentialWrite write) =>
      _read(() async {
        final prior = await _previous(write.operationId, write.commandDigest);
        if (prior != null) {
          staging.resolve(write.operationId, committed: true);
          _pending.remove(write.operationId);
          return _receipt(prior);
        }
        final creating = write.ref == null;
        final old = creating ? null : _credential(write.ref!);
        if ((!creating &&
                (write.expectedRecordVersion == null ||
                    write.expectedMaterialVersion == null)) ||
            (creating &&
                (write.expectedRecordVersion != null ||
                    write.expectedMaterialVersion != null)) ||
            (write.linkedInformation?.any(
                  (r) => r.kind != WorkspaceRecordKind.information,
                ) ??
                false)) {
          throw const WorkspaceFailure('validation', '凭据版本或关联类型不匹配，请重新核对。');
        }
        if (creating && write.candidateId == null) {
          throw const WorkspaceFailure('validation', '请先输入或选择凭据材料。');
        }
        OwnerCredentialStage? stage;
        if (write.candidateId != null) {
          stage = staging.claim(write.candidateId!, write.operationId);
          if (old != null &&
              (stage.metadata.form == WorkspaceCredentialForm.file) !=
                  (old.form == core.CredentialForm.file)) {
            staging.resolve(write.operationId, committed: false);
            throw const WorkspaceFailure('validation', '更换材料须保持原有字符串或文件形态。');
          }
        }
        return _commit(
          write.operationId,
          core.CredentialRecordInput(
            action: creating
                ? core.CredentialRecordAction.create
                : stage != null
                ? core.CredentialRecordAction.replaceMaterial
                : core.CredentialRecordAction.edit,
            commandDigest: write.commandDigest,
            credentialId: write.ref?.id,
            expectedRevision: write.expectedRecordVersion,
            expectedMaterialVersion: write.expectedMaterialVersion,
            form: creating
                ? stage!.metadata.form == WorkspaceCredentialForm.file
                      ? core.CredentialForm.file
                      : core.CredentialForm.string
                : null,
            discoverable: write.discoverable,
            name: write.name,
            publicPurpose: write.purpose,
            privateNote: write.privateNote,
            suggestedBinding: write.binding,
            material: stage?.bytes,
            fileName: stage?.metadata.filename,
            linkedItemIds: write.linkedInformation?.map((r) => r.id),
            updateClassification: true,
            directoryId: write.directoryId,
            tagIds: write.tagIds,
          ),
        );
      });

  @override
  Future<WorkspaceCredentialReceipt> setEnabled(
    WorkspaceCredentialToggle change,
  ) => _read(() async {
    final prior = await _previous(change.operationId, change.commandDigest);
    if (prior != null) return _receipt(prior);
    _credential(change.ref);
    return _commit(
      change.operationId,
      core.CredentialRecordInput(
        action: core.CredentialRecordAction.setEnabled,
        commandDigest: change.commandDigest,
        credentialId: change.ref.id,
        expectedRevision: change.expectedRecordVersion,
        expectedMaterialVersion: change.expectedMaterialVersion,
        enabled: change.enabled,
      ),
    );
  });

  @override
  Future<WorkspaceCredentialReceipt?> receipt(String operationId) => _read(
    () async {
      try {
        final result = await owner.credentialRecordReceipt(operationId);
        _check();
        if (result != null &&
            _pending[operationId] != null &&
            result.commandDigest != _pending[operationId]) {
          throw const WorkspaceFailure('unknown_outcome', '原操作回执不匹配，请保留当前输入。');
        }
        staging.resolve(operationId, committed: result != null);
        _pending.remove(operationId);
        return result == null ? null : _receipt(result);
      } on StorageFailure {
        throw const WorkspaceFailure('unknown_outcome', '仍无法确认原操作结果，请稍后核对。');
      }
    },
  );
}
