@TestOn('!windows')
library;

// Real OnlineServer fixture uses POSIX secret mounts. Windows behavior is
// exercised by the explicit existing-NAS tests, without relaxing that boundary.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/online_desktop_launcher.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/workspace_app.dart';
import 'package:info_desktop/workspace/record_mutation.dart';
import 'package:info_desktop/workspace/remote_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_workspace/adoption_transport.dart';
import 'package:info_workspace/file_transport.dart';
import '../../server/test/support/device_credential_fixture.dart';
import '../../server/test/support/owner_reply_proxy.dart';
import '../../server/test/support/template_fixture.dart';
import 'support/online_ui_harness.dart';

class _Http extends HttpOverrides {}

Future<RemoteWorkspaceSource> _source(
  DeviceCredentialFixture f, {
  OwnerReplyProxy? proxy,
}) async {
  final c = await OwnerClient.connect(
    address: proxy?.address ?? f.owner.address,
    token: f.token,
    trust: f.trust,
  );
  final s = RemoteWorkspaceSource(c);
  addTearDown(s.dispose);
  return s;
}

Future<void> _install(
  DeviceCredentialFixture f,
  RemoteWorkspaceSource s,
) async {
  final staged = await f.owner.request('POST', '/v1/owner/plugins/stage', {
    'filename': 'synthetic.json',
    'bytes': base64Encode(
      utf8.encode(jsonEncode(syntheticTemplatePackage('1.0.0'))),
    ),
  });
  final p = await s.plugins.previewInstall(staged['selectionId'] as String);
  await s.plugins.change(
    WorkspacePluginChange(
      operationId: 'install-adoption',
      action: WorkspacePluginAction.install,
      packageId: p.package.id,
      expectedVersion: p.catalogVersion,
      expectedDigest: p.package.digest,
      selectionId: p.selectionId,
    ),
  );
}

Future<WorkspaceDetail> _create(RemoteWorkspaceSource s, String name) async {
  final t = await s.loadTemplate('generic');
  final result = await s.createRecord(
    WorkspaceCreate(
      operationId: workspaceOperationId(),
      typeId: 'generic',
      name: name,
      values: {'body': '# 合成原文\n\n保留内容'},
      expectedTemplateVersion: t['templateVersion'] as String,
      expectedTemplateDigest: t['packageDigest'] as String,
    ),
  );
  expect(result, isA<WorkspaceSaved>());
  return (result as WorkspaceSaved).detail;
}

