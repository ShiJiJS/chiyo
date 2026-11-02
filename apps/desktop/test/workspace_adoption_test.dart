import 'dart:io';
import 'package:info_desktop/workspace/record_mutation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_entries.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

Future<void> installDomain(SampleWorkspaceSource s) async {
  final choices = await s.pluginChoices();
  final c = choices.firstWhere((c) => c.filename == '域名管理-1.0.0.json');
  final p = await s.plugins.previewInstall(c.selectionId);
  await s.plugins.change(
    WorkspacePluginChange(
      operationId: workspaceOperationId(),
      action: WorkspacePluginAction.install,
      packageId: p.package.id,
      expectedVersion: p.catalogVersion,
      selectionId: c.selectionId,
      expectedDigest: p.package.digest,
    ),
  );
  for (final choice in choices) {
    await s.plugins.releaseCandidate(choice.selectionId);
  }
}

Future<WorkspaceDetail> generic(
  SampleWorkspaceSource s, {
  Map<String, Object?>? values,
}) async =>
    (await s.createRecord(
              WorkspaceCreate(
                operationId: workspaceOperationId(),
                typeId: 'generic',
                name: '原始域名资料',
                directoryId: (await s.loadCatalog()).directories
                    .firstWhere((d) => !['all', 'unfiled'].contains(d.id))
                    .id,
                values:
                    values ?? {'body': 'old.example', 'domain': '原来同名但不同含义的内容'},
              ),
            )
            as WorkspaceSaved)
        .detail;

WorkspaceAdoptionDraft domain(WorkspaceDetail d, {bool same = true}) =>
    WorkspaceAdoptionDraft(
      ref: d.record.ref,
      typeId: 'local.domain/domain',
      fields: {
        'domain': WorkspaceFieldMapping(sourceKey: 'body', sameMeaning: same),
      },
    );

class _WrongAdoptionReceipt extends SampleWorkspaceSource {
  WorkspaceOperationReceipt? wrong;
  @override
  Future<WorkspaceOperationReceipt?> recordOperationReceipt(String id) async =>
      wrong ?? await super.recordOperationReceipt(id);
}

