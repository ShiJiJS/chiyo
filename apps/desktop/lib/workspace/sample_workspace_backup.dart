part of 'sample_workspace_source.dart';

class _SampleChanges {
  _SampleChanges(this.changed);
  final void Function() changed;
  final _controller = StreamController<WorkspaceRecordRef?>.broadcast();
  Stream<WorkspaceRecordRef?> get stream => _controller.stream;
  void add(WorkspaceRecordRef? ref) {
    changed();
    _controller.add(ref);
  }

  Future<void> close() => _controller.close();
}

/// Detached sample state, never exposed by WorkspaceBackupSource. This is not
/// an encrypted file format or a database adapter. Real backup reuses storage.
class _PortableSample {
  _PortableSample(SampleWorkspaceSource s, this.files)
    : records = Map.unmodifiable(s._records),
      revisions = Map.unmodifiable({
        for (final e in s._revisions.entries)
          e.key: List<WorkspaceArchive>.unmodifiable(e.value),
      }),
      recycled = Map.unmodifiable(s._recycled),
      versions = Map.unmodifiable(s._versions),
      entryOwners = Map.unmodifiable(s._entryIdentityOwners),
      catalog = s._catalog,
      preferences = s.settings.portablePreferences,
      credentials = s._credentials.capturePortable(),
      links = s._credentialLinks.capturePortable(),
      plugins = s._plugins.capturePortable(),
      legacy = s._legacy.capturePortable(),
      hosts = s._hosts.capturePortable(),
      definitions = Map.unmodifiable({
        for (final d in s._initial.values.toList().reversed)
          if (d.record.ref.kind == WorkspaceRecordKind.information)
            d.record.type.id: d.definition,
        ...s._restoredTypeDefinitions,
      }),
      requests = {
        for (final r in s._approvals._all())
          if (s._approvals._facts.containsKey(r.id) &&
              r.kind != WorkspaceApprovalKind.organization)
            r.id: _ApprovalInput(
              r.id,
              r.title,
              r.kind,
              r.purpose,
              r.at,
              r.session,
              List.unmodifiable(r.targets),
              credential: r.credential,
              requestedKeys: Set.unmodifiable(r.requestedKeys),
              additional: r.additional,
              requestExpiresAt: r.requestExpiresAt,
            )..original = Map.unmodifiable(r.original),
      },
      facts = {
        for (final e in s._approvals._facts.entries)
          if (s._approvals._input(e.key).kind !=
              WorkspaceApprovalKind.organization)
            e.key: _ApprovalFact(
              e.value.action,
              Map.unmodifiable(e.value.scopes),
              Map.unmodifiable(e.value.files),
              e.value.at,
              e.value.fieldEnd,
              e.value.credentialEnd,
              e.value.revision,
            ),
      },
      executions = {
        for (final e in s._approvals._executions.entries)
          e.key: Map<String, WorkspaceApprovalExecution>.unmodifiable(e.value),
      },
      nextRecord = s._nextRecord,
      nextDirectory = s._nextDirectory,
      nextRecycle = s._nextRecycle,
      clock = s._clock;
  final Map<WorkspaceRecordRef, WorkspaceDetail> records;
  final Map<WorkspaceRecordRef, List<WorkspaceArchive>> revisions;
  final Map<String, ({WorkspaceRecycleEntry entry, WorkspaceArchive archive})>
  recycled;
  final Map<WorkspaceRecordRef, int> versions;
  final Map<String, String> entryOwners;
  final WorkspaceCatalog catalog;
  final WorkspacePreferences preferences;
  final SampleFileBackup files;
  final SampleCredentialBackup credentials;
  final Map<WorkspaceRecordRef, Set<WorkspaceRecordRef>> links;
  final Map<String, WorkspacePlugin> plugins;
  final Map<String, WorkspaceLegacyTemplate> legacy;
  final ({
    Map<String, WorkspaceHostEndpoint> endpoints,
    Map<String, String?> trusted,
  })
  hosts;
  final Map<String, Map<String, Object?>> definitions;
  final Map<String, _ApprovalInput> requests;
  final Map<String, _ApprovalFact> facts;
  final Map<String, Map<String, WorkspaceApprovalExecution>> executions;
  final int nextRecord, nextDirectory, nextRecycle, clock;
  WorkspaceBackupCounts get counts => WorkspaceBackupCounts({
    WorkspaceBackupCategory.information: records.keys
        .where((r) => r.kind == WorkspaceRecordKind.information)
        .length,
    WorkspaceBackupCategory.credentials: records.keys
        .where((r) => r.kind == WorkspaceRecordKind.credential)
        .length,
    WorkspaceBackupCategory.materials: credentials.materials,
    WorkspaceBackupCategory.files: files.versions,
    WorkspaceBackupCategory.fileBytes: files.byteLength,
    WorkspaceBackupCategory.directories: catalog.directories
        .where((d) => !['all', 'unfiled'].contains(d.id))
        .length,
    WorkspaceBackupCategory.tags: catalog.tags.length,
    WorkspaceBackupCategory.templates: definitions.length,
    WorkspaceBackupCategory.plugins: plugins.length,
    WorkspaceBackupCategory.legacyTemplates: legacy.length,
    WorkspaceBackupCategory.revisions: revisions.values.fold(
      0,
      (n, v) => n + v.length,
    ),
    WorkspaceBackupCategory.recycled: recycled.length,
    WorkspaceBackupCategory.grants: facts.length + credentials.historyCount,
    WorkspaceBackupCategory.operations:
        executions.values.fold(0, (n, v) => n + v.length) +
        credentials.operationCount,
    WorkspaceBackupCategory.hosts: hosts.trusted.length,
  });
}