WorkspaceAdoptionDraft _draft(
  WorkspaceDetail d, {
  String? sourceKey = 'body',
}) => WorkspaceAdoptionDraft(
  ref: d.record.ref,
  typeId: 'local.synthetic/note',
  fields: {
    'format': const WorkspaceFieldMapping(value: 'markdown'),
    'body': WorkspaceFieldMapping(
      sourceKey: sourceKey,
      sameMeaning: true,
      value: '独立合成说明',
    ),
  },
);
Matcher _fails(String code) =>
    throwsA(isA<WorkspaceFailure>().having((e) => e.code, 'code', code));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'normal online library menu maps, previews and applies an installed template using the original dialog',
    (t) async {
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = _Http();
      t.view.physicalSize = const Size(1500, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final ui = OnlineUiHarness(t);
      DeviceCredentialFixture? f;
      RemoteWorkspaceSource? live;
      RemoteWorkspaceSource? preparation;
      try {
        late WorkspaceDetail original;
        final profiles = await ui.resolve(() async {
          f = await DeviceCredentialFixture.create();
          preparation = await _source(f!);
          await _install(f!, preparation!);
          original = await _create(preparation!, '合成界面模板转换');
          final profiles = PrivateConnectionProfileStore(
            '${f!.root.path}/ui-profile',
          );
          await profiles.save(
            ConnectionProfile(
              address: f!.owner.address.toString(),
              token: f!.token,
              serverId: f!.owner.serverId,
              certificate: f!.certificate,
            ),
          );
          return profiles;
        });
        await t.pumpWidget(OnlineDesktopLauncher(profiles: profiles));
        ui.phase = 'online adoption library';
        await ui.until(
          () =>
              find.byType(LibraryPage).evaluate().isNotEmpty &&
              t
                      .widget<LibraryPage>(find.byType(LibraryPage))
                      .controller
                      .detail !=
                  null,
        );
        live =
            t.widget<WorkspaceApp>(find.byType(WorkspaceApp)).source
                as RemoteWorkspaceSource;
        await ui.tap('library-record-actions');
        await ui.until(() => find.text('采用资料模板').evaluate().isNotEmpty);
        await t.runAsync(() => t.tap(find.text('采用资料模板')));
        await t.pump();
        await ui.tap('adoption-target-local.synthetic/note');
        await ui.until(
          () => ui.key('adoption-value-format').evaluate().isNotEmpty,
        );
        await t.ensureVisible(ui.key('adoption-value-format'));
        await t.enterText(ui.key('adoption-value-format'), 'markdown');
        await ui.tap('adoption-source-body');
        await ui.until(() => find.text('内容 · multiline').evaluate().isNotEmpty);
        await t.runAsync(() => t.tap(find.text('内容 · multiline').last));
        await t.pump();
        await ui.tap('adoption-meaning-body');
        await ui.tap('adoption-preview');
        await ui.until(() => ui.key('adoption-apply').evaluate().isNotEmpty);
        expect(
          (await ui.resolve(
            () => live!.readDetail(original.record.ref),
          )).record.type.id,
          'generic',
        );
        await ui.tap('adoption-apply');
        await ui.until(
          () =>
              ui.key('adoption-apply').evaluate().isEmpty &&
              t
                      .widget<LibraryPage>(find.byType(LibraryPage))
                      .controller
                      .detail
                      ?.record
                      .type
                      .id ==
                  'local.synthetic/note',
        );
        final actual = await ui.resolve(
          () => live!.readDetail(original.record.ref),
        );
        expect(actual.values['body'], original.values['body']);
        expect(actual.fieldIds['body'], original.fieldIds['body']);
        expect(actual.values['format'], 'markdown');
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox());
        if (live != null) await ui.resolve(live.dispose);
        if (preparation != null) await ui.resolve(preparation!.dispose);
        if (f != null) await ui.resolve(f!.dispose);
        HttpOverrides.global = previousHttp;
      }
    },
  );
  test(
    'normal online template adoption preserves original field identity, content and relations, cancels previews and retains exact receipts through restart',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = await DeviceCredentialFixture.create();
        addTearDown(f.dispose);
        final s = await _source(f);
        await _install(f, s);
        final target = await _create(s, '关联目标');
        final note = await _create(s, '模板转换');
        await s.saveRecord(
          WorkspaceEdit(
            operationId: 'adoption-relations',
            record: note.record,
            expectedVersion: note.version,
            values: note.values,
            relations: {
              'related': [target.record.ref],
            },
          ),
        );
        final original = await s.readDetail(note.record.ref);
        final p = await s.previewAdoption(_draft(original));
        expect(p.canApply, isTrue, reason: '${p.errors}');
        expect(p.current.fieldIds, original.fieldIds);
        expect(p.result.fieldIds['body'], original.fieldIds['body']);
        expect(p.result.relations, original.relations);
        expect((await s.readDetail(note.record.ref)).record.type.id, 'generic');
        final saved = await s.applyAdoption('adopt-once', p.planId);
        expect(saved.ref, note.record.ref);
        expect(saved.version, original.version + 1);
        final after = await s.readDetail(saved.ref);
        expect(after.record.type.id, 'local.synthetic/note');
        expect(after.values['body'], original.values['body']);
        expect(after.values['format'], 'markdown');
        expect(after.fieldIds['body'], original.fieldIds['body']);
        expect(after.relations, original.relations);
        final receipt = (await s.recordOperationReceipt('adopt-once'))!;
        expect(receipt.intent.kind, WorkspaceOperationKind.adoptTemplate);
        expect(receipt.intent.planId, p.planId);
        expect(
          (await s.applyAdoption('adopt-once', p.planId)).version,
          saved.version,
        );
        final closed = await s.previewAdoption(_draft(after));
        await s.releaseAdoption(closed.planId);
        await expectLater(
          s.applyAdoption('cancelled', closed.planId),
          _fails('preview_expired'),
        );
        await f.reopen();
        final fresh = await _source(f);
        expect(
          (await fresh.applyAdoption('adopt-once', p.planId)).version,
          saved.version,
        );
        expect(
          (await fresh.recordOperationReceipt('adopt-once'))!.intent.planId,
          p.planId,
        );
        expect((await fresh.readDetail(saved.ref)).fieldIds, after.fieldIds);
        await expectLater(
          fresh.applyAdoption('adopt-once', 'different-plan'),
          _fails('conflict'),
        );
        final stale = await fresh.previewAdoption(_draft(after));
        await fresh.saveRecord(
          WorkspaceEdit(
            operationId: 'edit-after-preview',
            expectedVersion: after.version,
            record: after.record,
            values: {...after.values, 'body': '后来修改'},
          ),
        );
        await expectLater(
          fresh.applyAdoption('stale-plan', stale.planId),
          _fails('conflict'),
        );
        expect((await fresh.readDetail(saved.ref)).values['body'], '后来修改');
      }, _Http());
    },
  );

  test(
    'online adoption refuses incompatible attachment mapping and preserves exact original bytes when keeping the file outside the target template',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = await DeviceCredentialFixture.create();
        addTearDown(f.dispose);
        final s = await _source(f);
        await _install(f, s);
        final bytes = utf8.encode('# 合成附件\n\n不能变成字符串字段');
        final uploaded = fileCandidateFromJson(
          (await f.owner.request('POST', '/v1/owner/files/uploads', {
            'operationId': 'adoption-upload',
            'originalName': 'synthetic.md',
            'mediaType': 'text/markdown',
            'bytes': base64Encode(bytes),
          }))['candidate'],
        );
        final ref = await s.importFile(
          WorkspaceFileImport(
            operationId: 'adoption-file',
            selectionId: uploaded.selectionId,
            name: '合成文件',
          ),
        );
        final before = await s.readDetail(ref);
        final fileKey = before.fieldIds.keys.single;
        final invalid = await s.previewAdoption(
          _draft(before, sourceKey: fileKey),
        );
        expect(invalid.canApply, isFalse);
        expect(invalid.errors['body'], contains('形态不兼容'));
        await expectLater(
          s.applyAdoption('invalid-mapping', invalid.planId),
          _fails('validation'),
        );
        expect((await s.readDetail(ref)).version, before.version);
        await s.releaseAdoption(invalid.planId);
        final p = await s.previewAdoption(_draft(before, sourceKey: null));
        expect(p.canApply, isTrue, reason: '${p.errors}');
        expect(p.result.retainedFields, hasLength(1));
        final retained = p.result.retainedFields.single['key'] as String;
        expect(p.result.fieldIds[retained], before.fieldIds[fileKey]);
        await s.applyAdoption('retain-file', p.planId);
        final after = await s.readDetail(ref);
        expect(after.fieldIds[retained], before.fieldIds[fileKey]);
        final preview = await s.readFilePreview(ref, retained, version: 1);
        expect(preview.text, '# 合成附件\n\n不能变成字符串字段');
        expect(
          (await s.loadFileHistory(ref, retained)).versions.single.ref.version,
          1,
        );
      }, _Http());
    },
  );

  test(
    'lost online adoption response freezes the original normal record mutation and restart reconciliation does not apply twice',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = await DeviceCredentialFixture.create();
        addTearDown(f.dispose);
        final proxy = await OwnerReplyProxy.start(
          tls: f.tls,
          trust: f.trust,
          target: () => f.owner.address,
          serverId: f.owner.serverId,
        );
        addTearDown(proxy.close);
        final s = await _source(f, proxy: proxy);
        await _install(f, s);
        final before = await _create(s, '丢回复');
        final p = await s.previewAdoption(_draft(before));
        final mutation = RecordMutation(s);
        addTearDown(mutation.dispose);
        proxy.dropNextPath = '/v1/owner/adoption/changes';
        final intent = WorkspaceOperationIntent(
          kind: WorkspaceOperationKind.adoptTemplate,
          ref: before.record.ref,
          expectedVersion: before.version,
          typeId: p.target.type.id,
          planId: p.planId,
        );
        expect(
          await mutation.submit(intent, (id) => s.applyAdoption(id, p.planId)),
          isNull,
        );
        expect(mutation.uncertain, isTrue);
        expect(mutation.canSubmit, isFalse);
        proxy.failGetPrefix = '/v1/owner/operations/';
        await mutation.reconcile();
        expect(mutation.uncertain, isTrue);
        expect(proxy.requests['POST /v1/owner/adoption/changes'], 1);
        await f.reopen();
        proxy.failGetPrefix = null;
        final result = await mutation.reconcile();
        expect(mutation.failure, isNull);
        expect(result!.version, before.version + 1);
        expect(proxy.requests['POST /v1/owner/adoption/changes'], 1);
        expect((await s.loadRevisions(before.record.ref)), hasLength(1));
      }, _Http());
    },
  );

  test(
    'adoption wire rejects extra raw fields, wrong booleans and extra mapping keys',
    () {
      final draft = adoptionDraftToJson(
        WorkspaceAdoptionDraft(
          ref: const WorkspaceRecordRef(
            WorkspaceRecordKind.information,
            'synthetic',
          ),
          typeId: 'generic',
          fields: {'body': const WorkspaceFieldMapping(value: 'synthetic')},
        ),
      );
      expect(adoptionDraftFromJson(draft).fields['body']!.value, 'synthetic');
      expect(
        () => adoptionDraftFromJson({...draft, 'recoveryKey': 'SYNTHETIC'}),
        throwsFormatException,
      );
      expect(
        () => adoptionDraftFromJson({
          ...draft,
          'fields': {
            'body': {'sourceKey': null, 'sameMeaning': 1, 'value': ''},
          },
        }),
        throwsFormatException,
      );
      expect(
        () => adoptionDraftFromJson({
          ...draft,
          'fields': {
            'body': {
              'sourceKey': null,
              'sameMeaning': false,
              'value': '',
              'path': '/synthetic',
            },
          },
        }),
        throwsFormatException,
      );
    },
  );
}
