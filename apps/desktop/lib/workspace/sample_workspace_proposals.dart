part of 'sample_workspace_source.dart';

class _ProposalSaved {
  const _ProposalSaved(this.receipt, this.name, {this.snapshotVersion});
  final WorkspaceRecordReceipt receipt;
  final String name;
  final int? snapshotVersion;
  int get archivedVersion => snapshotVersion ?? receipt.version;
}

class _ProposalInput {
  _ProposalInput(
    this.id,
    this.title,
    this.kind,
    this.purpose,
    this.at,
    this.items, {
    this.organization,
  }) : itemCount = items.length,
       wholeDeletion =
           kind == WorkspaceProposalKind.deletion &&
           (items.firstOrNull?.changes.isEmpty ?? false),
       origin = items.firstOrNull?.before?.record.ref,
       originVersion = items.firstOrNull?.before?.version;
  final String id, title, purpose;
  final WorkspaceProposalKind kind;
  final DateTime at;
  final WorkspaceRecordRef? origin;
  final int? originVersion;
  final bool wholeDeletion;
  List<WorkspaceProposalItem> items;
  WorkspaceOrganizationReport? organization;
  List<_ProposalSaved> saved = const [];
  int version = 1, itemCount;
  WorkspaceProposalStatus status = WorkspaceProposalStatus.pending;
  bool get pending => status == WorkspaceProposalStatus.pending;
}

