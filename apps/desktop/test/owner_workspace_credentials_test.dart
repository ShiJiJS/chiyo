import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/workspace/library_credential.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/unavailable_workspace_sources.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async => value = List.of(key);
}

class _UnreadableLinks extends OwnerWorkspaceSource {
  _UnreadableLinks(core.OwnerAccess owner)
    : super(owner: owner, refreshInterval: Duration.zero);
  @override
  Future<List<WorkspaceRecordSummary>> readSummaries(
    Iterable<WorkspaceRecordRef> refs,
  ) async => throw const WorkspaceFailure('unavailable', '合成关联查询失败');
}

void main() {
  late Directory root;
  late _Keys keys;
  late EncryptedInformationRepository repo;
  late core.InformationService service;
  late OwnerWorkspaceSource source;
  var now = DateTime.utc(2026, 11, 1);
  const secret = 'SYNTHETIC-NOT-OWNER-secret-never-in-ui';
  WorkspaceRecordRef ref(core.ManagedCredential c) =>
      WorkspaceRecordRef(WorkspaceRecordKind.credential, c.id);
  Matcher fails(String code) =>
      throwsA(isA<WorkspaceFailure>().having((e) => e.code, 'code', code));
  Future<void> open() async {
    repo = await EncryptedInformationRepository.open(
      root.path,
      keys,
      clock: () => now,
    );
    service = core.InformationService(repository: repo, clock: () => now);
    source = OwnerWorkspaceSource(
      owner: service.owner,
      refreshInterval: Duration.zero,
    );
  }

  Future<void> close() async {
    await source.dispose();
    await service.close();
    await repo.close();
  }

  Future<core.ManagedCredential> create({DateTime? expiresAt}) =>
      service.owner.createStringCredential(
        name: '合成真实凭据',
        publicPurpose: '合成用途',
        privateNote: 'Owner私有备注',
        secret: secret,
        suggestedBinding: 'SYNTHETIC_TOKEN',
        expiresAt: expiresAt,
      );
  setUp(() async {
    now = DateTime.utc(2026, 11, 1);
    root = await Directory.systemTemp.createTemp('owner-credential-metadata-');
    keys = _Keys();
    await open();
  });
  tearDown(() async {
    await close();
    await root.delete(recursive: true);
  });

  test(
    'persisted credential opens through unified list with metadata only',
    () async {
      final c = await create();
      await close();
      await open();
      final list = await source.queryRecords(
        const WorkspaceQuery(typeId: 'credential'),
      );
      expect(list.total, 1);
      expect(list.items.single.ref, ref(c));
      final detail = await source.credentials.read(ref(c));
      expect(detail.record.name, c.name);
      expect(detail.record.description, c.publicPurpose);
      expect(detail.privateNote, 'Owner私有备注');
      expect(detail.binding, 'SYNTHETIC_TOKEN');
      expect(detail.recordVersion, c.revision);
      expect(detail.materialVersion, c.version);
      expect(detail.useGeneration, c.useGeneration);
      expect(detail.mask, '••••••••');
      expect(detail.canRequestUse, isFalse);
      expect(detail.unavailableReason, contains('尚未接入'));
      expect(
        jsonEncode([
          list.items.single.name,
          list.items.single.description,
          detail.privateNote,
          detail.binding,
          detail.mask,
          detail.format,
        ]),
        isNot(contains(secret)),
      );
      expect(
        (await source.queryRecords(
          const WorkspaceQuery(keyword: secret),
        )).total,
        0,
      );
      final shell = await source.readDetail(ref(c));
      expect(shell.values, isEmpty);
      expect(shell.record.ref, ref(c));
      expect(repo.credentialMaterials.single.bytes, utf8.encode(secret));
    },
  );

  test('file metadata never guesses format from its name', () async {
    final c = await service.owner.createFileCredential(
      name: '合成文件凭据',
      publicPurpose: '原用途',
      fileName: 'looks-like-ssh.pem',
      bytes: utf8.encode(secret),
    );
    final detail = await source.credentials.read(ref(c));
    expect(detail.form, WorkspaceCredentialForm.file);
    expect(detail.filename, 'looks-like-ssh.pem');
    expect(detail.format, '凭据文件');
    expect(detail.canRequestUse, isFalse);
    final history = await source.credentials.materials(ref(c));
    expect(history.materials.single.filename, c.fileName);
    expect(history.materials.single.mask, '••••••••');
  });

  test(
    'owner associations retain exact information identity without body projection',
    () async {
      final c = await create();
      final item = await service.owner.createInformation('合成关联目标', '', [
        const core.FieldInput('正文', '', secret),
      ]);
      await service.owner.setCredentialLinks(c.id, c.revision, [item.id]);
      final detail = await source.credentials.read(ref(c));
      expect(detail.linkedInformation, [
        WorkspaceRecordRef(WorkspaceRecordKind.information, item.id),
      ]);
      final summaries = await source.readSummaries(detail.linkedInformation);
      expect(summaries.single.name, '合成关联目标');
      expect(summaries.single.description, isNot(contains(secret)));
      final catalog = await source.loadCatalog();
      expect(catalog.types.map((t) => t.id), contains('credential'));
      expect(catalog.creatableTypes.map((t) => t.id), contains('credential'));
    },
  );

  test(
    'rotation and retention use actual core versions after reopening',
    () async {
      final c = await create();
      now = now.add(const Duration(hours: 1));
      final rotated = await service.owner.rotateStringCredential(
        c.id,
        c.revision,
        'SYNTHETIC-v2',
      );
      await close();
      await open();
      final history = await source.credentials.materials(ref(c));
      expect(history.current.recordVersion, rotated.revision);
      expect(history.current.materialVersion, 2);
      expect(history.current.enabled, isTrue);
      expect(history.materials.map((m) => m.version), [2, 1]);
      expect(history.materials.last.retiredAt, now);
      now = now.add(const Duration(days: 30));
      expect(
        (await source.credentials.materials(
          ref(c),
        )).materials.map((m) => m.version),
        [2],
      );
    },
  );

  test(
    'expiry recycle wrong kind and replaced library refuse misleading reads',
    () async {
      final c = await create(expiresAt: now.add(const Duration(minutes: 1)));
      now = now.add(const Duration(minutes: 1));
      expect(
        (await source.credentials.read(ref(c))).unavailableReason,
        contains('已到期'),
      );
      await expectLater(
        source.credentials.read(
          WorkspaceRecordRef(WorkspaceRecordKind.information, c.id),
        ),
        fails('invalid_reference'),
      );
      await service.owner.deleteCredential(c.id, c.revision);
      await expectLater(source.credentials.read(ref(c)), fails('not_found'));
      await expectLater(
        source.credentials.materials(ref(c)),
        fails('not_found'),
      );
      await service.owner.restoreLibrary(() async {});
      await expectLater(
        source.credentials.read(ref(c)),
        fails('library_changed'),
      );
    },
  );

  test(
    'clock-only expiry refreshes the owner view without rewriting metadata',
    () async {
      final c = await create(expiresAt: now.add(const Duration(minutes: 1)));
      source.refreshFromOwner();
      await Future<void>.delayed(Duration.zero);
      final next = source.changes.first.timeout(const Duration(seconds: 2));
      now = now.add(const Duration(minutes: 1));
      source.refreshFromOwner();
      expect(await next, isNull);
      expect(
        (await source.credentials.read(ref(c))).unavailableReason,
        contains('已到期'),
      );
      expect(service.owner.credential(c.id).toJson(), c.toJson());
    },
  );

  test(
    'unwired AI use and stale lifecycle fail while receipt lookup reports actual absence',
    () async {
      final c = await create();
      final before = jsonEncode(c.toJson());
      await expectLater(
        source.credentials.save(
          WorkspaceCredentialWrite(operationId: 'missing-input', name: '新建'),
        ),
        fails('validation'),
      );
      await expectLater(
        source.credentials.requests(ref: ref(c)),
        fails('unsupported'),
      );
      await expectLater(
        source.credentials.change(
          WorkspaceCredentialChange(
            operationId: 'stale-lifecycle',
            ref: ref(c),
            expectedRecordVersion: c.revision + 1,
            expectedMaterialVersion: c.version,
            action: WorkspaceCredentialAction.recycle,
          ),
        ),
        fails('conflict'),
      );
      expect(await source.credentials.receipt('unknown-operation'), isNull);
      expect(jsonEncode(service.owner.credential(c.id).toJson()), before);
      expect(service.owner.credentialUseRequests, isEmpty);
    },
  );

  testWidgets(
    'request failure preserves real owner detail and visibly reports unknown requests',
    (t) async {
      final c = (await t.runAsync(() => create()))!;
      t.view.physicalSize = const Size(1280, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: LibraryCredential(
                ref: ref(c),
                revision: 1,
                source: source,
                onOpen: (_) {},
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('凭据字符串'), findsOneWidget);
      expect(find.text('Owner私有备注', findRichText: true), findsOneWidget);
      expect(find.text('使用暂不可用'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('credential-request-read-failure')),
        findsOneWidget,
      );
      expect(find.text(secret), findsNothing);
      expect(
        find.byKey(const ValueKey('credential-request-use')),
        findsNothing,
      );
      expect(t.takeException(), isNull);
      final linksFailed = _UnreadableLinks(service.owner);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: LibraryCredential(
                ref: ref(c),
                revision: 1,
                source: linksFailed,
                onOpen: (_) {},
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Owner私有备注', findRichText: true), findsOneWidget);
      expect(
        find.byKey(const ValueKey('credential-link-read-failure')),
        findsOneWidget,
      );
      expect(find.text('尚未关联资料。'), findsNothing);
      expect(find.text('关联资料已不可用。'), findsNothing);
      final changed = OwnerWorkspaceSource(
        owner: service.owner,
        refreshInterval: Duration.zero,
        credentials: const UnavailableWorkspaceCredential(),
      );
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: LibraryCredential(
                ref: ref(c),
                revision: 1,
                source: changed,
                onOpen: (_) {},
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Owner私有备注', findRichText: true), findsNothing);
      expect(find.byKey(const ValueKey('credential-retry')), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
      await t.runAsync(changed.dispose);
      await t.runAsync(linksFailed.dispose);
    },
  );
}