class _BackupSampleResource {
  const _BackupSampleResource(
    this.resource, {
    this.keyId,
    this.archive,
    this.createdAt,
    this.valid = true,
    this.supported = true,
  });
  final WorkspaceBackupResource resource;
  final String? keyId;
  final _PortableSample? archive;
  final DateTime? createdAt;
  final bool valid, supported;
}

class _BackupSamplePlan {
  const _BackupSamplePlan(this.preview, this.state, this.epoch, this.revision);
  final WorkspaceBackupPreview preview;
  final _PortableSample state;
  final int epoch, revision;
}

/// Session-only resources and sample round trips. It performs no cryptography,
/// filesystem publication, database access, Keychain, OS dialogs or execution.
class SampleWorkspaceBackups implements WorkspaceBackupSource {
  SampleWorkspaceBackups(this.s);
  final SampleWorkspaceSource s;
  final _resources = <String, _BackupSampleResource>{};
  final _plans = <String, _BackupSamplePlan>{};
  final _cleanup = <String>{};
  final _receipts = <String, WorkspaceBackupReceipt>{};
  int _version = 1, _destinations = 0;
  String? _keyId;
  bool _keySaved = false, loseNextReply = false;
  WorkspaceFailure? nextCleanupFailure;
  WorkspaceBackupResource? _latest;
  List<String> _blockers() {
    final result = <String>[];
    if (s._scenario == SampleWorkspaceScenario.empty) {
      result.add('当前只是空数据视图，请切换到独立空资料库后恢复');
    }
    if (s._records.isNotEmpty) result.add('信息或凭据');
    if (s._recycled.isNotEmpty ||
        s._revisions.isNotEmpty ||
        s._versions.isNotEmpty) {
      result.add('回收、修订或历史事实');
    }
    if (s._catalog.tags.isNotEmpty ||
        s._catalog.directories.any((d) => !['all', 'unfiled'].contains(d.id))) {
      result.add('目录或标签');
    }
    if (s._plugins.capturePortable().isNotEmpty ||
        s._legacy.capturePortable().isNotEmpty ||
        s._restoredTypeDefinitions.isNotEmpty) {
      result.add('模板或插件');
    }
    if (s._basePending > 0 ||
        s._baseProposals > 0 ||
        s._approvals._all().isNotEmpty ||
        s._proposals._rows.isNotEmpty) {
      result.add('申请、提案或授权历史');
    }
    if (s._credentials.hasPortableData ||
        s._files.hasPortableData ||
        s._hosts.capturePortable().endpoints.isNotEmpty) {
      result.add('凭据、文件或主机事实');
    }
    return result;
  }