/// Central, resettable Owner-review fixture. A proposal has one transaction;
/// mixed queue operations do not claim a transaction spanning proposals.
class _SampleProposals
    implements WorkspaceProposalSource, WorkspaceProposalPreviewSource {
  _SampleProposals(this.s);
  final SampleWorkspaceSource s;
  final _rows = <String, _ProposalInput>{};
  final _receipts = <String, WorkspaceProposalReceipt>{};
  final _organizationUnobserved = <String, WorkspaceOrganizationReport>{};
  final _inFlight =
      <String, ({String digest, Future<WorkspaceProposalReceipt> future})>{};
  bool _seeded = false, loseNextReply = false;
  String? loseReplyFor;
  int _generation = 0;
  Future<void>? _organizationDemo;
  Future<void> demonstrateOrganization(WorkspaceOrganizationOutcome outcome) {
    if (_organizationDemo case final pending?) return pending;
    final active = _demonstrateOrganization(outcome);
    _organizationDemo = active;
    return active.whenComplete(() {
      if (identical(_organizationDemo, active)) _organizationDemo = null;
    });
  }

  void reset() {
    _generation++;
    _seeded = false;
    _rows.clear();
    _receipts.clear();
    _organizationUnobserved.clear();
    _organizationDemo = null;
    _inFlight.clear();
    loseNextReply = false;
    loseReplyFor = null;
  }

  WorkspaceRecordRef info(String id) =>
      WorkspaceRecordRef(WorkspaceRecordKind.information, id);
  void _seed() {
    if (_seeded) return;
    _seeded = true;
    if (s._baseProposals == 0) return;
    final service = s._initial[info('blinko')];
    if (service != null) {
      WorkspaceProposalItem item(
        String id,
        String name,
        String url,
        String purpose,
      ) => WorkspaceProposalItem(
        id: id,
        proposed: WorkspaceDetail(
          record: WorkspaceRecordSummary(
            ref: info('proposal-draft:import:$id'),
            name: name,
            description: purpose,
            type: service.record.type,
            updatedAt: s._now(),
            directoryId: service.record.directoryId,
            tags: s._catalog.tags.where(
              (t) => ['公网入口', '生产环境'].contains(t.name),
            ),
          ),
          version: 0,
          definition: service.definition,
          values: {'url': url, 'purpose': purpose, 'auth': '由各应用单独管理'},
          relations: {
            if (s._initial.containsKey(info('nas')))
              'hostedOn': [info('nas')],
          },
        ),
      );
      _rows['import'] = _ProposalInput(
        'import',
        'NAS 相关应用信息新增',
        WorkspaceProposalKind.addition,
        '将维护文档中独立的入口信息整理为资料，关联已有服务器。',
        s._now().subtract(const Duration(minutes: 1)),
        [
          item(
            'portal',
            '北辰服务入口',
            'https://portal.beichen.example',
            '集中访问自托管服务',
          ),
          item(
            'status',
            '北辰服务状态',
            'https://status.beichen.example',
            '查看自托管服务状态',
          ),
        ],
      );
    }
    final target = s._initial[info('aliyun')];
    if (s._baseProposals > 1 && target?.fieldIds['port'] != null) {
      _rows['update'] = _ProposalInput(
        'update',
        '更新杭州服务器连接说明',
        WorkspaceProposalKind.modification,
        'SSH 端口已调整，同步连接字段；保留已有凭据与维护文档。',
        s._now().subtract(const Duration(minutes: 2)),
        [
          WorkspaceProposalItem(
            id: 'server-port',
            before: target,
            proposed: WorkspaceDetail(
              record: target!.record,
              version: target.version,
              definition: target.definition,
              fieldIds: target.fieldIds,
              fieldOverrides: target.fieldOverrides,
              retainedFields: target.retainedFields,
              retainedRelations: target.retainedRelations,
              values: const {'port': '2222'},
            ),
            changes: [
              WorkspaceProposalFieldChange(
                intent: WorkspaceProposalFieldIntent.correct,
                key: 'port',
                label: 'SSH 端口',
                fieldId: target.fieldIds['port'],
                after: '2222',
              ),
            ],
          ).withoutOwnerBefore(),
        ],
      );
    }
  }

  int get pendingCount {
    _seed();
    return _rows.values.where((r) => r.pending).length;
  }

  void demonstrateDeletion() {
    _seed();
    if (_rows.containsKey('delete-service')) return;
    final target = s._records[info('blinko')];
    if (target == null) return;
    final metadata = WorkspaceDetail(
      record: target.record,
      version: target.version,
      definition: target.definition,
      fieldIds: target.fieldIds,
      fieldOverrides: target.fieldOverrides,
      retainedFields: target.retainedFields,
      retainedRelations: target.retainedRelations,
    );
    _rows['delete-service'] = _ProposalInput(
      'delete-service',
      '删除停用的 Blinko 资料',
      WorkspaceProposalKind.deletion,
      '此示例服务已停用，申请将整条资料移入回收站。',
      s._now(),
      [
        WorkspaceProposalItem(
          id: 'service',
          before: metadata,
          proposed: metadata,
        ),
      ],
    );
    s._changes.add(null);
  }

  _ProposalInput _row(String id) {
    _seed();
    if (s._scenario == SampleWorkspaceScenario.empty ||
        !_rows.containsKey(id)) {
      throw const WorkspaceFailure('not_found', '原提案已不可用。');
    }
    return _rows[id]!;
  }

  WorkspaceProposalStatus _status(_ProposalInput r) =>
      r.pending &&
          (r.organization?.legacyReview == true
              ? r.organization!.members.any(
                  (m) => s._records[m.record]?.version != m.baseVersion,
                )
              : r.origin != null &&
                    s._records[r.origin]?.version != r.originVersion)
      ? WorkspaceProposalStatus.conflicted
      : r.status;
  WorkspaceProposalSummary _summary(_ProposalInput r) =>
      WorkspaceProposalSummary(
        id: r.id,
        title: r.title,
        kind: r.kind,
        status: _status(r),
        pending: r.pending,
        version: r.version,
        at: r.at,
        agentClaim: 'Codex',
        chatClaim: '当前维护会话',
        purpose: r.purpose,
        itemCount: r.itemCount,
        wholeDeletion: r.wholeDeletion,
        organizationOutcome: _status(r) == WorkspaceProposalStatus.conflicted
            ? WorkspaceOrganizationOutcome.conflicted
            : r.organization?.outcome,
      );
  String _token(_ProposalInput r) => s._fingerprint([
    s._epoch,
    _generation,
    r.id,
    r.version,
    s._catalogVersion,
    r.organization?.toJson(),
    if (r.organization?.legacyReview == true)
      for (final m in r.organization!.members)
        [m.record.key, s._records[m.record]?.version],
    if (r.origin != null) [r.origin!.key, s._records[r.origin]?.version],
    for (final item in r.items)
      for (final ref in item.proposed.relations.values.expand((x) => x))
        [ref.key, s._records[ref]?.version],
  ]);
  @override
  Future<WorkspaceProposalResults> query(
    WorkspaceProposalQuery q, {
    String? keepSelection,
  }) async {
    await s._readable();
    _seed();
    if (q.keyword.length > 2000 ||
        q.offset < 0 ||
        q.offset > 1000000 ||
        q.limit < 1 ||
        q.limit > 100) {
      throw const WorkspaceFailure('invalid_query', '请核对提案查询条件。');
    }
    final all = s._scenario == SampleWorkspaceScenario.empty
        ? <_ProposalInput>[]
        : _rows.values.toList();
    final rows =
        all
            .where(
              (r) =>
                  (q.filter == WorkspaceProposalFilter.all ||
                      (q.filter == WorkspaceProposalFilter.pending) ==
                          r.pending) &&
                  (q.kind == null || q.kind == r.kind) &&
                  '${r.title} ${r.purpose} Codex 当前维护会话 ${r.kind.label}'
                      .toLowerCase()
                      .contains(q.keyword.trim().toLowerCase()),
            )
            .toList()
          ..sort((a, b) {
            final t = b.at.compareTo(a.at);
            return t != 0 ? t : a.id.compareTo(b.id);
          });
    final offset = rows.isEmpty
        ? 0
        : q.offset.clamp(0, (rows.length - 1) ~/ q.limit * q.limit);
    final selection = rows.any((r) => r.id == keepSelection)
        ? keepSelection
        : rows.skip(offset).firstOrNull?.id;
    return WorkspaceProposalResults(
      items: rows.skip(offset).take(q.limit).map(_summary),
      total: rows.length,
      pending: all.where((r) => r.pending).length,
      offset: offset,
      selection: selection,
      selectionIndex: selection == null
          ? null
          : rows.indexWhere((r) => r.id == selection),
    );
  }

  WorkspaceProposalItem _project(
    WorkspaceProposalItem item, {
    bool wholeDeletion = false,
  }) {
    final d = item.proposed;
    final state = d.definition['packageId'] is String
        ? s._plugins.stateFor(
            d.record.type.id,
            d.definition['packageId'] as String,
          )
        : WorkspaceTemplateState.available;
    final original = item.before;
    final archive = original == null
        ? null
        : s._grantHistory.archive(original.record.ref, original.version);
    bool available(WorkspaceProposalFieldChange c) =>
        archive != null &&
        c.fieldId != null &&
        workspaceProposalFieldId(archive.detail, c) == c.fieldId;
    return WorkspaceProposalItem(
      id: item.id,
      beforeState: archive == null
          ? WorkspaceProposalBeforeState.unavailable
          : WorkspaceProposalBeforeState.available,
      before: original == null
          ? null
          : WorkspaceDetail(
              record: original.record,
              version: original.version,
              definition: original.definition,
              fieldIds: original.fieldIds,
              fieldOverrides: original.fieldOverrides,
              retainedFields: original.retainedFields,
              retainedRelations: original.retainedRelations,
              values: archive?.detail.values ?? const {},
              relations: archive?.detail.relations ?? const {},
            ),
      changes: item.changes.map(
        (c) => c.withOwnerBefore(
          available(c) ? workspaceProposalFieldValue(archive!.detail, c) : null,
          available: available(c),
        ),
      ),
      proposed: WorkspaceDetail(
        record: d.record,
        version: d.version,
        templateState: state,
        definition: d.definition,
        values: d.values,
        relations: d.relations,
        fieldIds: d.fieldIds,
        fieldOverrides: d.fieldOverrides,
        retainedFields: d.retainedFields,
        retainedRelations: d.retainedRelations,
      ),
    );
  }

  @override
  Future<WorkspaceProposalDetail> read(String id) async {
    await s._readable();
    final r = _row(id);
    return WorkspaceProposalDetail(
      summary: _summary(r),
      reviewToken: _token(r),
      currentTargetRef: r.origin,
      currentAvailable: r.origin != null && s._records.containsKey(r.origin),
      organization: r.organization?.project(
        members: r.organization!.members.map(
          (m) => m.project(
            exists: s._records.containsKey(m.record),
            clearResult:
                r.organization?.outcome == WorkspaceOrganizationOutcome.unknown,
          ),
        ),
      ),
      items: r.kind == WorkspaceProposalKind.organization
          ? r.items
          : r.items.map((i) => _project(i, wholeDeletion: r.wholeDeletion)),
      targets: [
        for (final saved in r.saved)
          WorkspaceProposalTarget(
            record: saved.receipt.ref,
            name: saved.name,
            version: saved.archivedVersion,
            exists: s._records.containsKey(saved.receipt.ref),
            snapshotAvailable:
                s._grantHistory.archive(
                  saved.receipt.ref,
                  saved.archivedVersion,
                ) !=
                null,
          ),
      ],
      notice: _status(r) == WorkspaceProposalStatus.conflicted
          ? '当前资料已变化；原提案与审阅仍保留，不能覆盖新版本。请核对并让 Agent 按当前版本重新提交。'
          : null,
    );
  }

  @override
  WorkspaceRelationSource relations(
    String proposalId,
    String itemId,
    int version,
  ) => _ProposalRelations(
    this,
    proposalId,
    itemId,
    version,
    _generation,
    s._epoch,
  );
  @override
  Future<WorkspaceCatalog> catalog() => s.loadCatalog();
  bool _same(Object? a, Object? b) => _json(a) == _json(b);
  String _json(Object? value) {
    Object? normalize(Object? x) {
      if (x is Map) {
        final keys = x.keys.cast<String>().toList()..sort();
        return {for (final k in keys) k: normalize(x[k])};
      }
      if (x is Iterable) return x.map(normalize).toList();
      return x;
    }

    return jsonEncode(normalize(value));
  }

  Map<String, List<String>> _relationKeys(
    Map<String, List<WorkspaceRecordRef>> links,
  ) => {
    for (final e in links.entries) e.key: e.value.map((r) => r.key).toList(),
  };
  void _validate(
    _ProposalInput r,
    WorkspaceProposalItem item,
    WorkspaceProposalItemReview review,
  ) {
    if (r.kind == WorkspaceProposalKind.deletion) {
      if (!_same(
        review.toJson(),
        WorkspaceProposalItemReview.fromItem(item).toJson(),
      )) {
        throw const WorkspaceFailure('validation', '删除提案只能核对原范围，不能夹带资料编辑。');
      }
      return;
    }
    if (r.kind == WorkspaceProposalKind.modification) return;
    final d = item.proposed;
    final keys = {
      ...d.values.keys,
      ...workspaceFields(d).map((f) => f['key'] as String),
    };
    if (review.values.keys.any((k) => !keys.contains(k))) {
      throw const WorkspaceFailure('validation', '不能向提案加入未审阅的字段。');
    }
    if (workspaceFields(d).any((f) => f['type'] == 'file') &&
        item.before == null) {
      throw const WorkspaceFailure('unsupported', '普通附件需要通过资料库的文件导入流程处理。');
    }
    if (review.tagIds.length > 100 ||
        review.values.values.any((v) => v is String && v.length > 64000)) {
      throw const WorkspaceFailure('validation', '提案字段或分类超出当前审阅预算。');
    }
    for (final field in workspaceFields(
      d,
    ).where((f) => f['type'] == 'unknown')) {
      if (!_same(review.values[field['key']], d.values[field['key']])) {
        throw const WorkspaceFailure('unsupported', '未知结构只读保留，不能按当前模板重新解释。');
      }
    }
    final current = item.before == null
        ? null
        : s._records[item.before!.record.ref];
    final validationValues = current == null
        ? review.values
        : {...current.values, ...review.values};
    final errors = s._fieldErrors(
      review.name,
      review.description,
      workspaceEditingDefinition(d),
      validationValues,
      current: current,
    );
    errors.addAll(
      s._relationErrors(
        item.before?.record.ref,
        workspaceEditingDefinition(d),
        review.relations,
      ),
    );
    if ((review.directoryId != null &&
            !s._catalog.directories.any(
              (x) =>
                  x.id == review.directoryId &&
                  !['all', 'unfiled'].contains(x.id),
            )) ||
        review.tagIds.toSet().length != review.tagIds.length ||
        review.tagIds.any((id) => !s._catalog.tags.any((t) => t.id == id))) {
      errors['classification'] = '目录或标签已变化，请重新核对。';
    }
    if (item.before case final before?) {
      final editable = item.changes.map((c) => c.key).toSet();
      if (review.name != before.record.name ||
          review.description != before.record.description ||
          review.directoryId != before.record.directoryId ||
          !_same(review.tagIds, before.record.tags.map((t) => t.id).toList()) ||
          !_same(
            _relationKeys(review.relations),
            _relationKeys(before.relations),
          ) ||
          (review.values.keys.toSet().length != editable.length ||
              !review.values.keys.every(editable.contains))) {
        throw const WorkspaceFailure(
          'validation',
          '只会修改本提案明确列出的字段，其他资料保持当前内容。',
        );
      }
      for (final change in item.changes) {
        if (change.intent != WorkspaceProposalFieldIntent.correct ||
            change.entryId != null) {
          throw const WorkspaceFailure('unsupported', '请按明确的字段意图核对该变更。');
        }
        if (before.fieldIds[change.key] != change.fieldId) {
          throw const WorkspaceFailure('conflict', '原字段身份已变化，不能按同名字段覆盖。');
        }
      }
    }
    if (errors.isNotEmpty) {
      throw WorkspaceFailure(
        'validation',
        '请检查标记的资料与字段。',
        fieldErrors: {
          for (final e in errors.entries) 'item:${item.id}:${e.key}': e.value,
        },
      );
    }
  }

  @override
  Future<WorkspaceProposalReceipt> change(WorkspaceProposalChange c) {
    if (_inFlight[c.operationId] case final active?) {
      return active.digest == c.digest
          ? active.future
          : Future.error(
              const WorkspaceFailure('operation_conflict', '同一次操作不能用于不同提案或内容。'),
            );
    }
    final future = _change(c);
    final active = (digest: c.digest, future: future);
    _inFlight[c.operationId] = active;
    return future.whenComplete(() {
      if (identical(_inFlight[c.operationId]?.future, future)) {
        _inFlight.remove(c.operationId);
      }
    });
  }

  Future<WorkspaceProposalReceipt> _change(WorkspaceProposalChange c) async {
    await s._readable();
    final epoch = s._epoch, generation = _generation;
    if (c.operationId.isEmpty || c.operationId.length > 200) {
      throw const WorkspaceFailure('validation', '操作身份无效。');
    }
    if (_receipts[c.operationId] case final previous?) {
      if (previous.commandDigest != c.digest) {
        throw const WorkspaceFailure('operation_conflict', '同一次操作不能用于不同提案或内容。');
      }
      return previous;
    }
    final r = _row(c.proposalId);
    if (!r.pending || r.version != c.version || _token(r) != c.reviewToken) {
      throw const WorkspaceFailure('conflict', '提案、资料或分类已变化，请重新读取并核对。');
    }
    if (c.action == WorkspaceProposalAction.reject && c.reviewed.isNotEmpty) {
      throw const WorkspaceFailure('validation', '拒绝提案不提交资料内容。');
    }
    if (r.kind == WorkspaceProposalKind.organization) {
      return _changeLegacyOrganization(r, c);
    }
    final saved = <_ProposalSaved>[];
    if (c.action == WorkspaceProposalAction.confirm) {
      if (_status(r) != WorkspaceProposalStatus.pending) {
        throw const WorkspaceFailure('conflict', '资料版本已变化，不能用旧提案覆盖。');
      }
      if (r.kind == WorkspaceProposalKind.addition &&
          c.reviewed.length != r.items.length) {
        throw const WorkspaceFailure(
          'proposal_incomplete',
          '请核对整份提案后保存，不能只保存其中部分条目。',
        );
      }
      if (c.reviewed.isEmpty ||
          c.reviewed.length > 20 ||
          c.reviewed.map((i) => i.itemId).toSet().length != c.reviewed.length ||
          c.reviewed.any((i) => !r.items.any((x) => x.id == i.itemId)) ||
          r.kind != WorkspaceProposalKind.addition && c.reviewed.length != 1) {
        throw const WorkspaceFailure('validation', '请明确选择1–20份属于本提案的资料。');
      }
      if (r.kind == WorkspaceProposalKind.addition) {
        var totalFields = 0;
        for (final review in c.reviewed) {
          final d = r.items.singleWhere((i) => i.id == review.itemId).proposed;
          var fields = 0;
          for (final field in workspaceFields(d)) {
            if (field['type'] == 'entries') {
              late final List<WorkspaceRepeatedEntry> entries;
              try {
                entries = WorkspaceRepeatedEntry.read(
                  review.values[field['key']],
                );
              } on FormatException {
                throw const WorkspaceFailure('validation', '经历结构无效，请检查原提案。');
              }
              if (entries.any(
                (e) => e.toJson().entries.any(
                  (p) =>
                      WorkspaceRepeatedEntry.parts.contains(p.key) &&
                      (p.value as String).length > 64000,
                ),
              )) {
                throw const WorkspaceFailure('validation', '经历字段超出当前提案预算。');
              }
              fields += entries.fold(0, (sum, e) => sum + e.fieldIds.length);
            } else {
              fields++;
            }
          }
          if (fields == 0 || fields > 50) {
            throw const WorkspaceFailure(
              'validation',
              '单份新增提案需包含1–50个字段；经历按叶字段计数。',
            );
          }
          totalFields += fields;
        }
        if (totalFields > 200 ||
            utf8
                    .encode(
                      jsonEncode(c.reviewed.map((i) => i.toJson()).toList()),
                    )
                    .length >
                240000) {
          throw const WorkspaceFailure(
            'validation',
            '单次新增提案超出200个字段或240000字节的预算。',
          );
        }
      }
      for (final review in c.reviewed) {
        _validate(r, r.items.singleWhere((i) => i.id == review.itemId), review);
      }
      if (r.kind == WorkspaceProposalKind.addition) {
        // Prepare and validate every record before the first mutation. There
        // are no awaits between this point, all records, and the receipt.
        final prepared = <WorkspaceDetail>[];
        final owners = <String, String>{};
        for (final (index, review) in c.reviewed.indexed) {
          final item = r.items.singleWhere((i) => i.id == review.itemId),
              stamp = s._now().add(Duration(microseconds: s._clock + index));
          final ref = info('preview-record-${s._nextRecord + index + 1}');
          final detail = sampleWithFieldIds(
            WorkspaceDetail(
              record: WorkspaceRecordSummary(
                ref: ref,
                name: review.name.trim(),
                description: review.description,
                type: item.proposed.record.type,
                updatedAt: stamp,
                directoryId: review.directoryId,
                tags: s._catalog.tags.where(
                  (t) => review.tagIds.contains(t.id),
                ),
              ),
              version: 1,
              definition: item.proposed.definition,
              values: review.values,
              relations: review.relations,
            ),
          );
          for (final e in sampleEntryOwners(detail).entries) {
            if (owners.containsKey(e.key) ||
                s._entryIdentityOwners.containsKey(e.key)) {
              throw const WorkspaceFailure('validation', '新增经历必须使用独立的新身份。');
            }
            owners[e.key] = e.value;
          }
          prepared.add(detail);
        }
        if (s.nextSaveFailure case final failure?) {
          s.nextSaveFailure = null;
          throw failure;
        }
        for (final d in prepared) {
          s._putRecord(d);
          saved.add(
            _ProposalSaved(
              WorkspaceRecordReceipt(ref: d.record.ref, version: d.version),
              d.record.name,
            ),
          );
        }
        s._entryIdentityOwners.addAll(owners);
        s._clock += prepared.length;
        s._nextRecord += prepared.length;
      } else if (r.kind == WorkspaceProposalKind.modification ||
          r.kind == WorkspaceProposalKind.deletion && !r.wholeDeletion) {
        final plan = _fieldPlan(
          r.items.single,
          c.reviewed.single,
          c.operationId,
        );
        final receipt = _commitFieldPlan(plan);
        saved.add(
          _ProposalSaved(
            receipt,
            plan.result.record.name,
            snapshotVersion: r.kind == WorkspaceProposalKind.deletion
                ? plan.current.version
                : null,
          ),
        );
      } else if (r.kind == WorkspaceProposalKind.deletion) {
        final before = r.items.single.before!;
        final receipt = await s.changeRecord(
          WorkspaceRecordChange(
            operationId: 'proposal:${c.operationId}',
            ref: before.record.ref,
            expectedVersion: before.version,
            action: WorkspaceRecordAction.recycle,
          ),
        );
        saved.add(
          _ProposalSaved(
            receipt,
            before.record.name,
            snapshotVersion: before.version,
          ),
        );
      } else {
        throw const WorkspaceFailure('unsupported', '该类提案尚不可通过此决定处理。');
      }
    } else if (s.nextSaveFailure case final failure?) {
      s.nextSaveFailure = null;
      throw failure;
    }
    if (s._disposed || epoch != s._epoch || generation != _generation) {
      throw const WorkspaceFailure('cancelled', '资料集已变化，不能恢复旧提案结果。');
    }
    r.status = c.action == WorkspaceProposalAction.confirm
        ? WorkspaceProposalStatus.completed
        : WorkspaceProposalStatus.rejected;
    r.version++;
    r.saved = List.unmodifiable(saved);
    if (c.action == WorkspaceProposalAction.confirm) {
      r.itemCount = c.reviewed.length;
    }
    r.items =
        const []; // Terminal rows and receipts never retain submitted bodies.
    final receipt = WorkspaceProposalReceipt(
      operationId: c.operationId,
      proposalId: c.proposalId,
      action: c.action,
      reviewToken: c.reviewToken,
      reviewedVersion: c.version,
      resultingVersion: r.version,
      commandDigest: c.digest,
      records: saved.map((x) => x.receipt),
    );
    _receipts[c.operationId] = receipt;
    s._changes.add(null);
    if (loseNextReply || loseReplyFor == c.proposalId) {
      loseNextReply = false;
      loseReplyFor = null;
      throw const WorkspaceFailure('unknown_outcome', '提案处理结果暂时未知，请先核对本次操作。');
    }
    return receipt;
  }

  @override
  Future<WorkspaceProposalReceipt?> receipt(String operationId) async {
    if (_inFlight.containsKey(operationId)) {
      throw const WorkspaceFailure('unknown_outcome', '本次操作仍在处理中，请稍后核对。');
    }
    await s._readable();
    if (_inFlight.containsKey(operationId)) {
      throw const WorkspaceFailure('unknown_outcome', '本次操作仍在处理中，请稍后核对。');
    }
    return _receipts[operationId];
  }

  @override
  Future<WorkspaceArchive> snapshot(
    String proposalId,
    WorkspaceRecordRef record,
  ) async {
    final epoch = s._epoch;
    await s._readable();
    final r = _row(proposalId);
    if (epoch != s._epoch || s._disposed) {
      throw const WorkspaceFailure('cancelled', '资料集已变化，请重新读取。');
    }
    final saved = r.saved.where((x) => x.receipt.ref == record).firstOrNull;
    if (saved == null || record.kind != WorkspaceRecordKind.information) {
      throw const WorkspaceFailure('unsupported', '没有属于本提案的普通资料结果。');
    }
    return s._grantHistory.archive(record, saved.archivedVersion) ??
        (throw const WorkspaceFailure(
          'history_unavailable',
          '当时保存的资料快照已不可用，不会替换成当前或同名内容。',
        ));
  }

  @override
  WorkspaceRelationSource previewRelations() => s;
  @override
  Future<WorkspaceProposalItem> previewRelated(
    String proposalId,
    int version,
    WorkspaceRecordRef record, {
    WorkspaceProposalItemReview? review,
  }) async {
    final proposal = await read(proposalId);
    final reviewedRef =
        review != null &&
        proposal.items.any((i) => i.id == review.itemId) &&
        review.relations.values.expand((refs) => refs).contains(record);
    if (proposal.summary.version != version ||
        !reviewedRef &&
            !proposal.items.any(
              (i) => i.proposed.visibleRelations.values
                  .expand((refs) => refs)
                  .contains(record),
            )) {
      throw const WorkspaceFailure('conflict', '关联范围已变化，请重新读取。');
    }
    return WorkspaceProposalItem(
      id: record.key,
      proposed: await s.readDetail(record),
    );
  }

  @override
  Future<WorkspaceProposalItem> savedPreview(
    String proposalId,
    WorkspaceRecordRef record,
  ) async {
    final archive = await snapshot(proposalId, record);
    final proposal = await read(proposalId);
    final before = proposal.summary.kind == WorkspaceProposalKind.modification
        ? s._grantHistory.archive(record, archive.detail.version - 1)?.detail
        : null;
    return WorkspaceProposalItem(
      id: record.key,
      proposed: archive.detail,
      before: before,
      beforeState: before == null
          ? WorkspaceProposalBeforeState.unavailable
          : WorkspaceProposalBeforeState.available,
    );
  }

  @override
  Future<WorkspaceDetail> currentTarget(String proposalId) async {
    await s._readable();
    final r = _row(proposalId), target = s._records[r.origin];
    if (r.origin == null ||
        target == null ||
        target.record.ref.kind != WorkspaceRecordKind.information) {
      throw const WorkspaceFailure('not_found', '当前普通资料已不可用。');
    }
    return s._projectRecord(target);
  }
}

