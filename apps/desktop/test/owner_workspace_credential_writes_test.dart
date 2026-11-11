import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/credential_files.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/credential_mutation.dart';
import 'package:info_desktop/workspace/owner_credential_input.dart';
import 'package:info_desktop/workspace/owner_workspace_credentials.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_app.dart';
import 'package:info_desktop/workspace/workspace_inputs.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:sqlite3/sqlite3.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async => value = List.of(key);
}

class _Faults extends OwnerWorkspaceCredentials {
  _Faults(super.owner, {super.onChanged});
  bool wrongDigest = false;
  @override
  Future<WorkspaceCredentialReceipt?> receipt(String id) async {
    final value = await super.receipt(id);
    return !wrongDigest || value == null
        ? value
        : WorkspaceCredentialReceipt(
            value.ref,
            value.recordVersion,
            value.materialVersion,
            commandDigest: 'f' * 64,
          );
  }
}

class _Files implements CredentialFilePicker {
  final result = Completer<SelectedCredentialFile?>();
  @override
  Future<SelectedCredentialFile?> choose() => result.future;
}

void main() {
  const evidence = String.fromEnvironment('UI_EVIDENCE_DIR');
  const secret = 'SYNTHETIC-Host-only-secret';
  late Directory root;
  late _Keys keys;
  late EncryptedInformationRepository repo;
  late core.InformationService service;
  late OwnerWorkspaceSource source;
  var opened = false;
  OwnerWorkspaceCredentials getVault() =>
      source.credentials as OwnerWorkspaceCredentials;
  Matcher fails(String code) =>
      throwsA(isA<WorkspaceFailure>().having((e) => e.code, 'code', code));
  WorkspaceCredentialWrite write(
    String id, {
    WorkspaceCredentialCandidate? candidate,
    WorkspaceCredentialDetail? detail,
    String name = '合成凭据',
    String note = '合成私有备注',
    bool? discoverable,
    String? directory,
    List<String> tags = const [],
    List<WorkspaceRecordRef>? links,
  }) => WorkspaceCredentialWrite(
    operationId: id,
    name: name,
    purpose: '合成公开用途',
    privateNote: note,
    binding: 'SYNTHETIC_TOKEN',
    ref: detail?.record.ref,
    expectedRecordVersion: detail?.recordVersion,
    expectedMaterialVersion: detail?.materialVersion,
    candidateId: candidate?.id,
    discoverable: discoverable,
    directoryId: directory,
    tagIds: tags,
    linkedInformation: links,
  );
  Future<void> open() async {
    repo = await EncryptedInformationRepository.open(root.path, keys);
    service = core.InformationService(repository: repo);
    source = OwnerWorkspaceSource(
      owner: service.owner,
      refreshInterval: Duration.zero,
    );
    opened = true;
  }

  Future<void> close() async {
    if (!opened) return;
    await source.dispose();
    await service.close();
    await repo.close();
    opened = false;
  }

  Database inspect() {
    final db = sqlite3.open('${root.path}/library.db');
    final hex = keys.value!
        .map((v) => v.toRadixString(16).padLeft(2, '0'))
        .join();
    db.execute('PRAGMA key = "x\'$hex\'"');
    return db;
  }

  setUpAll(() async {
    if (evidence.isNotEmpty) await loadDesktopFonts();
  });
  setUp(() async {
    root = await Directory.systemTemp.createTemp('owner-credential-write-');
    keys = _Keys();
    await open();
  });
  tearDown(() async {
    await close();
    await root.delete(recursive: true);
  });

  test(
    'Host staging releases canceled input and consumes committed candidates exactly once',
    () async {
      final vault = getVault();
      final canceled = vault.staging.string(secret);
      expect(repo.managedCredentials, isEmpty);
      await vault.releaseCandidate(canceled.id);
      await expectLater(
        vault.save(write('cancelled', candidate: canceled)),
        fails('selection_expired'),
      );
      final candidate = vault.staging.string(secret);
      final input = write('create', candidate: candidate);
      final receipt = await vault.save(input);
      expect(receipt.commandDigest, input.commandDigest);
      expect(repo.credentialMaterials.single.bytes, utf8.encode(secret));
      expect((await source.readDetail(receipt.ref)).values, isEmpty);
      expect((await vault.save(input)).ref, receipt.ref);
      await expectLater(
        vault.save(write('new-operation', candidate: candidate)),
        fails('selection_expired'),
      );
      expect(repo.managedCredentials, hasLength(1));
      expect(service.owner.credentialUseRequests, isEmpty);
    },
  );

  test(
    'real workspace edit replacement toggle and receipt persist across repository/source reopen',
    () async {
      final vault = getVault();
      final created = await vault.save(
        write('new', candidate: vault.staging.string(secret)),
      );
      var detail = await vault.read(created.ref);
      await vault.save(write('edit', detail: detail, name: '实际改名'));
      detail = await vault.read(created.ref);
      final replaced = await vault.save(
        write(
          'replace',
          detail: detail,
          candidate: vault.staging.string('SYNTHETIC-next'),
        ),
      );
      detail = await vault.read(created.ref);
      final toggle = WorkspaceCredentialToggle(
        operationId: 'disable',
        ref: created.ref,
        expectedRecordVersion: detail.recordVersion,
        expectedMaterialVersion: detail.materialVersion,
        enabled: false,
      );
      await vault.setEnabled(toggle);
      await close();
      await open();
      detail = await getVault().read(created.ref);
      expect(detail.materialVersion, 2);
      expect(detail.enabled, isFalse);
      expect(detail.useGeneration, 3);
      expect(
        (await getVault().receipt('replace'))!.commandDigest,
        replaced.commandDigest,
      );
      expect(
        (await getVault().receipt('disable'))!.commandDigest,
        toggle.commandDigest,
      );
      expect(
        repo.credentialMaterials.last.bytes,
        utf8.encode('SYNTHETIC-next'),
      );
    },
  );

  test(
    'file staging creates and replaces exact bytes without path-bearing form values',
    () async {
      final vault = getVault();
      final candidate = vault.staging.file(
        SelectedCredentialFile(
          'synthetic.pem',
          utf8.encode('SYNTHETIC-file-one'),
        ),
      );
      final created = await vault.save(
        write('file-create', candidate: candidate),
      );
      var detail = await vault.read(created.ref);
      expect(detail.form, WorkspaceCredentialForm.file);
      expect(detail.filename, 'synthetic.pem');
      final next = vault.staging.file(
        SelectedCredentialFile(
          'synthetic-next.pem',
          utf8.encode('SYNTHETIC-file-two'),
        ),
      );
      await vault.save(write('file-replace', candidate: next, detail: detail));
      await close();
      await open();
      detail = await getVault().read(created.ref);
      expect(detail.filename, 'synthetic-next.pem');
      expect(detail.materialVersion, 2);
      expect(
        repo.credentialMaterials.last.bytes,
        utf8.encode('SYNTHETIC-file-two'),
      );
      expect((await source.readDetail(created.ref)).values, isEmpty);
    },
  );

  test(
    'credential relation picker queries only information metadata and saves stable target identities',
    () async {
      final item = await service.owner.createInformation('合成关联目标', '', [
        const core.FieldInput('正文', '', secret),
      ]);
      final vault = getVault();
      final created = await vault.save(
        write('linked-create', candidate: vault.staging.string(secret)),
      );
      final choices = await source.queryRelationCandidates(
        WorkspaceRelationQuery(
          source: created.ref,
          typeId: 'credential',
          key: 'related',
          keyword: '合成关联目标',
        ),
      );
      expect(choices.items.single.ref.id, item.id);
      final detail = await vault.read(created.ref);
      final target = WorkspaceRecordRef(
        WorkspaceRecordKind.information,
        item.id,
      );
      await vault.save(write('link', detail: detail, links: [target]));
      final shell = await source.readDetail(created.ref);
      expect(shell.relations['related'], [target]);
      expect(shell.values, isEmpty);
      expect(choices.items.single.description, isNot(contains(secret)));
    },
  );

  test(
    'discovery stays private by default and explicit metadata choice exposes no material or private note',
    () async {
      final vault = getVault();
      final created = await vault.save(
        write('private', candidate: vault.staging.string(secret)),
      );
      expect(service.agent.credentialCatalog().credentials, isEmpty);
      final detail = await vault.read(created.ref);
      await vault.save(
        write('discoverable', detail: detail, discoverable: true),
      );
      await close();
      await open();
      expect((await getVault().read(created.ref)).discoverable, isTrue);
      final public = jsonEncode(service.agent.credentialCatalog().toJson());
      expect(service.agent.credentialCatalog().credentials, hasLength(1));
      expect(public, isNot(contains(secret)));
      expect(public, isNot(contains('合成私有备注')));
    },
  );

  test(
    'credential classification reaches catalog counts filters details and reviewed tag deletion',
    () async {
      final parent = await service.owner.createDirectory('合成父目录');
      final child = await service.owner.createDirectory(
        '合成子目录',
        parentId: parent.id,
      );
      final tag = await service.owner.createTag('合成可搜索标签');
      final receipt = await getVault().save(
        write(
          'classified',
          candidate: getVault().staging.string(secret),
          directory: child.id,
          tags: [tag.id],
        ),
      );
      var catalog = await source.loadCatalog();
      expect(catalog.directoryCounts[parent.id], 1);
      expect(catalog.directoryCounts[child.id], 1);
      expect(catalog.directoryCounts['unfiled'], 0);
      expect(catalog.tagCounts[tag.id], 1);
      final detail = await getVault().read(receipt.ref);
      expect(detail.record.directoryId, child.id);
      expect(detail.record.tags.single.name, tag.name);
      expect(
        (await source.readDetail(receipt.ref)).record.tags.single.id,
        tag.id,
      );
      final matches = await source.queryRecords(
        WorkspaceQuery(
          directoryId: parent.id,
          tagId: tag.id,
          keyword: tag.name,
        ),
      );
      expect(matches.items.single.ref, receipt.ref);
      expect(
        (await source.queryRecords(
          const WorkspaceQuery(directoryId: 'unfiled'),
        )).items,
        isEmpty,
      );
      final preview = await source.previewTagRemoval(tag.id);
      expect(preview.affectedCount, 1);
      await source.changeClassification(
        WorkspaceTagChange(
          operationId: 'remove-tag',
          expectedVersion: preview.catalogVersion,
          action: WorkspaceTagAction.delete,
          tagId: tag.id,
          removalToken: preview.token,
        ),
      );
      catalog = await source.loadCatalog();
      expect(catalog.tags, isEmpty);
      expect((await getVault().read(receipt.ref)).record.tags, isEmpty);
      await close();
      await open();
      expect((await getVault().read(receipt.ref)).record.directoryId, child.id);
      expect(
        (await source.queryRecords(
          WorkspaceQuery(directoryId: parent.id),
        )).items.single.ref,
        receipt.ref,
      );
    },
  );

  test(
    'missing classification is rejected and wrong material shape does not replace a credential',
    () async {
      final vault = getVault();
      final candidate = vault.staging.string(secret);
      await expectLater(
        vault.save(
          write(
            'unsupported-folder',
            candidate: candidate,
            directory: 'chosen-folder',
          ),
        ),
        fails('validation'),
      );
      expect(repo.managedCredentials, isEmpty);
      final created = await vault.save(write('create', candidate: candidate));
      final detail = await vault.read(created.ref);
      final file = vault.staging.file(
        SelectedCredentialFile('synthetic.bin', [1, 2, 3]),
      );
      await expectLater(
        vault.save(write('wrong-form', detail: detail, candidate: file)),
        fails('validation'),
      );
      expect(repo.managedCredentials.single.version, 1);
      expect(repo.credentialMaterials.single.bytes, utf8.encode(secret));
    },
  );

  test(
    'unknown committed result and same-target wrong-command receipt freeze the UI until exact result',
    () async {
      final vault = _Faults(
        service.owner,
        onChanged: (_) => throw StateError('synthetic lost response'),
      );
      final mutation = CredentialMutation(vault);
      final candidate = vault.staging.string(secret);
      final result = await mutation.submitCommand(
        (id) => write(id, candidate: candidate),
        vault.save,
      );
      expect(result, isNull);
      expect(mutation.uncertain, isTrue);
      expect(repo.managedCredentials, hasLength(1));
      vault.wrongDigest = true;
      expect(await mutation.reconcile(), isNull);
      expect(mutation.uncertain, isTrue);
      var called = false;
      await mutation.submitCommand((id) => write(id, candidate: candidate), (
        cmd,
      ) {
        called = true;
        return vault.save(cmd);
      });
      expect(called, isFalse);
      vault.wrongDigest = false;
      final recovered = await mutation.reconcile();
      expect(recovered!.ref.id, repo.managedCredentials.single.id);
      expect(mutation.uncertain, isFalse);
      expect(repo.managedCredentials, hasLength(1));
      mutation.dispose();
      vault.dispose();
    },
  );

  test(
    'unsubmitted unknown operation retains service material after form release until confirmed absence',
    () async {
      final vault = getVault();
      final candidate = vault.staging.string(secret);
      final db = inspect();
      try {
        db.execute(
          "CREATE TRIGGER reject_owner_credential BEFORE INSERT ON information_record_operations BEGIN SELECT RAISE(ABORT,'synthetic'); END",
        );
        await expectLater(
          vault.save(write('uncertain', candidate: candidate)),
          fails('unknown_outcome'),
        );
        await vault.releaseCandidate(candidate.id);
        final held = vault.staging.claim(candidate.id, 'uncertain');
        expect(held.bytes, utf8.encode(secret));
        expect(await vault.receipt('uncertain'), isNull);
        expect(held.bytes.every((v) => v == 0), isTrue);
        await expectLater(
          vault.save(write('another', candidate: candidate)),
          fails('selection_expired'),
        );
        expect(repo.managedCredentials, isEmpty);
        db.execute('DROP TRIGGER reject_owner_credential');
      } finally {
        db.close();
      }
    },
  );

  test(
    'pending staging cannot be reused by another operation and stale-library access clears owned buffers',
    () async {
      final vault = getVault();
      final candidate = vault.staging.string(secret);
      final held = vault.staging.claim(candidate.id, 'one');
      expect(
        () => vault.staging.claim(candidate.id, 'two'),
        throwsA(isA<WorkspaceFailure>()),
      );
      await service.owner.restoreLibrary(() async {});
      await expectLater(
        vault.save(write('one', candidate: candidate)),
        fails('library_changed'),
      );
      expect(held.bytes.every((v) => v == 0), isTrue);
      expect(repo.managedCredentials, isEmpty);
    },
  );

  test(
    'bounded staging accepts only valid owned material metadata and releases capacity on cancel',
    () async {
      final staging = getVault().staging;
      for (final value in ['', 'bad\u0000secret', '字' * 22000]) {
        expect(() => staging.string(value), throwsA(isA<WorkspaceFailure>()));
      }
      expect(
        () => staging.file(SelectedCredentialFile('../bad', [1])),
        throwsA(isA<WorkspaceFailure>()),
      );
      final values = [
        for (var i = 0; i < 16; i++) staging.string('SYNTHETIC-$i'),
      ];
      expect(() => staging.string(secret), throwsA(isA<WorkspaceFailure>()));
      await getVault().releaseCandidate(values.first.id);
      expect(staging.string(secret).id, isNotEmpty);
      expect(
        jsonEncode(values.map((v) => [v.id, v.label, v.filename]).toList()),
        isNot(contains(secret)),
      );
    },
  );

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 12; i++) {
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await t.pump(const Duration(milliseconds: 100));
    }
    await t.pumpAndSettle();
  }

  Future<void> closeWidget(WidgetTester t) async {
    // UI-originated Owner audit futures belong to the fake-clock zone, while
    // SQLCipher I/O completes on the real loop. Drive both until close finishes.
    var done = false;
    Object? failure;
    final closing = close().then(
      (_) {
        done = true;
      },
      onError: (Object error) {
        failure = error;
        done = true;
      },
    );
    for (var i = 0; i < 40 && !done; i++) {
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(
      done,
      isTrue,
      reason: 'Owner and repository shutdown must both complete',
    );
    await closing;
    if (failure != null) throw failure!;
  }

  Future<void> tap(WidgetTester t, Finder finder) async {
    await t.ensureVisible(finder);
    await t.pumpAndSettle();
    await t.tap(finder);
    await settle(t);
  }

  Future<void> capture(WidgetTester t, String name) async {
    if (evidence.isEmpty) return;
    await t.runAsync(() async {
      await Directory(evidence).create(recursive: true);
      final image = await t
          .renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('owner-credential-capture')),
          )
          .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$evidence/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets(
    'complete workspace opens real credential and replaces it using native secure editor boundary',
    (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        t.view.physicalSize = const Size(1440, 1000);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final c = (await t.runAsync(
          () => service.owner.createStringCredential(
            name: '合成既有凭据',
            publicPurpose: '实际用途',
            privateNote: '合成旧备注',
            secret: secret,
          ),
        ))!;
        final ref = WorkspaceRecordRef(WorkspaceRecordKind.credential, c.id);
        var nativeEdits = 0;
        const channel = MethodChannel('agent_info_manage/secret_editor');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'edit') {
                nativeEdits++;
                return 'SYNTHETIC-native-replacement';
              }
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );
        await t.pumpWidget(
          RepaintBoundary(
            key: const ValueKey('owner-credential-capture'),
            child: WorkspaceApp(
              source: source,
              windowTitle: '合成凭据接入检查',
              initialSelection: ref,
              inputsBuilder: (context) => WorkspaceInputs(
                credential: (form) =>
                    showOwnerCredentialInput(context, getVault().staging, form),
              ),
            ),
          ),
        );
        await settle(t);
        expect(find.text('合成旧备注', findRichText: true), findsOneWidget);
        await tap(t, find.byKey(const ValueKey('credential-replace')));
        await tap(t, find.byKey(const ValueKey('credential-edit-candidate')));
        await tap(t, find.text('填写'));
        expect(nativeEdits, 1);
        expect(find.text('SYNTHETIC-native-replacement'), findsNothing);
        await capture(t, 'secure-input');
        await tap(
          t,
          find.byKey(const ValueKey('owner-credential-input-complete')),
        );
        await capture(t, 'opaque-material-selected');
        await tap(t, find.byKey(const ValueKey('credential-edit-save')));
        expect(find.text('更换凭据材料'), findsNothing);
        expect(repo.managedCredentials.single.version, 2);
        expect(
          repo.credentialMaterials.last.bytes,
          utf8.encode('SYNTHETIC-native-replacement'),
        );
        await tap(t, find.byKey(const ValueKey('credential-advanced')));
        expect(find.textContaining('凭据版本 2'), findsOneWidget);
        expect(service.owner.credentialUseRequests, isEmpty);
        await capture(t, 'persisted-material-version');
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox.shrink());
        await closeWidget(t);
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'complete workspace creates a real file credential from Host input and reopens it',
    (t) async {
      t.view.physicalSize = const Size(1440, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final picker = _Files()
        ..result.complete(
          SelectedCredentialFile(
            'synthetic-new.bin',
            utf8.encode('SYNTHETIC-new-file'),
          ),
        );
      WorkspaceRecordRef? saved;
      try {
        final directory = (await t.runAsync(
          () => service.owner.createDirectory('合成凭据目录'),
        ))!;
        final tag = (await t.runAsync(
          () => service.owner.createTag('合成凭据标签'),
        ))!;
        await t.pumpWidget(
          RepaintBoundary(
            key: const ValueKey('owner-credential-capture'),
            child: WorkspaceApp(
              source: source,
              windowTitle: '合成凭据新建检查',
              initialQuery: WorkspaceQuery(directoryId: directory.id),
              inputsBuilder: (context) => WorkspaceInputs(
                credential: (form) => showOwnerCredentialInput(
                  context,
                  getVault().staging,
                  form,
                  files: picker,
                ),
              ),
            ),
          ),
        );
        await settle(t);
        await tap(t, find.byKey(const ValueKey('library-create')));
        await tap(t, find.byKey(const ValueKey('library-new-type-credential')));
        await tap(t, find.byKey(const ValueKey('credential-edit-candidate')));
        await tap(t, find.text('文件').last);
        await tap(t, find.byKey(const ValueKey('owner-credential-pick-file')));
        await tap(
          t,
          find.byKey(const ValueKey('owner-credential-input-complete')),
        );
        await t.enterText(
          find.byKey(const ValueKey('credential-edit-name')),
          '合成文件凭据',
        );
        await t.enterText(
          find.byKey(const ValueKey('credential-edit-note')),
          '文件合成备注',
        );
        // Returning from the native material input must retain the directory
        // advertised by the library's creation entry, without reselecting it.
        expect(find.text('合成凭据目录'), findsWidgets);
        await tap(t, find.text('合成凭据标签').last);
        await tap(
          t,
          find.byKey(const ValueKey('credential-edit-discoverable')),
        );
        await tap(t, find.byKey(const ValueKey('credential-edit-save')));
        expect(repo.managedCredentials, hasLength(1));
        expect(repo.managedCredentials.single.discoverable, isTrue);
        expect(repo.managedCredentials.single.directoryId, directory.id);
        expect(repo.managedCredentials.single.tagIds, [tag.id]);
        expect(service.agent.credentialCatalog().credentials, hasLength(1));
        saved = WorkspaceRecordRef(
          WorkspaceRecordKind.credential,
          repo.managedCredentials.single.id,
        );
        expect(
          repo.credentialMaterials.single.bytes,
          utf8.encode('SYNTHETIC-new-file'),
        );
        expect(find.text('文件合成备注', findRichText: true), findsOneWidget);
        await capture(t, 'created-file-credential');
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox.shrink());
        await closeWidget(t);
      }
      await t.runAsync(open);
      final reopened = await t.runAsync(() => getVault().read(saved!));
      expect(reopened!.filename, 'synthetic-new.bin');
      expect(reopened.privateNote, '文件合成备注');
      expect(reopened.record.tags.single.name, '合成凭据标签');
      expect(reopened.record.directoryId, isNotNull);
      await closeWidget(t);
    },
  );

  testWidgets(
    'closing Host file input before late picker result never creates staged or saved material',
    (t) async {
      try {
        final picker = _Files();
        Future<WorkspaceCredentialCandidate?>? result;
        await t.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () {
                    result = showOwnerCredentialInput(
                      context,
                      getVault().staging,
                      WorkspaceCredentialForm.file,
                      files: picker,
                    );
                  },
                  child: const Text('Open input'),
                ),
              ),
            ),
          ),
        );
        await tap(t, find.text('Open input'));
        await t.tap(find.byKey(const ValueKey('owner-credential-pick-file')));
        await t.pump();
        await t.tap(
          find.byKey(const ValueKey('owner-credential-input-cancel')),
        );
        await settle(t);
        picker.result.complete(
          SelectedCredentialFile('synthetic-late.bin', [1, 2]),
        );
        await settle(t);
        expect(await result, isNull);
        expect(repo.managedCredentials, isEmpty);
        final entries = [
          for (var i = 0; i < 16; i++)
            getVault().staging.string('SYNTHETIC-$i'),
        ];
        expect(entries, hasLength(16));
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox.shrink());
        await closeWidget(t);
      }
    },
  );

  testWidgets(
    'real workspace material restore and recycle restore/purge use durable lifecycle source',
    (t) async {
      t.view.physicalSize = const Size(1440, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      try {
        final vault = getVault();
        final ref = (await t.runAsync(() async {
          final first = await vault.save(
            write('seed', candidate: vault.staging.string(secret)),
          );
          final detail = await vault.read(first.ref);
          await vault.save(
            write(
              'replace',
              detail: detail,
              candidate: vault.staging.string('SYNTHETIC-second'),
            ),
          );
          return first;
        }))!.ref;
        await t.pumpWidget(
          WorkspaceApp(
            source: source,
            windowTitle: '合成凭据生命周期',
            initialSelection: ref,
          ),
        );
        await settle(t);
        await tap(t, find.byKey(const ValueKey('library-record-actions')));
        await tap(t, find.text('材料版本').last);
        await tap(t, find.byKey(const ValueKey('credential-material-1')));
        await tap(t, find.byKey(const ValueKey('credential-material-restore')));
        expect(
          find.byKey(const ValueKey('credential-material-confirm')),
          findsOneWidget,
        );
        expect(find.text(secret), findsNothing);
        await tap(t, find.byKey(const ValueKey('credential-material-restore')));
        expect(repo.managedCredentials.single.version, 3);
        expect(repo.managedCredentials.single.enabled, isFalse);
        expect(repo.credentialMaterials.last.bytes, utf8.encode(secret));
        await tap(t, find.byKey(const ValueKey('library-record-actions')));
        await tap(t, find.text('移到回收站').last);
        await tap(t, find.byKey(const ValueKey('credential-recycle-submit')));
        expect(service.owner.credentials, isEmpty);
        await tap(t, find.byKey(const ValueKey('library-open-recycle')));
        expect(find.text('查看与恢复'), findsOneWidget);
        await tap(t, find.text('查看与恢复'));
        expect(find.text('恢复凭据'), findsOneWidget);
        await tap(t, find.byKey(const ValueKey('credential-recycle-submit')));
        expect(repo.managedCredentials.single.version, 4);
        expect(repo.managedCredentials.single.enabled, isFalse);
        // Return through the real parent so the restored credential can be managed.
        await tap(t, find.byKey(const ValueKey('library-recycle-back')));
        await settle(t);
        await tap(t, find.byKey(const ValueKey('library-record-actions')));
        await tap(t, find.text('移到回收站').last);
        await tap(t, find.byKey(const ValueKey('credential-recycle-submit')));
        await tap(t, find.byKey(const ValueKey('library-open-recycle')));
        await tap(t, find.text('查看与恢复'));
        await tap(t, find.byKey(const ValueKey('credential-recycle-purge')));
        expect(repo.credentialMaterials, isNotEmpty);
        await tap(t, find.byKey(const ValueKey('credential-recycle-submit')));
        expect(repo.credentialMaterials, isEmpty);
        expect(repo.managedCredentials.single.privateNote, isEmpty);
        expect(service.owner.recycledCredentials, isEmpty);
        expect(service.owner.credentialUseRequests, isEmpty);
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox.shrink());
        await closeWidget(t);
      }
    },
  );
}