  Future<void> _ready() async {
    final epoch = s._epoch;
    await s._readable();
    if (epoch != s._epoch) {
      throw const WorkspaceFailure('cancelled', '资料来源已变化，请重新核对备份操作。');
    }
  }

  @override
  Future<WorkspaceBackupStatus> status() async {
    await _ready();
    final blockers = _blockers();
    return WorkspaceBackupStatus(
      version: _version,
      keyCreated: _keyId != null,
      keySaved: _keySaved,
      recipientEmpty: blockers.isEmpty,
      blockers: blockers,
      cleanupCount: _cleanup.length,
      latestArchive: _latest,
    );
  }

  @override
  Future<String> revealRecoveryKey() async {
    await _ready();
    if (_keyId == null) {
      throw const WorkspaceFailure('key_unavailable', '尚未创建恢复密钥。');
    }
    return 'preview-recovery:$_keyId';
  }

  Future<List<WorkspaceBackupResource>> choices(
    WorkspaceBackupPick kind,
  ) async {
    await _ready();
    if (kind == WorkspaceBackupPick.keyOutput ||
        kind == WorkspaceBackupPick.archiveOutput) {
      final name = kind == WorkspaceBackupPick.keyOutput
          ? '知予恢复密钥-${++_destinations}.recovery'
          : '知予完整备份-${++_destinations}.aimbackup';
      final output = WorkspaceBackupResource(
        id: workspaceOperationId(),
        name: name,
        kind: kind,
      );
      _resources[output.id] = _BackupSampleResource(output);
      final result = [output];
      final existing = _resources.values
          .where(
            (e) =>
                e.resource.kind ==
                (kind == WorkspaceBackupPick.keyOutput
                    ? WorkspaceBackupPick.keyInput
                    : WorkspaceBackupPick.archiveInput),
          )
          .firstOrNull;
      if (existing != null) {
        final collision = WorkspaceBackupResource(
          id: workspaceOperationId(),
          name: existing.resource.name,
          kind: kind,
        );
        _resources[collision.id] = _BackupSampleResource(collision);
        result.add(collision);
      }
      return result;
    }
    if (kind == WorkspaceBackupPick.keyInput) {
      for (final (id, name, valid) in [
        ('wrong-key', '其他恢复密钥.recovery', true),
        ('bad-key', '无效恢复密钥.recovery', false),
      ]) {
        _resources.putIfAbsent(
          id,
          () => _BackupSampleResource(
            WorkspaceBackupResource(id: id, name: name, kind: kind),
            keyId: id,
            valid: valid,
          ),
        );
      }
    } else {
      _resources.putIfAbsent(
        'bad-archive',
        () => const _BackupSampleResource(
          WorkspaceBackupResource(
            id: 'bad-archive',
            name: '损坏的归档.aimbackup',
            kind: WorkspaceBackupPick.archiveInput,
          ),
          valid: false,
        ),
      );
      _resources.putIfAbsent(
        'new-format',
        () => const _BackupSampleResource(
          WorkspaceBackupResource(
            id: 'new-format',
            name: '较新格式.aimbackup',
            kind: WorkspaceBackupPick.archiveInput,
          ),
          supported: false,
        ),
      );
    }
    return _resources.values
        .where((e) => e.resource.kind == kind)
        .map((e) => e.resource)
        .toList();
  }

  _BackupSampleResource _resource(
    WorkspaceBackupResource r,
    WorkspaceBackupPick kind,
  ) {
    final e = _resources[r.id];
    if (e == null || r.kind != kind || !e.resource.same(r)) {
      throw const WorkspaceFailure('backup_changed', '文件选择或版本已变化，请重新选择并检查。');
    }
    return e;
  }