class _ProposalRelations implements WorkspaceRelationSource {
  const _ProposalRelations(
    this.p,
    this.proposalId,
    this.itemId,
    this.version,
    this.generation,
    this.epoch,
  );
  final _SampleProposals p;
  final String proposalId, itemId;
  final int version, generation, epoch;
  WorkspaceProposalItem _item() {
    final r = p._row(proposalId);
    if (epoch != p.s._epoch ||
        generation != p._generation ||
        !r.pending ||
        r.version != version) {
      throw const WorkspaceFailure('conflict', '提案已变化，请重新打开审阅。');
    }
    return r.items.where((i) => i.id == itemId).firstOrNull ??
        (throw const WorkspaceFailure('not_found', '原提案资料已不可用。'));
  }

  @override
  Future<List<WorkspaceRecordSummary>> readSummaries(
    Iterable<WorkspaceRecordRef> refs,
  ) async {
    await p.s._readable();
    _item();
    return p.s.readSummaries(refs);
  }

  @override
  Future<WorkspaceResults> queryRelationCandidates(
    WorkspaceRelationQuery q,
  ) async {
    await p.s._readable();
    final item = _item();
    if (q.typeId != item.proposed.record.type.id ||
        q.source != item.before?.record.ref ||
        q.keyword.length > 2000 ||
        q.offset < 0 ||
        q.limit < 1 ||
        q.limit > 500) {
      throw const WorkspaceFailure('invalid_query', '请核对提案关联查询条件。');
    }
    return p.s._relationCandidates(
      q,
      workspaceEditingDefinition(item.proposed),
      WorkspaceRecordKind.information,
    );
  }
}
