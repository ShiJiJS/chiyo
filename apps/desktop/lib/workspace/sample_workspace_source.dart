import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'sample_workspace_fixture.dart';
import 'sample_workspace_entries.dart';
import 'sample_workspace_content_fixture.dart';
import 'sample_workspace_files.dart';
import 'sample_workspace_credentials.dart';
import 'sample_credential_records.dart';
import 'sample_credential_links.dart';
import 'workspace_source.dart';
import 'sample_workspace_plugins.dart';
import 'sample_plugin_fixture.dart';
import 'sample_workspace_hosts.dart';
import 'sample_workspace_field_ids.dart';
import 'workspace_entries.dart';
import 'sample_workspace_legacy.dart';
export 'sample_workspace_hosts.dart' show SampleHostScenario;

part 'sample_workspace_history.dart';
part 'sample_workspace_adoption.dart';
part 'sample_workspace_approvals.dart';
part 'sample_workspace_grant_history.dart';
part 'sample_workspace_proposals.dart';

enum SampleWorkspaceScenario { ready, empty, waiting, failure }

/// The isolated composition root creates this provider. All values are the
/// approved prototype's fictional data; no production adapter imports it.
class SampleWorkspaceSource
    implements WorkspaceSource, SampleCredentialRecordStore {
  SampleWorkspaceSource({
    String fixtureJson = sampleWorkspaceJson,
    DateTime Function()? now,
    WorkspaceAssetReader? readAsset,
    Map<String, ({String filename, List<int> bytes})>? pluginInputs,
    Iterable<SampleLegacyInput>? legacyInputs,
  }) : _fixtureJson = fixtureJson,
       _files = SampleWorkspaceFiles(readAsset),
       _pluginInputs = pluginInputs,
       _legacyInputs = legacyInputs,
       _now = now ?? (() => DateTime.utc(2026, 10, 26));
  final SampleWorkspaceFiles _files;
  final Map<String, ({String filename, List<int> bytes})>? _pluginInputs;
  final Iterable<SampleLegacyInput>? _legacyInputs;
  final _credentialLinks = SampleCredentialLinks();
  late final _credentials = SampleWorkspaceCredentials(
    readable: _readable,
    records: this,
    approvalState: (r) => _approvals.credentialState(r),
    approvalHistory: (r) => _approvals.credentialHistory(r),
    approvalRequests: (r) => _approvals.seedCredentialRequests(r),
    beforeWrite: () {
      if (nextSaveFailure case final failure?) {
        nextSaveFailure = null;
        throw failure;
      }
    },
    changed: (ref) => _changes.add(ref),
    now: _now,
  );
  @override
  WorkspaceCredentialSource get credentials => _credentials;
  late final _approvals = _SampleApprovals(this);
  @override
  WorkspaceApprovalSource get approvals => _approvals;
  late final _grantHistory = _SampleGrantHistory(this);
  @override
  WorkspaceGrantHistorySource get grantHistory => _grantHistory;
  late final _proposals = _SampleProposals(this);
  @override
  WorkspaceProposalSource get proposals => _proposals;
  set loseNextProposalReply(bool value) => _proposals.loseNextReply = value;
  Future<void> demonstrateProposalConflict() async {
    await _readable();
    _proposals._seed();
    final proposal = _proposals._rows['update'];
    if (proposal == null || !proposal.pending) return;
    final current = _records[proposal.origin];
    if (current == null) return;
    await saveRecord(
      WorkspaceEdit(
        operationId: workspaceOperationId(),
        expectedVersion: current.version,
        record: current.record,
        values: {'port': '2200'},
      ),
    );
  }

  bool get loseNextApprovalReply => _approvals.loseNextReply;
  set loseNextApprovalReply(bool value) => _approvals.loseNextReply = value;
  void demonstrateApprovalExecutions(String id) =>
      _approvals.demonstrateExecutions(id);
  void publishApprovalExecutionObservation(String id) =>
      _approvals.publishExecutionObservation(id);
  set nextApprovalExecutionReadFailure(WorkspaceFailure? value) =>
      _approvals.nextExecutionReadFailure = value;
  void advanceApprovalClock(Duration value) => _approvals.advance(value);
  void endApprovalSession(String id) => _approvals.endSession(id);
  void _beforeApprovalWrite() {
    if (nextSaveFailure case final failure?) {
      nextSaveFailure = null;
      throw failure;
    }
  }

  late final _plugins = SampleWorkspacePlugins(
    readable: _readable,
    beforeWrite: () {
      if (nextSaveFailure case final failure?) {
        nextSaveFailure = null;
        throw failure;
      }
    },
    changed: () {
      _catalogVersion++;
      _changes.add(null);
    },
    recordCounts: () {
      final counts = <String, int>{};
      if (_scenario == SampleWorkspaceScenario.empty) return counts;
      for (final detail in _records.values) {
        final package = detail.definition['packageId'] as String?;
        if (package != null) {
          counts.update(package, (n) => n + 1, ifAbsent: () => 1);
        }
      }
      return counts;
    },
    inputs: _pluginInputs ?? samplePluginInputs(),
  );
  @override
  WorkspacePluginSource get plugins => _plugins;
  late final _legacy = SampleWorkspaceLegacy(
    readable: _readable,
    changed: () => _changes.add(null),
    plugins: _plugins,
    inputs: _legacyInputs ?? sampleLegacyInputs,
  );
  @override
  WorkspaceLegacyTemplateSource get legacyTemplates => _legacy;
  void reviseLegacyTemplate(String id) => _legacy.revise(id);
  late final _hosts = SampleWorkspaceHosts(
    readable: _readable,
    beforeWrite: () {
      if (nextSaveFailure case final failure?) {
        nextSaveFailure = null;
        throw failure;
      }
    },
    changed: () => _changes.add(null),
    records: () => _records.values,
    plugin: () => _plugins.forType('server'),
    pluginVersion: () => _plugins.version,
    empty: () => _scenario == SampleWorkspaceScenario.empty,
  );
  @override
  WorkspaceHostSource get hosts => _hosts;
  void observeHost(WorkspaceHostEndpoint endpoint, String? fingerprint) =>
      _hosts.observe(endpoint, fingerprint);
  set loseNextHostReply(bool value) => _hosts.loseNextReply = value;
  Future<void> demonstrateHost(SampleHostScenario scenario) async {
    await _readable();
    _hosts.demonstrate(scenario);
  }

  Future<List<WorkspacePluginCandidate>> pluginChoices() => _plugins.choices();
  set loseNextPluginReply(bool value) => _plugins.loseNextReply = value;
  set nextCredentialReadFailure(WorkspaceFailure? value) =>
      _credentials.nextReadFailure = value;
  @override
  int get credentialCatalogVersion => _catalogVersion;
  @override
  void commitCredentialRecord(WorkspaceDetail detail) {
    if (_scenario == SampleWorkspaceScenario.empty) _materializeEmpty();
    _putRecord(detail);
  }

  @override
  SampleCredentialRecycleRecord? recycledCredentialRecord(String entryId) {
    final value = _scenario == SampleWorkspaceScenario.empty
        ? null
        : _recycled[entryId];
    return value?.entry.record.ref.kind == WorkspaceRecordKind.credential
        ? value
        : null;
  }

  @override
  WorkspaceRecycleEntry recycleCredentialRecord(
    WorkspaceRecordRef ref,
    int version,
  ) {
    final current = currentCredentialRecord(ref), now = _now();
    final archive = _archive(current);
    final entry = WorkspaceRecycleEntry(
      id: workspaceOperationId(),
      record: current.record,
      version: version,
      deletedAt: now,
      expiresAt: now.add(const Duration(days: 30)),
      directoryName: archive.directoryName,
    );
    // Update the same relation fact and affected information revisions before
    // hiding this record. The immutable recycle snapshot retains old links.
    _putRecord(
      WorkspaceDetail(
        record: current.record,
        version: version,
        definition: current.definition,
        fieldIds: current.fieldIds,
        retainedFields: current.retainedFields,
        retainedRelations: current.retainedRelations,
        values: const {},
        relations: const {'related': []},
      ),
    );
    _records.remove(ref);
    _recycled[entry.id] = (entry: entry, archive: archive);
    return entry;
  }

  @override
  SampleCredentialRestoreRecord prepareCredentialRestore(
    String entryId,
    int version,
  ) {
    final recycled = recycledCredentialRecord(entryId);
    if (recycled == null) {
      throw const WorkspaceFailure('not_found', '回收凭据已不可用。');
    }
    if (_records.containsKey(recycled.entry.record.ref)) {
      throw const WorkspaceFailure('conflict', '凭据已存在，请重新核对。');
    }
    final notices = <String>[];
    final detail = _normalizeArchive(recycled.archive, version, notices);
    return (
      detail: detail,
      notices: notices.map((n) => n.replaceAll('“related”', '“关联资料”')).toList(),
    );
  }

  @override
  void commitCredentialRestore(String entryId, WorkspaceDetail detail) {
    _recycled.remove(entryId);
    _putRecord(detail);
  }

  @override
  void purgeCredentialRecord(String entryId) {
    final recycled = _recycled.remove(entryId);
    if (recycled != null) {
      _versions[recycled.entry.record.ref] = recycled.entry.version + 1;
      _forgetContent(recycled.entry.record.ref);
    }
  }

  WorkspaceDetail? _visibleRecord(WorkspaceRecordRef ref) {
    final raw = _scenario == SampleWorkspaceScenario.empty
        ? null
        : _records[ref];
    return raw == null ? null : _projectRecord(raw);
  }

  @override
  WorkspaceDetail currentCredentialRecord(WorkspaceRecordRef ref) {
    if (ref.kind != WorkspaceRecordKind.credential) {
      throw const WorkspaceFailure('unsupported', '此入口只管理托管凭据。');
    }
    return _visibleRecord(ref) ??
        (throw const WorkspaceFailure('not_found', '凭据已不存在。'));
  }

  WorkspaceDetail _projectRecord(WorkspaceDetail raw) {
    final ref = raw.record.ref, relations = {...raw.relations};
    if (ref.kind == WorkspaceRecordKind.credential) {
      relations['related'] = [
        ...?raw.relations['related'],
        ..._credentialLinks.information(ref),
      ];
    } else {
      final linked = _credentialLinks.credentials(ref).toList();
      if (linked.isNotEmpty || relations.containsKey('credentials')) {
        relations['credentials'] = [
          ...?raw.relations['credentials'],
          ...linked,
        ];
      }
    }
    return WorkspaceDetail(
      record: raw.record,
      version: raw.version,
      templateState: raw.definition['packageId'] is String
          ? _plugins.stateFor(
              raw.record.type.id,
              raw.definition['packageId'] as String,
            )
          : WorkspaceTemplateState.available,
      definition: raw.definition,
      fieldIds: raw.fieldIds,
      retainedFields: raw.retainedFields,
      retainedRelations: raw.retainedRelations,
      values: raw.values,
      relations: relations,
    );
  }

  WorkspaceDetail _rawRecord(WorkspaceDetail detail) {
    final relations = {...detail.relations};
    final key = detail.record.ref.kind == WorkspaceRecordKind.credential
        ? 'related'
        : 'credentials';
    if (relations.containsKey(key)) {
      final linkedKind =
          detail.record.ref.kind == WorkspaceRecordKind.credential
          ? WorkspaceRecordKind.information
          : WorkspaceRecordKind.credential;
      relations[key] = relations[key]!
          .where((r) => r.kind != linkedKind)
          .toList();
    }
    return WorkspaceDetail(
      record: detail.record,
      version: detail.version,
      definition: detail.definition,
      fieldIds: detail.fieldIds,
      retainedFields: detail.retainedFields,
      retainedRelations: detail.retainedRelations,
      values: detail.values,
      relations: relations,
    );
  }

  void _putRecord(WorkspaceDetail detail) {
    detail = sampleWithFieldIds(detail, previous: _records[detail.record.ref]);
    final ref = detail.record.ref,
        isCredential = ref.kind == WorkspaceRecordKind.credential;
    final key = isCredential ? 'related' : 'credentials';
    if (detail.relations.containsKey(key)) {
      final oldPeers =
          (isCredential
                  ? _credentialLinks.information(ref)
                  : _credentialLinks.credentials(ref))
              .toSet();
      final newPeers = detail.relations[key]!
          .where(
            (r) =>
                r.kind ==
                (isCredential
                    ? WorkspaceRecordKind.information
                    : WorkspaceRecordKind.credential),
          )
          .toSet();
      final changed = {
        ...oldPeers.difference(newPeers),
        ...newPeers.difference(oldPeers),
      };
      final prior = {
        for (final peer in changed)
          if (_records[peer] case final raw?) peer: _projectRecord(raw),
      };
      if (isCredential) {
        _credentialLinks.replaceCredential(ref, newPeers);
      } else {
        _credentialLinks.replaceInformation(ref, newPeers);
      }
      for (final e in prior.entries) {
        final old = e.value;
        if (e.key.kind == WorkspaceRecordKind.information) {
          (_revisions[e.key] ??= []).add(_archive(old));
        }
        _records[e.key] = _rawRecord(
          WorkspaceDetail(
            record: old.record.copyWith(
              updatedAt: _now().add(Duration(microseconds: _clock++)),
            ),
            version: old.version + 1,
            definition: old.definition,
            fieldIds: old.fieldIds,
            retainedFields: old.retainedFields,
            retainedRelations: old.retainedRelations,
            values: old.values,
            relations: _projectRecord(_records[e.key]!).relations,
          ),
        );
        _versions[e.key] = old.version + 1;
      }
    }
    _records[ref] = _rawRecord(detail);
    _versions[ref] = detail.version;
  }

  @override
  WorkspaceDetail prepareCredentialRecord(
    WorkspaceRecordRef ref,
    WorkspaceCredentialWrite? write,
  ) {
    final old = write?.ref == null && write != null
        ? null
        : currentCredentialRecord(ref);
    if (write == null) {
      return WorkspaceDetail(
        record: old!.record.copyWith(updatedAt: _now()),
        version: old.version + 1,
        definition: old.definition,
        fieldIds: old.fieldIds,
        retainedFields: old.retainedFields,
        retainedRelations: old.retainedRelations,
        values: const {},
        relations: old.relations,
      );
    }
    final errors = <String, String>{};
    if (write.directoryId != null &&
        !_catalog.directories.any(
          (d) =>
              d.id == write.directoryId && !['all', 'unfiled'].contains(d.id),
        )) {
      errors['directory'] = '目录已不可用。';
    }
    if (write.tagIds.toSet().length != write.tagIds.length ||
        write.tagIds.any((id) => !_catalog.tags.any((t) => t.id == id))) {
      errors['tags'] = '标签已不可用或重复。';
    }
    if (write.linkedInformation case final links?) {
      if (links.any(
        (r) =>
            r.kind != WorkspaceRecordKind.information ||
            _visibleRecord(r) == null,
      )) {
        errors['related'] = '关联资料已不可用，请重新选择。';
      }
    }
    if (errors.isNotEmpty) {
      throw WorkspaceFailure('validation', '请检查分类与关联。', fieldErrors: errors);
    }
    final type = _catalog.types.firstWhere((t) => t.id == 'credential');
    final record = WorkspaceRecordSummary(
      ref: ref,
      name: write.name.trim(),
      description: write.purpose,
      type: type,
      updatedAt: _now().add(Duration(microseconds: _clock++)),
      directoryId: write.directoryId,
      tags: _catalog.tags.where((t) => write.tagIds.contains(t.id)),
    );
    return WorkspaceDetail(
      record: record,
      version: (old?.version ?? 0) + 1,
      definition: sampleCredentialDefinition,
      relations: {
        'related': write.linkedInformation ?? old?.relations['related'] ?? [],
      },
    );
  }

  final _fileOperations =
      <
        String,
        ({
          String fingerprint,
          WorkspaceFileRef? file,
          WorkspaceRecordRef record,
          bool? actionCompleted,
        })
      >{};
  WorkspaceFailure? nextFilePreviewFailure, nextFileActionFailure;
  bool cancelNextFileAction = false;
  Future<List<WorkspaceFileCandidate>> fileChoices() => _files.choices();
  final DateTime Function() _now;
  final _revisions = <WorkspaceRecordRef, List<WorkspaceArchive>>{};
  final _recycled =
      <String, ({WorkspaceRecycleEntry entry, WorkspaceArchive archive})>{};
  final _recordOperations =
      <String, ({String fingerprint, WorkspaceRecordReceipt receipt})>{};
  final _committedRecordOperations = <String, WorkspaceOperationReceipt>{};
  final _adoptionPlans = <String, WorkspaceAdoptionPreview>{};

  @override
  Future<WorkspaceAdoptionPreview> previewAdoption(
    WorkspaceAdoptionDraft draft,
  ) => _previewAdoption(draft);
  @override
  Future<WorkspaceRecordReceipt> applyAdoption(
    String operationId,
    String planId,
  ) => _applyAdoption(operationId, planId);
  @override
  Future<void> releaseAdoption(String planId) async {
    _adoptionPlans.remove(planId);
  }

  /// Composition-only fault: commit the next ordinary write, then lose its reply.
  bool loseNextRecordReply = false;

  void _recordCommitted(
    String id,
    WorkspaceOperationIntent intent,
    WorkspaceRecordReceipt result,
  ) {
    _committedRecordOperations[id] = WorkspaceOperationReceipt(
      operationId: id,
      intent: intent,
      result: result,
    );
    if (loseNextRecordReply) {
      loseNextRecordReply = false;
      throw const WorkspaceFailure('unknown_outcome', '操作结果暂时无法确认，请先核对结果。');
    }
  }

  @override
  Future<WorkspaceOperationReceipt?> recordOperationReceipt(
    String operationId,
  ) async {
    await _readable();
    if (operationId.trim().isEmpty) {
      throw const WorkspaceFailure('validation', '操作身份不能为空。');
    }
    return _committedRecordOperations[operationId];
  }

  final _versions = <WorkspaceRecordRef, int>{};
  final _entryIdentityOwners = <String, String>{};
  int _nextRecycle = 0;
  String _fingerprint(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();
  String _fixtureJson;
  static const _genericDefinition = <String, Object?>{
    'name': '通用资料',
    'fields': [
      {'key': 'body', 'label': '内容', 'type': 'multiline'},
    ],
    'relations': [
      {'key': 'related', 'label': '相关资料', 'targetTemplates': <String>[]},
    ],
    'sections': [
      {'kind': 'text', 'title': '内容', 'key': 'body'},
      {'kind': 'relations', 'title': '相关资料', 'key': 'related'},
    ],
  };

  Map<String, Object?> _genericDefinitionFor(Map values) => {
    ..._genericDefinition,
    'fields': [
      if (!values.containsKey('body') || values['body'] is String)
        ..._genericDefinition['fields'] as List,
      for (final key in values.keys)
        if (key != 'body' && values[key] is String)
          {'key': key, 'label': key, 'type': 'multiline'},
    ],
    'sections': [
      {'kind': 'text', 'title': '内容', 'key': 'body'},
      for (final key in values.keys)
        if (key != 'body') {'kind': 'text', 'title': key, 'key': key},
      {'kind': 'relations', 'title': '相关资料', 'key': 'related'},
    ],
  };
  SampleWorkspaceScenario _scenario = SampleWorkspaceScenario.ready;
  final _waiting = <Completer<void>>[];
  final _changes = StreamController<WorkspaceRecordRef?>.broadcast();
  @override
  Stream<WorkspaceRecordRef?> get changes => _changes.stream;
  Future<void>? _loading;
  late WorkspaceCatalog _catalog;
  WorkspaceCatalog? _initialCatalog;
  int _catalogVersion = 1, _nextDirectory = 0;
  final _directoryOperations =
      <String, ({String fingerprint, WorkspaceDirectory? directory})>{};
  final _initialRecycled =
      <String, ({WorkspaceRecycleEntry entry, WorkspaceArchive archive})>{};
  final _initial = <WorkspaceRecordRef, WorkspaceDetail>{};
  final _records = <WorkspaceRecordRef, WorkspaceDetail>{};
  final _operations =
      <String, ({String fingerprint, WorkspaceSaveResult result})>{};
  WorkspaceFailure? nextSaveFailure;
  int _epoch = 0, _clock = 0, _nextRecord = 0;
  int _basePending = 5,
      _baseProposals = 2,
      _initialPending = 5,
      _initialProposals = 2;
  bool _disposed = false;
  static const initial = WorkspaceSummary(
    records: 31,
    pending: 5,
    proposals: 2,
  );
  SampleWorkspaceScenario get scenario => _scenario;

  void setScenario(SampleWorkspaceScenario value) {
    _epoch++;
    for (final request in _waiting) {
      request.completeError(const WorkspaceFailure('cancelled', '已切换预览状态。'));
    }
    _waiting.clear();
    _scenario = value;
  }

  Future<void> _ensureData() => _loading ??= () async {
    final data = jsonDecode(_fixtureJson) as Map<String, dynamic>;
    _basePending = _initialPending = data['pending'] as int? ?? initial.pending;
    _baseProposals = _initialProposals =
        data['proposals'] as int? ?? initial.proposals;
    final activeRows = (data['records'] as List).cast<Map<String, dynamic>>();
    final trashRows = (data['trash'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    final rows = [...activeRows, ...trashRows];
    final trashDetails = <WorkspaceRecordRef, WorkspaceDetail>{};
    final tagNames = <String>{
      for (final row in rows) ...List<String>.from(row['tags'] ?? []),
      ...List<String>.from(data['tags'] ?? []),
    };
    final tags = {
      for (final (index, name) in tagNames.indexed)
        name: WorkspaceTag('tag-$index', name),
    };
    final types = <String, WorkspaceType>{};
    WorkspaceType type(Map<String, dynamic> row) {
      final id =
          row['templateId'] as String? ??
          (row['kind'] == 'resume'
              ? 'file'
              : row['kind'] == 'note'
              ? 'generic'
              : row['kind'] as String);
      return types.putIfAbsent(id, () {
        final definition = row['definition'] as Map<String, dynamic>?;
        const names = {
          'server': '服务器信息',
          'service': '应用与服务',
          'profile': '个人档案',
          'document': '文档',
          'file': '文件',
          'credential': '凭据',
          'generic': '通用资料',
        };
        const icons = {
          'server': 'server',
          'service': 'layers',
          'profile': 'user',
          'document': 'book',
          'file': 'file',
          'credential': 'key',
        };
        return WorkspaceType(
          id,
          definition?['name'] as String? ?? names[id] ?? '通用资料',
          definition?['icon'] as String? ?? icons[id] ?? 'file',
        );
      });
    }

    WorkspaceRecordRef rowRef(Map<String, dynamic> row) => WorkspaceRecordRef(
      row['kind'] == 'credential'
          ? WorkspaceRecordKind.credential
          : WorkspaceRecordKind.information,
      row['id'] as String,
    );
    final refs = <String, Set<WorkspaceRecordRef>>{};
    for (final row in rows) {
      (refs[row['id'] as String] ??= {}).add(rowRef(row));
    }
    WorkspaceRecordRef relationRef(Object? raw) {
      if (raw is Map) {
        final kind = WorkspaceRecordKind.values.singleWhere(
          (k) => k.name == raw['kind'],
        );
        return WorkspaceRecordRef(kind, raw['id'] as String);
      }
      final id = raw as String;
      final matches = refs[id] ?? {};
      if (matches.length > 1) {
        throw const FormatException(
          'Ambiguous fixture reference: use a typed identity.',
        );
      }
      return matches.firstOrNull ??
          WorkspaceRecordRef(WorkspaceRecordKind.information, id);
    }

    for (final row in rows) {
      final ref = rowRef(row);
      final rawDirectory = row['directory'] as String?;
      final record = WorkspaceRecordSummary(
        ref: ref,
        name: row['name'] as String,
        description: row['summary'] as String? ?? '',
        type: type(row),
        updatedAt: DateTime.parse(
          '${row['updatedAt'] ?? row['deletedAt']}T00:00:00Z',
        ),
        directoryId: rawDirectory == 'unfiled' ? null : rawDirectory,
        tags: [for (final name in row['tags'] as List? ?? []) tags[name]!],
      );
      final relations = <String, dynamic>{
        ...?row['relations'] as Map<String, dynamic>?,
      };
      if (record.type.id == 'document' && row['owner'] is String) {
        final related = List<Object?>.from(relations['related'] as List? ?? []);
        if (!related.contains(row['owner'])) {
          related.add({'kind': 'information', 'id': row['owner']});
        }
        relations['related'] = related;
      }
      final definition = Map<String, Object?>.from(
        ref.kind == WorkspaceRecordKind.credential
            ? sampleCredentialDefinition
            : row['definition'] as Map? ??
                  (record.type.id == 'file'
                      ? sampleFileDefinition
                      : record.type.id == 'document'
                      ? sampleDocumentDefinition
                      : record.type.id == 'generic'
                      ? _genericDefinitionFor(row['values'] as Map? ?? {})
                      : {}),
      );
      if (row['packageId'] case final String package) {
        definition['packageId'] = package;
        definition['templateVersion'] = row['templateVersion'];
      }
      final detail = WorkspaceDetail(
        record: record,
        version: 1,
        definition: definition,
        // A credential's actual content is deliberately not a generic detail.
        values: ref.kind == WorkspaceRecordKind.credential
            ? {}
            : sampleInitialEntries(ref, definition, {
                if (record.type.id == 'document') ...{
                  'bodyFormat': 'markdown',
                  'body': sampleDocumentBodies[ref.id] ?? record.description,
                },
                ...Map<String, Object?>.from(row['values'] as Map? ?? {}),
                if (record.type.id == 'file')
                  'file': _files
                      .seed(
                        ref,
                        'file',
                        record.updatedAt,
                        row['filename'] as String? ?? record.name,
                        twoVersions: ref.id == 'resume',
                        assetId: ['resume', 'resume-en'].contains(ref.id)
                            ? 'pdf-v2'
                            : ref.id == 'portrait'
                            ? 'image'
                            : 'unknown',
                      )
                      .toJson(),
              }),
        relations: {
          for (final entry in relations.entries)
            entry.key: [
              for (final raw in entry.value as List) relationRef(raw),
            ],
        },
      );
      final destination = activeRows.contains(row) ? _initial : trashDetails;
      if (destination.containsKey(ref)) {
        throw const FormatException('Duplicate fixture identity.');
      }
      destination[ref] = sampleWithFieldIds(detail);
      if (ref.kind == WorkspaceRecordKind.credential) {
        _credentials.seed(ref, row);
      }
      _entryIdentityOwners.addAll(sampleEntryOwners(detail));
    }
    _records.addAll(_initial);
    for (final row in activeRows) {
      final ref = rowRef(row), detail = _records[ref]!;
      if (ref.kind == WorkspaceRecordKind.credential) {
        _credentialLinks.seed(
          ref,
          [
            ...?detail.relations['related']?.where(
              (r) => r.kind == WorkspaceRecordKind.information,
            ),
            if (row['owner'] is String)
              WorkspaceRecordRef(
                WorkspaceRecordKind.information,
                row['owner'] as String,
              ),
          ].where((r) => r.kind == WorkspaceRecordKind.information),
        );
      } else {
        for (final target
            in detail.relations['credentials'] ?? <WorkspaceRecordRef>[]) {
          if (target.kind == WorkspaceRecordKind.credential) {
            _credentialLinks.seed(target, [ref]);
          }
        }
      }
    }
    for (final e in _initial.entries.toList()) {
      _initial[e.key] = _records[e.key] = _rawRecord(e.value);
    }
    for (final detail in _initial.values) {
      _versions[detail.record.ref] = detail.version;
    }
    types.putIfAbsent(
      'credential',
      () => const WorkspaceType('credential', '凭据', 'key'),
    );
    _catalog = WorkspaceCatalog(
      directories: [
        for (final row in data['directories'] as List)
          WorkspaceDirectory(
            row['id'] as String,
            row['name'] as String,
            parentId: row['parent'] as String?,
          ),
      ],
      tags: tags.values,
      types: types.values,
    );
    _initialCatalog = _catalog;
    _plugins.seed(_initial.values);
    _hosts.seed();
    for (final row in trashRows) {
      final detail = trashDetails[rowRef(row)]!;
      if (detail.record.ref.kind != WorkspaceRecordKind.information ||
          _records.containsKey(detail.record.ref)) {
        throw const FormatException(
          'Recycled fixture identity must be an absent ordinary record.',
        );
      }
      final deletedAt = DateTime.parse('${row['deletedAt']}T00:00:00Z');
      final id = 'seed-recycle-${detail.record.ref.id}';
      _initialRecycled[id] = (
        entry: WorkspaceRecycleEntry(
          id: id,
          record: detail.record,
          version: detail.version + 1,
          deletedAt: deletedAt,
          expiresAt: deletedAt.add(const Duration(days: 30)),
          directoryName: _catalog.directories
              .where((d) => d.id == detail.record.directoryId)
              .firstOrNull
              ?.name,
        ),
        archive: _archive(detail, at: deletedAt),
      );
      _versions[detail.record.ref] = detail.version + 1;
    }
    _recycled.addAll(_initialRecycled);
    _approvals._seed();
  }();

  Future<void> _readable() async {
    final epoch = _epoch;
    if (_disposed) throw const WorkspaceFailure('cancelled', '预览已关闭。');
    if (_scenario == SampleWorkspaceScenario.waiting) {
      final request = Completer<void>();
      _waiting.add(request);
      await request.future;
    }
    if (_scenario == SampleWorkspaceScenario.failure) {
      throw const WorkspaceFailure('sample_unavailable', '暂时无法读取资料，请重试。');
    }
    await _ensureData();
    if (_disposed || epoch != _epoch) {
      throw const WorkspaceFailure('cancelled', '已切换预览状态。');
    }
    _expireHistory();
  }

  @override
  Future<WorkspaceSummary> loadSummary() async {
    await _readable();
    return _scenario == SampleWorkspaceScenario.empty
        ? const WorkspaceSummary.empty()
        : WorkspaceSummary(
            records: _records.length,
            pending: _approvals.pendingCount,
            proposals: _proposals.pendingCount,
          );
  }

  @override
  Future<WorkspaceCatalog> loadCatalog() async {
    await _readable();
    final records = _scenario == SampleWorkspaceScenario.empty
        ? <WorkspaceRecordSummary>[]
        : _records.values.map((d) => d.record);
    return WorkspaceCatalog(
      version: _catalogVersion,
      recycledCount: _scenario == SampleWorkspaceScenario.empty
          ? 0
          : _recycled.length,
      directories: _catalog.directories,
      tags: _catalog.tags,
      types: {
        for (final type in [..._catalog.types, ..._plugins.knownTypes])
          type.id: type,
      }.values,
      creatableTypes: {
        for (final type in [..._catalog.types, ..._plugins.knownTypes])
          if (_plugins.available(type.id)) type.id: type,
      }.values,
      directoryCounts: {
        for (final directory in _catalog.directories)
          directory.id: records
              .where((r) => _inDirectory(r.directoryId, directory.id))
              .length,
      },
      tagCounts: {
        for (final tag in _catalog.tags)
          tag.id: records
              .where((r) => r.tags.any((t) => t.id == tag.id))
              .length,
      },
    );
  }

  @override
  Future<WorkspaceDirectory?> changeDirectory(
    WorkspaceDirectoryChange change,
  ) async {
    await _readable();
    final fingerprint = _fingerprint({
      'action': change.action.name,
      'version': change.expectedVersion,
      'target': change.directoryId,
      'name': change.name,
      'parent': change.parentId,
    });
    final previous = _directoryOperations[change.operationId];
    if (previous != null) {
      if (previous.fingerprint != fingerprint) {
        throw const WorkspaceFailure('operation_conflict', '同一次操作不能用于不同目录内容。');
      }
      return previous.directory;
    }
    if (change.operationId.trim().isEmpty) {
      throw const WorkspaceFailure('validation', '目录操作身份不能为空。');
    }
    if (change.expectedVersion != _catalogVersion) {
      throw const WorkspaceFailure('conflict', '目录已变化，请重新读取后核对。');
    }
    final current = _catalog.directories
        .where((d) => d.id == change.directoryId)
        .firstOrNull;
    final creating = change.action == WorkspaceDirectoryAction.create;
    if ((!creating &&
            (current == null || ['all', 'unfiled'].contains(current.id))) ||
        (creating && change.directoryId != null)) {
      throw const WorkspaceFailure('not_found', '目录已不存在或不能修改。');
    }
    WorkspaceDirectory? result;
    if (change.action == WorkspaceDirectoryAction.delete) {
      if (_catalog.directories.any((d) => d.parentId == current!.id) ||
          (_scenario != SampleWorkspaceScenario.empty &&
              _records.values.any(
                (d) => d.record.directoryId == current!.id,
              ))) {
        throw const WorkspaceFailure(
          'directory_not_empty',
          '目录包含资料、凭据或子目录，请先移出后再删除。',
        );
      }
    } else {
      final name = change.name.trim();
      final errors = <String, String>{};
      if (name.isEmpty ||
          change.name.length > 200 ||
          name.contains('/') ||
          name.contains(r'\')) {
        errors['name'] = '请输入1–200字的目录名，不包含斜线。';
      }
      final visited = <String>{if (!creating) current!.id};
      var parent = change.parentId;
      while (parent != null) {
        final found = _catalog.directories
            .where((d) => d.id == parent && !['all', 'unfiled'].contains(d.id))
            .firstOrNull;
        if (found == null || !visited.add(parent)) {
          errors['parent'] = '请选择现存目录，不能移入自身或子目录。';
          break;
        }
        parent = found.parentId;
      }
      if (_catalog.directories.any(
        (d) =>
            d.id != current?.id &&
            d.parentId == change.parentId &&
            d.name.toLowerCase() == name.toLowerCase(),
      )) {
        errors['name'] = '此位置已有同名目录。';
      }
      if (errors.isNotEmpty) {
        throw WorkspaceFailure(
          'validation',
          '请检查标记的目录内容。',
          fieldErrors: errors,
        );
      }
      result = WorkspaceDirectory(
        creating ? 'preview-directory-${++_nextDirectory}' : current!.id,
        name,
        parentId: change.parentId,
      );
    }
    if (nextSaveFailure case final failure?) {
      nextSaveFailure = null;
      throw failure;
    }
    final directories = [..._catalog.directories];
    if (current != null) {
      final index = directories.indexWhere((d) => d.id == current.id);
      if (result == null) {
        directories.removeAt(index);
      } else {
        directories[index] = result;
      }
    } else if (result != null) {
      directories.add(result);
    }
    _catalog = WorkspaceCatalog(
      directories: directories,
      tags: _catalog.tags,
      types: _catalog.types,
    );
    _catalogVersion++;
    if (_scenario == SampleWorkspaceScenario.empty) {
      _materializeEmpty();
    }
    _directoryOperations[change.operationId] = (
      fingerprint: fingerprint,
      directory: result,
    );
    _changes.add(null);
    return result;
  }

  bool _inDirectory(String? id, String? ancestor) {
    if (ancestor == null || ancestor == 'all') return true;
    if (ancestor == 'unfiled') return id == null;
    final visited = <String>{};
    while (id != null && visited.add(id)) {
      if (id == ancestor) return true;
      final matches = _catalog.directories.where((d) => d.id == id);
      id = matches.isEmpty ? null : matches.first.parentId;
    }
    return false;
  }

  @override
  Future<Map<String, Object?>> loadTemplate(String typeId) async {
    await _readable();
    if (typeId == 'generic') return _genericDefinition;
    if (!_plugins.available(typeId)) {
      throw const WorkspaceFailure('not_found', '模板所属插件已停用或移除，请使用已有资料快照继续编辑。');
    }
    if (_plugins.template(typeId) case final template?) {
      return template.definition;
    }
    final template = _initial.values
        .where((d) => d.record.type.id == typeId)
        .firstOrNull;
    if (template == null ||
        template.record.ref.kind == WorkspaceRecordKind.credential) {
      throw const WorkspaceFailure('not_found', '资料模板不可用。');
    }
    return template.definition;
  }

  @override
  Future<WorkspaceResults> queryRecords(
    WorkspaceQuery query, {
    WorkspaceRecordRef? keepSelection,
  }) async {
    await _readable();
    if (query.offset < 0 || query.limit < 1 || query.limit > 500) {
      throw const WorkspaceFailure('invalid_query', '无效的分页范围。');
    }
    final items = _scenario == SampleWorkspaceScenario.empty
        ? <WorkspaceRecordSummary>[]
        : _records.values.map((d) => d.record).where((r) {
            return _inDirectory(r.directoryId, query.directoryId) &&
                (query.typeId == null || r.type.id == query.typeId) &&
                (query.tagId == null ||
                    r.tags.any((t) => t.id == query.tagId)) &&
                _matchesKeyword(r, query.keyword);
          }).toList();
    String group(WorkspaceRecordSummary record) => switch (query.grouping) {
      WorkspaceGrouping.none => '',
      WorkspaceGrouping.type => record.type.id,
      WorkspaceGrouping.directory => record.directoryId ?? 'unfiled',
    };
    items.sort((a, b) {
      final grouped = group(a).compareTo(group(b));
      if (grouped != 0) return grouped;
      final sorted = query.sort == WorkspaceSort.name
          ? a.name.compareTo(b.name)
          : b.updatedAt.compareTo(a.updatedAt);
      return sorted != 0 ? sorted : a.ref.key.compareTo(b.ref.key);
    });
    final counts = <String, int>{};
    for (final r in items) {
      counts.update(group(r), (count) => count + 1, ifAbsent: () => 1);
    }
    final offset = _pageOffset(query.offset, query.limit, items.length);
    final selection = items.any((r) => r.ref == keepSelection)
        ? keepSelection
        : (items.isEmpty ? null : items.skip(offset).firstOrNull?.ref);
    return WorkspaceResults(
      items: items.skip(offset).take(query.limit),
      total: items.length,
      offset: offset,
      selection: selection,
      selectionIndex: selection == null
          ? null
          : items.indexWhere((r) => r.ref == selection),
      groupCounts: counts,
    );
  }

  bool _matchesKeyword(WorkspaceRecordSummary record, String keyword) {
    final metadata =
        '${record.name} ${record.description} ${record.type.name} ${record.tags.map((t) => t.name).join(' ')}'
            .toLowerCase();
    return keyword
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .every(metadata.contains);
  }

  Map<String, Object?>? _relationRule(
    Map<String, Object?> definition,
    String key,
  ) {
    for (final rule in definition['relations'] as List? ?? []) {
      if (rule['key'] == key) return Map<String, Object?>.from(rule as Map);
    }
    return null;
  }

  bool _acceptsRelation(
    Map<String, Object?> rule,
    WorkspaceRecordSummary target,
  ) {
    final types = rule['targetTemplates'] as List? ?? [];
    return types.isEmpty || types.contains(target.type.id);
  }

  @override
  Future<WorkspaceResults> queryRelationCandidates(
    WorkspaceRelationQuery query,
  ) async {
    await _readable();
    if (query.offset < 0 || query.limit < 1 || query.limit > 500) {
      throw const WorkspaceFailure('invalid_query', '无效的关联分页范围。');
    }
    final source = query.source == null
        ? _initial.values
              .where((d) => d.record.type.id == query.typeId)
              .firstOrNull
        : _scenario == SampleWorkspaceScenario.empty
        ? null
        : _records[query.source];
    if (query.source == null && !_plugins.available(query.typeId)) {
      throw const WorkspaceFailure('not_found', '模板已停用或移除，请重新选择。');
    }
    final definition = query.source == null
        ? _plugins.template(query.typeId)?.definition ??
              (source == null ? null : workspaceEditingDefinition(source))
        : source == null
        ? null
        : workspaceEditingDefinition(source);
    if (definition == null ||
        source != null && source.record.type.id != query.typeId) {
      throw const WorkspaceFailure('not_found', '来源资料或模板已不可用。');
    }
    final sourceKind =
        source?.record.ref.kind ?? WorkspaceRecordKind.information;
    return _relationCandidates(query, definition, sourceKind);
  }

  WorkspaceResults _relationCandidates(
    WorkspaceRelationQuery query,
    Map<String, Object?> definition,
    WorkspaceRecordKind sourceKind,
  ) {
    final rule = _relationRule(definition, query.key);
    if (rule == null) {
      throw const WorkspaceFailure('unsupported', '此资料没有该关联类型。');
    }
    final candidates = _scenario == SampleWorkspaceScenario.empty
        ? <WorkspaceRecordSummary>[]
        : [
            for (final detail in _records.values)
              if (detail.record.ref != query.source &&
                  (sourceKind != WorkspaceRecordKind.credential ||
                      detail.record.ref.kind ==
                          WorkspaceRecordKind.information) &&
                  (sourceKind != WorkspaceRecordKind.information ||
                      query.key != 'credentials' ||
                      detail.record.ref.kind ==
                          WorkspaceRecordKind.credential) &&
                  _acceptsRelation(rule, detail.record) &&
                  _matchesKeyword(detail.record, query.keyword))
                detail.record,
          ];
    candidates.sort((a, b) {
      final named = a.name.compareTo(b.name);
      return named != 0 ? named : a.ref.key.compareTo(b.ref.key);
    });
    final offset = _pageOffset(query.offset, query.limit, candidates.length);
    return WorkspaceResults(
      items: candidates.skip(offset).take(query.limit),
      total: candidates.length,
      offset: offset,
    );
  }

  Map<String, String> _relationErrors(
    WorkspaceRecordRef? source,
    Map<String, Object?> definition,
    Map<String, List<WorkspaceRecordRef>> changes,
  ) {
    final errors = <String, String>{};
    for (final entry in changes.entries) {
      final rule = _relationRule(definition, entry.key);
      if (rule == null) {
        errors['relation:${entry.key}'] = '关联类型已不可用。';
      } else if (entry.value.toSet().length != entry.value.length) {
        errors['relation:${entry.key}'] = '同一种关联不能重复选择同一份资料。';
      } else if (entry.key == 'credentials' &&
          source?.kind != WorkspaceRecordKind.credential &&
          entry.value.any(
            (ref) =>
                ref.kind != WorkspaceRecordKind.credential &&
                !(_records[source]?.relations[entry.key]?.contains(ref) ??
                    false),
          )) {
        errors['relation:${entry.key}'] = '此关联只接受托管凭据。';
      } else if (entry.value.any((ref) => ref == source)) {
        errors['relation:${entry.key}'] = '不能将资料关联到自身。';
      } else if (entry.value.any(
        (ref) =>
            _records[ref] == null || _scenario == SampleWorkspaceScenario.empty,
      )) {
        errors['relation:${entry.key}'] = '关联目标已不可用，请移除后重新选择。';
      } else if (entry.value.any(
        (ref) => !_acceptsRelation(rule, _records[ref]!.record),
      )) {
        errors['relation:${entry.key}'] = '所选资料类型不符合此关联要求。';
      }
    }
    return errors;
  }

  @override
  Future<WorkspaceDetail> readDetail(WorkspaceRecordRef ref) async {
    await _readable();
    final detail = _scenario == SampleWorkspaceScenario.empty
        ? null
        : _records[ref];
    if (detail == null) {
      throw const WorkspaceFailure('not_found', '资料已不存在，请返回列表。');
    }
    return _projectRecord(detail);
  }

  @override
  Future<List<WorkspaceRecordSummary>> readSummaries(
    Iterable<WorkspaceRecordRef> refs,
  ) async {
    await _readable();
    return List.unmodifiable([
      if (_scenario != SampleWorkspaceScenario.empty)
        for (final ref in refs.toSet())
          if (_records[ref] case final detail?) detail.record,
    ]);
  }

  Map<String, String> _fieldErrors(
    String name,
    String description,
    Map<String, Object?> definition,
    Map<String, Object?> values, {
    WorkspaceDetail? current,
    bool creatingLegacy = false,
  }) {
    final fields = <String, String>{};
    if (name.trim().isEmpty || name.length > 160) {
      fields['name'] = '请输入1–160字的名称。';
    }
    if (description.length > 2000) fields['description'] = '说明不能超过2000字。';
    for (final field in definition['fields'] as List? ?? []) {
      if (['entries', 'unknown'].contains(field['type'])) continue;
      final errorKey = workspaceValueErrorKey(field['key'] as String);
      if (field['type'] == 'file') {
        if (creatingLegacy && values[field['key']] == null) continue;
        if (current == null ||
            jsonEncode(current.values[field['key']]) !=
                jsonEncode(values[field['key']])) {
          fields[errorKey] = '文件请通过导入、替换或恢复入口修改。';
        }
        continue;
      }
      if (values[field['key']] != null && values[field['key']] is! String) {
        fields[errorKey] = '此字段需要文本值，请勿用复合内容覆盖。';
        continue;
      }
      final text = values[field['key']]?.toString().trim() ?? '';
      if (field['required'] == true && text.isEmpty) {
        fields[errorKey] = '请填写${field['label']}。';
      } else if (text.isNotEmpty &&
          field['type'] == 'number' &&
          (!RegExp(r'^-?(?:0|[1-9]\d*)(?:\.\d+)?$').hasMatch(text) ||
              num.tryParse(text)?.isFinite != true)) {
        fields[errorKey] = '请输入有限的十进制数字。';
      } else if (text.isNotEmpty && field['type'] == 'date') {
        final date = DateTime.tryParse(text);
        if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text) ||
            date == null ||
            date.toIso8601String().substring(0, 10) != text) {
          fields[errorKey] = '请输入有效日期（YYYY-MM-DD）。';
        }
      }
    }
    fields.addAll(
      sampleEntryErrors(
        definition,
        values,
        current: current,
        identityOwners: _entryIdentityOwners,
        known: [
          ..._initial.values,
          for (final history in _revisions.values)
            for (final item in history) item.detail,
          for (final item in _recycled.values) item.archive.detail,
          ..._records.values,
          ?current,
        ],
      ),
    );
    for (final section in definition['sections'] as List? ?? []) {
      if (section['kind'] != 'text' || section['formatKey'] is! String) {
        continue;
      }
      final key = section['formatKey'] as String;
      if (!workspaceDocumentFormats.containsKey(values[key])) {
        fields[workspaceValueErrorKey(key)] = '请选择纯文本或Markdown。';
      }
      final body = values[section['key']];
      if (body is String && body.length > workspaceDocumentMaxLength) {
        fields[workspaceValueErrorKey(section['key'] as String)] =
            '正文不能超过100万个字符。';
      }
    }
    return fields;
  }

  @override
  Future<WorkspaceSaveResult> createRecord(WorkspaceCreate draft) async {
    try {
      await _readable();
    } on WorkspaceFailure catch (error) {
      return WorkspaceRejected(error);
    }
    final fingerprint = _fingerprint({
      'legacyTemplateId': draft.legacyTemplateId,
      'legacyTemplateVersion': draft.expectedLegacyVersion,
      'fileSelections': draft.fileSelections,
      'operation': 'create',
      'type': draft.typeId,
      'templateVersion': draft.expectedTemplateVersion,
      'templateDigest': draft.expectedTemplateDigest,
      'name': draft.name,
      'description': draft.description,
      'directory': draft.directoryId,
      'tags': draft.tagIds,
      'values': draft.values,
      'relations': {
        for (final entry in draft.relations.entries)
          entry.key: entry.value.map((r) => r.key).toList(),
      },
    });
    WorkspaceSaveResult? previousResult() {
      if (_recordOperations.containsKey(draft.operationId)) {
        return const WorkspaceRejected(
          WorkspaceFailure('operation_conflict', '同一次操作不能用于不同内容。'),
        );
      }
      final previous = _operations[draft.operationId];
      if (previous == null) return null;
      return previous.fingerprint == fingerprint
          ? previous.result
          : const WorkspaceRejected(
              WorkspaceFailure('operation_conflict', '同一次保存不能用于不同内容。'),
            );
    }

    if (previousResult() case final prior?) return prior;
    WorkspaceLegacyTemplate? legacy;
    if (draft.legacyTemplateId case final id?) {
      try {
        legacy = _legacy.current(id);
      } on WorkspaceFailure catch (e) {
        return WorkspaceRejected(e);
      }
      if (draft.typeId != 'generic') {
        return const WorkspaceRejected(
          WorkspaceFailure('unsupported', '旧版模板只用于新建通用资料。'),
        );
      }
      if (legacy.version != draft.expectedLegacyVersion) {
        return const WorkspaceRejected(
          WorkspaceFailure('conflict', '旧版模板已变化，请重新读取并核对表单。'),
        );
      }
    } else if (draft.fileSelections.isNotEmpty ||
        draft.expectedLegacyVersion != null) {
      return const WorkspaceRejected(
        WorkspaceFailure('unsupported', '此入口不接受普通附件选择或旧版模板版本。'),
      );
    }
    final legacyFiles = {
      for (final f in legacy?.definition['fields'] as List? ?? [])
        if (f['type'] == 'file') f['key'] as String,
    };
    final legacyText = {
      for (final f in legacy?.definition['fields'] as List? ?? [])
        if (f['type'] != 'file') f['key'] as String,
    };
    if (legacy != null &&
        (draft.values.length != legacyText.length ||
            !legacyText.every(draft.values.containsKey))) {
      return const WorkspaceRejected(
        WorkspaceFailure('validation', '旧版录入需要完整的文本字段对应，附件请单独选择。'),
      );
    }
    if (draft.fileSelections.keys.any((k) => !legacyFiles.contains(k)) ||
        legacyFiles.any(
          (k) =>
              !draft.fileSelections.containsKey(k) || draft.values[k] != null,
        )) {
      return const WorkspaceRejected(
        WorkspaceFailure('validation', '请通过宿主选择每个普通附件，不能用正文替代文件。'),
      );
    }
    final epoch = _epoch;
    try {
      for (final selection in draft.fileSelections.values) {
        await _files.candidate(selection);
        await _files.verifySelection(selection);
      }
    } on WorkspaceFailure catch (e) {
      return WorkspaceRejected(e);
    }
    if (_disposed || epoch != _epoch) {
      return const WorkspaceRejected(
        WorkspaceFailure('cancelled', '资料集已变化，请重新打开表单。'),
      );
    }
    // Attachment verification yields. A concurrent delivery may have committed
    // this same operation (or used its identity for another action) meanwhile.
    if (previousResult() case final prior?) return prior;
    if (legacy != null &&
        _legacy.current(legacy.id).version != legacy.version) {
      return const WorkspaceRejected(
        WorkspaceFailure('conflict', '旧版模板已变化，请重新读取并核对表单。'),
      );
    }
    final prototype = _initial.values
        .where((d) => d.record.type.id == draft.typeId)
        .firstOrNull;
    final registered = _plugins.template(draft.typeId);
    final type = registered?.type ?? prototype?.record.type;
    final definition =
        legacy?.definition ??
        (draft.typeId == 'generic'
            ? _genericDefinition
            : registered?.definition ??
                  prototype?.definition ??
                  <String, Object?>{});
    WorkspaceSaveResult result;
    final errors = _fieldErrors(
      draft.name,
      draft.description,
      definition,
      draft.values,
      creatingLegacy: legacy != null,
    );
    errors.addAll(_relationErrors(null, definition, draft.relations));
    if (!_plugins.available(draft.typeId)) {
      result = const WorkspaceRejected(
        WorkspaceFailure('template_unavailable', '所选模板已停用或移除，请重新选择；草稿仍保留。'),
      );
    } else if (registered != null &&
        (draft.expectedTemplateVersion != null &&
                draft.expectedTemplateVersion !=
                    definition['templateVersion'] ||
            draft.expectedTemplateDigest != null &&
                draft.expectedTemplateDigest != definition['packageDigest'])) {
      result = const WorkspaceRejected(
        WorkspaceFailure('conflict', '所选模板已更新，请重新读取并核对表单。'),
      );
    } else if (draft.operationId.isEmpty ||
        type == null ||
        draft.typeId == 'credential' ||
        draft.typeId == 'file') {
      result = const WorkspaceRejected(
        WorkspaceFailure('unsupported', '请选择可创建的普通资料类型。'),
      );
    } else if (errors.isNotEmpty) {
      result = WorkspaceRejected(
        WorkspaceFailure('validation', '请检查标记的字段。', fieldErrors: errors),
      );
    } else if ((draft.directoryId != null &&
            !_catalog.directories.any(
              (d) =>
                  d.id == draft.directoryId &&
                  !['all', 'unfiled'].contains(d.id),
            )) ||
        draft.tagIds.any((id) => !_catalog.tags.any((t) => t.id == id))) {
      result = const WorkspaceRejected(
        WorkspaceFailure('validation', '目录或标签引用已失效。'),
      );
    } else if (nextSaveFailure != null) {
      result = WorkspaceRejected(nextSaveFailure!);
      nextSaveFailure = null;
    } else {
      final record = WorkspaceRecordSummary(
        ref: WorkspaceRecordRef(
          WorkspaceRecordKind.information,
          'preview-record-${++_nextRecord}',
        ),
        name: draft.name.trim(),
        description: draft.description,
        type: type,
        updatedAt: DateTime.utc(
          2026,
          10,
          26,
        ).add(Duration(microseconds: _clock++)),
        directoryId: draft.directoryId,
        tags: _catalog.tags.where((t) => draft.tagIds.contains(t.id)),
      );
      final detail = WorkspaceDetail(
        record: record,
        version: 1,
        definition: definition,
        values: {
          ...draft.values,
          for (final e in draft.fileSelections.entries)
            e.key: _files
                .importFile(record.ref, e.key, e.value, record.updatedAt)
                .toJson(),
        },
        relations: draft.relations,
      );
      if (_scenario == SampleWorkspaceScenario.empty) {
        _materializeEmpty();
      }
      _versions[record.ref] = detail.version;
      _putRecord(detail);
      _entryIdentityOwners.addAll(sampleEntryOwners(detail));
      _changes.add(record.ref);
      result = WorkspaceSaved(_projectRecord(_records[record.ref]!));
    }
    _operations[draft.operationId] = (fingerprint: fingerprint, result: result);
    if (result case WorkspaceSaved(:final detail)) {
      _recordCommitted(
        draft.operationId,
        WorkspaceOperationIntent(
          kind: WorkspaceOperationKind.create,
          typeId: draft.typeId,
          legacyTemplateId: draft.legacyTemplateId,
          legacyTemplateVersion: draft.expectedLegacyVersion,
        ),
        WorkspaceRecordReceipt(ref: detail.record.ref, version: detail.version),
      );
    }
    return result;
  }

  @override
  Future<WorkspaceSaveResult> saveRecord(WorkspaceEdit edit) async {
    try {
      await _readable();
    } on WorkspaceFailure catch (failure) {
      return WorkspaceRejected(failure);
    }
    final fingerprint = _fingerprint({
      'target': edit.record.ref.key,
      'version': edit.expectedVersion,
      'name': edit.record.name,
      'description': edit.record.description,
      'type': edit.record.type.id,
      'directory': edit.record.directoryId,
      'tags': edit.record.tags.map((t) => t.id).toList(),
      'values': edit.values,
      'relations': {
        for (final entry in edit.relations.entries)
          entry.key: entry.value.map((r) => r.key).toList(),
      },
    });
    final previous = _operations[edit.operationId];
    if (_recordOperations.containsKey(edit.operationId)) {
      return const WorkspaceRejected(
        WorkspaceFailure('operation_conflict', '同一次操作不能用于不同内容。'),
      );
    }
    if (previous != null) {
      return previous.fingerprint == fingerprint
          ? previous.result
          : const WorkspaceRejected(
              WorkspaceFailure('operation_conflict', '同一次保存不能用于不同内容。'),
            );
    }
    WorkspaceSaveResult result;
    final current = _scenario == SampleWorkspaceScenario.empty
        ? null
        : _visibleRecord(edit.record.ref);
    final values = {...?current?.values, ...edit.values};
    final fields = _fieldErrors(
      edit.record.name,
      edit.record.description,
      current == null ? const {} : workspaceEditingDefinition(current),
      values,
      current: current,
    );
    fields.addAll(
      _relationErrors(
        edit.record.ref,
        current == null ? const {} : workspaceEditingDefinition(current),
        edit.relations,
      ),
    );
    if (edit.record.ref.kind == WorkspaceRecordKind.credential &&
        edit.record.name.length > 60) {
      fields['name'] = '凭据名称不能超过60字。';
    }
    if (edit.operationId.trim().isEmpty || current == null) {
      result = const WorkspaceRejected(
        WorkspaceFailure('not_found', '保存目标或操作身份无效。'),
      );
    } else if (nextSaveFailure != null) {
      result = WorkspaceRejected(nextSaveFailure!);
      nextSaveFailure = null;
    } else if (current.version != edit.expectedVersion) {
      result = const WorkspaceRejected(
        WorkspaceFailure('conflict', '资料已更新，请重新读取并核对修改。'),
      );
    } else if (edit.record.ref.kind == WorkspaceRecordKind.credential &&
        (edit.values.isNotEmpty || edit.relations.isNotEmpty)) {
      result = const WorkspaceRejected(
        WorkspaceFailure('unsupported', '凭据正文和关联不通过普通资料接口读写。'),
      );
    } else if (fields.isNotEmpty) {
      result = WorkspaceRejected(
        WorkspaceFailure('validation', '请检查标记的字段。', fieldErrors: fields),
      );
    } else if (edit.record.type.id != current.record.type.id ||
        (edit.record.directoryId != null &&
            !_catalog.directories.any(
              (d) =>
                  d.id == edit.record.directoryId &&
                  !['all', 'unfiled'].contains(d.id),
            )) ||
        edit.record.tags.any(
          (t) => !_catalog.tags.any((known) => known.id == t.id),
        )) {
      result = const WorkspaceRejected(
        WorkspaceFailure('validation', '类型、目录或标签引用已失效。'),
      );
    } else {
      final detail = WorkspaceDetail(
        record: edit.record.copyWith(
          name: edit.record.name.trim(),
          updatedAt: DateTime.utc(
            2026,
            10,
            26,
          ).add(Duration(microseconds: _clock++)),
        ),
        version: current.version + 1,
        definition: current.definition,
        fieldIds: current.fieldIds,
        retainedFields: current.retainedFields,
        retainedRelations: current.retainedRelations,
        values: values,
        relations: {...current.relations, ...edit.relations},
      );
      if (edit.record.ref.kind == WorkspaceRecordKind.information) {
        (_revisions[edit.record.ref] ??= []).add(_archive(current));
      }
      _versions[edit.record.ref] = detail.version;
      _putRecord(detail);
      _entryIdentityOwners.addAll(sampleEntryOwners(detail));
      _changes.add(edit.record.ref);
      result = WorkspaceSaved(_projectRecord(_records[edit.record.ref]!));
    }
    _operations[edit.operationId] = (fingerprint: fingerprint, result: result);
    if (result case WorkspaceSaved(
      :final detail,
    ) when detail.record.ref.kind == WorkspaceRecordKind.information) {
      _recordCommitted(
        edit.operationId,
        WorkspaceOperationIntent(
          kind: WorkspaceOperationKind.edit,
          ref: edit.record.ref,
          typeId: edit.record.type.id,
          expectedVersion: edit.expectedVersion,
        ),
        WorkspaceRecordReceipt(ref: detail.record.ref, version: detail.version),
      );
    }
    return result;
  }

  WorkspaceDetail _fileRecord(WorkspaceRecordRef ref, String key) {
    final detail = _current(ref);
    if (ref.kind != WorkspaceRecordKind.information ||
        !workspaceFields(
          detail,
        ).any((f) => f['key'] == key && f['type'] == 'file')) {
      throw const WorkspaceFailure('unsupported', '此入口只读取普通信息中的文件字段。');
    }
    return detail;
  }

  void _checkFileRead(WorkspaceDetail detail, int epoch) {
    if (_disposed ||
        epoch != _epoch ||
        _records[detail.record.ref]?.version != detail.version) {
      throw const WorkspaceFailure('cancelled', '资料已变化，请重新读取文件。');
    }
  }

  @override
  Future<WorkspaceFileHistory> loadFileHistory(
    WorkspaceRecordRef record,
    String fieldKey,
  ) async {
    await _readable();
    final epoch = _epoch, detail = _fileRecord(record, fieldKey);
    final value = await _files.history(detail, fieldKey);
    _checkFileRead(detail, epoch);
    return value;
  }

  @override
  Future<WorkspaceFilePreview> readFilePreview(
    WorkspaceRecordRef record,
    String fieldKey, {
    int? version,
    int page = 0,
  }) async {
    await _readable();
    final epoch = _epoch, detail = _fileRecord(record, fieldKey);
    if (nextFilePreviewFailure case final error?) {
      nextFilePreviewFailure = null;
      throw error;
    }
    final value = await _files.preview(
      detail,
      fieldKey,
      version: version,
      page: page,
    );
    _checkFileRead(detail, epoch);
    return value;
  }

  @override
  Future<WorkspaceRecordRef> importFile(WorkspaceFileImport input) async {
    await _readable();
    final epoch = _epoch, catalogVersion = _catalogVersion;
    final fingerprint = _fingerprint({
      'op': 'import-file',
      'selection': input.selectionId,
      'name': input.name,
      'description': input.description,
      'directory': input.directoryId,
      'tags': input.tagIds,
    });
    if (_fileOperations[input.operationId] case final previous?) {
      if (previous.fingerprint != fingerprint) {
        throw const WorkspaceFailure('operation_conflict', '同一次操作不能用于不同内容。');
      }
      return previous.record;
    }
    final errors = _fieldErrors(input.name, input.description, {}, {});
    if (input.operationId.isEmpty || errors.isNotEmpty) {
      throw WorkspaceFailure('validation', '请检查文件名称和用途。', fieldErrors: errors);
    }
    if ((input.directoryId != null &&
            !_catalog.directories.any(
              (d) =>
                  d.id == input.directoryId &&
                  !['all', 'unfiled'].contains(d.id),
            )) ||
        input.tagIds.any((id) => !_catalog.tags.any((t) => t.id == id))) {
      throw const WorkspaceFailure('validation', '目录或标签引用已失效。');
    }
    final type = _catalog.types.where((t) => t.id == 'file').firstOrNull;
    if (type == null) throw const WorkspaceFailure('unsupported', '文件类型暂不可用。');
    await _files.verifySelection(input.selectionId);
    if (_disposed || epoch != _epoch) {
      throw const WorkspaceFailure('cancelled', '预览状态已变化，请重新选择文件。');
    }
    if (_fileOperations[input.operationId] case final committed?) {
      if (committed.fingerprint != fingerprint) {
        throw const WorkspaceFailure('operation_conflict', '同一次操作不能用于不同内容。');
      }
      return committed.record;
    }
    if (_catalogVersion != catalogVersion) {
      throw const WorkspaceFailure('conflict', '分类已变化，请核对后重新导入。');
    }
    if (nextSaveFailure case final failure?) {
      nextSaveFailure = null;
      throw failure;
    }
    if (_scenario == SampleWorkspaceScenario.empty) _materializeEmpty();
    final ref = WorkspaceRecordRef(
      WorkspaceRecordKind.information,
      'preview-record-${++_nextRecord}',
    );
    final now = _now();
    final file = _files.importFile(ref, 'file', input.selectionId, now);
    final detail = WorkspaceDetail(
      record: WorkspaceRecordSummary(
        ref: ref,
        name: input.name.trim(),
        description: input.description,
        type: type,
        updatedAt: now,
        directoryId: input.directoryId,
        tags: _catalog.tags.where((t) => input.tagIds.contains(t.id)),
      ),
      version: 1,
      definition: sampleFileDefinition,
      values: {'file': file.toJson()},
      relations: {'related': []},
    );
    _putRecord(detail);
    _versions[ref] = 1;
    _fileOperations[input.operationId] = (
      fingerprint: fingerprint,
      file: file,
      record: ref,
      actionCompleted: null,
    );
    _changes.add(ref);
    return ref;
  }

  @override
  Future<WorkspaceFileRef> changeFile(WorkspaceFileChange change) async {
    await _readable();
    final epoch = _epoch;
    final fingerprint = _fingerprint({
      'op': 'file-change',
      'record': change.record.key,
      'key': change.fieldKey,
      'recordVersion': change.expectedRecordVersion,
      'fileVersion': change.expectedFileVersion,
      'kind': change.kind.name,
      'selection': change.selectionId,
      'restore': change.restoreVersion,
    });
    if (_fileOperations[change.operationId] case final previous?) {
      if (previous.fingerprint != fingerprint || previous.file == null) {
        throw const WorkspaceFailure('operation_conflict', '同一次操作不能用于不同内容。');
      }
      return previous.file!;
    }
    if (change.operationId.isEmpty) {
      throw const WorkspaceFailure('invalid_request', '操作身份无效。');
    }
    final current = _fileRecord(change.record, change.fieldKey);
    await _files.validateChange(current, change);
    final committed = epoch == _epoch && !_disposed
        ? _fileOperations[change.operationId]
        : null;
    if (committed != null) {
      if (committed.fingerprint != fingerprint || committed.file == null) {
        throw const WorkspaceFailure('operation_conflict', '同一次操作不能用于不同内容。');
      }
      return committed.file!;
    }
    _checkFileRead(current, epoch);
    if (nextSaveFailure case final failure?) {
      nextSaveFailure = null;
      throw failure;
    }
    final file = _files.next(current, change.fieldKey), now = _now();
    final detail = WorkspaceDetail(
      record: current.record.copyWith(updatedAt: now),
      version: current.version + 1,
      definition: current.definition,
      fieldIds: current.fieldIds,
      retainedFields: current.retainedFields,
      retainedRelations: current.retainedRelations,
      values: {...current.values, change.fieldKey: file.toJson()},
      relations: current.relations,
    );
    _files.commitChange(current, change, now);
    (_revisions[change.record] ??= []).add(_archive(current));
    _putRecord(detail);
    _versions[change.record] = detail.version;
    _fileOperations[change.operationId] = (
      fingerprint: fingerprint,
      file: file,
      record: change.record,
      actionCompleted: null,
    );
    _changes.add(change.record);
    return file;
  }

  @override
  Future<WorkspaceFileOperationReceipt?> fileOperationReceipt(
    String operationId,
  ) async {
    await _readable();
    final value = _fileOperations[operationId];
    return value == null
        ? null
        : WorkspaceFileOperationReceipt(
            value.record,
            value.file,
            actionCompleted: value.actionCompleted,
          );
  }

  @override
  Future<WorkspaceFileActionResult> fileAction(
    WorkspaceRecordRef record,
    String fieldKey,
    int version,
    WorkspaceFileAction action, {
    required String operationId,
  }) async {
    await _readable();
    if (operationId.isEmpty) {
      throw const WorkspaceFailure('invalid_request', '操作身份无效。');
    }
    final fingerprint = _fingerprint({
      'op': 'file-action',
      'record': record.key,
      'field': fieldKey,
      'version': version,
      'action': action.name,
    });
    final previous = _fileOperations[operationId];
    if (previous != null &&
        (previous.fingerprint != fingerprint ||
            previous.actionCompleted == null)) {
      throw const WorkspaceFailure('operation_conflict', '同一次操作不能用于不同内容。');
    }
    final epoch = _epoch, detail = _fileRecord(record, fieldKey);
    final metadata = await _files.metadata(
      record,
      fieldKey,
      WorkspaceFileRef(
        WorkspaceFileRef.fromJson(detail.values[fieldKey]).id,
        version,
      ),
    );
    _checkFileRead(detail, epoch);
    if (previous != null) {
      return WorkspaceFileActionResult(
        completed: previous.actionCompleted!,
        filename: metadata.filename,
      );
    }
    if (cancelNextFileAction) {
      cancelNextFileAction = false;
      _fileOperations[operationId] = (
        fingerprint: fingerprint,
        record: record,
        file: metadata.ref,
        actionCompleted: false,
      );
      return WorkspaceFileActionResult(
        completed: false,
        filename: metadata.filename,
      );
    }
    if (nextFileActionFailure case final error?) {
      nextFileActionFailure = null;
      throw error;
    }
    await _files.verifyVersion(detail, fieldKey, version);
    _checkFileRead(detail, epoch);
    if (_fileOperations[operationId] case final committed?) {
      if (committed.fingerprint != fingerprint ||
          committed.actionCompleted == null) {
        throw const WorkspaceFailure('operation_conflict', '同一次操作不能用于不同内容。');
      }
      return WorkspaceFileActionResult(
        completed: committed.actionCompleted!,
        filename: metadata.filename,
      );
    }
    _fileOperations[operationId] = (
      fingerprint: fingerprint,
      record: record,
      file: metadata.ref,
      actionCompleted: true,
    );
    // The fictional adapter reports its result; it never writes or launches.
    return WorkspaceFileActionResult(
      completed: true,
      filename: metadata.filename,
    );
  }

  @override
  Future<List<WorkspaceRevision>> loadRevisions(WorkspaceRecordRef ref) =>
      _loadRevisions(ref);
  @override
  Future<WorkspaceRevisionPreview> previewRevision(
    WorkspaceRecordRef ref,
    int version, {
    required int expectedVersion,
  }) => _previewRevision(ref, version, expectedVersion: expectedVersion);
  @override
  Future<WorkspaceRecycleResults> queryRecycled({
    String keyword = '',
    int offset = 0,
    int limit = 25,
  }) => _queryRecycled(keyword: keyword, offset: offset, limit: limit);
  @override
  Future<WorkspaceArchive> readRecycled(String entryId) =>
      _readRecycled(entryId);
  @override
  Future<WorkspaceRecordReceipt> changeRecord(WorkspaceRecordChange change) =>
      _changeRecord(change);

  void _materializeEmpty() {
    _basePending = _baseProposals = 0;
    _credentialLinks.clearCurrent();
    _credentials.clearCurrent();
    _approvals.reset();
    _proposals.reset();
    _hosts.clearCurrent();
    _records.clear();
    _revisions.clear();
    _recycled.clear();
    _operations.clear();
    _recordOperations.clear();
    _adoptionPlans.clear();
    _committedRecordOperations.clear();
    _fileOperations.clear();
    _scenario = SampleWorkspaceScenario.ready;
  }

  /// Composition-root-only fixture switch. All pending reads are cancelled;
  /// page code still consumes the same WorkspaceSource contract.
  Future<void> replaceFixture(String fixtureJson) async {
    setScenario(SampleWorkspaceScenario.ready);
    _fixtureJson = fixtureJson;
    _loading = null;
    _initial.clear();
    _initialRecycled.clear();
    _records.clear();
    _initialCatalog = null;
    _revisions.clear();
    _recycled.clear();
    _operations.clear();
    _recordOperations.clear();
    _adoptionPlans.clear();
    _committedRecordOperations.clear();
    loseNextRecordReply = false;
    _directoryOperations.clear();
    _versions.clear();
    _entryIdentityOwners.clear();
    _files.clear();
    _credentialLinks.clear();
    _credentials.clear();
    _approvals.reset();
    _proposals.reset();
    _plugins.clear();
    _legacy.reset();
    _hosts.clear();
    _fileOperations.clear();
    _clock = _nextRecord = _nextDirectory = _nextRecycle = 0;
    _catalogVersion++;
    nextSaveFailure = null;
    await _ensureData();
    if (!_disposed) _changes.add(null);
  }

  void reset() {
    setScenario(SampleWorkspaceScenario.ready);
    _files.reset();
    _credentialLinks.reset();
    _credentials.reset();
    _approvals.reset();
    _proposals.reset();
    _plugins.reset();
    _legacy.reset();
    _hosts.reset();
    _basePending = _initialPending;
    _baseProposals = _initialProposals;
    _fileOperations.clear();
    nextFilePreviewFailure = nextFileActionFailure = null;
    cancelNextFileAction = false;
    _entryIdentityOwners
      ..clear()
      ..addAll({
        for (final detail in [
          ..._initial.values,
          ..._initialRecycled.values.map((r) => r.archive.detail),
        ])
          ...sampleEntryOwners(detail),
      });
    _records
      ..clear()
      ..addAll(_initial);
    _operations.clear();
    _revisions.clear();
    _recycled
      ..clear()
      ..addAll(_initialRecycled);
    _recordOperations.clear();
    _adoptionPlans.clear();
    _committedRecordOperations.clear();
    loseNextRecordReply = false;
    _versions
      ..clear()
      ..addEntries(
        _initial.entries.map((e) => MapEntry(e.key, e.value.version)),
      );
    _versions.addEntries(
      _initialRecycled.values.map(
        (r) => MapEntry(r.entry.record.ref, r.entry.version),
      ),
    );
    _nextRecycle = 0;
    _directoryOperations.clear();
    if (_initialCatalog case final initial?) _catalog = initial;
    _catalogVersion++;
    nextSaveFailure = null;
    _clock = 0;
    _nextRecord = 0;
    if (_loading != null) _approvals._seed();
    if (!_disposed) _changes.add(null);
  }

  void dispose() {
    _disposed = true;
    setScenario(SampleWorkspaceScenario.ready);
    unawaited(_changes.close());
  }
}