  @override
  Future<WorkspaceBackupPreview> inspect(
    WorkspaceBackupResource archive,
    WorkspaceBackupResource key,
  ) async {
    await _ready();
    if (_blockers().isNotEmpty) {
      throw const WorkspaceFailure(
        'recipient_not_empty',
        '目标库非空，不能覆盖或合并恢复。请在独立空库操作。',
      );
    }
    final a = _resource(archive, WorkspaceBackupPick.archiveInput),
        k = _resource(key, WorkspaceBackupPick.keyInput);
    if (!k.valid) {
      throw const WorkspaceFailure(
        'invalid_recovery_key',
        '恢复密钥文件格式无效，请重新选择完整密钥文件。',
      );
    }
    if (!a.supported) {
      throw const WorkspaceFailure('unsupported_backup', '备份格式不受支持，当前资料库未改变。');
    }
    if (!a.valid || a.archive == null || a.keyId != k.keyId) {
      throw const WorkspaceFailure(
        'invalid_backup',
        '密钥不匹配、归档损坏或内容无效，当前资料库未改变。',
      );
    }
    if (_plans.length >= 32) {
      throw const WorkspaceFailure('preview_busy', '待清理的检查过多，请先清理临时资源。');
    }
    final p = WorkspaceBackupPreview(
      token: workspaceOperationId(),
      archive: archive,
      key: key,
      counts: a.archive!.counts,
      createdAt: a.createdAt!,
      formatLabel: '完整归档',
    );
    _plans[p.token] = _BackupSamplePlan(
      p,
      a.archive!,
      s._epoch,
      s._backupRevision,
    );
    return p;
  }

  @override
  Future<void> releasePreview(String token) async {
    if (!_plans.containsKey(token)) return;
    if (nextCleanupFailure case final failure?) {
      nextCleanupFailure = null;
      _cleanup.add(token);
      _version++;
      s._changes.add(null);
      throw failure;
    }
    _plans.remove(token);
    if (_cleanup.remove(token)) {
      _version++;
      s._changes.add(null);
    }
  }

  void startRecipient() {
    _keyId = null;
    _keySaved = false;
    _version++;
    _plans.clear();
    _cleanup.clear();
  }

  void changeResource(String id) {
    final e = _resources[id];
    if (e == null) return;
    _resources[id] = _BackupSampleResource(
      WorkspaceBackupResource(
        id: id,
        name: e.resource.name,
        kind: e.resource.kind,
        version: e.resource.version + 1,
      ),
      archive: e.archive,
      keyId: e.keyId,
      createdAt: e.createdAt,
      valid: e.valid,
      supported: e.supported,
    );
  }

  void _afterCommitCleanup(String id) {
    if (nextCleanupFailure != null) {
      nextCleanupFailure = null;
      _cleanup.add(id);
    } else {
      _plans.remove(id);
      _cleanup.remove(id);
    }
  }