void main() {
  Matcher failure(String code) =>
      isA<WorkspaceFailure>().having((e) => e.code, 'code', code);
  test(
    'same-template suggestions copy values but preserve identities only after explicit meaning confirmation',
    () async {
      final s = SampleWorkspaceSource();
      addTearDown(s.dispose);
      await installDomain(s);
      final original = await generic(s);
      final first = await s.previewAdoption(domain(original));
      final applied = await s.applyAdoption('initial-adoption', first.planId);
      final current = await s.readDetail(applied.ref);
      final target = (await s.plugins.load()).packages
          .expand((p) => p.templates)
          .singleWhere((t) => t.type.id == current.record.type.id);
      final suggested = workspaceSuggestedAdoptionMappings(current, target);
      expect(suggested['domain']!.sourceKey, 'domain');
      expect(suggested['domain']!.sameMeaning, isFalse);
      final copy = await s.previewAdoption(
        WorkspaceAdoptionDraft(
          ref: current.record.ref,
          typeId: target.type.id,
          fields: suggested,
        ),
      );
      expect(copy.result.values['domain'], current.values['domain']);
      expect(copy.result.fieldIds['domain'], isNot(current.fieldIds['domain']));
      final confirmed = await s.previewAdoption(
        WorkspaceAdoptionDraft(
          ref: current.record.ref,
          typeId: target.type.id,
          fields: {
            ...suggested,
            'domain': const WorkspaceFieldMapping(
              sourceKey: 'domain',
              sameMeaning: true,
            ),
          },
        ),
      );
      expect(confirmed.result.fieldIds['domain'], current.fieldIds['domain']);
      expect(workspaceSuggestedAdoptionMappings(original, target), isEmpty);
      final foreign = WorkspacePluginTemplate(
        id: target.id,
        type: target.type,
        definition: {...target.definition, 'packageId': 'another.package'},
      );
      expect(workspaceSuggestedAdoptionMappings(current, foreign), isEmpty);
    },
  );
  test(
    'adoption preview preserves source and exact target snapshot, distinguishes same-meaning identity from same-named retained content',
    () async {
      final s = SampleWorkspaceSource();
      addTearDown(s.dispose);
      await installDomain(s);
      final old = await generic(s), p = await s.previewAdoption(domain(old));
      expect(p.canApply, true, reason: p.errors.toString());
      expect((await s.readDetail(old.record.ref)).version, old.version);
      expect(p.result.definition, p.target.definition);
      expect(p.result.fieldIds['domain'], old.fieldIds['body']);
      expect(p.result.retainedFields.single['label'], 'domain');
      final retainedKey = p.result.retainedFields.single['key'] as String;
      expect(p.result.values[retainedKey], old.values['domain']);
      expect(p.result.fieldIds[retainedKey], old.fieldIds['domain']);
      final r = await s.applyAdoption('adopt-original', p.planId),
          after = await s.readDetail(r.ref);
      expect(after.record.ref, old.record.ref);
      expect(after.record.directoryId, old.record.directoryId);
      expect(after.record.type.id, 'local.domain/domain');
      expect(after.values['domain'], 'old.example');
      expect(after.fieldIds, p.result.fieldIds);
      expect(after.retainedFields, p.result.retainedFields);
      expect((await s.loadRevisions(r.ref)).last.version, old.version);
      final receipt = (await s.recordOperationReceipt('adopt-original'))!;
      expect(receipt.intent.kind, WorkspaceOperationKind.adoptTemplate);
      expect(receipt.intent.planId, p.planId);
      expect(
        (await s.applyAdoption('adopt-original', p.planId)).version,
        r.version,
      );
      await expectLater(
        s.saveRecord(
          WorkspaceEdit(
            operationId: 'adopt-original',
            expectedVersion: after.version,
            record: after.record,
            values: const {},
          ),
        ),
        completion(isA<WorkspaceRejected>()),
      );
    },
  );

  test(
    'changed meaning creates a new identity and keeps original raw content, including composite shapes',
    () async {
      final s = SampleWorkspaceSource();
      addTearDown(s.dispose);
      await installDomain(s);
      final old = await generic(
        s,
        values: {
          'body': 'old.example',
          'legacy': {
            'nested': ['原始内容', 42],
          },
        },
      );
      final p = await s.previewAdoption(domain(old, same: false));
      expect(p.canApply, true, reason: p.errors.toString());
      expect(p.result.fieldIds['domain'], isNot(old.fieldIds['body']));
      expect(p.result.retainedFields, hasLength(2));
      final raw = p.result.retainedFields.singleWhere(
        (f) => f['label'] == 'legacy',
      );
      expect(raw['type'], 'unknown');
      expect(p.result.values[raw['key']], old.values['legacy']);
      await s.applyAdoption('changed-meaning', p.planId);
      final after = await s.readDetail(old.record.ref);
      final preserved = after.retainedFields.singleWhere(
        (f) => f['label'] == '内容',
      );
      final saved = await s.saveRecord(
        WorkspaceEdit(
          operationId: 'edit-kept',
          expectedVersion: after.version,
          record: after.record,
          values: {preserved['key'] as String: '保留字段仍可编辑'},
        ),
      );
      expect(saved, isA<WorkspaceSaved>());
      expect(
        (saved as WorkspaceSaved).detail.values[raw['key']],
        old.values['legacy'],
      );
      expect(saved.detail.fieldIds, after.fieldIds);
    },
  );

  test(
    'missing required and incompatible mapping remain reviewable without partial changes',
    () async {
      final s = SampleWorkspaceSource(readAsset: (p) => File(p).readAsBytes());
      addTearDown(s.dispose);
      await installDomain(s);
      const resume = WorkspaceRecordRef(
        WorkspaceRecordKind.information,
        'resume',
      );
      final old = await s.readDetail(resume);
      final missing = await s.previewAdoption(
        WorkspaceAdoptionDraft(ref: resume, typeId: 'local.domain/domain'),
      );
      expect(missing.canApply, false);
      expect(missing.errors, contains('domain'));
      final p = await s.previewAdoption(
        WorkspaceAdoptionDraft(
          ref: resume,
          typeId: 'local.domain/domain',
          fields: {
            'domain': const WorkspaceFieldMapping(
              sourceKey: 'file',
              sameMeaning: true,
            ),
          },
        ),
      );
      expect(p.canApply, false);
      expect(p.retained, isNotEmpty);
      await expectLater(
        s.applyAdoption('invalid', p.planId),
        throwsA(failure('validation')),
      );
      expect((await s.readDetail(resume)).version, old.version);
      expect(await s.recordOperationReceipt('invalid'), isNull);
    },
  );

  test(
    'retained attachment keeps versions, owner scope, replacement and layout restoration',
    () async {
      final s = SampleWorkspaceSource(readAsset: (p) => File(p).readAsBytes());
      addTearDown(s.dispose);
      await installDomain(s);
      const resume = WorkspaceRecordRef(
        WorkspaceRecordKind.information,
        'resume',
      );
      final old = await s.readDetail(resume),
          history = await s.loadFileHistory(resume, 'file');
      final p = await s.previewAdoption(
        WorkspaceAdoptionDraft(
          ref: resume,
          typeId: 'local.domain/domain',
          fields: {
            'domain': const WorkspaceFieldMapping(value: 'resume.example'),
          },
        ),
      );
      expect(p.canApply, true, reason: p.errors.toString());
      await s.applyAdoption('file-adopt', p.planId);
      final kept = p.result.retainedFields.singleWhere(
            (f) => f['type'] == 'file',
          ),
          key = kept['key'] as String;
      var after = await s.readDetail(resume);
      final read = await s.loadFileHistory(resume, key);
      expect(read.current.ref, history.current.ref);
      expect(read.versions.length, history.versions.length);
      final preview = await s.readFilePreview(resume, key);
      expect(preview.file.ref, history.current.ref);
      await s.changeFile(
        WorkspaceFileChange(
          operationId: 'retained-replace',
          record: resume,
          fieldKey: key,
          expectedRecordVersion: after.version,
          expectedFileVersion: history.current.ref.version,
          kind: WorkspaceFileChangeKind.replace,
          selectionId: 'image',
        ),
      );
      after = await s.readDetail(resume);
      expect(after.retainedFields, p.result.retainedFields);
      expect(after.fieldIds[key], old.fieldIds['file']);
      final restored = await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'old-layout',
          ref: resume,
          expectedVersion: after.version,
          action: WorkspaceRecordAction.restoreRevision,
          revisionVersion: old.version,
          expectedCatalogVersion: (await s.loadCatalog()).version,
        ),
      );
      expect((await s.readDetail(restored.ref)).record.type.id, 'resume');
      expect(
        (await s.loadFileHistory(resume, 'file')).current.ref.id,
        history.current.ref.id,
      );
    },
  );

  test(
    'retained profile entries keep leaf identities through adoption, editing and restoration',
    () async {
      final s = SampleWorkspaceSource();
      addTearDown(s.dispose);
      await installDomain(s);
      final profile = (await s.queryRecords(
        const WorkspaceQuery(typeId: 'profile'),
      )).items.first;
      final old = await s.readDetail(profile.ref);
      final entryField = workspaceFields(
        old,
      ).firstWhere((f) => f['type'] == 'entries');
      final entries = WorkspaceRepeatedEntry.read(
        old.values[entryField['key']],
      );
      final p = await s.previewAdoption(
        WorkspaceAdoptionDraft(
          ref: profile.ref,
          typeId: 'local.domain/domain',
          fields: {
            'domain': const WorkspaceFieldMapping(value: 'profile.example'),
          },
        ),
      );
      expect(p.canApply, true, reason: p.errors.toString());
      await s.applyAdoption('profile-adopt', p.planId);
      final kept = p.result.retainedFields.singleWhere(
        (f) => f['label'] == entryField['label'],
      );
      var after = await s.readDetail(profile.ref);
      final updated = [
        entries.first.withText('detail', '保留身份后修改'),
        ...entries.skip(1),
      ];
      final result = await s.saveRecord(
        WorkspaceEdit(
          operationId: 'retained-entry-edit',
          expectedVersion: after.version,
          record: after.record,
          values: {
            kept['key'] as String: updated.map((e) => e.toJson()).toList(),
          },
        ),
      );
      expect(
        result,
        isA<WorkspaceSaved>(),
        reason: (result is WorkspaceRejected
            ? result.failure.fieldErrors.toString()
            : ''),
      );
      after = (result as WorkspaceSaved).detail;
      expect(
        WorkspaceRepeatedEntry.read(after.values[kept['key']]).first.fieldIds,
        entries.first.fieldIds,
      );
      await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'restore-profile',
          ref: profile.ref,
          expectedVersion: after.version,
          action: WorkspaceRecordAction.restoreRevision,
          revisionVersion: old.version,
          expectedCatalogVersion: (await s.loadCatalog()).version,
        ),
      );
      final restored = await s.readDetail(profile.ref);
      expect(restored.values[entryField['key']], isNotNull);
    },
  );

  test(
    'source/template changes and deterministic failure preserve draft state; unknown reply reconciles once',
    () async {
      final s = SampleWorkspaceSource();
      addTearDown(s.dispose);
      await installDomain(s);
      final old = await generic(s), p = await s.previewAdoption(domain(old));
      await s.saveRecord(
        WorkspaceEdit(
          operationId: 'external-edit',
          expectedVersion: old.version,
          record: old.record,
          values: {'body': 'updated.example'},
        ),
      );
      await expectLater(
        s.applyAdoption('stale', p.planId),
        throwsA(failure('conflict')),
      );
      final now = await s.readDetail(old.record.ref),
          fresh = await s.previewAdoption(domain(now));
      s.nextSaveFailure = const WorkspaceFailure('offline', '合成保存失败');
      await expectLater(
        s.applyAdoption('failed', fresh.planId),
        throwsA(failure('offline')),
      );
      expect((await s.readDetail(old.record.ref)).record.type.id, 'generic');
      s.loseNextRecordReply = true;
      await expectLater(
        s.applyAdoption('lost', fresh.planId),
        throwsA(failure('unknown_outcome')),
      );
      final fact = await s.recordOperationReceipt('lost');
      expect(fact, isNotNull);
      expect(
        (await s.applyAdoption('lost', fresh.planId)).version,
        fact!.result.version,
      );
      expect(
        (await s.readDetail(old.record.ref)).values['domain'],
        'updated.example',
      );
      await s.releaseAdoption(fresh.planId);
      expect(await s.recordOperationReceipt('lost'), isNotNull);
      await s.releaseAdoption(p.planId);
      await expectLater(
        s.applyAdoption('released', p.planId),
        throwsA(failure('preview_expired')),
      );
    },
  );

  test(
    'credentials cannot adopt ordinary templates and reset clears plans',
    () async {
      final s = SampleWorkspaceSource();
      addTearDown(s.dispose);
      await installDomain(s);
      await expectLater(
        s.previewAdoption(
          WorkspaceAdoptionDraft(
            ref: const WorkspaceRecordRef(
              WorkspaceRecordKind.credential,
              'sshkey',
            ),
            typeId: 'local.domain/domain',
          ),
        ),
        throwsA(failure('unsupported')),
      );
      final old = await generic(s), p = await s.previewAdoption(domain(old));
      s.reset();
      await expectLater(
        s.applyAdoption('after-reset', p.planId),
        throwsA(failure('preview_expired')),
      );
    },
  );

  test(
    'package revision and disable invalidate a plan, even after re-enabling the same definition',
    () async {
      final s = SampleWorkspaceSource();
      addTearDown(s.dispose);
      await installDomain(s);
      final old = await generic(s), p = await s.previewAdoption(domain(old));
      for (final enabled in [false, true]) {
        final catalog = await s.plugins.load(),
            package = catalog.packages.singleWhere(
              (p) => p.id == 'local.domain',
            );
        await s.plugins.change(
          WorkspacePluginChange(
            operationId: workspaceOperationId(),
            action: enabled
                ? WorkspacePluginAction.enable
                : WorkspacePluginAction.disable,
            packageId: package.id,
            expectedVersion: catalog.version,
            expectedDigest: package.digest,
          ),
        );
        if (!enabled) {
          await expectLater(
            s.previewAdoption(domain(old)),
            throwsA(failure('template_unavailable')),
          );
        }
      }
      await expectLater(
        s.applyAdoption('stale-package', p.planId),
        throwsA(failure('conflict')),
      );
      expect((await s.readDetail(old.record.ref)).version, old.version);
    },
  );
  test(
    'duplicate identity mappings and retained-plus-target leaf budgets are rejected before commit',
    () async {
      final s = SampleWorkspaceSource();
      addTearDown(s.dispose);
      await installDomain(s);
      final old = await generic(
        s,
        values: {
          'body': 'budget.example',
          for (var i = 0; i < 199; i++) 'old$i': '原字段$i',
        },
      );
      final oversized = await s.previewAdoption(domain(old));
      expect(oversized.errors, contains('budget'));
      await expectLater(
        s.applyAdoption('over-budget', oversized.planId),
        throwsA(failure('validation')),
      );
      final small = await generic(s),
          duplicate = await s.previewAdoption(
            WorkspaceAdoptionDraft(
              ref: small.record.ref,
              typeId: 'local.domain/domain',
              fields: {
                'domain': const WorkspaceFieldMapping(
                  sourceKey: 'body',
                  sameMeaning: true,
                ),
                'registrar': const WorkspaceFieldMapping(
                  sourceKey: 'body',
                  sameMeaning: true,
                ),
              },
            ),
          );
      expect(duplicate.errors['registrar'], contains('同一来源'));
      expect((await s.readDetail(small.record.ref)).fieldIds, small.fieldIds);
    },
  );
  test(
    'repeated adoption keeps retained content and credential links; orphan host identity is not changed',
    () async {
      final s = SampleWorkspaceSource();
      addTearDown(s.dispose);
      await installDomain(s);
      const azure = WorkspaceRecordRef(
        WorkspaceRecordKind.information,
        'azure',
      );
      final old = await s.readDetail(azure),
          host = await s.hosts.read(const WorkspaceHostTarget.record(azure));
      final p = await s.previewAdoption(
        WorkspaceAdoptionDraft(
          ref: azure,
          typeId: 'local.domain/domain',
          fields: {
            'domain': const WorkspaceFieldMapping(value: 'server.example'),
          },
        ),
      );
      expect(p.canApply, true, reason: p.errors.toString());
      await s.applyAdoption('server-layout', p.planId);
      final after = await s.readDetail(azure);
      expect(after.relations, old.relations);
      expect(
        (await s.hosts.read(
          WorkspaceHostTarget.identity(host.identityId),
        )).state,
        host.state,
      );
      final mappings = {
        for (final f in after.definition['fields'] as List)
          f['key'] as String: WorkspaceFieldMapping(
            sourceKey: f['key'] as String,
            sameMeaning: true,
          ),
      };
      final again = await s.previewAdoption(
        WorkspaceAdoptionDraft(
          ref: azure,
          typeId: 'local.domain/domain',
          fields: mappings,
        ),
      );
      expect(again.canApply, true, reason: again.errors.toString());
      await s.applyAdoption('same-layout', again.planId);
      final twice = await s.readDetail(azure);
      expect(twice.values, after.values);
      expect(twice.fieldIds, after.fieldIds);
      expect(twice.retainedFields, after.retainedFields);
      expect(twice.relations, old.relations);
    },
  );
  test(
    'a receipt from a different adoption plan cannot release an uncertain mutation',
    () async {
      final s = _WrongAdoptionReceipt();
      addTearDown(s.dispose);
      await installDomain(s);
      final old = await generic(s),
          p = await s.previewAdoption(domain(old)),
          m = RecordMutation(s);
      addTearDown(m.dispose);
      final intent = WorkspaceOperationIntent(
        kind: WorkspaceOperationKind.adoptTemplate,
        ref: old.record.ref,
        typeId: p.target.type.id,
        expectedVersion: old.version,
        planId: p.planId,
      );
      var operation = '';
      s.loseNextRecordReply = true;
      await m.submit(intent, (id) {
        operation = id;
        return s.applyAdoption(id, p.planId);
      });
      final actual = (await s.recordOperationReceipt(operation))!;
      s.wrong = WorkspaceOperationReceipt(
        operationId: operation,
        intent: WorkspaceOperationIntent(
          kind: intent.kind,
          ref: intent.ref,
          typeId: intent.typeId,
          expectedVersion: intent.expectedVersion,
          planId: 'other-plan',
        ),
        result: actual.result,
      );
      expect(await m.reconcile(), isNull);
      expect(m.uncertain, true);
      s.wrong = null;
      expect((await m.reconcile())!.ref, old.record.ref);
      expect(m.canSubmit, true);
    },
  );
}