  @override
  Future<WorkspaceBackupReceipt> change(WorkspaceBackupChange c) async {
    await _ready();
    if (c.operationId.isEmpty || c.operationId.length > 200) {
      throw const WorkspaceFailure('validation', '备份操作身份无效。');
    }
    if (_receipts[c.operationId] case final old?) {
      if (!old.matches(c)) {
        throw const WorkspaceFailure('operation_conflict', '同次操作不能保存不同的备份意图。');
      }
      return old;
    }
    if (c.expectedVersion != _version) {
      throw const WorkspaceFailure('conflict', '备份设置或资源状态已变化，请重新读取后核对。');
    }
    WorkspaceBackupResource? result;
    WorkspaceBackupCounts? counts;
    _BackupSamplePlan? restorePlan;
    _BackupSampleResource? destination;
    _PortableSample? captured;
    if (c.action == WorkspaceBackupAction.enableKey) {
      if (_keyId != null) {
        throw const WorkspaceFailure('conflict', '已存在恢复密钥，请重新读取。');
      }
    } else if (c.action == WorkspaceBackupAction.saveKey ||
        c.action == WorkspaceBackupAction.export) {
      if (_keyId == null) {
        throw const WorkspaceFailure('key_unavailable', '请先创建恢复密钥。');
      }
      if (c.action == WorkspaceBackupAction.export && !_keySaved) {
        throw const WorkspaceFailure(
          'recovery_key_not_saved',
          '请先另存恢复密钥，另存成功后才能导出。',
        );
      }
      if (c.selection == null) {
        throw const WorkspaceFailure('validation', '请先选择新的文件名。');
      }
      final kind = c.action == WorkspaceBackupAction.saveKey
          ? WorkspaceBackupPick.keyOutput
          : WorkspaceBackupPick.archiveOutput;
      destination = _resource(c.selection!, kind);
      if (_resources.values.any(
        (e) =>
            e.resource.id != c.selection!.id &&
            e.resource.kind ==
                (kind == WorkspaceBackupPick.keyOutput
                    ? WorkspaceBackupPick.keyInput
                    : WorkspaceBackupPick.archiveInput) &&
            e.resource.name == c.selection!.name,
      )) {
        throw const WorkspaceFailure('output_exists', '文件名已存在，请选择新名称，原文件未覆盖。');
      }
      if (c.action == WorkspaceBackupAction.export) {
        final epoch = s._epoch, revision = s._backupRevision;
        final files = await s._files.capturePortable();
        if (epoch != s._epoch ||
            revision != s._backupRevision ||
            c.expectedVersion != _version) {
          throw const WorkspaceFailure('conflict', '资料在准备备份时变化，请重新导出。');
        }
        captured = _PortableSample(s, files);
        counts = captured.counts;
      }
    } else if (c.action == WorkspaceBackupAction.restore) {
      restorePlan = _plans[c.previewToken];
      if (restorePlan == null ||
          restorePlan.epoch != s._epoch ||
          restorePlan.revision != s._backupRevision) {
        throw const WorkspaceFailure(
          'backup_changed',
          '检查后的目标资料已变化，请重新检查，尚未恢复。',
        );
      }
      _resource(restorePlan.preview.archive, WorkspaceBackupPick.archiveInput);
      _resource(restorePlan.preview.key, WorkspaceBackupPick.keyInput);
      if (c.selection == null ||
          !c.selection!.same(restorePlan.preview.archive)) {
        throw const WorkspaceFailure('backup_changed', '恢复选择与检查结果不符，尚未恢复。');
      }
      if (_blockers().isNotEmpty) {
        throw const WorkspaceFailure('recipient_not_empty', '目标资料库已不为空，尚未恢复。');
      }
      counts = restorePlan.state.counts;
      result = restorePlan.preview.archive;
    } else if (nextCleanupFailure case final failure?) {
      nextCleanupFailure = null;
      throw failure;
    }
    s._beforeApprovalWrite();
    // No await from this point through the sample mutation, receipt and event.
    switch (c.action) {
      case WorkspaceBackupAction.enableKey:
        _keyId = workspaceOperationId();
      case WorkspaceBackupAction.saveKey:
        result = WorkspaceBackupResource(
          id: destination!.resource.id,
          name: destination.resource.name,
          kind: WorkspaceBackupPick.keyInput,
        );
        _resources[result.id] = _BackupSampleResource(result, keyId: _keyId);
        _keySaved = true;
      case WorkspaceBackupAction.export:
        result = WorkspaceBackupResource(
          id: destination!.resource.id,
          name: destination.resource.name,
          kind: WorkspaceBackupPick.archiveInput,
        );
        _resources[result.id] = _BackupSampleResource(
          result,
          keyId: _keyId,
          archive: captured,
          createdAt: s._now(),
        );
        _latest = result;
        _afterCommitCleanup('export:${c.operationId}');
      case WorkspaceBackupAction.restore:
        s._installBackup(restorePlan!.state);
        _afterCommitCleanup(c.previewToken!);
      case WorkspaceBackupAction.cleanup:
        for (final id in _cleanup) {
          _plans.remove(id);
        }
        _cleanup.clear();
    }
    final r = WorkspaceBackupReceipt(
      operationId: c.operationId,
      commandDigest: c.digest,
      action: c.action,
      expectedVersion: c.expectedVersion,
      version: ++_version,
      resource: result,
      counts: counts,
    );
    _receipts[c.operationId] = r;
    s._changes.add(null);
    if (loseNextReply) {
      loseNextReply = false;
      throw const WorkspaceFailure(
        'unknown_outcome',
        '备份操作结果未知，请核对原操作，不要重复提交。',
      );
    }
    return r;
  }

  @override
  Future<WorkspaceBackupReceipt?> receipt(String id) async {
    await _ready();
    return _receipts[id];
  }
}

extension _SampleBackupInstall on SampleWorkspaceSource {
  void _installBackup(_PortableSample value) {
    _epoch++;
    runtime.resetCurrent();
    _basePending = _baseProposals = 0;
    _approvals.reset();
    _proposals.reset();
    _records
      ..clear()
      ..addAll(value.records);
    _revisions
      ..clear()
      ..addAll({
        for (final e in value.revisions.entries) e.key: List.of(e.value),
      });
    _recycled
      ..clear()
      ..addAll(value.recycled);
    _versions
      ..clear()
      ..addAll(value.versions);
    _entryIdentityOwners
      ..clear()
      ..addAll(value.entryOwners);
    _catalog = value.catalog;
    _catalogVersion++;
    _restoredTypeDefinitions
      ..clear()
      ..addAll(value.definitions);
    _files.installPortable(value.files);
    _credentials.installPortable(value.credentials);
    _credentialLinks.installPortable(value.links);
    _plugins.installPortable(value.plugins);
    _legacy.installPortable(value.legacy);
    _hosts.installPortable(value.hosts);
    settings.installPortable(value.preferences);
    _approvals._inputs.addAll({
      for (final r in value.requests.values)
        r.id: _ApprovalInput(
          r.id,
          r.title,
          r.kind,
          r.purpose,
          r.at,
          r.session,
          List.of(r.targets),
          credential: r.credential,
          requestedKeys: r.requestedKeys,
          additional: r.additional,
          requestExpiresAt: r.requestExpiresAt,
        )..original = Map.of(r.original),
    });
    _approvals._facts.addAll(value.facts);
    _approvals._revision = value.facts.values.fold(
      0,
      (n, f) => n > f.revision ? n : f.revision,
    );
    _approvals._seeded = true;
    _approvals._restored.addAll(value.requests.keys);
    _approvals._ended.addAll(value.requests.values.map((r) => r.session.id));
    _approvals._executions.addAll({
      for (final e in value.executions.entries)
        if (value.requests.containsKey(e.key))
          e.key: {for (final x in e.value.entries) x.key: x.value.asRestored()},
    });
    _nextRecord = _nextRecord > value.nextRecord
        ? _nextRecord
        : value.nextRecord;
    _nextDirectory = _nextDirectory > value.nextDirectory
        ? _nextDirectory
        : value.nextDirectory;
    _nextRecycle = _nextRecycle > value.nextRecycle
        ? _nextRecycle
        : value.nextRecycle;
    _clock = _clock > value.clock ? _clock : value.clock;
    _tagRemovalPlans.clear();
    _operations.clear();
    _recordOperations.clear();
    _fileOperations.clear();
    _adoptionPlans.clear();
    _committedRecordOperations.clear();
  }
}

extension SampleBackupPreparation on SampleWorkspaceSource {
  /// Explicit composition-only fixture switch, never a product erase action.
  Future<void> prepareBackupRecipient() async {
    final data = jsonDecode(sampleWorkspaceJson) as Map<String, dynamic>;
    data['records'] = [];
    data['trash'] = [];
    data['tags'] = [];
    data['pending'] = 0;
    data['proposals'] = 0;
    data['directories'] = (data['directories'] as List)
        .where((d) => ['all', 'unfiled'].contains(d['id']))
        .toList();
    await replaceFixture(jsonEncode(data));
    _legacy.installPortable({});
    _plugins.installPortable({});
    _hosts.clear();
    _restoredTypeDefinitions.clear();
    backups.startRecipient();
    _changes.add(null);
  }

  /// Explicit composition-only reset to the complete frozen synthetic dataset.
  /// Unsupported preview formats still have original bytes and stay in backup.
  Future<void> prepareBackupExportFixture() =>
      replaceFixture(sampleWorkspaceJson);
}
